#!/system/bin/sh
# Magisk late_start. Must return quickly — the gateway runs in the background.

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

mkdir -p "$RNS_DATA" /data/local/tmp
echo "$(date) RNS Gateway service.sh" >> /data/local/tmp/rns_hotspot.log

(
  # The listener can be useful before the AP exists (the Action button uses
  # it), while the watcher itself waits for hostapd/ap0.  A short delay is
  # enough for Magisk and avoids the v3 Action race.
  sleep 3
  exec "$BB" sh "$RNS_HOME/bin/rnsd.sh"
) >> /data/local/tmp/rns_hotspot.log 2>&1 &
