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

for _pidf in \
  "$RNS_DATA/rnsd.pid" "$RNS_DATA/httpd.pid" "$RNS_DATA/apwatch.pid" \
  /data/adb/rns/rnsd.pid /data/adb/rns/httpd.pid /data/adb/rns/apwatch.pid
do
  if [ -f "$_pidf" ]; then
    kill "$(cat "$_pidf")" 2>/dev/null || true
  fi
done

if [ -f "$RNS_HOME/bin/net.sh" ]; then
  . "$RNS_HOME/bin/net.sh"
  fw_clear
fi

# Vouchers stay in /data/adb/rns so a reinstall does not wipe the shop.
# To wipe them too, create /data/adb/rns/PURGE before uninstalling.
if [ -f "$RNS_DATA/PURGE" ]; then
  rm -rf "$RNS_DATA"
fi
