<#
.SYNOPSIS
  deploy-aws.ps1 - one-command AWS deployment for the Wake-on-LAN skill.

  Creates/updates the CloudFormation stack (docs/installer/wol-stack.template.json)
  and uploads the real handler code from src/ to both Lambdas (the stack creates
  placeholders because inline CFN code is capped at 4KB).

  Works from a repo checkout OR standalone: when src/index.js is not found next
  to this script the sources are downloaded from GitHub.

.EXAMPLE
  .\deploy-aws.ps1 -Region eu-west-1 `
      -AlexaClientId "amzn1.application-oa2-client.xxxx" -AlexaClientSecret "yyyy" `
      -DevicesJson '[{"endpointId":"wol-pc-001","friendlyName":"Office PC","macAddress":"AA:BB:CC:DD:EE:FF"}]' `
      -PcSecretsJson '{"wol-pc-001":"long-random-secret"}'
#>
[CmdletBinding()]
param(
  [string]$StackName = "wol-stack",
  [ValidateSet("us-east-1", "us-west-2", "eu-west-1", "ap-northeast-1")]
  [string]$Region = "eu-west-1",

  # Incremental mode: add one or more devices to an EXISTING deployment
  # (updates WOL_DEVICES + PC_SECRETS in place, no stack changes).
  # Each entry, repeatable:
  #   'endpointId|FriendlyName|MAC'  full control
  #   'endpointId|MAC'               friendly name defaults to endpointId
  #   'endpointId|FriendlyName'      MAC auto-detected from this machine
  #   'endpointId'                   both defaults applied
  # Auto-detection picks this machine's wired Ethernet adapter - run the
  # command ON the target PC, or pass the MAC explicitly for remote adds:
  #   -AddDevice 'gaming-rig|Gaming Rig','laptop|AA:BB:CC:DD:EE:FF'
  [string[]]$AddDevice = @(),

  [string]$AlexaClientId = "",
  [string]$AlexaClientSecret = "",
  [string]$DevicesJson = "",
  [string]$SingleMacAddress = "",
  [string]$EndpointId = "wol-pc-001",
  [string]$FriendlyName = "PC",
  [string]$PcSecretsJson = "",
  [string]$DynamoTableName = "AlexaEventTokens",
  # Empty = derived from Region below.
  [string]$EventGatewayUrl = "",
  [string]$DeviceStaleMs = "",
  [string]$PagesOrigin = "https://pierluigi-depalo.github.io",
  [ValidateSet("true", "false")]
  [string]$CreateNewTable = "true",

  # Standalone mode: where to fetch template + handlers from.
  [string]$RawBase = "https://raw.githubusercontent.com/pierluigi-depalo/personal-wake-on-lan-skill/main",

  # Proceed even when conflicting resources (old manual setup) are detected.
  [switch]$Force,

  [switch]$SkipCodeUpload
)

$ErrorActionPreference = 'Stop'
function Write-Step([string]$m) { Write-Host "==> $m" }
function Write-Ok([string]$m)   { Write-Host "    OK  $m" -ForegroundColor Green }
function Write-Warn2([string]$m){ Write-Host "    !!  $m" -ForegroundColor Yellow }

$script:RawSourceBase = "https://raw.githubusercontent.com/pierluigi-depalo/personal-wake-on-lan-skill/main"

function New-RandomSecret {
  $bytes = New-Object byte[] 32
  ([Security.Cryptography.RandomNumberGenerator]::Create()).GetBytes($bytes)
  return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-LambdaEnvHashtable([string]$fnName) {
  $cfg = aws lambda get-function-configuration --function-name $fnName --region $Region --output json |
    ConvertFrom-Json
  if ($cfg.LastUpdateStatus -eq 'InProgress') { throw "'$fnName' is mid-update - retry in a moment." }
  $vars = @{}
  if ($cfg.Environment -and $cfg.Environment.Variables) {
    foreach ($p in $cfg.Environment.Variables.PSObject.Properties) { $vars[$p.Name] = $p.Value }
  }
  return $vars
}

function Update-LambdaEnv([string]$fnName, [hashtable]$vars) {
  $payloadFile = Join-Path ([IO.Path]::GetTempPath()) ("env-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + ".json")
  @{ Variables = $vars } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $payloadFile -Encoding UTF8
  aws lambda update-function-configuration --function-name $fnName --region $Region `
    --environment "file://$($payloadFile -replace '\\', '/')" | Out-Null
  Remove-Item -LiteralPath $payloadFile -Force
  for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 1
    $status = aws lambda get-function-configuration --function-name $fnName --region $Region `
      --output text --query LastUpdateStatus
    if ($status -eq 'Successful') { return }
    if ($status -in @('Failed', 'Incompatible')) { throw "$fnName update failed: $status" }
  }
  throw "$fnName update did not settle in time"
}

# --- incremental add-device mode -------------------------------------------------
function Get-LocalWiredMac {
  $nic = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
    Where-Object { $_.MediaType -eq '802.3' } |
    Sort-Object { [int]($_.Status -ne 'Up') } |
    Select-Object -First 1
  if (-not $nic) {
    throw "no wired Ethernet adapter found on this machine - pass the MAC explicitly."
  }
  Write-Warn2 "auto-detected MAC $($nic.MacAddress) from '$($nic.Name)' [$($nic.Status)]"
  return ($nic.MacAddress -replace '-', ':').ToUpper()
}

function Resolve-MacOrAuto([string]$value) {
  $v = $value.Trim()
  if ($v -eq '' -or $v -ieq 'auto') { return Get-LocalWiredMac }
  $hex = ($v -replace '[^0-9a-fA-F]', '').ToUpper()
  if ($hex.Length -ne 12) { throw "'$v' does not look like AA:BB:CC:DD:EE:FF" }
  return (($hex -replace '..', '$&:').TrimEnd(':'))
}

if ($AddDevice.Count -gt 0) {

  $devices = foreach ($entry in $AddDevice) {
    $parts = $entry -split '\|'
    if ($parts.Count -lt 1 -or $parts.Count -gt 3) {
      throw "bad -AddDevice entry '$entry' - expected 'endpointId|FriendlyName|MAC' (see header for the short forms)"
    }
    $id = $parts[0].Trim()
    if ($id -notmatch '^[a-z0-9][a-z0-9-]{1,62}$') { throw "endpoint id '$id' must be a short slug." }
    $macToken = ''
    $name = ''
    switch ($parts.Count) {
      1 { $macToken = 'auto' }
      2 {
        if ($parts[1].Trim() -match '^[0-9A-Fa-f]{2}([:-]?[0-9A-Fa-f]{2}){5}$') { $macToken = $parts[1] }
        else { $name = $parts[1].Trim(); $macToken = 'auto' }
      }
      3 { $name = $parts[1].Trim(); $macToken = $parts[2] }
    }
    [pscustomobject]@{
      EndpointId   = $id
      FriendlyName = $(if ($name) { $name } else { $id })
      Mac          = Resolve-MacOrAuto $macToken
      Secret       = New-RandomSecret
    }
  }
  $dups = @($devices | Group-Object EndpointId | Where-Object Count -gt 1)
  if ($dups.Count -gt 0) { throw "duplicate endpoint id '$($dups[0].Name)'." }

  # Resolve function names / bridge URL from stack outputs, with fallbacks.
  $outputs = @{}
  $stackJson = aws cloudformation describe-stacks --stack-name $StackName --region $Region `
    --output json 2>$null | ConvertFrom-Json
  if ($LASTEXITCODE -eq 0) {
    foreach ($o in $stackJson.Stacks[0].Outputs) { $outputs[$o.OutputKey] = $o.OutputValue }
  }
  $skillFn  = if ($outputs['SkillFunctionName'])  { $outputs['SkillFunctionName'] }  else { 'alexa-wake-on-lan' }
  $bridgeFn = if ($outputs['BridgeFunctionName']) { $outputs['BridgeFunctionName'] } else { 'wol-bridge' }
  $bridgeUrl = $outputs['BridgeFunctionUrl']
  if (-not $bridgeUrl) {
    $bridgeUrl = aws lambda get-function-url-config --function-name $bridgeFn --region $Region `
      --output text --query FunctionUrl 2>$null
  }

  # Skill Lambda: merge all new entries into WOL_DEVICES.
  Write-Step "updating skill Lambda '$skillFn'"
  $skillVars = Get-LambdaEnvHashtable $skillFn
  $existing = @()
  if ($skillVars['WOL_DEVICES']) {
    try { $existing = @(ConvertFrom-Json $skillVars['WOL_DEVICES']) } catch {
      throw "WOL_DEVICES on '$skillFn' is not valid JSON."
    }
  } elseif ($skillVars['MAC_ADDRESS']) {
    Write-Warn2 "single-device mode detected - migrating to WOL_DEVICES"
    $existing = @([pscustomobject]@{
      endpointId   = $(if ($skillVars['ENDPOINT_ID']) { $skillVars['ENDPOINT_ID'] } else { 'wol-pc-001' })
      friendlyName = $(if ($skillVars['PC_FRIENDLY_NAME']) { $skillVars['PC_FRIENDLY_NAME'] } else { 'PC' })
      macAddress   = $skillVars['MAC_ADDRESS']
    })
    foreach ($k in @('MAC_ADDRESS', 'ENDPOINT_ID', 'PC_FRIENDLY_NAME')) { $skillVars.Remove($k) | Out-Null }
  }
  foreach ($new in $devices) {
    if ($existing | Where-Object { $_.endpointId -eq $new.EndpointId }) {
      throw "device '$($new.EndpointId)' already exists on '$skillFn'."
    }
    $existing += [pscustomobject]@{ endpointId = $new.EndpointId; friendlyName = $new.FriendlyName; macAddress = $new.Mac }
  }
  # NOTE: -InputObject keeps a single-element array from being flattened.
  $skillVars['WOL_DEVICES'] = ConvertTo-Json -Compress -InputObject @($existing)
  Update-LambdaEnv $skillFn $skillVars
  Write-Ok "WOL_DEVICES now lists $($existing.Count) device(s)"

  # Bridge Lambda: merge secrets into PC_SECRETS.
  Write-Step "updating bridge Lambda '$bridgeFn'"
  $bridgeVars = Get-LambdaEnvHashtable $bridgeFn
  $secrets = @{}
  if ($bridgeVars['PC_SECRETS']) {
    try {
      $secretsObj = $bridgeVars['PC_SECRETS'] | ConvertFrom-Json
      foreach ($p in $secretsObj.PSObject.Properties) { $secrets[$p.Name] = $p.Value }
    } catch { throw "PC_SECRETS on '$bridgeFn' is not valid JSON." }
  }
  foreach ($new in $devices) { $secrets[$new.EndpointId] = $new.Secret }
  $bridgeVars['PC_SECRETS'] = ConvertTo-Json -Compress -InputObject $secrets
  Update-LambdaEnv $bridgeFn $bridgeVars
  Write-Ok "PC_SECRETS now holds $($secrets.Count) secret(s)"

  $urlForCmd = if ($bridgeUrl) { $bridgeUrl } else { '<BRIDGE_URL>' }
  Write-Host ""
  Write-Host "================ DEVICES ADDED ================" -ForegroundColor Cyan
  foreach ($d in $devices) {
    Write-Host ""
    Write-Host "endpointId : $($d.EndpointId)"
    Write-Host "secret     : $($d.Secret)"
    Write-Host "# Windows (elevated PowerShell):"
    Write-Host "iwr $RawSourceBase/scripts/install-agent.ps1 -OutFile `$env:TEMP\wol-install.ps1; powershell -NoProfile -ExecutionPolicy Bypass -File `"`$env:TEMP\wol-install.ps1`" -Install -DeviceId '$($d.EndpointId)' -ApiUrl '$urlForCmd' -Secret '$($d.Secret)'"
    Write-Host "# Linux:"
    Write-Host "curl -fsSL $RawSourceBase/scripts/install-agent.sh | sudo env DEVICE_ID='$($d.EndpointId)' API_URL='$urlForCmd' SECRET='$($d.Secret)' bash -s -- install"
  }
  Write-Host ""
  Write-Warn2 "If you later re-run a full CloudFormation deploy, pass the FULL device list"
  Write-Warn2 "(use -AddDevice for future additions instead of stack updates)."
  Write-Host "===============================================" -ForegroundColor Cyan
  exit 0
}

# EU endpoint is the code default; other regions MUST override it.
if ($AddDevice.Count -eq 0) {
  foreach ($p in 'AlexaClientId', 'AlexaClientSecret', 'PcSecretsJson') {
    if (-not $PSBoundParameters.ContainsKey($p)) {
      throw "$p is required for a full deployment (or use -AddDevice for incremental mode)."
    }
  }
}
if (-not $EventGatewayUrl) {
  $EventGatewayUrl = switch ($Region) {
    "us-east-1"       { "https://api.amazonalexa.com/v3/events" }
    "us-west-2"       { "https://api.amazonalexa.com/v3/events" }
    "ap-northeast-1"  { "https://api.fe.amazonalexa.com/v3/events" }
    default           { "" }
  }
}

$here = $PSScriptRoot
$templateFile = Join-Path $here '..\docs\installer\wol-stack.template.json'
$srcIndex     = Join-Path $here '..\src\index.js'
$srcBridge    = Join-Path $here '..\src\bridge.js'

$standalone = -not (Test-Path $srcIndex)
if (-not (Test-Path $templateFile)) {
  Write-Step "fetching template from $RawSourceBase"
  $templateFile = Join-Path ([IO.Path]::GetTempPath()) 'wol-stack.template.json'
  Invoke-WebRequest "$RawSourceBase/docs/installer/wol-stack.template.json" -OutFile $templateFile -UseBasicParsing
}
if ($standalone) {
  Write-Step "standalone run - fetching handlers from $RawSourceBase"
  $tmpSrc = New-Item -ItemType Directory -Force -Path (Join-Path ([IO.Path]::GetTempPath()) "wol-src-$([guid]::NewGuid().ToString('N').Substring(0,8))")
  $srcIndex  = Join-Path $tmpSrc 'index.js'
  $srcBridge = Join-Path $tmpSrc 'bridge.js'
  Invoke-WebRequest "$RawSourceBase/src/index.js"  -OutFile $srcIndex  -UseBasicParsing
  Invoke-WebRequest "$RawSourceBase/src/bridge.js" -OutFile $srcBridge -UseBasicParsing
}

Write-Step "checking AWS CLI"
if (-not (Get-Command aws -ErrorAction SilentlyContinue)) { throw "AWS CLI v2 not found - install it and run 'aws configure'." }
aws sts get-caller-identity --output text --query Account 1>$null
if ($LASTEXITCODE -ne 0) { throw "AWS credentials not usable - run 'aws configure' or set a profile." }
Write-Ok "credentials OK"

# Pre-flight: leftovers from a previous/manual deployment make CREATE fail.
Write-Step "checking for conflicting resources"
if ($CreateNewTable -eq 'true') {
  aws dynamodb describe-table --table-name $DynamoTableName --region $Region 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) {
    $msg = "table '$DynamoTableName' already exists - run scripts\remove-aws.ps1 -DeleteTable first, or redeploy with -CreateNewTable false"
    if ($Force) { Write-Warn2 $msg } else { throw $msg }
  }
}
foreach ($fnName in @('alexa-wake-on-lan', 'wol-bridge')) {
  aws lambda get-function --function-name $fnName --region $Region 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) {
    $msg = "Lambda '$fnName' already exists (outside the stack?) - run scripts\remove-aws.ps1 first, or retry with -Force"
    if ($Force) { Write-Warn2 $msg } else { throw $msg }
  }
}
Write-Ok "no conflicts"

function New-LambdaZip([string]$HandlerPath, [string]$ZipPath) {
  $stage = Join-Path ([IO.Path]::GetTempPath()) ("wol-zip-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Force -Path $stage | Out-Null
  Copy-Item $HandlerPath (Join-Path $stage ([IO.Path]::GetFileName($HandlerPath)))
  # Both handlers are ESM ('import ...') - mark the package as a module.
  Set-Content -LiteralPath (Join-Path $stage 'package.json') -Value '{"type":"module"}' -Encoding ASCII
  if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }
  Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $ZipPath -CompressionLevel Optimal
  Remove-Item $stage -Recurse -Force
}

Write-Step "packaging handler zips"
$work = New-Item -ItemType Directory -Force -Path (Join-Path ([IO.Path]::GetTempPath()) "wol-deploy-$([guid]::NewGuid().ToString('N').Substring(0,8))")
$skillZip  = Join-Path $work 'skill.zip'
$bridgeZip = Join-Path $work 'bridge.zip'
New-LambdaZip $srcIndex  $skillZip
New-LambdaZip $srcBridge $bridgeZip
Write-Ok "skill.zip / bridge.zip ready"

$overrides = @(
  "AlexaClientId=$AlexaClientId",
  "AlexaClientSecret=$AlexaClientSecret",
  "EndpointId=$EndpointId",
  "FriendlyName=$FriendlyName",
  "PcSecretsJson=$PcSecretsJson",
  "DynamoTableName=$DynamoTableName",
  "PagesOrigin=$PagesOrigin",
  "CreateNewTable=$CreateNewTable"
)
if ($DevicesJson)      { $overrides += "DevicesJson=$DevicesJson" }
if ($SingleMacAddress) { $overrides += "SingleMacAddress=$SingleMacAddress" }
if ($EventGatewayUrl)  { $overrides += "EventGatewayUrl=$EventGatewayUrl" }
if ($DeviceStaleMs)    { $overrides += "DeviceStaleMs=$DeviceStaleMs" }

if ((Get-Content $templateFile -Raw) -match '"\$schema"') {
  $cleanFile = Join-Path $work "wol-stack.clean.json"
  $tmpl = Get-Content $templateFile -Raw | ConvertFrom-Json
  $tmpl.PSObject.Properties.Remove('$schema')
  # ensure format version is set for CFN
  if (-not $tmpl.PSObject.Properties['AWSTemplateFormatVersion']) {
    $tmpl | Add-Member -NotePropertyName AWSTemplateFormatVersion -NotePropertyValue "2010-09-09"
  }
  $tmpl | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $cleanFile -Encoding UTF8
  $templateFile = $cleanFile
}
Write-Step "deploying stack '$StackName' to $Region"
aws cloudformation deploy `
  --stack-name $StackName `
  --template-file $templateFile `
  --region $Region `
  --capabilities CAPABILITY_NAMED_IAM `
  --no-fail-on-empty-changeset `
  --parameter-overrides @overrides
if ($LASTEXITCODE -ne 0) { throw "CloudFormation deploy failed." }

Write-Step "reading stack outputs"
$out = aws cloudformation describe-stacks --stack-name $StackName --region $Region `
  --output json | ConvertFrom-Json
$outputs = @{}
foreach ($o in $out.Stacks[0].Outputs) { $outputs[$o.OutputKey] = $o.OutputValue }
$skillFn  = $outputs['SkillFunctionName']
$bridgeFn = $outputs['BridgeFunctionName']
$bridgeUrl = $outputs['BridgeFunctionUrl']

if (-not $SkipCodeUpload) {
  Write-Step "uploading real handler code"
  aws lambda update-function-code --function-name $skillFn  --region $Region --zip-file "fileb://$skillZip"  --output text --query LastUpdateStatus
  if ($LASTEXITCODE -ne 0) { throw "code upload failed for $skillFn" }
  aws lambda update-function-code --function-name $bridgeFn --region $Region --zip-file "fileb://$bridgeZip" --output text --query LastUpdateStatus
  if ($LASTEXITCODE -ne 0) { throw "code upload failed for $bridgeFn" }
  Write-Ok "handlers deployed"
}

Remove-Item $work -Recurse -Force

Write-Host ""
Write-Host "================ DEPLOYMENT COMPLETE ================" -ForegroundColor Cyan
Write-Host "Skill Lambda : $skillFn"
Write-Host "Skill ARN    : $($outputs['SkillFunctionArn'])"
Write-Host "Bridge Lambda: $bridgeFn"
Write-Host "Bridge URL   : $bridgeUrl"
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Alexa console -> skill endpoint = Skill ARN above"
Write-Host "  2. PC agent install (Windows):"
Write-Host "     irm https://raw.githubusercontent.com/pierluigi-depalo/personal-wake-on-lan-skill/main/scripts/install-agent.ps1 -OutFile `$env:TEMP\install-agent.ps1"
Write-Host "     powershell -ExecutionPolicy Bypass -File `$env:TEMP\install-agent.ps1 -Install -DeviceId <id> -ApiUrl `"$bridgeUrl`" -Secret <secret>"
Write-Host "======================================================" -ForegroundColor Cyan
