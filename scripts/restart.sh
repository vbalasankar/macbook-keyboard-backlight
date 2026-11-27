set -u
SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/common.sh
. "$SRC_ROOT/scripts/common.sh"
require_non_root
[ -f "$AGENT_PLIST" ] || { err "not installed (missing $AGENT_PLIST). Run scripts/install.sh"; exit 1; }
rm -rf "$APP_DIR/run/lock.d"   # clear any lock left by a killed controller
agent_loaded && launchctl bootout "$(gui_domain)/${LABEL}" 2>/dev/null
bootstrap_agent || { err "bootstrap failed"; exit 1; }
if agent_loaded; then say "daemon restarted"; else err "daemon not running after restart; run scripts/diagnostics.sh"; exit 1; fi
