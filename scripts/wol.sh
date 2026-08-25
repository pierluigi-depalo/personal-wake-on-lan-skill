#!/usr/bin/env bash
# wol.sh - single entry point for every wol management task (Linux/macOS).
#
# Thin dispatcher: maps subcommands to the underlying scripts in this folder.
# Any extra arguments are passed through unchanged.
#
# Usage:
#   ./wol.sh deploy [deploy-aws.sh args]
#   sudo ./wol.sh add-dev 'endpointId|FriendlyName|MAC' [...]
#   sudo ./wol.sh install --id ID --url URL --secret SECRET [--grace N]   # or no options = wizard
#   ./wol.sh status [--live]
#   sudo ./wol.sh uninstall [--purge]
#   ./wol.sh test [DEVICE_ID API_URL SECRET]
#   ./wol.sh remove [remove-aws.sh args]
set -u

DIR="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")" && pwd)"

usage() {
  cat <<'EOF'
usage: wol.sh <subcommand> [args...]

  deploy   [deploy-aws.sh args]      deploy/update the AWS side
  add-dev  <id[|Name][|MAC]> [...]   add devices to an existing deployment
  install  [--id .. --url .. --secret ..] [--grace N]
                                     install the agent + systemd service (root)
  repair                              re-register the service from saved config
  uninstall [--purge]                 remove the service
  status [--live]                     show agent state / poll the bridge
  test    [ID URL SECRET]             one-off bridge connectivity check
  remove [remove-aws.sh args]         tear down the AWS deployment
EOF
}

[ $# -gt 0 ] || { usage; exit 2; }
sub="$1"; shift

case "$sub" in
  deploy) exec "$DIR/deploy-aws.sh" "$@" ;;
  add-dev)
    if [ $# -eq 0 ]; then
      echo "usage: wol.sh add-dev 'endpointId|FriendlyName|MAC' [...]" >&2
      exit 2
    fi
    args=()
    for e in "$@"; do args+=(--add-device "$e"); done
    exec "$DIR/deploy-aws.sh" "${args[@]}"
    ;;
  install)
    # Accept --id/--url/--secret/--grace and forward as the env vars that
    # install-agent.sh understands; with none given it runs its wizard.
    while [ $# -gt 0 ]; do
      case "$1" in
        --id)     export DEVICE_ID="$2"; shift 2 ;;
        --url)    export API_URL="$2";   shift 2 ;;
        --secret) export SECRET="$2";    shift 2 ;;
        --grace)  export GRACE="$2";     shift 2 ;;
        *) echo "unknown option: $1 (expected --id/--url/--secret/--grace)" >&2; exit 2 ;;
      esac
    done
    exec "$DIR/install-agent.sh" install
    ;;
  repair)    exec "$DIR/install-agent.sh" repair "$@" ;;
  uninstall) exec "$DIR/install-agent.sh" uninstall "$@" ;;
  status)    exec "$DIR/install-agent.sh" status "$@" ;;
  test)      exec "$DIR/install-agent.sh" test "$@" ;;
  wizard)    exec "$DIR/install-agent.sh" wizard "$@" ;;
  remove|teardown) exec "$DIR/remove-aws.sh" "$@" ;;
  help|-h|--help) usage ;;
  *)
    echo "unknown subcommand '$sub'" >&2
    usage
    exit 2
    ;;
esac
