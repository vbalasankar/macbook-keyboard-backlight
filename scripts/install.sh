set -eu
umask 077
SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/common.sh
. "$SRC_ROOT/scripts/common.sh"

PREBUILT=""
case "${1:-}" in
  "") ;;
  --prebuilt) [ "$#" -eq 2 ] || { echo "usage: install.sh [--prebuilt /path/to/dir]" >&2; exit 2; }; PREBUILT="$2" ;;
  *) echo "usage: install.sh [--prebuilt /path/to/dir]" >&2; exit 2 ;;
esac

STAGE=""
# shellcheck disable=SC2329  # invoked via trap
cleanup() { [ -n "$STAGE" ] && rm -rf "$STAGE"; return 0; }
trap cleanup EXIT

require_non_root
validate_home

say "== keyboard-light installer =="
# 1-3. Platform checks
[ "$(uname -s)" = "Darwin" ] || { err "macOS required (found $(uname -s))"; exit 1; }
ARCH="$(uname -m)"
[ "$ARCH" = "arm64" ] || { err "Apple Silicon (arm64) required, found $ARCH. Under Rosetta? Run from a native Terminal."; exit 1; }
OSVER="$(sw_vers -productVersion)"; OSMAJOR="${OSVER%%.*}"
case "$OSMAJOR" in ''|*[!0-9]*) err "cannot parse macOS version '$OSVER'"; exit 1 ;; esac
[ "$OSMAJOR" -ge 13 ] || { err "macOS 13 or newer required (found $OSVER)"; exit 1; }
CHIP="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"
say "Detected: macOS $OSVER, $ARCH, $CHIP"
case "$CHIP" in *"Apple M4"*) ;; *) warn "chip is '$CHIP', not Apple M4; the project is only targeted at M4 MacBook Air" ;; esac

# 4. Dependencies
NEEDED="codesign launchctl plutil install sed"
[ -n "$PREBUILT" ] || NEEDED="swiftc $NEEDED"
for tool in $NEEDED; do
  command -v "$tool" >/dev/null 2>&1 || {
    err "missing dependency: $tool"
    [ "$tool" = swiftc ] && err "install Xcode Command Line Tools with:  xcode-select --install"
    exit 1; }
done

# 5-6. Build helper in a private temp dir, then install atomically
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/kbl-install.XXXXXXXX")"
BINARIES="kbl-helper kbl-media"
if [ -n "$PREBUILT" ]; then
  [ -d "$PREBUILT" ] && [ ! -L "$PREBUILT" ] || { err "--prebuilt must be a directory containing kbl-helper and kbl-media: $PREBUILT"; exit 1; }
  for b in $BINARIES; do
    [ -f "$PREBUILT/$b" ] && [ ! -L "$PREBUILT/$b" ] || { err "--prebuilt: $PREBUILT/$b missing or not a regular file"; exit 1; }
    if ! file "$PREBUILT/$b" 2>/dev/null | grep -q 'Mach-O 64-bit executable arm64'; then
      err "$PREBUILT/$b is not an arm64 macOS executable"; exit 1
    fi
  done
  say "Using prebuilt helpers from $PREBUILT (only use binaries you built yourself, e.g. from your own CI run)"
  for b in $BINARIES; do
    install -m 755 "$PREBUILT/$b" "$STAGE/$b"
    xattr -c "$STAGE/$b" 2>/dev/null || true     # drop the browser-download quarantine flag
  done
else
  say "Building native helpers (swiftc -Osize)..."
  for b in $BINARIES; do
    swiftc -Osize -o "$STAGE/$b" "$SRC_ROOT/src/native-helper/$b.swift" \
      || { err "build of $b failed (see compiler output above)"; exit 1; }
  done
fi
codesign --force --sign - --identifier "${LABEL}.helper" "$STAGE/kbl-helper" \
  || { err "ad-hoc code signing failed"; exit 1; }
codesign --force --sign - --identifier "${LABEL}.media" "$STAGE/kbl-media" \
  || { err "ad-hoc code signing failed"; exit 1; }

mkdir -p "$APP_DIR/bin" "$APP_DIR/libexec" "$APP_DIR/run" "$LOG_DIR" "$(dirname "$AGENT_PLIST")"
chmod 700 "$APP_DIR" "$APP_DIR/bin" "$APP_DIR/libexec" "$APP_DIR/run" "$LOG_DIR"
agent_loaded && launchctl bootout "$(gui_domain)/${LABEL}" 2>/dev/null || true   # stop old version before replacing
install -m 755 "$STAGE/kbl-helper" "$HELPER_DST.new" && mv -f "$HELPER_DST.new" "$HELPER_DST"
install -m 755 "$STAGE/kbl-media" "$MEDIA_DST.new" && mv -f "$MEDIA_DST.new" "$MEDIA_DST"
install -m 755 "$SRC_ROOT/src/keyboard-light.sh" "$CONTROLLER_DST.new" && mv -f "$CONTROLLER_DST.new" "$CONTROLLER_DST"

# 7. Config (never overwrite the user's)
if [ ! -e "$CONFIG_DST" ]; then install -m 600 "$SRC_ROOT/config/config.example" "$CONFIG_DST"; say "Created $CONFIG_DST"; else say "Keeping existing config"; fi

# 8. LaunchAgent from template
sed -e "s|@LABEL@|$LABEL|g" -e "s|@HELPER@|$HELPER_DST|g" -e "s|@CONTROLLER@|$CONTROLLER_DST|g" \
    -e "s|@DISABLED_FLAG@|$DISABLED_FLAG|g" -e "s|@LOG_DIR@|$LOG_DIR|g" \
    "$SRC_ROOT/launchagent/keyboard-light.plist" > "$STAGE/agent.plist"
plutil -lint "$STAGE/agent.plist" >/dev/null || { err "generated LaunchAgent plist is invalid"; exit 1; }
install -m 644 "$STAGE/agent.plist" "$AGENT_PLIST"

# 9. Start
bootstrap_agent || { err "launchctl bootstrap failed; see TROUBLESHOOTING.md"; exit 1; }

# 10. Verify
FAILED=0
[ -x "$HELPER_DST" ] && [ -x "$MEDIA_DST" ] && [ -x "$CONTROLLER_DST" ] && [ -f "$AGENT_PLIST" ] || { err "installed files missing"; FAILED=1; }
if agent_loaded; then say "LaunchAgent: loaded"; else warn "LaunchAgent not loaded"; FAILED=1; fi
if PROBE="$("$HELPER_DST" probe 2>&1)"; then say "$PROBE"; else warn "helper probe failed: $PROBE"; fi
if V="$("$CONTROLLER_DST" get 2>&1)"; then say "Current keyboard brightness: ${V}%"; else
  warn "could not read brightness via CoreBrightness ($V). The media-key fallback will be used (BACKEND=auto)."; fi

cat <<MSG

NEXT STEP (required, cannot be automated): macOS must trust the helper.
  System Settings > Privacy & Security > Accessibility  -> click +, press Cmd+Shift+G, paste:
      $HELPER_DST
  Do the same under Input Monitoring. (Only if the media-key fallback is ever used, also add
  ${MEDIA_DST} under Accessibility.) Then run:  $SRC_ROOT/scripts/restart.sh
Shortcuts: Control+Option+O = brighter, Control+Option+P = dimmer.
MSG
exit "$FAILED"
