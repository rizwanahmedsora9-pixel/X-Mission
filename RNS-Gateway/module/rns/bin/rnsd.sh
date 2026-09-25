#!/system/bin/sh
# Supervisor. Pages are started before any voucher or firewall script is read.
# This process must stay alive even when function scripts have a syntax error.

_here=${0%/*}
if [ -z "${RNS_HOME:-}" ]; then
  RNS_HOME=${_here%/*}
fi
export RNS_HOME
export RNS_DATA=${RNS_DATA:-/data/adb/rns}
export RNS_LAB=${RNS_LAB:-0}
export RNS_DATA_AUTO=${RNS_DATA_AUTO:-1}

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

if [ "$RNS_LAB" = "1" ] && [ -n "$RNS_DATA" ]; then
  SUP_DIR=$RNS_DATA
else
  SUP_DIR=/data/adb/rns
fi
mkdir -p "$SUP_DIR" 2>/dev/null || true
SUP_PID="$SUP_DIR/rnsd.pid"

# Never let a missing log directory take the supervisor down with it.
SUP_LOG=/data/local/tmp/rns_hotspot.log
if [ ! -d /data/local/tmp ] && ! mkdir -p /data/local/tmp 2>/dev/null; then
  SUP_LOG="$SUP_DIR/rnsd.log"
fi

if [ -f "$SUP_PID" ]; then
  _old=$(cat "$SUP_PID" 2>/dev/null)
  case "$_old" in
    ''|*[!0-9]*) ;;
    *)
      if [ "$_old" != "$$" ] && kill -0 "$_old" 2>/dev/null; then
        printf '%s rnsd already running pid=%s\n' "$(date 2>/dev/null || echo now)" "$_old" >> "$SUP_LOG" 2>/dev/null || true
        exit 0
      fi
      ;;
  esac
fi
printf '%s\n' "$$" > "$SUP_PID" 2>/dev/null || true

# Bind admin + captive portal before touching function code.
"$BB" sh "$RNS_HOME/bin/rns-pages.sh" || true

# Detach background children into their own session so the caller (Magisk
# Action, late_start service) exiting cannot kill them. `setsid PROG` execs
# PROG, so $! is the child's own pid. Without setsid, a HUP-ignoring subshell
# is used instead.
SETSID=""
for _c in "$BB" setsid /system/bin/setsid /usr/bin/setsid; do
  if "$_c" setsid true >/dev/null 2>&1; then
    SETSID="$_c setsid"
    break
  fi
done

start_apwatch() {
  _ap="$SUP_DIR/apwatch.pid"
  if [ -f "$_ap" ]; then
    _p=$(cat "$_ap" 2>/dev/null)
    case "$_p" in
      ''|*[!0-9]*) ;;
      *)
        kill -0 "$_p" 2>/dev/null && return 0
        ;;
    esac
  fi
  if [ -n "$SETSID" ]; then
    # shellcheck disable=SC2086
    $SETSID "$BB" sh "$RNS_HOME/bin/rns-apwatch.sh" \
      >> "$SUP_LOG" 2>&1 < /dev/null &
  else
    (
      trap '' HUP
      exec "$BB" sh "$RNS_HOME/bin/rns-apwatch.sh"
    ) >> "$SUP_LOG" 2>&1 < /dev/null &
  fi
  echo $! > "$_ap" 2>/dev/null || true
}

# Pages, then functions. The worker runs before the minimum gate so a failed
# firewall rebuild is immediately followed by the captive redirect in the same
# pass — the sign-in page is never left unreachable while a flush is in flight.
while true; do
  "$BB" sh "$RNS_HOME/bin/rns-pages.sh" || true
  "$BB" sh "$RNS_HOME/bin/rns-worker.sh" || true
  "$BB" sh "$RNS_HOME/bin/rns-gate-min.sh" || true
  start_apwatch || true
  sleep 15
done
