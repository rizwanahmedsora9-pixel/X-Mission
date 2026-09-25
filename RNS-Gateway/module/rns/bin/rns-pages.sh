#!/system/bin/sh
# Start ONLY the admin panel and captive portal listener.
# Do not source store.sh, net.sh, common.sh, or rns-http.sh.
# Called from service.sh (boot), action.sh (Magisk Action), and rnsd.sh.
# A broken voucher or firewall script must not stop this listener.

_here=${0%/*}
export RNS_HOME=${RNS_HOME:-${_here%/*}}
export RNS_LAB=${RNS_LAB:-0}

if [ -z "${BB:-}" ]; then
  if [ -x /data/adb/magisk/busybox ]; then
    BB=/data/adb/magisk/busybox
  elif [ -x /usr/bin/busybox ]; then
    BB=/usr/bin/busybox
  else
    BB=busybox
  fi
fi
export BB
export RNS_BB=$BB

if [ "$RNS_LAB" = "1" ] && [ -n "${RNS_DATA:-}" ]; then
  STATE=$RNS_DATA
else
  STATE=/data/adb/rns
fi
mkdir -p "$STATE" 2>/dev/null || true
mkdir -p /data/local/tmp 2>/dev/null || true

# The pid and mode files decide whether the listener is already up. If the
# state directory cannot be written, pid_alive() would never see the listener
# and every supervisor pass would try to relaunch it. Pick a writable state
# directory instead, and still read the port config from every known place.
if [ ! -w "$STATE" ]; then
  for _d in "${RNS_DATA:-}" /data/local/tmp /tmp; do
    [ -n "$_d" ] || continue
    if mkdir -p "$_d" 2>/dev/null && [ -w "$_d" ]; then
      STATE=$_d
      break
    fi
  done
fi

read_port_file() {
  _f=$1
  [ -f "$_f" ] || return 1
  _p=$("$BB" sed -n 's/^PORTAL_PORT=//p' "$_f" 2>/dev/null | "$BB" head -n 1 | "$BB" tr -d '\r')
  case "$_p" in
    ''|*[!0-9]*) return 1 ;;
  esac
  PORT=$_p
  return 0
}

PORT=8080
if [ -n "${RNS_PORT:-}" ]; then
  case "$RNS_PORT" in
    *[!0-9]*) ;;
    *) PORT=$RNS_PORT ;;
  esac
else
  read_port_file "$STATE/page.env" \
    || read_port_file "$STATE/config.env" \
    || read_port_file /data/adb/rns/page.env \
    || read_port_file /data/adb/rns/config.env \
    || true
fi

if [ -w /data/local/tmp ]; then
  LOG=/data/local/tmp/rns_hotspot.log
else
  LOG="$STATE/pages.log"
fi

logp() {
  _ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)
  printf '%s %s\n' "$_ts" "$*" >> "$LOG" 2>/dev/null || true
}

pick_httpd() {
  # Print the first listener binary that actually executes. The ABI property
  # can lie (32-bit userspace on a 64-bit kernel is common on budget
  # phones), so the exact ABI match is only the first candidate — every
  # shipped binary gets a --check run before we fall back to busybox nc.
  _abi=""
  if command -v getprop >/dev/null 2>&1; then
    _abi=$(getprop ro.product.cpu.abi 2>/dev/null)
  fi
  case "$_abi" in
    arm64*)        set -- arm64 arm x86_64 ;;
    armeabi*|arm*) set -- arm arm64 x86_64 ;;
    x86_64)        set -- x86_64 arm64 arm ;;
    *)             set -- arm64 arm x86_64 ;;
  esac
  for _a in "$@"; do
    _b="$RNS_HOME/bin/rns-httpd-$_a"
    if [ -x "$_b" ] && "$_b" --check >/dev/null 2>&1; then
      printf '%s' "$_b"
      return 0
    fi
  done
  return 1
}

HANDLER="$RNS_HOME/bin/rns-front.sh"
printf '%s\n' "$PORT" > "$STATE/portal.port" 2>/dev/null || true

record_engine() {
  # The page shell and diagnostics read this to say which listener serves.
  printf '%s\n' "$1" > "$STATE/httpd.engine" 2>/dev/null || true
  printf '%s\n' "$1" > "$RNS_HOME/engine" 2>/dev/null || true
}

pid_alive() {
  [ -f "$STATE/httpd.pid" ] || return 1
  _pid=$(cat "$STATE/httpd.pid" 2>/dev/null)
  case "$_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$_pid" 2>/dev/null
}

if pid_alive && [ -f "$STATE/httpd.mode" ] && [ "$(cat "$STATE/httpd.mode" 2>/dev/null)" = "front" ]; then
  # A healthy page listener is already up. One exception: a busybox nc
  # fallback serves one connection at a time and cannot see client
  # addresses by itself — upgrade it to a real binary the moment one works.
  _eng=$(cat "$STATE/httpd.engine" 2>/dev/null)
  if [ "$_eng" = "busybox-nc" ] && _upbin=$(pick_httpd); then
    logp "upgrading busybox nc fallback to $_upbin"
    _old=$(cat "$STATE/httpd.pid" 2>/dev/null)
    kill "$_old" 2>/dev/null || true
    sleep 1
    kill -9 "$_old" 2>/dev/null || true
  else
    logp "pages already listening port=$PORT pid=$(cat "$STATE/httpd.pid" 2>/dev/null) engine=${_eng:-unknown}"
    exit 0
  fi
fi

if pid_alive; then
  _old=$(cat "$STATE/httpd.pid" 2>/dev/null)
  logp "replacing listener that is not the isolated page shell pid=$_old"
  kill "$_old" 2>/dev/null || true
  sleep 1
  kill -9 "$_old" 2>/dev/null || true
fi

# Detach a background program from the caller's session so the caller
# returning (Magisk Action, late_start service) cannot take the pages down.
# `setsid PROG` execs PROG, so $! is the program's own pid. Builds without
# setsid fall back to a HUP-ignoring subshell.
SETSID=""
for _c in "$BB" setsid /system/bin/setsid /usr/bin/setsid; do
  if "$_c" setsid true >/dev/null 2>&1; then
    SETSID="$_c setsid"
    break
  fi
done

launch() {
  # The listener must outlive whoever started it, so it gets its own session.
  if [ -n "$SETSID" ]; then
    # shellcheck disable=SC2086
    $SETSID "$@" >> "$LOG" 2>&1 < /dev/null &
  else
    (
      trap '' HUP
      exec "$@"
    ) >> "$LOG" 2>&1 < /dev/null &
  fi
  echo $! > "$STATE/httpd.pid"
  printf 'front\n' > "$STATE/httpd.mode"
  logp "pages listening 0.0.0.0:$PORT pid=$!"
}

if _bin=$(pick_httpd); then
  record_engine "rns-httpd ${_bin##*/}"
  logp "pages listener $_bin port=$PORT"
  launch "$_bin" "$PORT" "$HANDLER"
  exit 0
fi

logp "no rns-httpd binary would start — busybox nc fallback (page shell resolves client addresses itself)"
record_engine "busybox-nc"
_wrap="$STATE/nc-wrap.sh"
cat > "$_wrap" << EOF
#!/system/bin/sh
export RNS_HOME='$RNS_HOME'
export RNS_DATA='${RNS_DATA:-/data/adb/rns}'
export RNS_LAB='${RNS_LAB}'
export RNS_DATA_AUTO='${RNS_DATA_AUTO:-1}'
export BB='$BB'
export RNS_BB='$BB'
exec '$BB' sh '$HANDLER'
EOF
chmod 755 "$_wrap" 2>/dev/null || true
launch "$BB" nc -lk -p "$PORT" -e "$_wrap"
exit 0
