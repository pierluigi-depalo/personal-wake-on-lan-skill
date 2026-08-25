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

  [Parameter(Mandatory)] [string]$AlexaClientId,
  [Parameter(Mandatory)] [string]$AlexaClientSecret,
  [string]$DevicesJson = "",
  [string]$SingleMacAddress = "",
  [string]$EndpointId = "wol-pc-001",
  [string]$FriendlyName = "PC",
  [Parameter(Mandatory)] [string]$PcSecretsJson,
  [string]$DynamoTableName = "AlexaEventTokens",
  # Empty = derived from Region below.
  [string]$EventGatewayUrl = "",
  [string]$DeviceStaleMs = "",
  [string]$PagesOrigin = "https://pierluigi-depalo.github.io",
  [ValidateSet("true", "false")]
  [string]$CreateNewTable = "true",

  # Standalone mode: where to fetch template + handlers from.
  [string]$RawBase = "https://raw.githubusercontent.com/pierluigi-depalo/personal-wake-on-lan-skill/main",

  [switch]$SkipCodeUpload
)

$ErrorActionPreference = 'Stop'
function Write-Step([string]$m) { Write-Host "==> $m" }
function Write-Ok([string]$m)   { Write-Host "    OK  $m" -ForegroundColor Green }
function Write-Warn2([string]$m){ Write-Host "    !!  $m" -ForegroundColor Yellow }

# EU endpoint is the code default; other regions MUST override it.
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
  Write-Step "fetching template from $RawBase"
  $templateFile = Join-Path ([IO.Path]::GetTempPath()) 'wol-stack.template.json'
  Invoke-WebRequest "$RawBase/docs/installer/wol-stack.template.json" -OutFile $templateFile -UseBasicParsing
}
if ($standalone) {
  Write-Step "standalone run - fetching handlers from $RawBase"
  $tmpSrc = New-Item -ItemType Directory -Force -Path (Join-Path ([IO.Path]::GetTempPath()) "wol-src-$([guid]::NewGuid().ToString('N').Substring(0,8))")
  $srcIndex  = Join-Path $tmpSrc 'index.js'
  $srcBridge = Join-Path $tmpSrc 'bridge.js'
  Invoke-WebRequest "$RawBase/src/index.js"  -OutFile $srcIndex  -UseBasicParsing
  Invoke-WebRequest "$RawBase/src/bridge.js" -OutFile $srcBridge -UseBasicParsing
}

Write-Step "checking AWS CLI"
if (-not (Get-Command aws -ErrorAction SilentlyContinue)) { throw "AWS CLI v2 not found - install it and run 'aws configure'." }
aws sts get-caller-identity --output text --query Account 1>$null
if ($LASTEXITCODE -ne 0) { throw "AWS credentials not usable - run 'aws configure' or set a profile." }
Write-Ok "credentials OK"

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
