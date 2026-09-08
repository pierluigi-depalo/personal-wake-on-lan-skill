#!/usr/bin/env bash
# update-credentials.sh — update Alexa Skill credentials, PC agent secrets, and LWA info.
#
# Updates:
#   1. alexa-wake-on-lan Lambda: ALEXA_CLIENT_ID and ALEXA_CLIENT_SECRET
#   2. wol-bridge Lambda: PC_SECRETS (mapping for deviceId -> secret)
#   3. Local Linux agent (optional/auto-detected): /etc/wol-agent.conf & systemd unit
#   4. Provides guidance/links for Login with Amazon (LWA) Account Linking
#
# Usage:
#   ./update-credentials.sh                                  # interactive wizard
#   ./update-credentials.sh --alexa-id ID --alexa-secret SEC  # update Alexa credentials
#   ./update-credentials.sh --device-id ID --generate-secret  # gen new secret for device
#   ./update-credentials.sh --device-id ID --device-secret S  # set specific device secret
set -euo pipefail

REGION="${AWS_REGION:-eu-west-1}"
SKILL_FN="alexa-wake-on-lan"
BRIDGE_FN="wol-bridge"
CONF_FILE="/etc/wol-agent.conf"
SERVICE_NAME="wol-agent"

NEW_ALEXA_ID=""
NEW_ALEXA_SECRET=""
DEVICE_ID=""
DEVICE_SECRET=""
GEN_SECRET=0
UPDATE_LOCAL=0
INTERACTIVE=0

ok()   { printf '  OK  %s\n' "$*"; }
warn() { printf '  !!  %s\n' "$*" >&2; }
fail() { printf '  XX  %s\n' "$*" >&2; }
step() { printf '==> %s\n' "$*"; }
die()  { fail "$*"; exit 1; }

usage() {
  cat <<'EOF'
usage: update-credentials.sh [options]

Options:
  --alexa-id <id>          Set ALEXA_CLIENT_ID on alexa-wake-on-lan
  --alexa-secret <secret>  Set ALEXA_CLIENT_SECRET on alexa-wake-on-lan
  --device-id <id>         Target deviceId for PC secret (e.g. server, wol-pc-001)
  --device-secret <secret> Set new device secret on wol-bridge
  --generate-secret        Generate a cryptographically secure 32-byte hex secret
  --update-local           Update local /etc/wol-agent.conf and restart systemd service
  --region <region>        AWS region (default: eu-west-1 or $AWS_REGION)
  -i, --interactive        Run interactive setup wizard
  -h, --help               Show this help message
EOF
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --alexa-id)        NEW_ALEXA_ID="$2"; shift 2 ;;
    --alexa-secret)    NEW_ALEXA_SECRET="$2"; shift 2 ;;
    --device-id)       DEVICE_ID="$2"; shift 2 ;;
    --device-secret)   DEVICE_SECRET="$2"; shift 2 ;;
    --generate-secret) GEN_SECRET=1; shift ;;
    --update-local)    UPDATE_LOCAL=1; shift ;;
    --region)          REGION="$2"; shift 2 ;;
    -i|--interactive)  INTERACTIVE=1; shift ;;
    -h|--help)         usage ;;
    *) die "Unknown option: $1 (run with --help for usage)" ;;
  esac
done

command -v aws >/dev/null 2>&1 || die "AWS CLI not found on PATH. Please install or configure it."
command -v python3 >/dev/null 2>&1 || die "python3 is required for JSON processing."

# Check AWS credentials
aws sts get-caller-identity --output text --query Account >/dev/null 2>&1 ||
  die "AWS credentials not configured or expired. Run 'aws configure'."

# If no flags passed, default to interactive
if [ -z "$NEW_ALEXA_ID" ] && [ -z "$NEW_ALEXA_SECRET" ] && [ -z "$DEVICE_SECRET" ] && [ "$GEN_SECRET" -eq 0 ] && [ "$INTERACTIVE" -eq 0 ]; then
  INTERACTIVE=1
fi

# Detect deviceId from local config if installed and not provided
if [ -z "$DEVICE_ID" ] && [ -f "$CONF_FILE" ]; then
  DEVICE_ID=$(grep -E '^DEVICE_ID=' "$CONF_FILE" 2>/dev/null | cut -d'=' -f2- | tr -d '"'\'' ' || true)
fi
[ -z "$DEVICE_ID" ] && DEVICE_ID="server"

if [ "$INTERACTIVE" -eq 1 ]; then
  printf '\n=== Wake-on-LAN Credentials Manager ===\n'
  printf 'Region: %s\n\n' "$REGION"

  echo "1. Alexa Skill Credentials (Permissions -> Send Alexa Events in Alexa Console):"
  read -r -p "   New ALEXA_CLIENT_ID [press Enter to skip]: " input_id
  [ -n "$input_id" ] && NEW_ALEXA_ID="$input_id"

  read -r -p "   New ALEXA_CLIENT_SECRET [press Enter to skip]: " input_sec
  [ -n "$input_sec" ] && NEW_ALEXA_SECRET="$input_sec"

  echo ""
  echo "2. PC Agent Secret (used by wol-bridge and the PC polling agent):"
  read -r -p "   Target Device ID [$DEVICE_ID]: " input_dev
  [ -n "$input_dev" ] && DEVICE_ID="$input_dev"

  read -r -p "   Generate a new random secret for '$DEVICE_ID'? [Y/n/custom]: " choice
  case "${choice,,}" in
    ""|y|yes)
      GEN_SECRET=1
      ;;
    c|custom)
      read -r -p "   Enter custom secret: " DEVICE_SECRET
      ;;
    *)
      # skipped
      ;;
  esac

  if [ -f "$CONF_FILE" ] || systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    read -r -p "   Update local wol-agent service config on this machine as well? [Y/n]: " update_choice
    case "${update_choice,,}" in
      ""|y|yes) UPDATE_LOCAL=1 ;;
      *) UPDATE_LOCAL=0 ;;
    esac
  fi
fi

# 1. Update Alexa Skill credentials if requested
if [ -n "$NEW_ALEXA_ID" ] || [ -n "$NEW_ALEXA_SECRET" ]; then
  step "Updating $SKILL_FN environment variables"
  CURRENT_SKILL_CFG=$(aws lambda get-function-configuration --function-name "$SKILL_FN" --region "$REGION" --output json)
  
  UPDATED_SKILL_VARS=$(python3 - <<PY
import json, sys
cfg = json.loads('''$CURRENT_SKILL_CFG''')
vars = (cfg.get("Environment") or {}).get("Variables") or {}

new_id = "$NEW_ALEXA_ID"
new_sec = "$NEW_ALEXA_SECRET"

if new_id:
    vars["ALEXA_CLIENT_ID"] = new_id
if new_sec:
    vars["ALEXA_CLIENT_SECRET"] = new_sec

print(json.dumps({"Variables": vars}))
PY
)

  aws lambda update-function-configuration \
    --function-name "$SKILL_FN" \
    --region "$REGION" \
    --environment "$UPDATED_SKILL_VARS" >/dev/null
  ok "Updated $SKILL_FN credentials"
fi

# 2. Update PC Agent Secret if requested
if [ "$GEN_SECRET" -eq 1 ]; then
  DEVICE_SECRET=$(python3 -c 'import secrets; print(secrets.token_hex(32))')
fi

if [ -n "$DEVICE_SECRET" ]; then
  step "Updating $BRIDGE_FN PC_SECRETS for device '$DEVICE_ID'"
  CURRENT_BRIDGE_CFG=$(aws lambda get-function-configuration --function-name "$BRIDGE_FN" --region "$REGION" --output json)

  UPDATED_BRIDGE_VARS=$(python3 - <<PY
import json, sys
cfg = json.loads('''$CURRENT_BRIDGE_CFG''')
vars = (cfg.get("Environment") or {}).get("Variables") or {}

try:
    secrets = json.loads(vars.get("PC_SECRETS") or "{}")
except Exception:
    secrets = {}

secrets["$DEVICE_ID"] = "$DEVICE_SECRET"
vars["PC_SECRETS"] = json.dumps(secrets, separators=(",", ":"))

print(json.dumps({"Variables": vars}))
PY
)

  aws lambda update-function-configuration \
    --function-name "$BRIDGE_FN" \
    --region "$REGION" \
    --environment "$UPDATED_BRIDGE_VARS" >/dev/null
  ok "Updated PC_SECRETS on $BRIDGE_FN for '$DEVICE_ID'"

  # 3. Update local agent if requested
  if [ "$UPDATE_LOCAL" -eq 1 ] || [ -f "$CONF_FILE" ]; then
    if [ "$(id -u)" -ne 0 ]; then
      warn "Updating local config requires root — skipping local agent update. Run with sudo if you want to update local /etc/wol-agent.conf"
    else
      step "Updating local agent configuration at $CONF_FILE"
      # Update or append SECRET in CONF_FILE
      if [ -f "$CONF_FILE" ]; then
        if grep -qE '^SECRET=' "$CONF_FILE"; then
          sed -i "s|^SECRET=.*|SECRET=\"$DEVICE_SECRET\"|" "$CONF_FILE"
        else
          echo "SECRET=\"$DEVICE_SECRET\"" >> "$CONF_FILE"
        fi
        if grep -qE '^DEVICE_ID=' "$CONF_FILE"; then
          sed -i "s|^DEVICE_ID=.*|DEVICE_ID=\"$DEVICE_ID\"|" "$CONF_FILE"
        fi
      fi

      # Update systemd unit environment
      UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
      if [ -f "$UNIT_FILE" ]; then
        sed -i "s|^Environment=SECRET=.*|Environment=SECRET=$DEVICE_SECRET|" "$UNIT_FILE"
        sed -i "s|^Environment=DEVICE_ID=.*|Environment=DEVICE_ID=$DEVICE_ID|" "$UNIT_FILE"
        systemctl daemon-reload
        if systemctl is-active --quiet "$SERVICE_NAME"; then
          systemctl restart "$SERVICE_NAME"
          ok "Restarted local $SERVICE_NAME service with the new secret"
        fi
      fi
      ok "Local agent config updated"
    fi
  fi

  printf '\n--------------------------------------------------\n'
  printf '  Device ID: %s\n' "$DEVICE_ID"
  printf '  Secret:    %s\n' "$DEVICE_SECRET"
  printf '--------------------------------------------------\n'
fi

# 4. Clarification / Reminder about LWA
cat <<'EOF'

[!] Note about Login with Amazon (LWA) Client ID & Secret:
    LWA credentials belong to your Amazon Security Profile and are configured in
    the Alexa Developer Console under:
      Skill -> PERMISSIONS / ACCOUNT LINKING -> Account Linking
    They are managed by Amazon's OAuth servers and are NOT stored on AWS Lambda.
    If you rotated your LWA Security Profile credentials:
      1. Go to https://developer.amazon.com/alexa/console/ask
      2. Open your skill -> Account Linking
      3. Update 'Client ID' and 'Client Secret' with your new LWA credentials
      4. Save and re-link the skill in your Alexa mobile app (Skills -> Your Skills -> Dev).
EOF

ok "Done!"
