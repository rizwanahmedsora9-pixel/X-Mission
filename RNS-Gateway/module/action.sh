#!/system/bin/sh
# Magisk "Action" button for Gateway 4.0.
# The old action fired am immediately, while service.sh was still waiting for
# Android to settle.  This one waits for the local listener and starts the
# browser as user 0, with fallbacks for Android builds that reject --user.

MODDIR=${0%/*}
export RNS_HOME="$MODDIR/rns"
export RNS_DATA=${RNS_DATA:-/data/adb/rns}
export RNS_DATA_AUTO=1
export RNS_LAB=0

if [ -x /data/adb/magisk/busybox ]; then
  BB=/data/adb/magisk/busybox
else
  BB=busybox
fi
export BB
export RNS_BB=$BB

# common.sh also selects /sdcard/HotspotBilling when it is mounted, so the
# action checks the same PORTAL_PORT and data location as the daemon.
. "$RNS_HOME/bin/common.sh"
PORT=$(cfg_get PORTAL_PORT 8080)
case "$PORT" in
  ''|*[!0-9]*) PORT=8080 ;;
esac
URL="http://127.0.0.1:${PORT}/admin"
HEALTH="http://127.0.0.1:${PORT}/health"

probe_health() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --connect-timeout 1 --max-time 2 -o /dev/null "$HEALTH" >/dev/null 2>&1
    return $?
  fi
  if "$BB" wget --help >/dev/null 2>&1; then
    "$BB" wget -q -T 2 -O /dev/null "$HEALTH" >/dev/null 2>&1
    return $?
  fi
  if "$BB" nc -z -w 1 127.0.0.1 "$PORT" >/dev/null 2>&1; then
    return 0
  fi
  return 2
}

supervisor_alive() {
  [ -f "$RNS_DATA/rnsd.pid" ] || return 1
  _spid=$(cat "$RNS_DATA/rnsd.pid" 2>/dev/null)
  case "$_spid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$_spid" 2>/dev/null
}

ready=0
unsupported=0
i=0
while [ "$i" -lt 30 ]; do
  probe_health
  rc=$?
  if [ "$rc" -eq 0 ]; then
    ready=1
    break
  fi
  if [ "$rc" -eq 2 ]; then
    unsupported=1
    # There is no portable socket probe on every Android image. If the
    # supervisor is already alive, its listener is normally next; otherwise
    # break early so the on-demand start below can recover a missed service.
    if [ "$i" -ge 4 ]; then
      supervisor_alive && ready=1
      break
    fi
  fi
  i=$((i + 1))
  sleep 1
done

# If Magisk did not run service.sh (or the first boot was interrupted), start
# the same guarded supervisor on demand. rnsd.sh refuses a second live copy.
if [ "$ready" -eq 0 ] && [ -x "$RNS_HOME/bin/rnsd.sh" ]; then
  echo "RNS listener is not ready; starting the gateway supervisor..."
  "$BB" sh "$RNS_HOME/bin/rnsd.sh" >> /data/local/tmp/rns_hotspot.log 2>&1 &
  j=0
  while [ "$j" -lt 15 ]; do
    probe_health
    rc=$?
    if [ "$rc" -eq 0 ]; then
      ready=1
      break
    fi
    if [ "$rc" -eq 2 ] && [ "$j" -ge 4 ]; then
      unsupported=1
      ready=1
      break
    fi
    j=$((j + 1))
    sleep 1
  done
fi

AM=/system/bin/am
[ -x "$AM" ] || AM=am

start_browser() {
  "$AM" start --user 0 -a android.intent.action.VIEW \
    -c android.intent.category.BROWSABLE -d "$URL" >/dev/null 2>&1 && return 0
  # Android 9 variants differ on the placement/support of --user.
  "$AM" start -a android.intent.action.VIEW \
    -c android.intent.category.BROWSABLE -d "$URL" >/dev/null 2>&1 && return 0
  if command -v cmd >/dev/null 2>&1; then
    cmd activity start-activity --user 0 -a android.intent.action.VIEW \
      -c android.intent.category.BROWSABLE -d "$URL" >/dev/null 2>&1 && return 0
  fi
  return 1
}

if start_browser; then
  if [ "$ready" -eq 1 ]; then
    echo "RNS admin opened: $URL"
  elif [ "$unsupported" -eq 1 ]; then
    echo "RNS admin launch requested: $URL"
    echo "Listener probe is unavailable; if the page is blank, wait a few seconds and retry Action."
  else
    echo "RNS admin launch requested, but the listener did not answer: $URL"
    echo "Check /data/local/tmp/rns_hotspot.log"
  fi
else
  echo "Could not open a browser automatically. Open $URL manually."
  echo "Check /data/local/tmp/rns_hotspot.log"
fi
echo "Customer page: http://127.0.0.1:${PORT}/"
