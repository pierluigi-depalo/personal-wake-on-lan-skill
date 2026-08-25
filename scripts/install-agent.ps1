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

function Resolve-ConfigValues {
  $cfg = Get-Config
  # NOTE: plain '$x = if ...' is not valid in PowerShell 5.1 - wrap in $().
  $deviceId = $(if ($DeviceId) { $DeviceId } elseif ($cfg) { $cfg.deviceId } else { $null })
  $apiUrl   = $(if ($ApiUrl)   { $ApiUrl }   elseif ($cfg) { $cfg.apiUrl }   else { $null })
  $secret   = $(if ($Secret)   { $Secret }   elseif ($cfg) { $cfg.secret }   else { $null })
  $grace    = $(if ($PSBoundParameters.ContainsKey('GraceSeconds')) { $GraceSeconds } elseif ($cfg) { [int]$cfg.graceSeconds } else { 10 })
  foreach ($pair in @(@('DeviceId', $deviceId), @('ApiUrl', $apiUrl), @('Secret', $secret))) {
    if (-not $pair[1]) { throw "$($pair[0]) is required (pass it or install first)." }
  }
  [pscustomobject]@{ DeviceId = $deviceId; ApiUrl = $apiUrl; Secret = $secret; GraceSeconds = $grace }
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
    if ($ApiUrl -notmatch '^https://') { Write-Warn2 "ApiUrl does not start with https:// - double-check it" }
    if ($v.Secret -match 'REPLACE_ME|CHANGE_ME') { throw "Secret still looks like a placeholder." }

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
      Write-Warn2 "installed, but the bridge did not answer - check URL/secret (run: .\install-agent.ps1 -TestConnection)"
      exit 2
    }
  }
}
