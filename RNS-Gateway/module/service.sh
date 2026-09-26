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

mkdir -p "$RNS_DATA" /data/local/tmp 2>/dev/null || true

# A log that cannot be opened must never stop the pages from starting.
LOG=/data/local/tmp/rns_hotspot.log
if [ ! -d /data/local/tmp ] && ! mkdir -p /data/local/tmp 2>/dev/null; then
  LOG="$RNS_DATA/rns_hotspot.log"
fi
echo "$(date) RNS Gateway service.sh" >> "$LOG" 2>/dev/null || true

# Pages first. This call does not source function scripts.
"$BB" sh "$RNS_HOME/bin/rns-pages.sh" >> "$LOG" 2>&1 || \
  "$BB" sh "$RNS_HOME/bin/rns-pages.sh" >> /dev/null 2>&1 || true

# The captive redirect goes in NOW, not two seconds from now. A customer
# phone that associates in the boot window must never see an unprotected
# probe escape to the internet — that is what makes Android mark the network
# "validated" and skip the sign-in sheet forever. rns-gate-min.sh only adds
# missing rules and never flushes, so running it early is always safe.
"$BB" sh "$RNS_HOME/bin/rns-gate-min.sh" >> "$LOG" 2>&1 || \
  "$BB" sh "$RNS_HOME/bin/rns-gate-min.sh" >> /dev/null 2>&1 || true

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
  # Args: $1=gate-min  $2=supervisor  $3=log. RNS_BB comes from the
  # environment so it works whether busybox is an absolute path or a PATH
  # lookup — `sh busybox script` would try to read busybox as a script.
  $SETSID "$BB" sh -c '
    sleep 2
    "$RNS_BB" sh "$1" >> "$3" 2>&1 || true
    exec "$RNS_BB" sh "$2" >> "$3" 2>&1
  ' rns-sup "$RNS_HOME/bin/rns-gate-min.sh" "$RNS_HOME/bin/rnsd.sh" "$LOG" &
else
  (
    trap '' HUP
    # Give Android a moment, then make sure the captive redirect exists even
    # if the supervisor's function scripts fail to load.
    sleep 2
    "$BB" sh "$RNS_HOME/bin/rns-gate-min.sh" >> "$LOG" 2>&1 || true
    exec "$BB" sh "$RNS_HOME/bin/rnsd.sh" >> "$LOG" 2>&1
  ) &
fi
