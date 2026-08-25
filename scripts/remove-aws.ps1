<#
.SYNOPSIS
  remove-aws.ps1 - tears down everything the skill deployed in AWS, so the new
  CloudFormation-based deployment can be tested from scratch.

  Handles BOTH origins:
    - the new 'wol-stack' CloudFormation stack (deleted as a whole), and
    - leftovers from the original manual console setup (setup-guide.md Steps
      3 + 6): both Lambdas, their Function URL, warmup EventBridge rules,
      optionally the DynamoDB table and log groups.

.PARAMETER DeleteTable
  Also delete the DynamoDB token/state table. Destructive: Alexa account
  linking tokens are lost and the skill must be re-enabled afterwards.

.PARAMETER DeleteLogs
  Also delete the two /aws/lambda/* CloudWatch log groups.

.EXAMPLE
  .\remove-aws.ps1                          # interactive, keeps the table
  .\remove-aws.ps1 -DeleteTable -Force      # full wipe, no prompts
#>
[CmdletBinding()]
param(
  [string]$StackName = "wol-stack",
  [ValidateSet("us-east-1", "us-west-2", "eu-west-1", "ap-northeast-1")]
  [string]$Region = "eu-west-1",
  [string]$TableName = "AlexaEventTokens",
  [string[]]$FunctionNames = @("alexa-wake-on-lan", "wol-bridge"),
  [switch]$DeleteTable,
  [switch]$DeleteLogs,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
function Write-Step([string]$m) { Write-Host "==> $m" }
function Write-Ok([string]$m)   { Write-Host "    OK  $m" -ForegroundColor Green }

if (-not (Get-Command aws -ErrorAction SilentlyContinue)) { throw "AWS CLI v2 not found." }
aws sts get-caller-identity --output text --query Account 1>$null
if ($LASTEXITCODE -ne 0) { throw "AWS credentials not usable - run 'aws configure'." }

function Confirm-Step([string]$msg) {
  if ($Force) { return $true }
  $answer = Read-Host "$msg [y/N]"
  return ($answer -eq 'y' -or $answer -eq 'Y')
}

# --- 1. CloudFormation stack -------------------------------------------------
$stack = aws cloudformation describe-stacks --stack-name $StackName --region $Region `
  --output json 2>$null | ConvertFrom-Json
if ($LASTEXITCODE -eq 0) {
  Write-Step "deleting CloudFormation stack '$StackName'"
  if (-not (Confirm-Step "delete stack '$StackName'?")) {
    throw "aborted - stack left in place."
  }
  aws cloudformation delete-stack --stack-name $StackName --region $Region
  Write-Step "waiting for stack deletion (this can take a minute)"
  aws cloudformation wait stack-delete-complete --stack-name $StackName --region $Region
  Write-Ok "stack '$StackName' deleted"
} else {
  Write-Ok "no CloudFormation stack '$StackName' found"
}

# --- 2. Warmup EventBridge schedules pointing at our functions ---------------
Write-Step "scanning EventBridge rules for warmup schedules"
$rulesJson = aws events list-rules --region $Region --output json 2>$null | ConvertFrom-Json
foreach ($rule in $rulesJson.Rules) {
  $targets = aws events list-targets-by-rule --rule $rule.Name --region $Region --output json 2>$null |
    ConvertFrom-Json
  foreach ($t in $targets.Targets) {
    if ($FunctionNames | Where-Object { $t.Arn -like "*function/$_" }) {
      if (Confirm-Step "delete EventBridge rule '$($rule.Name)' (targets our Lambda)?") {
        $ids = ($targets.Targets | Where-Object { $FunctionNames | Where-Object { $_.Arn -like "*function/$_" } } |
          ForEach-Object Id) -join ' '
        aws events remove-targets --rule $rule.Name --ids @($ids -split ' ') --region $Region | Out-Null
        aws events delete-rule --name $rule.Name --region $Region | Out-Null
        Write-Ok "removed rule '$($rule.Name)'"
      }
    }
  }
}

# --- 3. Orphaned Lambdas (created manually before the stack existed) ----------
foreach ($fn in $FunctionNames) {
  Write-Step "checking Lambda '$fn'"
  # Function URL first (delete-function would leave it dangling otherwise).
  aws lambda delete-function-url-config --function-name $fn --region $Region 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) { Write-Ok "Function URL removed" }
  aws lambda delete-function --function-name $fn --region $Region 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) { Write-Ok "Lambda '$fn' deleted" }
  else { Write-Host "    --  '$fn' not found (already gone)" }
}

# --- 4. DynamoDB table ---------------------------------------------------------
if ($DeleteTable) {
  Write-Step "deleting DynamoDB table '$TableName'"
  Write-Host "    !!  This erases the stored Alexa Event Gateway tokens." -ForegroundColor Yellow
  Write-Host "    !!  You must re-enable the skill in the Alexa app afterwards." -ForegroundColor Yellow
  if (Confirm-Step "really delete table '$TableName'?") {
    aws dynamodb delete-table --table-name $TableName --region $Region | Out-Null
    Write-Ok "table deletion requested"
  } else {
    Write-Host "    --  table kept"
  }
} else {
  Write-Host "    --  keeping table '$TableName' (pass -DeleteTable to remove)"
}

# --- 5. Log groups --------------------------------------------------------------
if ($DeleteLogs) {
  foreach ($fn in $FunctionNames) {
    aws logs delete-log-group --log-group-name "/aws/lambda/$fn" --region $Region 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Ok "log group /aws/lambda/$fn removed" }
  }
}

Write-Host ""
Write-Host "================ TEARDOWN DONE ================" -ForegroundColor Cyan
Write-Host "Manual steps that cannot be scripted:"
Write-Host "  1. Alexa Developer Console: disable or delete the skill"
Write-Host "     (removes it from your Echo devices)."
Write-Host "  2. Login with Amazon console: delete the security profile"
Write-Host "     if you want a completely fresh start."
Write-Host "  3. On each PC: remove the old polling task/service:"
Write-Host "       Windows: .\install-agent.ps1 -Uninstall -Purge"
Write-Host "       Linux:   sudo ./install-agent.sh uninstall --purge"
Write-Host "Then redeploy fresh via docs/installer (web wizard Step 3)." -ForegroundColor Cyan
Write-Host "===============================================" -ForegroundColor Cyan
