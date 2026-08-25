#!/usr/bin/env bash
# install-agent.sh — interactive installer/manager for the wol-agent systemd
# service. Replaces the manual steps in scripts/README.md.
#
# Usage:
#   sudo ./install-agent.sh                  # interactive wizard (whiptail/dialog or plain prompts)
#   sudo ./install-agent.sh install          # non-interactive when DEVICE_ID/API_URL/SECRET are set
#   sudo ./install-agent.sh uninstall [--purge]
#   sudo ./install-agent.sh repair           # re-register from saved config
#   ./install-agent.sh status [--live]
#   ./install-agent.sh test [DEVICE_ID] [API_URL] [SECRET]
#
# Env overrides: INSTALL_DIR, SERVICE_NAME, AGENT_SOURCE_URL
set -u

INSTALL_DIR="${INSTALL_DIR:-/opt/wol-agent}"
SERVICE_NAME="${SERVICE_NAME:-wol-agent}"
CONF_FILE="/etc/${SERVICE_NAME}.conf"
AGENT_SOURCE_URL="${AGENT_SOURCE_URL:-https://raw.githubusercontent.com/pierluigi-depalo/personal-wake-on-lan-skill/main/scripts/wol-agent.sh}"

ok()   { printf '  OK  %s\n' "$*"; }
warn() { printf '  !!  %s\n' "$*" >&2; }
fail() { printf '  XX  %s\n' "$*" >&2; }
step() { printf '==> %s\n' "$*"; }

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    fail "root required — re-run with sudo"
    exit 1
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }

# ---------- minimal TUI layer ----------
TUI="plain"
if have whiptail; then TUI="whiptail"; elif have dialog; then TUI="dialog"; fi

tui_title() { printf '%s' "wol-agent installer"; }

tui_msg() { # tui_msg <text>
  case "$TUI" in
    whiptail) whiptail --title "$(tui_title)" --msgbox "$1" 0 0 ;;
    dialog)   dialog   --title "$(tui_title)" --msgbox "$1" 0 0 ;;
    *)        printf '\n%s\n' "$1" ;;
  esac
}

tui_input() { # tui_input <prompt> <default> -> stdout
  local prompt="$1" def="${2:-}" val=""
  case "$TUI" in
    whiptail) val=$(whiptail --title "$(tui_title)" --inputbox "$prompt" 0 0 "$def" 3>&1 1>&2 2>&3) || exit 1 ;;
    dialog)   val=$(dialog   --title "$(tui_title)" --inputbox "$prompt" 0 0 "$def" 3>&1 1>&2 2>&3) || exit 1 ;;
    *)
      while [ -z "$val" ]; do
        read -r -p "$prompt [$def]: " val
        val="${val:-$def}"
      done
      ;;
  esac
  printf '%s' "$val"
}

tui_yesno() { # tui_yesno <question>
  case "$TUI" in
    whiptail) whiptail --title "$(tui_title)" --yesno "$1" 0 0 ;;
    dialog)   dialog   --title "$(tui_title)" --yesno "$1" 0 0 ;;
    *)        read -r -p "$1 [y/N]: " a; [ "${a:-n}" = "y" ] || [ "${a:-n}" = "Y" ] ;;
  esac
}

# ---------- config ----------
load_conf() {
  if [ -f "$CONF_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONF_FILE"
  fi
}

save_conf() {
  cat > "$CONF_FILE" <<EOF
DEVICE_ID='$DEVICE_ID'
API_URL='$API_URL'
SECRET='$SECRET'
GRACE='$GRACE'
EOF
  chmod 600 "$CONF_FILE"
  ok "config written to $CONF_FILE"
}

resolve_values() {
  load_conf
  DEVICE_ID="${DEVICE_ID:-}"
  API_URL="${API_URL:-}"
  SECRET="${SECRET:-}"
  GRACE="${GRACE:-10}"
}

# ---------- pre-flight ----------
preflight() {
  step "pre-flight checks"
  if have ethtool && have ip; then
    local iface
    iface=$(ip -o -4 route show default 2>/dev/null | awk '{print $5; exit}')
    if [ -n "$iface" ]; then
      local wol caps
      wol=$(ethtool "$iface" 2>/dev/null | awk '/Supports Wake-on:/ {$0=$NF} {print}' | tail -n1)
      caps=$(ethtool "$iface" 2>/dev/null | sed -n 's/^.*Wake-on: //p')
      if echo "$caps" | grep -q 'g'; then
        ok "'$iface' supports magic-packet wake"
      else
        warn "'$iface' Wake-on caps '$caps' lack 'g' — enable WoL in BIOS/UEFI"
      fi
      if ethtool "$iface" 2>/dev/null | grep -q 'Wireless'; then
        warn "'$iface' looks wireless — WoL does not work over Wi-Fi when off"
      fi
    else
      warn "no default route/interface found"
    fi
  else
    warn "ethtool/ip missing — skipping adapter checks"
  fi
  tui_msg "BIOS checklist (cannot be verified from the OS):\n  - Wake on LAN / Power on by PCI-E enabled\n  - PC shut down with power connected\n  - Echo device on the same LAN/subnet"
}

# ---------- agent + service ----------
fetch_agent() {
  local dest="$INSTALL_DIR/wol-agent.sh" src=""
  mkdir -p "$INSTALL_DIR"
  # Prefer the agent shipped next to the installer (repo checkout); when run
  # via curl | bash, $0 is unusable and we fall through to downloading.
  src="$(dirname "$(readlink -f "$0" 2>/dev/null || echo x)")/wol-agent.sh"
  if [ -f "$src" ] && [ "$(dirname "$src")" != "$INSTALL_DIR" ]; then
    cp "$src" "$dest"
    ok "agent copied from alongside installer"
  elif [ ! -f "$dest" ]; then
    step "downloading agent from $AGENT_SOURCE_URL"
    if have curl; then curl -fsSL "$AGENT_SOURCE_URL" -o "$dest" ||
      { fail "download failed"; exit 1; }
    elif have wget; then wget -qO "$dest" "$AGENT_SOURCE_URL" ||
      { fail "download failed"; exit 1; }
    else fail "need curl or wget to download the agent"; exit 1; fi
  else
    ok "keeping installed agent at $dest"
  fi
  chmod +x "$dest"
}

write_unit() {
  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Alexa Wake-on-LAN agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=DEVICE_ID=$DEVICE_ID
Environment=API_URL=$API_URL
Environment=SECRET=$SECRET
Environment=GRACE=$GRACE
ExecStart=$INSTALL_DIR/wol-agent.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "/etc/systemd/system/${SERVICE_NAME}.service"
}

poll_once() { # poll_once <state> -> prints action ("shutdown"/"none") or fails
  local state="$1" resp rc=0
  resp=$(curl -sS --max-time 15 -X POST \
    -H "Content-Type: application/json" \
    -H "x-pc-secret: ${SECRET}" \
    -d "{\"powerState\":\"${state}\"}" \
    "${API_URL}?deviceId=${DEVICE_ID}") || rc=$?
  if [ "$rc" -ne 0 ]; then return "$rc"; fi
  case "$resp" in
    *'"action"'*':'*'"shutdown"'*) echo "shutdown" ;;
    *'"action"'*)                  echo "none" ;;
    *) warn "unexpected bridge reply"; return 1 ;;
  esac
}

do_test() {
  resolve_values
  [ $# -ge 3 ] && { DEVICE_ID="$1"; API_URL="$2"; SECRET="$3"; }
  for v in DEVICE_ID API_URL SECRET; do
    [ -n "${!v}" ] || { fail "$v is required"; exit 1; }
  done
  step "testing bridge ($API_URL)"
  action=$(poll_once "ON") || { fail "poll failed"; exit 1; }
  ok "bridge reachable, action='$action'"
  [ "$action" = "shutdown" ] && warn "fresh shutdown pending — the PC would power off now!"
}

do_install() {
  need_root
  resolve_values
  # Non-interactive when all three values arrive via env/config.
  if [ -z "${DEVICE_ID}" ] || [ -z "${API_URL}" ] || [ -z "${SECRET}" ]; then
    tui_msg "This will install the wol-agent polling service so Alexa can turn this PC OFF."
    DEVICE_ID=$(tui_input "Device ID (must match WOL_DEVICES on the skill)" "${DEVICE_ID:-wol-pc-001}")
    API_URL=$(tui_input "Bridge Function URL" "${API_URL:-https://<url>.lambda-url.<region>.on.aws/}")
    SECRET=$(tui_input "Device secret (must match PC_SECRETS)" "${SECRET:-}")
    GRACE=$(tui_input "Shutdown grace seconds" "$GRACE")
  fi
  case "$API_URL" in https://*) ;; *) warn "API_URL should start with https://" ;; esac

  save_conf
  preflight

  step "installing agent to $INSTALL_DIR"
  fetch_agent
  write_unit
  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
  sleep 2
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    ok "service active — Alexa can now turn '$DEVICE_ID' OFF"
  else
    warn "service not running yet — check: journalctl -u $SERVICE_NAME -e"
  fi
  step "verifying bridge connectivity"
  action=$(poll_once "ON" 2>/dev/null) && ok "bridge replied action='$action'" ||
    warn "bridge did not answer — check URL/secret (run: $0 test)"
}

do_repair() {
  need_root
  resolve_values
  for v in DEVICE_ID API_URL SECRET; do
    [ -n "${!v}" ] || { fail "$v missing in $CONF_FILE — run install instead"; exit 1; }
  done
  step "re-registering service from saved config"
  fetch_agent
  write_unit
  systemctl daemon-reload
  systemctl restart "$SERVICE_NAME"
  ok "repaired"
}

do_uninstall() {
  need_root
  step "removing $SERVICE_NAME"
  systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
  systemctl daemon-reload
  ok "service removed"
  if [ "${1:-}" = "--purge" ]; then
    rm -rf "$INSTALL_DIR" "$CONF_FILE"
    ok "removed $INSTALL_DIR and $CONF_FILE"
  else
    warn "kept $INSTALL_DIR and $CONF_FILE (use --purge to delete)"
  fi
}

do_status() {
  if systemctl list-unit-files 2>/dev/null | grep -q "^${SERVICE_NAME}.service"; then
    state=$(systemctl is-active "$SERVICE_NAME")
    ok "service: $state ($(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null))"
    resolve_values
    echo "device : ${DEVICE_ID:-?}"
    echo "bridge : ${API_URL:-?}"
    if [ "${1:-}" = "--live" ]; then
      action=$(poll_once "ON" 2>/dev/null) &&
        ok "online — bridge replied action='$action'" || fail "offline — bridge did not answer"
    fi
  else
    fail "service not installed"
    exit 1
  fi
}

case "${1:-wizard}" in
  wizard)
    need_root
    tui_msg "wol-agent setup\n\nInstalls the polling agent that lets Alexa turn this PC off.\nYou will need:\n  - bridge Function URL\n  - device secret (matches PC_SECRETS)\n  - device ID (matches WOL_DEVICES)"
    tui_yesno "Continue with installation?" && do_install || echo "aborted"
    ;;
  install)   shift || true; do_install "$@" ;;
  repair)    shift || true; do_repair "$@" ;;
  uninstall) shift || true; do_uninstall "$@" ;;
  status)    shift || true; do_status "$@" ;;
  test)      shift || true; do_test "$@" ;;
  *)
    echo "usage: $0 [wizard|install|repair|uninstall [--purge]|status [--live]|test [ID URL SECRET]]" >&2
    exit 2
    ;;
esac
