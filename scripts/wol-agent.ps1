<#
.SYNOPSIS
  wol-agent.ps1 — polls the wol-bridge Lambda for shutdown commands and keeps
  the device state fresh. No Node.js, no AWS SDK, no IAM keys — just PowerShell.

.PARAMETER DeviceId
  The Alexa endpoint id (must match WOL_DEVICES / ENDPOINT_ID on the skill).

.PARAMETER ApiUrl
  The wol-bridge Function URL, e.g. https://abc123.lambda-url.eu-west-1.on.aws/

.PARAMETER Secret
  This device's shared secret (must match PC_SECRETS on the bridge).

.PARAMETER GraceSeconds
  Seconds the OS waits before shutting down (default 10).
#>
param(
  [string]$DeviceId = "wol-pc-001",
  [string]$ApiUrl = "https://<url>.lambda-url.<region>.on.aws/",
  [string]$Secret = "REPLACE_ME",
  [int]$GraceSeconds = 10
)

$headers = @{ "x-pc-secret" = $Secret }

function Send-Poll([string]$state) {
  try {
    $body = @{ powerState = $state } | ConvertTo-Json -Compress
    $resp = Invoke-RestMethod -Method Post -Uri "$ApiUrl`?deviceId=$DeviceId" `
      -Headers $headers -ContentType "application/json" -Body $body -TimeoutSec 15
    return $resp.action
  } catch {
    Write-Host "$(Get-Date -Format o) poll failed: $($_.Exception.Message)"
    return "none"
  }
}

# Boot: report ON so Alexa learns the PC is up even if it was started by hand.
Send-Poll "ON" | Out-Null

while ($true) {
  if ((Send-Poll "ON") -eq "shutdown") {
    # Tell Alexa we are turning off, then power down.
    Send-Poll "OFF" | Out-Null
    shutdown /s /t $GraceSeconds /c "Alexa requested shutdown"
    exit 0
  }
  Start-Sleep -Seconds 20
}
