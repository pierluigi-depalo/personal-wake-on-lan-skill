#!/usr/bin/env bash
# remove-aws.sh - tears down everything the skill deployed in AWS (Linux/macOS).
# Mirror of scripts/remove-aws.ps1: deletes the wol-stack CloudFormation stack
# if present, plus manual-setup leftovers (Lambdas, Function URL, warmup rules,
# optionally the DynamoDB table and log groups).
#
# Usage:
#   ./remove-aws.sh [--region eu-west-1] [--table AlexaEventTokens] \
#                   [--delete-table] [--delete-logs] [-y]
set -euo pipefail

REGION="eu-west-1"
STACK_NAME="wol-stack"
TABLE_NAME="AlexaEventTokens"
FUNCTIONS=(alexa-wake-on-lan wol-bridge)
DELETE_TABLE=0
DELETE_LOGS=0
ASSUME_YES=0

step() { printf '==> %s\n' "$*"; }
ok()   { printf '  OK  %s\n' "$*"; }
note() { printf '    --  %s\n' "$*"; }
warn() { printf '    !!  %s\n' "$*" >&2; }
die()  { printf '  XX  %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    -r|--region)      REGION="$2"; shift 2 ;;
    -s|--stack)       STACK_NAME="$2"; shift 2 ;;
    -t|--table)       TABLE_NAME="$2"; shift 2 ;;
    --delete-table)   DELETE_TABLE=1; shift ;;
    --delete-logs)    DELETE_LOGS=1; shift ;;
    -y|--yes)         ASSUME_YES=1; shift ;;
    -h|--help)        sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

command -v aws >/dev/null 2>&1 || die "AWS CLI v2 not found"
aws sts get-caller-identity --output text --query Account >/dev/null ||
  die "AWS credentials not usable"

confirm() { # confirm <question>
  [ "$ASSUME_YES" = "1" ] && return 0
  read -r -p "$1 [y/N]: " a
  [ "${a:-n}" = "y" ] || [ "${a:-n}" = "Y" ]
}

# --- 1. CloudFormation stack -------------------------------------------------
if aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" >/dev/null 2>&1; then
  step "deleting CloudFormation stack '$STACK_NAME'"
  confirm "delete stack '$STACK_NAME'?" || die "aborted - stack left in place"
  aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION"
  step "waiting for stack deletion (this can take a minute)"
  aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$REGION"
  ok "stack '$STACK_NAME' deleted"
else
  note "no CloudFormation stack '$STACK_NAME' found"
fi

# --- 2. Warmup EventBridge schedules pointing at our functions ---------------
step "scanning EventBridge rules for warmup schedules"
for rule in $(aws events list-rules --region "$REGION" --output text --query 'Rules[].Name'); do
  # Each output line: "<TAB-separated> Id <TAB> Arn"
  targets=$(aws events list-targets-by-rule --rule "$rule" --region "$REGION" \
              --output text --query 'Targets[].[Id,Arn]' 2>/dev/null || true)
  hit_ids=""
  while IFS=$'\t' read -r t_id t_arn; do
    [ -n "${t_arn:-}" ] || continue
    for fn in "${FUNCTIONS[@]}"; do
      case "$t_arn" in
        *"function/$fn") hit_ids="$hit_ids $t_id"; break ;;
      esac
    done
  done <<< "$targets"
  if [ -n "$hit_ids" ]; then
    if confirm "delete EventBridge rule '$rule' (targets our Lambda)?"; then
      # shellcheck disable=SC2086
      aws events remove-targets --rule "$rule" --ids $hit_ids --region "$REGION" >/dev/null
      aws events delete-rule --name "$rule" --region "$REGION"
      ok "removed rule '$rule'"
    fi
  fi
done

# --- 3. Orphaned Lambdas -------------------------------------------------------
for fn in "${FUNCTIONS[@]}"; do
  step "checking Lambda '$fn'"
  # Function URL first (delete-function would leave it dangling otherwise).
  if aws lambda delete-function-url-config --function-name "$fn" --region "$REGION" >/dev/null 2>&1; then
    ok "Function URL removed"
  fi
  if aws lambda delete-function --function-name "$fn" --region "$REGION" >/dev/null 2>&1; then
    ok "Lambda '$fn' deleted"
  else
    note "'$fn' not found (already gone)"
  fi
done

# --- 4. DynamoDB table ----------------------------------------------------------
if [ "$DELETE_TABLE" = "1" ]; then
  step "deleting DynamoDB table '$TABLE_NAME'"
  warn "This erases the stored Alexa Event Gateway tokens."
  warn "You must re-enable the skill in the Alexa app afterwards."
  confirm "really delete table '$TABLE_NAME'?" || { note "table kept"; DELETE_TABLE=0; }
  if [ "$DELETE_TABLE" = "1" ]; then
    aws dynamodb delete-table --table-name "$TABLE_NAME" --region "$REGION" >/dev/null
    ok "table deletion requested"
  fi
else
  note "keeping table '$TABLE_NAME' (pass --delete-table to remove)"
fi

# --- 5. Log groups ----------------------------------------------------------------
if [ "$DELETE_LOGS" = "1" ]; then
  for fn in "${FUNCTIONS[@]}"; do
    if aws logs delete-log-group --log-group-name "/aws/lambda/$fn" --region "$REGION" >/dev/null 2>&1; then
      ok "log group /aws/lambda/$fn removed"
    fi
  done
fi

printf '\n================ TEARDOWN DONE ================\n'
echo "Manual steps that cannot be scripted:"
echo "  1. Alexa Developer Console: disable or delete the skill."
echo "  2. Login with Amazon console: delete the security profile"
echo "     if you want a completely fresh start."
echo "  3. On each PC: remove the old polling task/service:"
echo "       Windows: .\\install-agent.ps1 -Uninstall -Purge"
echo "       Linux:   sudo ./install-agent.sh uninstall --purge"
echo "Then redeploy fresh via docs/installer (web wizard Step 3)."
printf '===============================================\n'
