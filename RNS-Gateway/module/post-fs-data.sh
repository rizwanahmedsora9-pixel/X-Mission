#!/system/bin/sh
MODDIR=${0%/*}
mkdir -p /data/adb/rns/sessions /data/adb/rns/ratelimit
chmod 700 /data/adb/rns 2>/dev/null
# Do not patch hostapd here. The file does not exist until the hotspot starts,
# and MtkSoftApManager rewrites it. service.sh owns that race.
