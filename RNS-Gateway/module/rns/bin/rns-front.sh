#!/system/bin/sh
# ISOLATED PAGE SHELL.
# This file serves the staff admin panel and the customer captive portal.
# Do not source store.sh, net.sh, common.sh, or rns-http.sh from here.
# A syntax error or a hang in voucher, firewall, or UI function code must
# not stop these two pages. tools/isolate-check.sh enforces that rule.
#
# The listener (rns-pages.sh) execs this script for every connection.
# /api/* is handed to rns-http.sh in a child. If that child is broken, the
# browser still gets a complete response and the pages stay on screen.

_here=${0%/*}
if [ -z "${RNS_HOME:-}" ]; then
  RNS_HOME=${_here%/*}
fi
export RNS_HOME
RNS_WWW="$RNS_HOME/www"

# The page shell itself never writes to the voucher store, but the /api child
# and the bound/heal helpers need to know where it lives. Default it here so a
# standalone start still hands the right path to the function code.
if [ -z "${RNS_DATA:-}" ]; then
  RNS_DATA=/data/adb/rns
fi
export RNS_DATA
export RNS_LAB=${RNS_LAB:-0}
export RNS_DATA_AUTO=${RNS_DATA_AUTO:-1}

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

if [ "${RNS_LAB:-0}" = "1" ] && [ -n "${RNS_DATA:-}" ]; then
  SPOOL=$RNS_DATA
  mkdir -p "$SPOOL" 2>/dev/null || SPOOL=/tmp
elif mkdir -p /data/local/tmp 2>/dev/null && [ -w /data/local/tmp ]; then
  SPOOL=/data/local/tmp
else
  SPOOL=/tmp
  mkdir -p "$SPOOL" 2>/dev/null || true
fi

TO_STYLE=manual
_help=$("$BB" timeout --help 2>&1 || true)
case "$_help" in
  *"-t SECS"*|*"[-t "*) TO_STYLE=t ;;
  *SECS*) TO_STYLE=secs ;;
esac

run_limited() {
  _secs=$1
  shift
  case "$TO_STYLE" in
    t) "$BB" timeout -t "$_secs" "$@" ;;
    secs) "$BB" timeout "$_secs" "$@" ;;
    *)
      "$@" &
      _p=$!
      _i=0
      while [ "$_i" -lt "$_secs" ]; do
        if ! kill -0 "$_p" 2>/dev/null; then
          wait "$_p"
          return $?
        fi
        sleep 1
        _i=$((_i + 1))
      done
      kill "$_p" 2>/dev/null || true
      sleep 1
      kill -9 "$_p" 2>/dev/null || true
      wait "$_p" 2>/dev/null || true
      return 124
      ;;
  esac
}

send_headers() {
  _status=$1
  _ctype=$2
  _len=$3
  printf 'HTTP/1.0 %s\r\n' "$_status"
  printf 'Content-Type: %s\r\n' "$_ctype"
  printf 'Content-Length: %s\r\n' "$_len"
  printf 'Connection: close\r\n'
  printf 'Cache-Control: no-store, no-cache, must-revalidate\r\n'
  printf 'X-Content-Type-Options: nosniff\r\n'
  printf 'X-RNS-Front: 1\r\n'
  printf '\r\n'
}

send_bytes() {
  _status=$1
  _ctype=$2
  _body=$3
  _len=$(printf '%s' "$_body" | "$BB" wc -c | "$BB" tr -d ' ')
  send_headers "$_status" "$_ctype" "$_len"
  [ "${RNS_METHOD:-GET}" = "HEAD" ] || printf '%s' "$_body"
}

send_file() {
  _status=$1
  _ctype=$2
  _file=$3
  if [ ! -s "$_file" ]; then
    return 1
  fi
  _len=$("$BB" wc -c < "$_file" | "$BB" tr -d ' ')
  send_headers "$_status" "$_ctype" "$_len"
  [ "${RNS_METHOD:-GET}" = "HEAD" ] || cat "$_file"
  return 0
}

send_no_content() {
  printf 'HTTP/1.0 204 No Content\r\n'
  printf 'Connection: close\r\n'
  printf 'Cache-Control: no-store, no-cache, must-revalidate\r\n'
  printf 'X-RNS-Front: 1\r\n'
  printf '\r\n'
}

fallback_portal() {
  cat << 'EOF'
<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>RNS</title>
<style>body{margin:0;font-family:sans-serif;background:#10283c;color:#123}main{max-width:420px;margin:8vh auto;background:#fff;border-radius:18px;padding:24px}h1{margin:0 0 8px}input,button{font:inherit;width:100%;box-sizing:border-box}input{padding:14px;font-size:22px;letter-spacing:.12em;text-align:center}button{margin-top:12px;padding:14px;border:0;background:#0d777c;color:#fff;font-weight:700}</style>
</head><body><main>
<h1>Welcome online.</h1>
<p>Enter the voucher from the counter. One code unlocks this phone.</p>
<form method="post" action="/api/redeem"><input name="code" autocomplete="one-time-code" maxlength="16" placeholder="ABCD-1234" required><button type="submit">Connect securely</button></form>
</main></body></html>
EOF
}

fallback_admin() {
  cat << 'EOF'
<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>RNS Gateway · Staff</title>
<style>body{margin:0;font-family:sans-serif;background:#07131f;color:#f5fafb}main{max-width:420px;margin:10vh auto;padding:28px;border:1px solid rgba(255,255,255,.15);border-radius:20px}h1{margin:0 0 8px}p{color:#a6bac4;line-height:1.4}code{color:#70e4db}</style>
</head><body><main>
<h1 id="gateTitle">Staff login</h1>
<p>The staff panel shell is open. The full panel file could not be loaded, so this fallback is showing instead. Voucher tools come back when gateway functions are healthy.</p>
<p>On the shop phone open <code>http://127.0.0.1:8080/admin</code></p>
</main></body></html>
EOF
}

send_portal() {
  if ! send_file "200 OK" "text/html; charset=utf-8" "$RNS_WWW/portal.html"; then
    _tmp="$SPOOL/rns-portal-fb.$$"
    fallback_portal > "$_tmp"
    send_file "200 OK" "text/html; charset=utf-8" "$_tmp" || send_bytes "200 OK" "text/html; charset=utf-8" "Welcome online."
    rm -f "$_tmp"
  fi
}

send_admin() {
  if ! send_file "200 OK" "text/html; charset=utf-8" "$RNS_WWW/admin.html"; then
    _tmp="$SPOOL/rns-admin-fb.$$"
    fallback_admin > "$_tmp"
    send_file "200 OK" "text/html; charset=utf-8" "$_tmp" || send_bytes "200 OK" "text/html; charset=utf-8" "Staff login"
    rm -f "$_tmp"
  fi
}

send_api_down() {
  case "${RNS_ACCEPT:-}" in
    *application/json*)
      send_bytes "200 OK" "application/json; charset=utf-8" '{"ok":false,"error":"Gateway functions are unavailable. The admin panel and captive portal are still up.","pages":true}'
      ;;
    *)
      send_bytes "200 OK" "text/html; charset=utf-8" '<!doctype html><html><body><h1>Welcome online.</h1><p>The sign-in page is up. Voucher check is not answering yet. Wait a few seconds and try again.</p><p><a href="/">Back</a></p></body></html>'
      ;;
  esac
}

is_shop_ip() {
  _ip=$1
  if [ "${RNS_LAB:-0}" = "1" ]; then
    return 0
  fi
  case "$_ip" in
    127.*|::1|192.168.43.1|192.168.42.1|192.168.49.1) return 0 ;;
    "") return 1 ;;
  esac
  if [ -f /data/adb/rns/page.env ] && "$BB" grep -q '^ADMIN_LAN=1' /data/adb/rns/page.env 2>/dev/null; then
    return 0
  fi
  if [ -f /data/adb/rns/phone.ips ] && "$BB" grep -qx "$_ip" /data/adb/rns/phone.ips 2>/dev/null; then
    return 0
  fi
  return 1
}

is_probe() {
  case "$1" in
    /generate_204|/gen_204|/generate204|/hotspot-detect.html|/library/test/success.html|/ncsi.txt|/connecttest.txt|/success.txt|/canonical.html|/check_network_status.txt|/kindle-wifi/wifistub.html|/connectivity-check.html)
      return 0
      ;;
  esac
  return 1
}

read_request() {
  IFS= read -r RNS_REQ || return 1
  RNS_REQ=$(printf '%s' "$RNS_REQ" | "$BB" tr -d '\r')
  RNS_METHOD=$(printf '%s' "$RNS_REQ" | "$BB" awk '{print $1}')
  RNS_TARGET=$(printf '%s' "$RNS_REQ" | "$BB" awk '{print $2}')
  RNS_PATH=${RNS_TARGET%%\?*}
  RNS_QUERY=""
  case "$RNS_TARGET" in
    *\?*) RNS_QUERY=${RNS_TARGET#*\?} ;;
  esac
  case "$RNS_PATH" in
    /) ;;
    */) RNS_PATH=${RNS_PATH%/} ;;
  esac
  RNS_CL=0
  RNS_COOKIE=""
  RNS_ACCEPT=""
  RNS_HOST=""
  while IFS= read -r _line; do
    _line=$(printf '%s' "$_line" | "$BB" tr -d '\r')
    [ -z "$_line" ] && break
    _lk=$(printf '%s' "$_line" | "$BB" cut -d: -f1 | "$BB" tr 'A-Z' 'a-z')
    _lv=$(printf '%s' "$_line" | "$BB" cut -d: -f2- | "$BB" sed 's/^ *//')
    case "$_lk" in
      content-length) RNS_CL=$_lv ;;
      cookie) RNS_COOKIE=$_lv ;;
      accept) RNS_ACCEPT=$_lv ;;
      host) RNS_HOST=$_lv ;;
    esac
  done
  RNS_BODY=""
  case "$RNS_CL" in
    ''|*[!0-9]*) RNS_CL=0 ;;
  esac
  if [ "$RNS_CL" -gt 8192 ]; then
    RNS_CL=8192
  fi
  if [ "$RNS_CL" -gt 0 ]; then
    RNS_BODY=$("$BB" dd bs=1 count="$RNS_CL" 2>/dev/null || true)
  fi
  [ -n "$RNS_METHOD" ] || return 1
  return 0
}

delegate_api() {
  _api="$RNS_HOME/bin/rns-http.sh"
  _out="$SPOOL/rns-api.$$"
  _err="$SPOOL/rns-api-err.$$"
  if [ ! -f "$_api" ]; then
    send_api_down
    rm -f "$_out" "$_err"
    return 0
  fi
  if ! "$BB" sh -n "$_api" >/dev/null 2>"$_err"; then
    send_api_down
    rm -f "$_out" "$_err"
    return 0
  fi
  export RNS_DELEGATED=1
  export RNS_METHOD RNS_PATH RNS_QUERY RNS_BODY RNS_COOKIE RNS_ACCEPT RNS_HOST RNS_CL
  # The function child needs the same identity, lab flag, and data dir as the
  # page shell, or vouchers would be read from the wrong place.
  export CLIENT_IP RNS_LAB RNS_DATA RNS_DATA_AUTO
  export RNS_HOME BB RNS_BB
  if ! run_limited 12 "$BB" sh "$_api" >"$_out" 2>>"$_err"; then
    if [ -s "$_out" ] && "$BB" grep -q '^HTTP/' "$_out" 2>/dev/null; then
      cat "$_out"
    else
      send_api_down
    fi
    rm -f "$_out" "$_err"
    return 0
  fi
  if [ -s "$_out" ] && "$BB" grep -q '^HTTP/' "$_out" 2>/dev/null; then
    cat "$_out"
  else
    send_api_down
  fi
  rm -f "$_out" "$_err"
}

bound_mac() {
  _ip=$1
  [ -n "$_ip" ] || return 1
  [ -f "$RNS_HOME/bin/rns-bound.sh" ] || return 1
  _out=$(run_limited 2 "$BB" sh "$RNS_HOME/bin/rns-bound.sh" "$_ip" 2>/dev/null || true)
  case "$_out" in
    bound\|*)
      printf '%s' "$_out" | "$BB" cut -d'|' -f2 | "$BB" tr -cd '0-9a-f:'
      return 0
      ;;
  esac
  return 1
}

heal_ok() {
  _mac=$1
  _ip=$2
  [ -n "$_mac" ] || return 1
  [ -f "$RNS_HOME/bin/rns-heal.sh" ] || return 1
  run_limited 4 "$BB" sh "$RNS_HOME/bin/rns-heal.sh" "$_mac" "$_ip" >/dev/null 2>&1
}

if ! read_request; then
  exit 0
fi

case "$RNS_PATH" in
  /favicon.ico)
    send_no_content
    ;;
  /health)
    send_bytes "200 OK" "application/json; charset=utf-8" '{"ok":true,"service":"rns-front","pages":true,"admin":true,"portal":true}'
    ;;
  /admin)
    if ! is_shop_ip "${CLIENT_IP:-}"; then
      send_bytes "200 OK" "text/html; charset=utf-8" '<!doctype html><html><body><h1>Staff only</h1><p>Open this page on the shop phone: http://127.0.0.1:8080/admin</p></body></html>'
      exit 0
    fi
    send_admin
    ;;
  /)
    send_portal
    ;;
  /api/*)
    delegate_api
    ;;
  *)
    if is_probe "$RNS_PATH"; then
      _mac=$(bound_mac "${CLIENT_IP:-}" || true)
      if [ -n "$_mac" ] && heal_ok "$_mac" "${CLIENT_IP:-}"; then
        send_no_content
        exit 0
      fi
      send_portal
      exit 0
    fi
    _mac=$(bound_mac "${CLIENT_IP:-}" || true)
    if [ -n "$_mac" ] && heal_ok "$_mac" "${CLIENT_IP:-}"; then
      _host=$(printf '%s' "${RNS_HOST:-}" | "$BB" tr -cd 'A-Za-z0-9.:_-' | "$BB" cut -c1-253)
      case "$_host" in
        ""|127.*|localhost|192.168.43.1|192.168.42.1)
          send_portal
          ;;
        *)
          _u="http://${_host}${RNS_PATH}"
          [ -n "$RNS_QUERY" ] && _u="${_u}?${RNS_QUERY}"
          printf 'HTTP/1.0 302 Found\r\n'
          printf 'Location: %s\r\n' "$_u"
          printf 'Content-Length: 0\r\n'
          printf 'Connection: close\r\n'
          printf 'X-RNS-Front: 1\r\n'
          printf '\r\n'
          ;;
      esac
      exit 0
    fi
    send_portal
    ;;
esac
exit 0
