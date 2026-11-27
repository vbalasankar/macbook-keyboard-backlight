set -u
SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/common.sh
. "$SRC_ROOT/scripts/common.sh"
say "== system =="; say "macOS $(sw_vers -productVersion 2>/dev/null) / $(uname -m) / $(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
say "== files =="
for f in "$CONTROLLER_DST" "$HELPER_DST" "$MEDIA_DST" "$CONFIG_DST" "$AGENT_PLIST"; do
  if [ -e "$f" ]; then printf 'ok      %s (%s)\n' "$f" "$(stat -f '%Sp %Su' "$f" 2>/dev/null || stat -c '%A %U' "$f")"; else printf 'MISSING %s\n' "$f"; fi
done
say "== launch agent =="
if agent_loaded; then launchctl print "$(gui_domain)/${LABEL}" 2>/dev/null | grep -E 'state =|pid =|last exit code' ; else say "not loaded"; fi
say "== helper probe =="
if [ -x "$HELPER_DST" ]; then "$HELPER_DST" probe 2>&1; else say "helper missing"; fi
say "== controller status =="
if [ -x "$CONTROLLER_DST" ]; then "$CONTROLLER_DST" status 2>&1; else say "controller missing"; fi
say "== shortcuts flag =="
if [ -e "$DISABLED_FLAG" ]; then say "DISABLED (run: $CONTROLLER_DST enable)"; else say "enabled"; fi
for l in "$LOG_DIR/helper.log" "$LOG_DIR/controller.log"; do
  say "== tail $l =="
  if [ -f "$l" ]; then tail -n 15 "$l"; else say "(none)"; fi
done
