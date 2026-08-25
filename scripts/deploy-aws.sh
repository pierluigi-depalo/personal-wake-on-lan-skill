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
#
# Incremental mode - add one or more devices to an EXISTING deployment
# (updates WOL_DEVICES + PC_SECRETS in place, no stack changes). Repeatable,
# each entry in one of these forms:
#   'endpointId|FriendlyName|MAC'  full control
#   'endpointId|MAC'               friendly name defaults to endpointId
#   'endpointId|FriendlyName'      MAC auto-detected from this machine
#   'endpointId'                   both defaults applied
# Auto-detection picks this machine's wired interface - run ON the target PC,
# or pass the MAC explicitly for remote adds:
#   ./deploy-aws.sh --add-device 'gaming-rig|Gaming Rig' \
#                   --add-device 'laptop|AA:BB:CC:DD:EE:FF'
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
FORCE=0
ADD_DEVICES=()

usage() { sed -n '2,20p' "$0" >&2; exit 2; }

step() { printf '==> %s\n' "$*"; }
ok()   { printf '  OK  %s\n' "$*"; }
warn() { printf '    !!  %s\n' "$*" >&2; }
die()  { printf '  XX  %s\n' "$*" >&2; exit 1; }

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
    -f|--force)          FORCE=1; shift ;;
    --add-device)        ADD_DEVICES+=("$2"); shift 2 ;;
    -h|--help)           usage ;;
    *) echo "unknown option: $1" >&2; usage ;;
  esac
done

# ---------------------------------------------------------------------------
# Incremental add-device mode (multi-device): updates env vars in place.
# ---------------------------------------------------------------------------
if [ "${#ADD_DEVICES[@]}" -gt 0 ]; then
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  DEVS_FILE="$TMP/devices.tsv"   # endpointId<TAB>friendlyName<TAB>mac<TAB>secret
  : > "$DEVS_FILE"

  detect_local_mac() {
    local iface mac
    iface=$(ip -o -4 route show default 2>/dev/null | awk '{print $5; exit}')
    if [ -z "$iface" ] && [ -d /sys/class/net ]; then
      iface=$(ls /sys/class/net | grep -v '^lo$' | head -1)
    fi
    [ -n "$iface" ] || die "cannot detect a network interface on this machine - pass the MAC explicitly"
    mac=$(cat "/sys/class/net/$iface/address" 2>/dev/null || true)
    [ -n "$mac" ] && [ "$mac" != "00:00:00:00:00:00" ] ||
      die "no MAC found for '$iface' - pass the MAC explicitly"
    warn "auto-detected MAC $mac from '$iface'"
    printf '%s' "$mac" | tr 'abcdef' 'ABCDEF'
  }

  is_mac() { printf '%s' "$1" | grep -Eq '^[0-9a-fA-F]{2}([-:]?[0-9a-fA-F]{2}){5}$'; }

  for entry in "${ADD_DEVICES[@]}"; do
    IFS='|' read -r e_id e_name e_mac <<< "$entry"
    e_id=$(printf '%s' "$e_id" | tr -d '[:space:]')
    printf '%s' "$e_id" | grep -Eq '^[a-z0-9][a-z0-9-]{1,62}$' ||
      die "endpoint id '$e_id' must be a short slug (letters/digits/dashes)"
    # Forms: 'id' | 'id|name' | 'id|MAC' | 'id|name|MAC' (MAC may be 'auto').
    if [ -z "$e_name" ] && [ -z "${e_mac:-}" ]; then
      e_mac="auto"                                          # 'id'
    elif [ -z "${e_mac:-}" ]; then                          # 'id|name' | 'id|MAC'
      if is_mac "$e_name"; then
        e_mac="$e_name"; e_name=""
      elif [ "$e_name" = "auto" ]; then
        e_name=""; e_mac="auto"
      else
        e_mac="auto"
      fi
    fi
    if [ "$e_mac" = "auto" ]; then
      # detect_local_mac may die() - the subshell cannot abort us, so re-check.
      e_mac=$(detect_local_mac)
      [ -n "$e_mac" ] || exit 1
    else
      mac_norm=$(printf '%s' "$e_mac" | tr -d ':.-' | tr 'abcdef' 'ABCDEF')
      printf '%s' "$mac_norm" | grep -Eq '^[0-9A-F]{12}$' ||
        die "MAC '$e_mac' in '$entry' does not look like AA:BB:CC:DD:EE:FF"
      e_mac=$(printf '%s' "$mac_norm" | sed 's/../&:/g; s/:$//')
    fi
    [ -n "$e_name" ] || e_name="$e_id"
    secret=$(openssl rand -hex 32 2>/dev/null || head -c32 /dev/urandom | od -An -tx1 | tr -d ' \n')
    printf '%s\t%s\t%s\t%s\n' "$e_id" "$e_name" "$e_mac" "$secret" >> "$DEVS_FILE"
  done
  if [ "$(cut -f1 "$DEVS_FILE" | sort | uniq -d | wc -l)" -gt 0 ]; then
    die "duplicate endpoint ids in --add-device list"
  fi

  command -v aws >/dev/null 2>&1 || die "AWS CLI v2 not found"
  command -v python3 >/dev/null 2>&1 || die "python3 required for JSON handling"
  aws sts get-caller-identity --output text --query Account >/dev/null ||
    die "AWS credentials not usable"

  SKILL_FN="alexa-wake-on-lan"; BRIDGE_FN="wol-bridge"; BRIDGE_URL=""
  if OUTS=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
              --region "$REGION" --output json 2>/dev/null); then
    get_out() {
      printf '%s' "$OUTS" | python3 -c '
import json,sys
for o in json.load(sys.stdin)["Stacks"][0]["Outputs"]:
    if o["OutputKey"]==sys.argv[1]: print(o["OutputValue"]); break
' "$1"
    }
    SKILL_FN="$(get_out SkillFunctionName)"
    BRIDGE_FN="$(get_out BridgeFunctionName)"
    BRIDGE_URL="$(get_out BridgeFunctionUrl)"
  fi
  if [ -z "$BRIDGE_URL" ]; then
    BRIDGE_URL=$(aws lambda get-function-url-config --function-name "$BRIDGE_FN" \
                   --region "$REGION" --output text --query FunctionUrl 2>/dev/null || true)
  fi

  wait_settled() {
    for _ in $(seq 1 30); do
      sleep 1
      s=$(aws lambda get-function-configuration --function-name "$1" --region "$REGION" \
            --output text --query LastUpdateStatus)
      [ "$s" = "Successful" ] && return 0
      [ "$s" = "Failed" ] && return 1
    done
    return 1
  }

  merge_skill() { # merge_skill <config.json> -> writes skill-env.json, prints count
    python3 - "$1" "$DEVS_FILE" "$TMP/skill-env.json" <<'PY'
import json, sys
infile, devsfile, outfile = sys.argv[1:]
rows = [l.rstrip("\n").split("\t") for l in open(devsfile) if l.strip()]
cfg = json.load(open(infile))
env = (cfg.get("Environment") or {}).get("Variables") or {}
if cfg.get("LastUpdateStatus") == "InProgress":
    sys.exit("function is mid-update - retry in a moment")
devices = []
if env.get("WOL_DEVICES"):
    devices = json.loads(env["WOL_DEVICES"])
    if not isinstance(devices, list): devices = [devices]
elif env.get("MAC_ADDRESS"):
    print("!! single-device mode - migrating to WOL_DEVICES", file=sys.stderr)
    devices = [{"endpointId": env.get("ENDPOINT_ID", "wol-pc-001"),
                "friendlyName": env.get("PC_FRIENDLY_NAME", "PC"),
                "macAddress": env["MAC_ADDRESS"]}]
    for k in ("MAC_ADDRESS", "ENDPOINT_ID", "PC_FRIENDLY_NAME"):
        env.pop(k, None)
for _id, _name, _mac, _sec in rows:
    if any(d.get("endpointId") == _id for d in devices):
        sys.exit(f"device '{_id}' already exists")
    devices.append({"endpointId": _id, "friendlyName": _name, "macAddress": _mac})
env["WOL_DEVICES"] = json.dumps(devices, separators=(",", ":"))
with open(outfile, "w") as f:
    json.dump({"Variables": env}, f)
print(len(devices))
PY
  }

  merge_bridge() { # merge_bridge <config.json> -> writes bridge-env.json, prints count
    python3 - "$1" "$DEVS_FILE" "$TMP/bridge-env.json" <<'PY'
import json, sys
infile, devsfile, outfile = sys.argv[1:]
rows = [l.rstrip("\n").split("\t") for l in open(devsfile) if l.strip()]
cfg = json.load(open(infile))
env = (cfg.get("Environment") or {}).get("Variables") or {}
if cfg.get("LastUpdateStatus") == "InProgress":
    sys.exit("function is mid-update - retry in a moment")
secrets = {}
if env.get("PC_SECRETS"):
    secrets = json.loads(env["PC_SECRETS"])
for _id, _name, _mac, _sec in rows:
    secrets[_id] = _sec
env["PC_SECRETS"] = json.dumps(secrets, separators=(",", ":"))
with open(outfile, "w") as f:
    json.dump({"Variables": env}, f)
print(len(secrets))
PY
  }

  step "updating skill Lambda '$SKILL_FN'"
  aws lambda get-function-configuration --function-name "$SKILL_FN" \
        --region "$REGION" --output json > "$TMP/skill-cfg.json"
  merge_skill "$TMP/skill-cfg.json" > "$TMP/count" ||
    die "skill env merge failed (see message above)"
  aws lambda update-function-configuration --function-name "$SKILL_FN" \
        --region "$REGION" --environment "file://$TMP/skill-env.json" >/dev/null
  wait_settled "$SKILL_FN" || die "'$SKILL_FN' update did not settle successfully"
  ok "WOL_DEVICES now lists $(cat "$TMP/count") device(s)"

  step "updating bridge Lambda '$BRIDGE_FN'"
  aws lambda get-function-configuration --function-name "$BRIDGE_FN" \
        --region "$REGION" --output json > "$TMP/bridge-cfg.json"
  merge_bridge "$TMP/bridge-cfg.json" > "$TMP/count" ||
    die "bridge env merge failed (see message above)"
  aws lambda update-function-configuration --function-name "$BRIDGE_FN" \
        --region "$REGION" --environment "file://$TMP/bridge-env.json" >/dev/null
  wait_settled "$BRIDGE_FN" || die "'$BRIDGE_FN' update did not settle successfully"
  ok "PC_SECRETS now holds $(cat "$TMP/count") secret(s)"

  if [ -z "$BRIDGE_URL" ]; then
    warn "could not read the bridge Function URL - substitute <BRIDGE_URL> below"
    BRIDGE_URL="<BRIDGE_URL>"
  fi

  printf '\n================ DEVICES ADDED ================\n'
  while IFS=$'\t' read -r d_id d_name d_mac d_secret; do
    echo ""
    echo "endpointId : $d_id"
    echo "secret     : $d_secret"
    echo "# Windows (elevated PowerShell):"
    echo "iwr $RAW_BASE/scripts/install-agent.ps1 -OutFile \$env:TEMP\\wol-install.ps1; powershell -NoProfile -ExecutionPolicy Bypass -File \"\$env:TEMP\\wol-install.ps1\" -Install -DeviceId '$d_id' -ApiUrl '$BRIDGE_URL' -Secret '$d_secret'"
    echo "# Linux:"
    echo "curl -fsSL $RAW_BASE/scripts/install-agent.sh | sudo env DEVICE_ID='$d_id' API_URL='$BRIDGE_URL' SECRET='$d_secret' bash -s -- install"
  done < "$DEVS_FILE"
  echo ""
  warn "If you later re-run a full CloudFormation deploy, pass the FULL device list"
  warn "(use --add-device for future additions instead of stack updates)."
  printf '===============================================\n'
  exit 0
fi

[ -n "$ALEXA_CLIENT_ID" ]     || { echo "--client-id required" >&2; exit 1; }
[ -n "$ALEXA_CLIENT_SECRET" ] || { echo "--client-secret required" >&2; exit 1; }
[ -n "$PC_SECRETS_JSON" ]     || { echo "--secrets required" >&2; exit 1; }

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

# Pre-flight: leftovers from a previous/manual deployment make CREATE fail.
step "checking for conflicting resources"
if [ "$CREATE_NEW_TABLE" = "true" ]; then
  if aws dynamodb describe-table --table-name "$TABLE_NAME" --region "$REGION" >/dev/null 2>&1; then
    msg="table '$TABLE_NAME' already exists - run scripts/remove-aws.sh --delete-table first, or redeploy with --no-new-table"
    [ "$FORCE" = "1" ] && warn "$msg" || die "$msg"
  fi
fi
for fn in alexa-wake-on-lan wol-bridge; do
  if aws lambda get-function --function-name "$fn" --region "$REGION" >/dev/null 2>&1; then
    msg="Lambda '$fn' already exists (outside the stack?) - run scripts/remove-aws.sh first, or retry with --force"
    [ "$FORCE" = "1" ] && warn "$msg" || die "$msg"
  fi
done
ok "no conflicts"

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
