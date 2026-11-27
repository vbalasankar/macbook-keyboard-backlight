set -u
SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/common.sh
. "$SRC_ROOT/scripts/common.sh"
KEEP_CONFIG=0; KEEP_LOGS=0
for a in "$@"; do case "$a" in --keep-config) KEEP_CONFIG=1 ;; --keep-logs) KEEP_LOGS=1 ;; *) err "unknown option: $a"; exit 2 ;; esac; done
require_non_root; validate_home

# Guard: never rm -rf anything but the exact expected directories.
[ "$APP_DIR" = "${HOME}/Library/Application Support/keyboard-light" ] || { err "unexpected APP_DIR"; exit 1; }
[ "$LOG_DIR" = "${HOME}/Library/Logs/keyboard-light" ] || { err "unexpected LOG_DIR"; exit 1; }

say "Stopping hotkey daemon..."
if agent_loaded; then launchctl bootout "$(gui_domain)/${LABEL}" 2>/dev/null || warn "bootout reported an error"; fi
# Belt and braces: kill a leftover helper started from our exact path, owned by this user.
pkill -u "$(id -u)" -f "^${HELPER_DST} listen " 2>/dev/null || true

[ -L "$AGENT_PLIST" ] && { err "$AGENT_PLIST is a symlink; refusing to touch it"; exit 1; }
rm -f "$AGENT_PLIST"
if [ "$KEEP_CONFIG" -eq 1 ] && [ -f "$CONFIG_DST" ]; then
  rm -rf "${APP_DIR:?}/bin" "${APP_DIR:?}/libexec" "${APP_DIR:?}/run"; say "Kept $CONFIG_DST"
else
  [ -L "$APP_DIR" ] && { err "$APP_DIR is a symlink; refusing to remove"; exit 1; }
  rm -rf "${APP_DIR:?}"
fi
[ "$KEEP_LOGS" -eq 1 ] || { [ -L "$LOG_DIR" ] && { err "$LOG_DIR is a symlink; refusing"; exit 1; }; rm -rf "${LOG_DIR:?}"; }
say "Uninstalled. The installer changed no macOS settings, so nothing needs restoring."
say "Manual step: remove 'kbl-helper' from Accessibility and Input Monitoring in System Settings > Privacy & Security."
