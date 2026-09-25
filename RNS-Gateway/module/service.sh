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
  # Let the radio and netd settle before we touch ap0.
  sleep 12
  exec "$BB" sh "$RNS_HOME/bin/rnsd.sh"
) >> /data/local/tmp/rns_hotspot.log 2>&1 &
