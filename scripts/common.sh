LABEL="io.github.keyboard-light"
APP_DIR="${HOME}/Library/Application Support/keyboard-light"
LOG_DIR="${HOME}/Library/Logs/keyboard-light"
AGENT_PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
CONTROLLER_DST="${APP_DIR}/bin/keyboard-light.sh"
HELPER_DST="${APP_DIR}/libexec/kbl-helper"
MEDIA_DST="${APP_DIR}/libexec/kbl-media"
CONFIG_DST="${APP_DIR}/config"
DISABLED_FLAG="${APP_DIR}/run/disabled"

say()  { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
err()  { printf 'ERROR: %s\n' "$*" >&2; }

require_non_root() {
  if [ "$(id -u)" -eq 0 ]; then err "do not run as root/sudo; this tool lives entirely in your home directory"; exit 1; fi
}
# $HOME ends up inside an XML plist and shell paths; refuse characters that could break either.
validate_home() {
  case "$HOME" in
    /*) ;; *) err "HOME is not an absolute path"; exit 1 ;;
  esac
  case "$HOME" in
    *[\<\>\&\"\'\`\$\\]*|*[[:cntrl:]]*) err "HOME contains unsupported characters"; exit 1 ;;
  esac
}
gui_domain() { printf 'gui/%s' "$(id -u)"; }
agent_loaded() { launchctl print "$(gui_domain)/${LABEL}" >/dev/null 2>&1; }

# bootstrap right after bootout can fail transiently (launchd I/O error 5); retry a few times.
bootstrap_agent() {
  local i=1
  while [ "$i" -le 5 ]; do
    launchctl bootstrap "$(gui_domain)" "$AGENT_PLIST" 2>/dev/null && return 0
    agent_loaded && return 0
    sleep 1; i=$((i + 1))
  done
  launchctl bootstrap "$(gui_domain)" "$AGENT_PLIST"   # final attempt, show the real error
}
