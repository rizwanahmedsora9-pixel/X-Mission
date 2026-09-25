#!/system/bin/sh
# Voucher sweep, firewall rebuild, and storage migration.
# Always executed as a child of rnsd.sh — never sourced.
# If this file fails, the page listener started by rns-pages.sh keeps running.

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

. "$RNS_HOME/bin/common.sh"
. "$RNS_HOME/bin/store.sh"
. "$RNS_HOME/bin/net.sh"

store_init

_port=$(cfg_get PORTAL_PORT 8080)
_lan=$(cfg_get ADMIN_LAN 0)
if mkdir -p /data/adb/rns 2>/dev/null; then
  printf 'PORTAL_PORT=%s\nADMIN_LAN=%s\n' "$_port" "$_lan" > /data/adb/rns/page.env 2>/dev/null || true
  if command -v ip >/dev/null 2>&1; then
    ip -4 -o addr show 2>/dev/null | "$BB" awk '{print $4}' | "$BB" cut -d/ -f1 > /data/adb/rns/phone.ips 2>/dev/null || true
  fi
fi

housekeeping
exit 0
