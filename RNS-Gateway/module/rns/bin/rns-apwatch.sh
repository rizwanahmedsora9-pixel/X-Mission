#!/system/bin/sh
# Hotspot config watcher. Child process only. A failure here must not stop
# the admin panel or the captive portal.

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

. "$RNS_HOME/bin/net.sh"

if "$BB" --list 2>/dev/null | "$BB" grep -qx inotifyd; then
  _hook="${RNS_DATA}/ap-hook.sh"
  mkdir -p "$RNS_DATA" 2>/dev/null || true
  cat > "$_hook" << EOF
#!/system/bin/sh
export RNS_HOME='$RNS_HOME'
export RNS_DATA='$RNS_DATA'
export RNS_DATA_AUTO='${RNS_DATA_AUTO}'
export RNS_LAB='${RNS_LAB}'
export BB='$BB'
. '$RNS_HOME/bin/net.sh'
ap_watch_once
EOF
  chmod 755 "$_hook" 2>/dev/null || true
  mkdir -p /data/vendor/wifi/hostapd 2>/dev/null || true
  if [ -d /data/vendor/wifi/hostapd ]; then
    log_line "inotifyd on hostapd dir"
    exec "$BB" inotifyd "$_hook" /data/vendor/wifi/hostapd:nce
  fi
fi

while true; do
  ap_watch_once
  "$BB" usleep 200000 2>/dev/null || sleep 1
done
