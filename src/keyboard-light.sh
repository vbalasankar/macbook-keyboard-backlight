set -u
set -o pipefail
umask 077

readonly KBL_VERSION="1.1.0"
readonly EX_OK=0 EX_ERR=1 EX_USAGE=2 EX_BACKEND=3 EX_CONFIG=4 EX_LOCK=5 EX_PERM=6

# Install root. Overridable for tests; every file used below is still permission-checked.
KBL_HOME="${KBL_HOME:-${HOME}/Library/Application Support/keyboard-light}"
KBL_LOG_DIR="${KBL_LOG_DIR:-${HOME}/Library/Logs/keyboard-light}"
readonly CONFIG_FILE="${KBL_HOME}/config"
readonly RUN_DIR="${KBL_HOME}/run"
readonly LOCK_DIR="${RUN_DIR}/lock.d"
readonly DISABLED_FLAG="${RUN_DIR}/disabled"
readonly HELPER="${KBL_HOME}/libexec/kbl-helper"
readonly MEDIA_HELPER="${KBL_HOME}/libexec/kbl-media"   # only used by the media-key fallback
readonly LOG_FILE="${KBL_LOG_DIR}/controller.log"
readonly LOG_MAX_BYTES=262144
readonly LOCK_TIMEOUT_TICKS=200    # 200 x 0.05s = 10 seconds

# Defaults (overridden by config file). Percent values, integers only.
STEP_PERCENT=10
MIN_PERCENT=0
MAX_PERCENT=100
BACKEND="auto"          # auto | corebrightness | mediakey
LOG_LEVEL="error"       # error | info | debug (error = no log work on the hot path)

log() {  # log <level> <message...>   (logs controller state only, never user content)
  local level="$1"; shift
  case "$LOG_LEVEL:$level" in
    error:error|info:error|info:info|debug:*) ;;
    *) return 0 ;;
  esac
  [ -d "$KBL_LOG_DIR" ] || mkdir -p "$KBL_LOG_DIR" 2>/dev/null || return 0
  [ -L "$LOG_FILE" ] && return 0                 # refuse to write through a symlink
  if [ -f "$LOG_FILE" ]; then
    local size; size=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
    [ "${size:-0}" -gt "$LOG_MAX_BYTES" ] && mv -f "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null
  fi
  printf '%s [%s] pid=%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$level" "$$" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

die() {  # die <exit-code> <message>
  local code="$1"; shift
  printf 'keyboard-light: %s\n' "$*" >&2
  log error "exit=$code $*"
  exit "$code"
}

is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; *) [ "${#1}" -le 9 ] ;; esac; }

# Succeeds when $1 exists, is not a symlink, is owned by the current user and is not
# group/world writable. One stat call; flavor chosen from the builtin $OSTYPE (no extra forks):
# BSD stat on macOS, GNU stat elsewhere (used by the test suite on Linux).
check_file_secure() {
  local path="$1" info owner mode
  [ -L "$path" ] && return 1
  case "$OSTYPE" in
    darwin*) info=$(stat -f '%u %Lp' "$path" 2>/dev/null) || return 1 ;;
    *)       info=$(stat -c '%u %a' "$path" 2>/dev/null) || return 1 ;;
  esac
  owner="${info%% *}"; mode="${info##* }"
  case "$owner$mode" in ''|*[!0-9]*) return 1 ;; esac
  [ "$owner" = "$UID" ] || return 1
  [ $(( 8#${mode} & 8#022 )) -eq 0 ]
}

# Parse "KEY=VALUE" lines WITHOUT sourcing/evaluating the file. Whitelisted keys only.
load_config() {
  [ -e "$CONFIG_FILE" ] || return 0              # missing config -> defaults
  check_file_secure "$CONFIG_FILE" || die $EX_PERM "config file is a symlink, not owned by you, or group/world-writable"
  local line key value
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) ;; *) die $EX_CONFIG "malformed config line (expected KEY=VALUE)" ;; esac
    key="${line%%=*}"; value="${line#*=}"
    key="${key//[[:space:]]/}"; value="${value//[[:space:]]/}"
    case "$key" in
      STEP_PERCENT|MIN_PERCENT|MAX_PERCENT)
        if ! is_uint "$value" || [ "$((10#$value))" -gt 100 ]; then die $EX_CONFIG "$key must be an integer 0-100"; fi
        printf -v "$key" '%s' "$((10#$value))" ;;
      BACKEND)
        case "$value" in auto|corebrightness|mediakey) BACKEND="$value" ;; *) die $EX_CONFIG "BACKEND must be auto, corebrightness or mediakey" ;; esac ;;
      LOG_LEVEL)
        case "$value" in error|info|debug) LOG_LEVEL="$value" ;; *) die $EX_CONFIG "LOG_LEVEL must be error, info or debug" ;; esac ;;
      *) die $EX_CONFIG "unknown config key" ;;
    esac
  done < "$CONFIG_FILE"
  [ "$STEP_PERCENT" -ge 1 ] || die $EX_CONFIG "STEP_PERCENT must be >= 1"
  [ "$MIN_PERCENT" -lt "$MAX_PERCENT" ] || die $EX_CONFIG "MIN_PERCENT must be lower than MAX_PERCENT"
}

# ---- Pure brightness math (permille in, permille out) -----------------------------------
clamp_permille() {  # clamp_permille <value> -> stdout; bounds come from config
  local v="$1" lo=$(( MIN_PERCENT * 10 )) hi=$(( MAX_PERCENT * 10 ))
  [ "$v" -lt "$lo" ] && v=$lo
  [ "$v" -gt "$hi" ] && v=$hi
  printf '%s\n' "$v"
}
compute_target() {  # compute_target <current_permille> <up|down> -> stdout
  local cur="$1" dir="$2" step=$(( STEP_PERCENT * 10 ))
  if [ "$dir" = up ]; then clamp_permille $(( cur + step )); else clamp_permille $(( cur - step )); fi
}

# ---- Backend access -----------------------------------------------------------------------
require_helper() {
  [ -x "$HELPER" ] || die $EX_BACKEND "native helper not found or not executable: $HELPER (run scripts/install.sh)"
  check_file_secure "$HELPER" || die $EX_PERM "helper has unsafe ownership/permissions: $HELPER"
}
backend_get() {  # prints permille; returns 0 on success
  local out
  out=$("$HELPER" get 2>/dev/null) || return 1
  is_uint "$out" && [ "$out" -le 1000 ] || return 1
  printf '%s\n' "$out"
}
backend_set()   { "$HELPER" set "$1" >/dev/null 2>&1; }
backend_media() { "$MEDIA_HELPER" "$1" >/dev/null 2>&1; }
require_media() {
  [ -x "$MEDIA_HELPER" ] || die $EX_BACKEND "fallback helper not found: $MEDIA_HELPER (run scripts/install.sh)"
  check_file_secure "$MEDIA_HELPER" || die $EX_PERM "fallback helper has unsafe ownership/permissions: $MEDIA_HELPER"
}

# ---- Locking (mkdir is atomic on every filesystem macOS uses) -----------------------------
LOCK_HELD=0
LOCK_STALE_SECONDS=2   # critical section lasts milliseconds; a lock this old with a dead owner is stale

lock_age_seconds() {   # age of the lock directory; GNU stat first, then BSD stat (macOS)
  local mtime
  case "$OSTYPE" in
    darwin*) mtime=$(stat -f '%m' "$LOCK_DIR" 2>/dev/null) ;;
    *)       mtime=$(stat -c '%Y' "$LOCK_DIR" 2>/dev/null) ;;
  esac || true
  case "$mtime" in ''|*[!0-9]*) echo 0; return ;; esac
  echo $(( $(date +%s) - mtime ))
}

acquire_lock() {
  [ -L "$RUN_DIR" ] && die $EX_PERM "run directory is a symlink"
  if ! { mkdir -p "$RUN_DIR" && chmod 700 "$RUN_DIR"; } 2>/dev/null; then die $EX_ERR "cannot create run directory"; fi
  local waited=0 holder
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    holder=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
    # Break only when the owner is dead (or never recorded a pid) AND the lock is old. The age
    # check prevents deleting a fresh lock that another process created after we read the pid.
    if { [ -z "$holder" ] || ! kill -0 "$holder" 2>/dev/null; } && [ "$(lock_age_seconds)" -ge "$LOCK_STALE_SECONDS" ]; then
      rm -rf "$LOCK_DIR" 2>/dev/null; continue
    fi
    waited=$(( waited + 1 ))
    [ "$waited" -ge "$LOCK_TIMEOUT_TICKS" ] && die $EX_LOCK "timed out waiting for another controller instance"
    sleep 0.05
  done
  LOCK_HELD=1
  printf '%s\n' "$$" > "$LOCK_DIR/pid"
}
release_lock() { if [ "$LOCK_HELD" -eq 1 ]; then rm -rf "$LOCK_DIR" 2>/dev/null; fi; LOCK_HELD=0; }
trap release_lock EXIT
trap 'exit 130' INT TERM HUP

# ---- Commands -----------------------------------------------------------------------------
cmd_adjust() {  # cmd_adjust <up|down>
  local dir="$1" cur target
  acquire_lock
  if [ "$BACKEND" != mediakey ]; then
    require_helper
    if cur=$(backend_get); then
      target=$(compute_target "$cur" "$dir")
      if [ "$target" = "$cur" ]; then log debug "already at limit ($cur), no write"; return $EX_OK; fi
      backend_set "$target" || die $EX_BACKEND "helper failed to set brightness"
      log info "$dir: $cur -> $target permille"; return $EX_OK
    fi
    [ "$BACKEND" = corebrightness ] && die $EX_BACKEND "cannot read keyboard brightness (private CoreBrightness interface unavailable on this macOS version?)"
    log info "corebrightness unavailable, falling back to mediakey"
  fi
  require_media
  backend_media "$dir" || die $EX_BACKEND "media-key fallback failed (is Accessibility permission granted to the helper?)"
  log info "$dir via mediakey (no readback/clamping available)"
}

cmd_set() {  # cmd_set <percent>
  { is_uint "${1:-}" && [ "$((10#$1))" -le 100 ]; } || die $EX_USAGE "set requires an integer percent 0-100"
  local permille; permille=$(clamp_permille $(( 10#$1 * 10 )))
  acquire_lock; require_helper
  backend_set "$permille" || die $EX_BACKEND "helper failed to set brightness"
  log info "set: $permille permille"
}

cmd_get() {
  require_helper
  local v; v=$(backend_get) || die $EX_BACKEND "cannot read keyboard brightness"
  printf '%s\n' "$(( v / 10 ))"
}

cmd_status() {
  local v
  printf 'version: %s\nbackend setting: %s\nstep: %s%%  range: %s-%s%%\n' "$KBL_VERSION" "$BACKEND" "$STEP_PERCENT" "$MIN_PERCENT" "$MAX_PERCENT"
  if [ -e "$DISABLED_FLAG" ]; then echo "shortcuts: DISABLED"; else echo "shortcuts: enabled"; fi
  if [ -x "$HELPER" ] && v=$("$HELPER" get 2>/dev/null) && is_uint "$v"; then echo "brightness: $(( v / 10 ))%"; else echo "brightness: unreadable"; fi
}

usage() {
  cat <<USAGE
Usage: keyboard-light.sh <command>
  up | down         raise / lower brightness by STEP_PERCENT (clamped)
  set <0-100>       set brightness percent
  get               print current brightness percent
  status            show configuration and state
  disable | enable  pause / resume the global shortcuts
  version | help
USAGE
}

main() {
  local cmd="${1:-help}"
  case "$cmd" in
    help|-h|--help) usage; return $EX_OK ;;
    version|--version) echo "$KBL_VERSION"; return $EX_OK ;;
  esac
  [ "$#" -le 2 ] || die $EX_USAGE "too many arguments"
  load_config
  case "$cmd" in
    up|down) [ "$#" -eq 1 ] || die $EX_USAGE "$cmd takes no arguments"; cmd_adjust "$cmd" ;;
    set)     [ "$#" -eq 2 ] || die $EX_USAGE "set requires one argument"; cmd_set "$2" ;;
    get)     cmd_get ;;
    status)  cmd_status ;;
    disable) mkdir -p "$RUN_DIR" && chmod 700 "$RUN_DIR" && : > "$DISABLED_FLAG" && echo "shortcuts disabled" ;;
    enable)  rm -f "$DISABLED_FLAG" && echo "shortcuts enabled" ;;
    *) usage >&2; die $EX_USAGE "unknown command" ;;
  esac
}
main "$@"
