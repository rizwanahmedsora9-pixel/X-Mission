#!/system/bin/sh
# Restore firewall rules for one already-bound device.
# Executed by the page shell only after rns-bound.sh says the device is
# paid, and only with a timeout. A failure here must not be sourced into
# the page shell — the caller shows the portal instead of pretending the
# gate was repaired.

_here=${0%/*}
export RNS_HOME=${RNS_HOME:-${_here%/*}}
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

. "$RNS_HOME/bin/net.sh" || exit 1
store_init || exit 1

_mac=$(printf '%s' "${1:-}" | "$BB" tr -cd '0-9a-f:')
_ip=$(printf '%s' "${2:-}" | "$BB" tr -cd '0-9.')
[ -n "$_mac" ] || exit 1
client_touch "$_mac" "$_ip" "" || true
with_lock voucher_set_ip "$_mac" "$_ip" >/dev/null 2>&1 || true
gate_heal
