#!/system/bin/sh
MODDIR=${0%/*}
export RNS_HOME="$MODDIR/rns"
export RNS_DATA=/data/adb/rns
export RNS_DATA_AUTO=1
export RNS_LAB=0
if [ -x /data/adb/magisk/busybox ]; then
  BB=/data/adb/magisk/busybox
else
  BB=busybox
fi
export BB
. "$RNS_HOME/bin/common.sh"

if [ -f "$RNS_DATA/rnsd.pid" ]; then
  kill "$(cat "$RNS_DATA/rnsd.pid")" 2>/dev/null
fi
if [ -f "$RNS_DATA/httpd.pid" ]; then
  kill "$(cat "$RNS_DATA/httpd.pid")" 2>/dev/null
fi
if [ -f "$RNS_DATA/apwatch.pid" ]; then
  kill "$(cat "$RNS_DATA/apwatch.pid")" 2>/dev/null
fi

if [ -f "$RNS_HOME/bin/net.sh" ]; then
  . "$RNS_HOME/bin/net.sh"
  fw_clear
fi

# Vouchers stay in /data/adb/rns so a reinstall does not wipe the shop.
# To wipe them too, create /data/adb/rns/PURGE before uninstalling.
if [ -f "$RNS_DATA/PURGE" ]; then
  rm -rf "$RNS_DATA"
fi
