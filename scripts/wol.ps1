<#
.SYNOPSIS
  wol.ps1 - single entry point for every wol management task (Windows).

  Thin dispatcher: maps subcommands to the underlying scripts in this folder.
  Any extra arguments are passed through unchanged.

.SUBCOMMANDS
  deploy   [deploy-aws.ps1 args]     Deploy/update the AWS side (CloudFormation + Lambdas).
  add-dev  <id[|Name][|MAC]> [...]   Add one or more devices to an existing deployment.
  install  [-DeviceId .. -ApiUrl .. -Secret ..]
                                     Install the polling agent + scheduled task on this PC.
  repair                              Re-register the task from the saved config.
  uninstall [-Purge]                  Remove the scheduled task (and optionally the files).
  status [-Live]                      Show agent/task state, optionally live-poll the bridge.
  test    [-DeviceId .. -ApiUrl .. -Secret ..]
                                     One-off poll against the bridge.
  remove  [remove-aws.ps1 args]       Tear down the AWS deployment.

.EXAMPLE
  .\wol.ps1 deploy -Region eu-west-1 -AlexaClientId ... -AlexaClientSecret ... `
      -DevicesJson '[{"endpointId":"wol-pc-001","friendlyName":"Office PC","macAddress":"AA:BB:CC:DD:EE:FF"}]' `
      -PcSecretsJson '{"wol-pc-001":"long-random-secret"}'

.EXAMPLE
  .\wol.ps1 install -DeviceId wol-pc-001 -ApiUrl "https://...lambda-url.../" -Secret REPLACE_ME
  .\wol.ps1 status -Live
  .\wol.ps1 uninstall -Purge
#>
$ErrorActionPreference = 'Stop'

function Show-Usage {
  Write-Host @'
usage: wol.ps1 <subcommand> [args...]

  deploy   [deploy-aws.ps1 args]      deploy/update the AWS side
  add-dev  <id[|Name][|MAC]> [...]    add devices to an existing deployment
  install  [-DeviceId .. -ApiUrl .. -Secret ..]
                                      install the agent + scheduled task (elevated)
  repair                              re-register the task from saved config
  uninstall [-Purge]                  remove the scheduled task
  status [-Live]                      show agent state / poll the bridge
  test [-DeviceId .. -ApiUrl .. -Secret ..]
                                      one-off bridge connectivity check
  remove [remove-aws.ps1 args]        tear down the AWS deployment
'@
}

if ($args.Count -eq 0) { Show-Usage; exit 2 }

$sub = $args[0]
$rest = @()
if ($args.Count -gt 1) { $rest = $args[1..($args.Count - 1)] }
$install = Join-Path $PSScriptRoot 'install-agent.ps1'
$deploy  = Join-Path $PSScriptRoot 'deploy-aws.ps1'
$remove  = Join-Path $PSScriptRoot 'remove-aws.ps1'

switch ($sub) {
  'deploy'     { & $deploy @rest }
  'add-dev'    {
    if (-not $rest) { Write-Host "usage: wol.ps1 add-dev 'endpointId|FriendlyName|MAC' [...]" -ForegroundColor Yellow; exit 2 }
    & $deploy -AddDevice @rest
  }
  'install'    { & $install -Install @rest }
  'repair'     { & $install -Repair @rest }
  'uninstall'  { & $install -Uninstall @rest }
  'status'     { & $install -Status @rest }
  'test'       { & $install -TestConnection @rest }
  'remove'     { & $remove @rest }
  'help'       { Show-Usage }
  default      {
    Write-Host "unknown subcommand '$sub'" -ForegroundColor Red
    Show-Usage
    exit 2
  }
}

# Propagate the delegate script's exit code so callers can rely on it.
if ($null -ne $LASTEXITCODE) { exit $LASTEXITCODE }
