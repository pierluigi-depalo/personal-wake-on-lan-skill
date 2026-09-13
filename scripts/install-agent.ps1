<#
.SYNOPSIS
  install-agent.ps1 - installs, updates, removes and inspects the wol-agent
  Windows scheduled task. Replaces the manual Task Scheduler steps from
  scripts/README.md.

.PARAMETER Install
  Copy wol-agent.ps1 into InstallDir, save the config and register the task.
  Requires -DeviceId, -ApiUrl and -Secret (or an existing saved config).

.PARAMETER Repair
  Re-register the task from the saved config (after changing GraceSeconds etc.).

.PARAMETER Uninstall
  Stop and delete the task. Add -Purge to also delete the installed files.

.PARAMETER Status
  Show task state and (with -Live) do one poll against the bridge.

.PARAMETER TestConnection
  One-off poll against the bridge without touching the installation.

.EXAMPLE
  .\install-agent.ps1 -Install -DeviceId wol-pc-001 `
      -ApiUrl "https://abc123.lambda-url.eu-west-1.on.aws/" -Secret "REPLACE_ME"

.EXAMPLE
  .\install-agent.ps1 -TestConnection -DeviceId wol-pc-001 -ApiUrl "https://..." -Secret "..."

.EXAMPLE
  .\install-agent.ps1 -Uninstall -Purge
#>
[CmdletBinding(DefaultParameterSetName = 'Status')]
param(
  [Parameter(ParameterSetName = 'Install')] [switch]$Install,
  [Parameter(ParameterSetName = 'Repair')]  [switch]$Repair,
  [Parameter(ParameterSetName = 'Remove')]  [switch]$Uninstall,
  [Parameter(ParameterSetName = 'Test')]    [switch]$TestConnection,
  [Parameter(ParameterSetName = 'Status')]  [switch]$Status,

  [string]$DeviceId,
  [string]$ApiUrl,
  [string]$Secret,
  [ValidateRange(0, 3600)]
  [int]$GraceSeconds = 10,
  [string]$InstallDir = "$env:ProgramData\wol-agent",
  [string]$TaskName = "wol-agent",
  # Used to fetch wol-agent.ps1 when it is not next to this script.
  [string]$AgentSourceUrl = "https://raw.githubusercontent.com/pierluigi-depalo/personal-wake-on-lan-skill/main/scripts/wol-agent.ps1",
  [switch]$FixFastStartup,
  [switch]$SkipPreflight,
  [switch]$RegisterAws,
  [switch]$Purge,
  [switch]$Live
)

$ErrorActionPreference = 'Stop'
$configPath = Join-Path $InstallDir 'agent-config.json'

function Write-Step([string]$msg)  { Write-Host "==> $msg" }
function Write-Ok([string]$msg)    { Write-Host "    OK  $msg" -ForegroundColor Green }
function Write-Warn2([string]$msg) { Write-Host "    !!  $msg" -ForegroundColor Yellow }
function Write-Fail([string]$msg)  { Write-Host "    XX  $msg" -ForegroundColor Red }

function Assert-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Administrator rights are required. Re-run from an elevated PowerShell."
  }
}

function Get-Config {
  if (Test-Path -LiteralPath $configPath) {
    return Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
  }
  return $null
}

function Save-Config($cfg) {
  New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
  $json = $cfg | ConvertTo-Json
  # Only Administrators/SYSTEM should read the shared secret.
  Set-Content -LiteralPath $configPath -Value $json -Encoding UTF8
  icacls $configPath /inheritance:r /grant:r "SYSTEM:F" "Administrators:F" | Out-Null
}

function New-RandomSecret {
  $bytes = New-Object byte[] 32
  ([Security.Cryptography.RandomNumberGenerator]::Create()).GetBytes($bytes)
  return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Register-AwsDevice([string]$deviceId, [string]$secret, [string]$apiUrl) {
  if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
    Write-Warn2 "AWS CLI not found on PATH - cannot register device in AWS automatically."
    return $false
  }
  aws sts get-caller-identity --output text --query Account 1>$null 2>$null
  if ($LASTEXITCODE -ne 0) {
    Write-Warn2 "AWS credentials not configured or expired - cannot register device in AWS automatically."
    return $false
  }
  $reg = "eu-west-1"
  if ($apiUrl -match 'lambda-url\.([a-z0-9-]+)\.on\.aws') {
    $reg = $Matches[1]
  }
  Write-Step "registering device '$deviceId' in wol-bridge Lambda (region $reg)"
  try {
    $cfg = aws lambda get-function-configuration --function-name "wol-bridge" --region $reg --output json 2>$null | ConvertFrom-Json
    if (-not $cfg) {
      Write-Warn2 "could not find 'wol-bridge' Lambda in region $reg"
      return $false
    }
    $vars = @{}
    if ($cfg.Environment -and $cfg.Environment.Variables) {
      foreach ($p in $cfg.Environment.Variables.PSObject.Properties) { $vars[$p.Name] = $p.Value }
    }
    $secrets = @{}
    if ($vars['PC_SECRETS']) {
      try {
        $sObj = $vars['PC_SECRETS'] | ConvertFrom-Json
        foreach ($p in $sObj.PSObject.Properties) { $secrets[$p.Name] = $p.Value }
      } catch {}
    }
    $secrets[$deviceId] = $secret
    $vars['PC_SECRETS'] = ConvertTo-Json -Compress -InputObject $secrets
    $payloadFile = Join-Path ([IO.Path]::GetTempPath()) ("env-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + ".json")
    @{ Variables = $vars } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $payloadFile -Encoding UTF8
    aws lambda update-function-configuration --function-name "wol-bridge" --region $reg `
      --environment "file://$($payloadFile -replace '\\', '/')" 1>$null 2>$null
    Remove-Item -LiteralPath $payloadFile -Force -ErrorAction SilentlyContinue
    Write-Ok "registered secret in wol-bridge on AWS"
    return $true
  } catch {
    Write-Warn2 "failed to update wol-bridge: $($_.Exception.Message)"
    return $false
  }
}

function Resolve-ConfigValues {
  $cfg = Get-Config
  # NOTE: plain '$x = if ...' is not valid in PowerShell 5.1 - wrap in $().
  $deviceId = $(if ($DeviceId) { $DeviceId } elseif ($cfg) { $cfg.deviceId } else { $null })
  $apiUrl   = $(if ($ApiUrl)   { $ApiUrl }   elseif ($cfg) { $cfg.apiUrl }   else { $null })
  $secret   = $(if ($Secret)   { $Secret }   elseif ($cfg) { $cfg.secret }   else { $null })
  $grace    = $(if ($PSBoundParameters.ContainsKey('GraceSeconds')) { $GraceSeconds } elseif ($cfg) { [int]$cfg.graceSeconds } else { 10 })

  if (-not $deviceId) {
    if ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
      $inputDev = Read-Host "Device ID (must match WOL_DEVICES on the skill) [wol-pc-001]"
      $deviceId = $(if ($inputDev -and $inputDev.Trim()) { $inputDev.Trim() } else { "wol-pc-001" })
    } else {
      $deviceId = "wol-pc-001"
    }
  }

  if (-not $apiUrl) {
    if ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
      $inputUrl = Read-Host "Bridge Function URL"
      $apiUrl = $(if ($inputUrl -and $inputUrl.Trim()) { $inputUrl.Trim() } else { $null })
    }
    if (-not $apiUrl) { throw "ApiUrl is required (pass it or install first)." }
  }

  $isAdHoc = $false
  if (-not $secret) {
    if ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
      $inputSec = Read-Host "Device secret (leave empty to generate ad-hoc)"
      if ($inputSec -and $inputSec.Trim()) {
        $secret = $inputSec.Trim()
      }
    }
    if (-not $secret) {
      $secret = New-RandomSecret
      $isAdHoc = $true
    }
  }

  [pscustomobject]@{ DeviceId = $deviceId; ApiUrl = $apiUrl; Secret = $secret; GraceSeconds = $grace; IsAdHoc = $isAdHoc }
}

function Get-AgentScript {
  param([string]$Destination)
  $local = Join-Path $PSScriptRoot 'wol-agent.ps1'
  if (Test-Path -LiteralPath $local) {
    Copy-Item -LiteralPath $local -Destination $Destination -Force
    Write-Ok "agent copied from $local"
    return
  }
  $installed = Join-Path $InstallDir 'wol-agent.ps1'
  if (Test-Path -LiteralPath $installed) {
    Write-Ok "keeping installed agent at $installed"
    return
  }
  Write-Step "downloading agent from $AgentSourceUrl"
  Invoke-WebRequest -Uri $AgentSourceUrl -OutFile $Destination -UseBasicParsing
  Write-Ok "agent downloaded"
}

function Invoke-Poll {
  param([string]$State)
  $v = Resolve-ConfigValues
  try {
    $body = @{ powerState = $State } | ConvertTo-Json -Compress
    $resp = Invoke-RestMethod -Method Post -Uri "$($v.ApiUrl)?deviceId=$($v.DeviceId)" `
      -Headers @{ "x-pc-secret" = $v.Secret } -ContentType "application/json" `
      -Body $body -TimeoutSec 15
    return $resp.action
  } catch {
    Write-Fail "poll failed: $($_.Exception.Message)"
    return $null
  }
}

function Test-FastStartup {
  $p = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' `
        -Name HiberbootEnabled -ErrorAction SilentlyContinue
  if ($null -ne $p -and $p.HiberbootEnabled -eq 1) {
    if ($FixFastStartup) {
      Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -Value 0
      Write-Ok "Fast Startup disabled (reboot required)"
    } else {
      Write-Warn2 "Fast Startup is enabled - WoL often fails after shutdown. Re-run with -FixFastStartup."
    }
  } else {
    Write-Ok "Fast Startup disabled"
  }
}

function Invoke-Preflight {
  Write-Step "pre-flight checks"
  Test-FastStartup

  $wired = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
    Where-Object { $_.MediaType -eq '802.3' })
  if ($wired.Count -eq 0) {
    Write-Warn2 "no physical Ethernet adapter found - WoL requires wired Ethernet"
    return
  }
  foreach ($a in $wired) {
    $state = $(if ($a.Status -eq 'Up') { 'Up' } else { $a.Status })
    Write-Host "    NIC  $($a.Name) | $($a.InterfaceDescription) | $($a.MacAddress) | $state"
    if ($state -eq 'Up') {
      try {
        $mp = Get-NetAdapterAdvancedProperty -Name $a.Name -DisplayName '*Magic Packet*' -ErrorAction Stop |
              Select-Object -First 1
        if ($mp -and $mp.DisplayValue -notin @('Enabled','1','On')) {
          Write-Warn2 "'$($a.Name)': Wake on Magic Packet is '$($mp.DisplayValue)' - enable it in Device Manager"
        } else {
          Write-Ok "'$($a.Name)' accepts magic packets"
        }
      } catch { Write-Warn2 "'$($a.Name)': could not read WoL capability ($($_.Exception.Message))" }
    } else {
      Write-Warn2 "'$($a.Name)' is $state - plug in the cable or pick another adapter"
    }
  }
}

function Register-AgentTask {
  param($v)
  Import-Module ScheduledTasks -ErrorAction Stop

  $agent = Join-Path $InstallDir 'wol-agent.ps1'
  Get-AgentScript -Destination $agent

  $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument `
    "-NoProfile -ExecutionPolicy Bypass -File `"$agent`" -DeviceId `"$($v.DeviceId)`" -ApiUrl `"$($v.ApiUrl)`" -Secret `"$($v.Secret)`" -GraceSeconds $($v.GraceSeconds)"
  # SYSTEM account: survives logoffs/reboots without storing any user password.
  $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  $trigger = New-ScheduledTaskTrigger -AtStartup
  $trigger.Delay = 'PT30S'
  # The agent loops forever - remove the default 72h execution limit.
  $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero)

  $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  if ($existing) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Ok "removed previous task '$TaskName'"
  }
  Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal `
    -Trigger $trigger -Settings $settings -Description 'Alexa Wake-on-LAN agent (polls wol-bridge)' | Out-Null
  Write-Ok "task '$TaskName' registered"

  Start-ScheduledTask -TaskName $TaskName
  Start-Sleep -Seconds 2
  $t = Get-ScheduledTask -TaskName $TaskName
  Write-Ok "task state: $($t.State)"
}

switch ($PSCmdlet.ParameterSetName) {
  'Test' {
    $v = Resolve-ConfigValues
    Write-Step "testing bridge ($($v.ApiUrl))"
    $action = Invoke-Poll -State 'ON'
    if ($null -eq $action) { exit 1 }
    Write-Ok "bridge reachable, action='$action'"
    if ($action -eq 'shutdown') { Write-Warn2 "a fresh shutdown command was pending - the PC would power off now!" }
  }

  'Remove' {
    Assert-Admin
    Import-Module ScheduledTasks -ErrorAction Stop
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($t) {
      Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
      Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
      Write-Ok "task '$TaskName' removed"
    } else { Write-Warn2 "task '$TaskName' not found" }
    if ($Purge -and (Test-Path -LiteralPath $InstallDir)) {
      Remove-Item -LiteralPath $InstallDir -Recurse -Force
      Write-Ok "removed $InstallDir"
    }
  }

  'Status' {
    Import-Module ScheduledTasks -ErrorAction Stop
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $t) {
      Write-Fail "task '$TaskName' is not installed"
      exit 1
    }
    $info = $t | Get-ScheduledTaskInfo
    Write-Host "task     : $($t.TaskName) [$($t.State)]"
    Write-Host "lastrun  : $($info.LastRunTime) (result 0x$('{0:X}' -f $info.LastTaskResult))"
    Write-Host "nextrun  : $($info.NextRunTime)"
    $cfg = Get-Config
    if ($cfg) {
      Write-Host "device   : $($cfg.deviceId)"
      Write-Host "bridge   : $($cfg.apiUrl)"
    }
    if ($Live) {
      Write-Step "live poll"
      $action = Invoke-Poll -State 'ON'
      if ($action) { Write-Ok "online - bridge replied action='$action'" }
      else { exit 1 }
    }
  }

  default {
    # Install / Repair
    Assert-Admin
    $v = Resolve-ConfigValues
    if ($v.ApiUrl -notmatch '^https://') { Write-Warn2 "ApiUrl does not start with https:// - double-check it" }
    if ($v.Secret -match 'REPLACE_ME|CHANGE_ME') { throw "Secret still looks like a placeholder." }

    if ($v.IsAdHoc) {
      Write-Ok "Generated ad-hoc secret for '$($v.DeviceId)': $($v.Secret)"
    } else {
      Write-Ok "Using secret for '$($v.DeviceId)'"
    }

    if ($RegisterAws) {
      Register-AwsDevice -deviceId $v.DeviceId -secret $v.Secret -apiUrl $v.ApiUrl | Out-Null
    }

    Save-Config ([pscustomobject]@{
      deviceId = $v.DeviceId; apiUrl = $v.ApiUrl; secret = $v.Secret; graceSeconds = $v.GraceSeconds
      installedAt = (Get-Date).ToString('o')
    })

    if (-not $SkipPreflight -and -not $Repair) { Invoke-Preflight }

    Write-Step "registering scheduled task"
    Register-AgentTask -v $v
    Write-Step "verifying bridge connectivity"
    $action = Invoke-Poll -State 'ON'
    if ($action) {
      Write-Ok "installation complete - Alexa can now turn '$($v.DeviceId)' OFF"
    } else {
      Write-Warn2 "installed, but the bridge did not answer (or returned 401 Unauthorized)."
      Write-Host ""
      Write-Host "================ NEXT STEPS ================" -ForegroundColor Cyan
      Write-Host "Device ID : $($v.DeviceId)"
      Write-Host "Secret    : $($v.Secret)"
      Write-Host ""
      Write-Host "To register this device with your AWS stack, run:" -ForegroundColor Yellow
      Write-Host "  .\scripts\wol.ps1 add-dev '$($v.DeviceId)|$($v.DeviceId)|auto|$($v.Secret)'" -ForegroundColor White
      Write-Host "Or add '$($v.DeviceId)': '$($v.Secret)' to PC_SECRETS in wol-bridge Lambda configuration."
      Write-Host ""
      Write-Host "Once registered in AWS, test anytime with:" -ForegroundColor Cyan
      Write-Host "  .\scripts\wol.ps1 status -Live" -ForegroundColor White
      Write-Host "============================================" -ForegroundColor Cyan
      if (-not $v.IsAdHoc) {
        exit 2
      }
    }
  }
}
