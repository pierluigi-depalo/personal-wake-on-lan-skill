#!/usr/bin/env bash
# deploy-aws.sh — one-command AWS deployment for the Wake-on-LAN skill (Linux/macOS).
# Mirror of scripts/deploy-aws.ps1: creates/updates the CloudFormation stack and
# uploads the real handler code from src/.
#
# Usage:
#   ./deploy-aws.sh -r eu-west-1 \
#     --client-id amzn1.application-oa2-client.xxxx \
#     --client-secret yyyy \
#     --devices '[{"endpointId":"wol-pc-001","friendlyName":"Office PC","macAddress":"AA:BB:CC:DD:EE:FF"}]' \
#     --secrets '{"wol-pc-001":"long-random-secret"}'
set -euo pipefail

STACK_NAME="wol-stack"
REGION="eu-west-1"
ALEXA_CLIENT_ID=""
ALEXA_CLIENT_SECRET=""
DEVICES_JSON=""
SINGLE_MAC=""
ENDPOINT_ID="wol-pc-001"
FRIENDLY_NAME="PC"
PC_SECRETS_JSON=""
TABLE_NAME="AlexaEventTokens"
GATEWAY_URL=""
DEVICE_STALE_MS=""
PAGES_ORIGIN="https://pierluigi-depalo.github.io"
CREATE_NEW_TABLE="true"
RAW_BASE="https://raw.githubusercontent.com/pierluigi-depalo/personal-wake-on-lan-skill/main"
SKIP_CODE_UPLOAD=0

usage() { sed -n '2,20p' "$0" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    -s|--stack)          STACK_NAME="$2"; shift 2 ;;
    -r|--region)         REGION="$2"; shift 2 ;;
    --client-id)         ALEXA_CLIENT_ID="$2"; shift 2 ;;
    --client-secret)     ALEXA_CLIENT_SECRET="$2"; shift 2 ;;
    --devices)           DEVICES_JSON="$2"; shift 2 ;;
    --single-mac)        SINGLE_MAC="$2"; shift 2 ;;
    --endpoint-id)       ENDPOINT_ID="$2"; shift 2 ;;
    --friendly-name)     FRIENDLY_NAME="$2"; shift 2 ;;
    --secrets)           PC_SECRETS_JSON="$2"; shift 2 ;;
    --table)             TABLE_NAME="$2"; shift 2 ;;
    --gateway-url)       GATEWAY_URL="$2"; shift 2 ;;
    --stale-ms)          DEVICE_STALE_MS="$2"; shift 2 ;;
    --pages-origin)      PAGES_ORIGIN="$2"; shift 2 ;;
    --no-new-table)      CREATE_NEW_TABLE="false"; shift ;;
    --raw-base)          RAW_BASE="$2"; shift 2 ;;
    --skip-code-upload)  SKIP_CODE_UPLOAD=1; shift ;;
    -h|--help)           usage ;;
    *) echo "unknown option: $1" >&2; usage ;;
  esac
done

[ -n "$ALEXA_CLIENT_ID" ]     || { echo "--client-id required" >&2; exit 1; }
[ -n "$ALEXA_CLIENT_SECRET" ] || { echo "--client-secret required" >&2; exit 1; }
[ -n "$PC_SECRETS_JSON" ]     || { echo "--secrets required" >&2; exit 1; }

step() { printf '==> %s\n' "$*"; }
ok()   { printf '  OK  %s\n' "$*"; }
die()  { printf '  XX  %s\n' "$*" >&2; exit 1; }

case "$REGION" in
  us-east-1|us-west-2|eu-west-1|ap-northeast-1) ;;
  *) die "unsupported Alexa region '$REGION' (use us-east-1, us-west-2, eu-west-1, ap-northeast-1)" ;;
esac

if [ -z "$GATEWAY_URL" ]; then
  case "$REGION" in
    us-east-1|us-west-2)  GATEWAY_URL="https://api.amazonalexa.com/v3/events" ;;
    ap-northeast-1)       GATEWAY_URL="https://api.fe.amazonalexa.com/v3/events" ;;
    *)                    GATEWAY_URL="" ;; # eu-west-1: code default is already EU
  esac
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TEMPLATE="$HERE/../docs/installer/wol-stack.template.json"
SRC_INDEX="$HERE/../src/index.js"
SRC_BRIDGE="$HERE/../src/bridge.js"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ ! -f "$TEMPLATE" ]; then
  step "fetching template from $RAW_BASE"
  curl -fsSL "$RAW_BASE/docs/installer/wol-stack.template.json" -o "$TMP/template.json" ||
    wget -qO "$TMP/template.json" "$RAW_BASE/docs/installer/wol-stack.template.json" ||
    die "template download failed"
  TEMPLATE="$TMP/template.json"
fi

STANDALONE=0
[ -f "$SRC_INDEX" ] || STANDALONE=1
if [ "$STANDALONE" = "1" ]; then
  step "standalone run - fetching handlers from $RAW_BASE"
  curl -fsSL "$RAW_BASE/src/index.js"  -o "$TMP/index.js"  || die "index.js download failed"
  curl -fsSL "$RAW_BASE/src/bridge.js" -o "$TMP/bridge.js" || die "bridge.js download failed"
  SRC_INDEX="$TMP/index.js"
  SRC_BRIDGE="$TMP/bridge.js"
fi

command -v aws >/dev/null 2>&1 || die "AWS CLI v2 not found - install it and run 'aws configure'"
step "checking AWS credentials"
aws sts get-caller-identity --output text --query Account >/dev/null ||
  die "AWS credentials not usable - run 'aws configure'"
ok "credentials OK"

make_zip() { # make_zip <handler-src> <zip-out>
  local stage="$TMP/stage.$$"
  mkdir -p "$stage"
  cp "$1" "$stage/"
  printf '{"type":"module"}' > "$stage/package.json" # handlers are ESM
  rm -f "$2"
  if command -v zip >/dev/null 2>&1; then
    (cd "$stage" && zip -q -X "$2" "$(basename "$1")" package.json)
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$stage" "$2" "$(basename "$1")" <<'PY'
import sys, zipfile, os
stage, out, name = sys.argv[1], sys.argv[2], sys.argv[3]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for f in (name, "package.json"):
        z.write(os.path.join(stage, f), f)
PY
  else
    die "need 'zip' or 'python3' to package handler code"
  fi
  rm -rf "$stage"
}

step "packaging handler zips"
SKILL_ZIP="$TMP/skill.zip"
BRIDGE_ZIP="$TMP/bridge.zip"
make_zip "$SRC_INDEX"  "$SKILL_ZIP"
make_zip "$SRC_BRIDGE" "$BRIDGE_ZIP"
ok "skill.zip / bridge.zip ready"

ARGS=(--stack-name "$STACK_NAME"
      --template-file "$TEMPLATE"
      --region "$REGION"
      --capabilities CAPABILITY_NAMED_IAM
      --no-fail-on-empty-changeset
      --parameter-overrides
        "AlexaClientId=$ALEXA_CLIENT_ID"
        "AlexaClientSecret=$ALEXA_CLIENT_SECRET"
        "EndpointId=$ENDPOINT_ID"
        "FriendlyName=$FRIENDLY_NAME"
        "PcSecretsJson=$PC_SECRETS_JSON"
        "DynamoTableName=$TABLE_NAME"
        "PagesOrigin=$PAGES_ORIGIN"
        "CreateNewTable=$CREATE_NEW_TABLE")
[ -n "$DEVICES_JSON" ]     && ARGS+=("DevicesJson=$DEVICES_JSON")
[ -n "$SINGLE_MAC" ]       && ARGS+=("SingleMacAddress=$SINGLE_MAC")
[ -n "$GATEWAY_URL" ]      && ARGS+=("EventGatewayUrl=$GATEWAY_URL")
[ -n "$DEVICE_STALE_MS" ]  && ARGS+=("DeviceStaleMs=$DEVICE_STALE_MS")

step "deploying stack '$STACK_NAME' to $REGION"
aws cloudformation deploy "${ARGS[@]}" || die "CloudFormation deploy failed"

step "reading stack outputs"
OUTPUTS_JSON="$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" --output json)"
get_out() {
  printf '%s' "$OUTPUTS_JSON" | python3 -c '
import json,sys
d=json.load(sys.stdin)
for o in d["Stacks"][0]["Outputs"]:
    if o["OutputKey"]==sys.argv[1]:
        print(o["OutputValue"]); break
' "$1"
}
SKILL_FN="$(get_out SkillFunctionName)"
BRIDGE_FN="$(get_out BridgeFunctionName)"
BRIDGE_URL="$(get_out BridgeFunctionUrl)"
SKILL_ARN="$(get_out SkillFunctionArn)"

if [ "$SKIP_CODE_UPLOAD" != "1" ]; then
  step "uploading real handler code"
  aws lambda update-function-code --function-name "$SKILL_FN"  --region "$REGION" --zip-file "fileb://$SKILL_ZIP"  --output text --query LastUpdateStatus
  aws lambda update-function-code --function-name "$BRIDGE_FN" --region "$REGION" --zip-file "fileb://$BRIDGE_ZIP" --output text --query LastUpdateStatus
  ok "handlers deployed"
fi

printf '\n================ DEPLOYMENT COMPLETE ================\n'
echo "Skill Lambda : $SKILL_FN"
echo "Skill ARN    : $SKILL_ARN"
echo "Bridge Lambda: $BRIDGE_FN"
echo "Bridge URL   : $BRIDGE_URL"
printf '\nNext steps:\n'
echo "  1. Alexa console -> skill endpoint = Skill ARN above"
echo "  2. PC agent install:"
echo "     curl -fsSL $RAW_BASE/scripts/install-agent.sh -o install-agent.sh && sudo bash install-agent.sh install"
echo "======================================================"
