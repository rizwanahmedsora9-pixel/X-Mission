#!/system/bin/sh
# Supervisor. Started from Magisk service.sh. Restarts the portal if it dies.

_here=${0%/*}
# This file is $RNS_HOME/bin/rnsd.sh. Keep an exported RNS_HOME from service.sh.
if [ -z "$RNS_HOME" ]; then
  RNS_HOME=${_here%/*}
fi
export RNS_HOME
export RNS_DATA=${RNS_DATA:-/data/adb/rns}
export RNS_LAB=${RNS_LAB:-0}

if [ -z "$BB" ]; then
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

. "$RNS_HOME/bin/common.sh"
. "$RNS_HOME/bin/store.sh"
. "$RNS_HOME/bin/net.sh"

store_init

# The Magisk service and the Action fallback can both race during boot. Keep
# one supervisor per data directory so a second copy cannot fight over the
# HTTP port or repeatedly rebuild the firewall. A stale pid is harmless and
# is replaced when the process no longer exists.
SUP_PID="$RNS_DATA/rnsd.pid"
if [ -f "$SUP_PID" ]; then
  _old_super=$(cat "$SUP_PID" 2>/dev/null)
  case "$_old_super" in
    ''|*[!0-9]*) ;;
    *)
      if [ "$_old_super" != "$$" ] && kill -0 "$_old_super" 2>/dev/null; then
        log_line "rnsd already running pid=$_old_super"
        exit 0
      fi
      ;;
  esac
fi
printf '%s\n' "$$" > "$SUP_PID" 2>/dev/null || true

pick_httpd() {
  _abi=""
  if command -v getprop >/dev/null 2>&1; then
    _abi=$(getprop ro.product.cpu.abi 2>/dev/null)
  fi
  case "$_abi" in
    arm64*) printf '%s/bin/rns-httpd-arm64' "$RNS_HOME"; return ;;
    armeabi*|arm) printf '%s/bin/rns-httpd-arm' "$RNS_HOME"; return ;;
    x86_64) printf '%s/bin/rns-httpd-x86_64' "$RNS_HOME"; return ;;
  esac
  case "$(uname -m 2>/dev/null)" in
    aarch64) printf '%s/bin/rns-httpd-arm64' "$RNS_HOME" ;;
    armv7*|armv8l|arm) printf '%s/bin/rns-httpd-arm' "$RNS_HOME" ;;
    x86_64) printf '%s/bin/rns-httpd-x86_64' "$RNS_HOME" ;;
    *) printf '%s/bin/rns-httpd-arm64' "$RNS_HOME" ;;
  esac
}

httpd_alive() {
  [ -f "$RNS_DATA/httpd.pid" ] || return 1
  _pid=$(cat "$RNS_DATA/httpd.pid" 2>/dev/null)
  [ -n "$_pid" ] || return 1
  kill -0 "$_pid" 2>/dev/null
}

runtime_repair() {
  # Recreate runtime folders/files after a partial cleanup or storage remount.
  _before="$RNS_DATA/.runtime-ready"
  mkdir -p "$RNS_DATA" "$RNS_DB_DIR" "$RNS_LOG_DIR" "$RNS_DATA/backups" "$RNS_DATA/exports" "$RNS_DATA/sessions" "$RNS_DATA/ratelimit" 2>/dev/null || true
  store_init
  if [ ! -f "$_before" ]; then
    printf '%s\n' "$(now_epoch)" > "$_before" 2>/dev/null || true
    log_line "runtime storage repaired at $RNS_DATA"
  fi
}

runtime_repair
log_line "rnsd started home=$RNS_HOME data=$RNS_DATA"

start_httpd() {
  if httpd_alive; then
    return 0
  fi
  _port=$(cfg_get PORTAL_PORT 8080)
  _bin=$(pick_httpd)
  if [ -x "$_bin" ] && "$_bin" --check >/dev/null 2>&1; then
    "$_bin" "$_port" "$RNS_HOME/bin/rns-http.sh" >> "$LOG" 2>&1 &
    echo $! > "$RNS_DATA/httpd.pid"
    log_line "portal listening 0.0.0.0:$_port via $_bin pid $!"
    return 0
  fi
  log_line "rns-httpd unusable ($_bin) — falling back to busybox nc"
  _wrap="$RNS_DATA/nc-wrap.sh"
  cat > "$_wrap" << EOF
#!/system/bin/sh
export RNS_HOME='$RNS_HOME'
export RNS_DATA='$RNS_DATA'
export RNS_LAB='${RNS_LAB}'
export BB='$BB'
export RNS_BB='$BB'
exec '$BB' sh '$RNS_HOME/bin/rns-http.sh'
EOF
  chmod 755 "$_wrap" 2>/dev/null
  "$BB" nc -lk -p "$_port" -e "$_wrap" >> "$LOG" 2>&1 &
  echo $! > "$RNS_DATA/httpd.pid"
  log_line "portal nc pid $! port $_port"
}

# Fast AP patcher. inotifyd on Magisk busybox, poll otherwise.
(
  if "$BB" --list 2>/dev/null | "$BB" grep -qx inotifyd; then
    _hook="$RNS_DATA/ap-hook.sh"
    cat > "$_hook" << EOF
#!/system/bin/sh
export RNS_HOME='$RNS_HOME'
export RNS_DATA='$RNS_DATA'
export BB='$BB'
. '$RNS_HOME/bin/net.sh'
ap_watch_once
EOF
    chmod 755 "$_hook"
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
) &
echo $! > "$RNS_DATA/apwatch.pid"

while true; do
  runtime_repair
  start_httpd
  housekeeping
  sleep 15
done
