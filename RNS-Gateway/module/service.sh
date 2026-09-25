#!/system/bin/sh
# Magisk late_start. Must return quickly — the gateway runs in the background.
# The admin panel and captive portal are started before the supervisor, and
# they do not wait for /sdcard, hostapd, or voucher/firewall scripts.

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
export RNS_BB=$BB

mkdir -p "$RNS_DATA" /data/local/tmp
echo "$(date) RNS Gateway service.sh" >> /data/local/tmp/rns_hotspot.log

# Pages first. This call does not source function scripts.
"$BB" sh "$RNS_HOME/bin/rns-pages.sh" >> /data/local/tmp/rns_hotspot.log 2>&1 || true

# Detach the supervisor into its own session so this service returning cannot
# take it down. `setsid PROG` execs PROG. Without setsid, a HUP-ignoring
# subshell is used instead.
SETSID=""
for _c in "$BB" setsid /system/bin/setsid /usr/bin/setsid; do
  if "$_c" setsid true >/dev/null 2>&1; then
    SETSID="$_c setsid"
    break
  fi
done

if [ -n "$SETSID" ]; then
  # shellcheck disable=SC2086
  $SETSID "$BB" sh -c '
    sleep 2
    "$1" "$2" >> "$4" 2>&1 || true
    exec "$1" "$3" >> "$4" 2>&1
  ' rns-sup "$BB" "$RNS_HOME/bin/rns-gate-min.sh" "$RNS_HOME/bin/rnsd.sh" \
    /data/local/tmp/rns_hotspot.log &
else
  (
    trap '' HUP
    # Give Android a moment, then make sure the captive redirect exists even
    # if the supervisor's function scripts fail to load.
    sleep 2
    "$BB" sh "$RNS_HOME/bin/rns-gate-min.sh" >> /data/local/tmp/rns_hotspot.log 2>&1 || true
    exec "$BB" sh "$RNS_HOME/bin/rnsd.sh" >> /data/local/tmp/rns_hotspot.log 2>&1
  ) &
fi
