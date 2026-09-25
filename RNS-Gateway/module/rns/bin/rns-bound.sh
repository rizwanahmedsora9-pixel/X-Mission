#!/system/bin/sh
# Fast "does this client already hold a voucher?" check.
# Executed by the page shell with a short timeout. Never sourced.
# If this script or the store is broken, it must fail closed (print nothing
# and exit non-zero) so the page shell still shows the captive portal.

_here=${0%/*}
export RNS_HOME=${RNS_HOME:-${_here%/*}}
export RNS_DATA=${RNS_DATA:-/data/adb/rns}
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

. "$RNS_HOME/bin/store.sh" || exit 1
store_init || exit 1

_ip=$(printf '%s' "${1:-}" | "$BB" tr -cd '0-9a-fA-F.:')
[ -n "$_ip" ] || { printf 'free\n'; exit 0; }
_mac=$(mac_for_ip "$_ip" 2>/dev/null) || _mac=""
[ -n "$_mac" ] || { printf 'free\n'; exit 0; }
_row=$(voucher_for_mac "$_mac" 2>/dev/null) || _row=""
if [ -n "$_row" ]; then
  printf 'bound|%s\n' "$_mac"
else
  printf 'free\n'
fi
exit 0
