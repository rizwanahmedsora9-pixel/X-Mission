#!/system/bin/sh
# One-shot wall-clock expiry enforcement.
# Executed (never sourced) by the page shell as a detached child whenever an
# unpaid device shows up at the sign-in page, and by rns-ctl.sh. It is the
# safety net for the 15-second supervisor sweep: even if rnsd.sh is dead,
# a voucher whose time is over loses its firewall allow and the device is
# knocked off so its next captive check lands on the portal.
#
# Rate limited: at most one pass every RNS_EXPIRE_MIN_GAP seconds (default
# 10) so a burst of probes cannot stack iptables rebuilds.

_here=${0%/*}
export RNS_HOME=${RNS_HOME:-${_here%/*}}
export RNS_DATA=${RNS_DATA:-/data/adb/rns}
export RNS_DATA_AUTO=${RNS_DATA_AUTO:-1}
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

_gap=${RNS_EXPIRE_MIN_GAP:-10}
_stamp="$RNS_DATA/expire.stamp"
if [ "${1:-}" != "--force" ] && [ -f "$_stamp" ]; then
  _last=$(cat "$_stamp" 2>/dev/null)
  _now=$("$BB" date +%s 2>/dev/null || date +%s)
  case "$_last" in
    ''|*[!0-9]*) ;;
    *)
      if [ $((_now - _last)) -lt "$_gap" ]; then
        exit 0
      fi
      ;;
  esac
fi
mkdir -p "$RNS_DATA" 2>/dev/null || true
printf '%s\n' "$("$BB" date +%s 2>/dev/null || date +%s)" > "$_stamp" 2>/dev/null || true

. "$RNS_HOME/bin/net.sh" || exit 1
store_init || exit 1

_gone=$(expire_enforce)
if [ -n "$_gone" ]; then
  printf '%s\n' "$_gone"
fi
exit 0
