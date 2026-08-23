#!/usr/bin/env bash
# wol-agent.sh — polls the wol-bridge Lambda for shutdown commands and keeps the
# device state fresh. No Node.js, no AWS SDK, no IAM keys — just curl + jq.
#
# Env: DEVICE_ID, API_URL, SECRET, GRACE (optional, default 10)
set -u

DEVICE_ID="${DEVICE_ID:-wol-pc-001}"
API_URL="${API_URL:-https://<url>.lambda-url.<region>.on.aws/}"
SECRET="${SECRET:-REPLACE_ME}"
GRACE="${GRACE:-10}"

log() { echo "$(date -Is) $*" >&2; } # lands in journalctl under systemd

poll() {
  local state="$1" rc=0 resp
  resp=$(curl -sS --max-time 15 -X POST \
    -H "Content-Type: application/json" \
    -H "x-pc-secret: ${SECRET}" \
    -d "{\"powerState\":\"${state}\"}" \
    "${API_URL}?deviceId=${DEVICE_ID}") || rc=$?
  if [ "$rc" -ne 0 ]; then
    log "poll failed: curl exit ${rc} (${state})"
    echo "none"
    return 0
  fi
  printf '%s' "$resp" | jq -r .action 2>/dev/null || {
    log "poll returned non-JSON: ${resp}"
    echo "none"
  }
}

case "$API_URL" in *\<*) log "WARNING: API_URL still contains a placeholder";; esac

# Boot: report ON so Alexa learns the PC is up even if it was started by hand.
poll "ON" >/dev/null

while true; do
  if [ "$(poll "ON")" = "shutdown" ]; then
    # Tell Alexa we are turning off, then power down.
    poll "OFF" >/dev/null
    sleep "$GRACE"
    shutdown -h now
    exit 0
  fi
  sleep 20
done
