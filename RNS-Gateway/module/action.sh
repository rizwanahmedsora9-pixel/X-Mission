#!/system/bin/sh
# Magisk Action. Opens the staff panel.
# Does not source common.sh, store.sh, or net.sh. Those files can be broken
# and this button must still start the page listener and open the browser.

MODDIR=${0%/*}
export RNS_HOME="$MODDIR/rns"
export RNS_DATA=${RNS_DATA:-/data/adb/rns}
export RNS_DATA_AUTO=${RNS_DATA_AUTO:-1}
export RNS_LAB=${RNS_LAB:-0}

if [ -x /data/adb/magisk/busybox ]; then
  BB=/data/adb/magisk/busybox
elif [ -x /usr/bin/busybox ]; then
  BB=/usr/bin/busybox
else
  BB=busybox
fi
export BB
export RNS_BB=$BB

mkdir -p /data/adb/rns /data/local/tmp 2>/dev/null || true

# A log that cannot be opened must never stop the pages from starting, so the
# redirect target is chosen defensively and the page launch is separate.
LOG=/data/local/tmp/rns_hotspot.log
if [ ! -d /data/local/tmp ] && ! mkdir -p /data/local/tmp 2>/dev/null; then
  LOG="$RNS_DATA/rns_hotspot.log"
  mkdir -p "$RNS_DATA" 2>/dev/null || true
fi

PORT=8080
if [ -n "${RNS_PORT:-}" ]; then
  case "$RNS_PORT" in
    *[!0-9]*) ;;
    *) PORT=$RNS_PORT ;;
  esac
elif [ -f /data/adb/rns/page.env ]; then
  _p=$("$BB" sed -n 's/^PORTAL_PORT=//p' /data/adb/rns/page.env 2>/dev/null | "$BB" head -n 1 | "$BB" tr -d '\r')
  case "$_p" in
    ''|*[!0-9]*) ;;
    *) PORT=$_p ;;
  esac
elif [ -f /data/adb/rns/config.env ]; then
  _p=$("$BB" sed -n 's/^PORTAL_PORT=//p' /data/adb/rns/config.env 2>/dev/null | "$BB" head -n 1 | "$BB" tr -d '\r')
  case "$_p" in
    ''|*[!0-9]*) ;;
    *) PORT=$_p ;;
  esac
fi
export RNS_PORT=$PORT

URL="http://127.0.0.1:${PORT}/admin"
HEALTH="http://127.0.0.1:${PORT}/health"

# Pages first, before the supervisor and before any voucher/firewall code.
# Each attempt is guarded: if the log cannot be written the pages still start.
start_pages() {
  "$BB" sh "$RNS_HOME/bin/rns-pages.sh" >> "$LOG" 2>&1 && return 0
  "$BB" sh "$RNS_HOME/bin/rns-pages.sh" >> /dev/null 2>&1 && return 0
  sh "$RNS_HOME/bin/rns-pages.sh" >> /dev/null 2>&1
}
start_pages || true

# Functions may start too, but the browser does not wait on them. The
# supervisor gets its own session (`setsid PROG` execs PROG, so $! is its pid)
# so this Action returning cannot kill it. Without setsid, a HUP-ignoring
# subshell is used instead.
if [ -x "$RNS_HOME/bin/rnsd.sh" ] || [ -f "$RNS_HOME/bin/rnsd.sh" ]; then
  SETSID=""
  for _c in "$BB" setsid /system/bin/setsid /usr/bin/setsid; do
    if "$_c" setsid true >/dev/null 2>&1; then
      SETSID="$_c setsid"
      break
    fi
  done
  if [ -n "$SETSID" ]; then
    # shellcheck disable=SC2086
    $SETSID "$BB" sh "$RNS_HOME/bin/rnsd.sh" \
      >> "$LOG" 2>&1 < /dev/null &
  else
    (
      trap '' HUP
      exec "$BB" sh "$RNS_HOME/bin/rnsd.sh"
    ) >> "$LOG" 2>&1 < /dev/null &
  fi
fi

probe_health() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --connect-timeout 1 --max-time 2 "$HEALTH" 2>/dev/null | "$BB" grep -q 'rns-front'
    return $?
  fi
  if "$BB" wget --help >/dev/null 2>&1; then
    "$BB" wget -q -T 2 -O - "$HEALTH" 2>/dev/null | "$BB" grep -q 'rns-front'
    return $?
  fi
  if "$BB" nc -z -w 1 127.0.0.1 "$PORT" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

ready=0
i=0
while [ "$i" -lt 8 ]; do
  if probe_health; then
    ready=1
    break
  fi
  i=$((i + 1))
  sleep 1
done

AM=/system/bin/am
[ -x "$AM" ] || AM=am

start_browser() {
  # Android 9 / Infinix builds disagree about --user and which browser is
  # the default. Try the generic view first, then known browser components.
  "$AM" start --user 0 -f 0x14000000 -a android.intent.action.VIEW \
    -c android.intent.category.BROWSABLE -d "$URL" >/dev/null 2>&1 && return 0
  "$AM" start -f 0x10000000 -a android.intent.action.VIEW \
    -c android.intent.category.BROWSABLE -d "$URL" >/dev/null 2>&1 && return 0
  if command -v cmd >/dev/null 2>&1; then
    cmd activity start-activity --user 0 -a android.intent.action.VIEW \
      -c android.intent.category.BROWSABLE -d "$URL" >/dev/null 2>&1 && return 0
  fi
  for _comp in \
    com.android.chrome/com.google.android.apps.chrome.Main \
    com.android.browser/.BrowserActivity \
    com.android.chrome/com.google.android.apps.chrome.IntentDispatcher \
    mark.via/.Shell
  do
    "$AM" start --user 0 -n "$_comp" -a android.intent.action.VIEW -d "$URL" >/dev/null 2>&1 && return 0
  done
  return 1
}

if start_browser; then
  if [ "$ready" -eq 1 ]; then
    echo "RNS admin opened: $URL"
  else
    echo "RNS admin launch requested: $URL"
    echo "If the page is blank, wait two seconds and tap Action again."
  fi
else
  echo "Could not open a browser automatically."
  echo "Open this on the phone browser: $URL"
fi
echo "If Magisk stays in front, switch to the browser. The panel is already running."
echo "Customer sign-in page: http://127.0.0.1:${PORT}/"
echo "Log: $LOG"
