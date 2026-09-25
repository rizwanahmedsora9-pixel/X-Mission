#!/system/bin/sh
# Function handler for one HTTP request. Voucher, login, and firewall live here.
# The admin panel and captive portal are NOT served from this file when the
# listener is healthy: rns-front.sh serves those pages first and only execs
# this script for /api/*. A syntax error in this file must not blank the pages.
# Direct invocation (old listener, or nc) still reads the socket itself.

RNS_EXTRA_HDR=""
. "$RNS_HOME/bin/common.sh"
. "$RNS_HOME/bin/store.sh"
. "$RNS_HOME/bin/net.sh"

store_init
CLIENT_IP=$(resolve_client_ip 2>/dev/null || true)

send_raw() {
  _status=$1
  _ctype=$2
  _file=$3
  _len=$("$BB" wc -c < "$_file" | "$BB" tr -d ' ')
  printf 'HTTP/1.0 %s\r\n' "$_status"
  printf 'Content-Type: %s\r\n' "$_ctype"
  printf 'Content-Length: %s\r\n' "$_len"
  printf 'Connection: close\r\n'
  printf 'Cache-Control: no-store, no-cache, must-revalidate\r\n'
  printf 'X-Content-Type-Options: nosniff\r\n'
  if [ -n "${RNS_EXTRA_HDR:-}" ]; then
    printf '%s\r\n' "$RNS_EXTRA_HDR"
  fi
  printf '\r\n'
  # Android probes commonly use HEAD before opening the sign-in sheet. A
  # correct empty HEAD response prevents the captive login activity from
  # treating a body-less connection as a failed page load.
  [ "${RNS_METHOD:-GET}" = "HEAD" ] || cat "$_file"
}

send_text() {
  _status=$1
  _ctype=$2
  _body=$3
  _tmp="$RNS_DATA/body.$$"
  printf '%s' "$_body" > "$_tmp"
  send_raw "$_status" "$_ctype" "$_tmp"
  rm -f "$_tmp"
}

send_json() {
  send_text "$1" "application/json; charset=utf-8" "$2"
}

send_html_file() {
  send_raw "200 OK" "text/html; charset=utf-8" "$1"
}

send_no_content() {
  # The standard "internet OK" answer to a captive-portal probe. A device
  # that already holds a valid voucher must get this (not the portal page)
  # after it reconnects, so the OS clears its "no internet" indicator.
  printf 'HTTP/1.0 204 No Content\r\n'
  printf 'Connection: close\r\n'
  printf 'Cache-Control: no-store, no-cache, must-revalidate\r\n'
  printf '\r\n'
}

bound_client_heal() {
  # $1 = mac of a device that already holds an active voucher. Keep the
  # stored lease current and make sure its gate rules really exist before
  # we tell it (or its OS probe) that it is connected.
  _mac=$(sanitize_mac "$1")
  [ -n "$_mac" ] || return 1
  client_touch "$_mac" "$CLIENT_IP" "" || true
  with_lock voucher_set_ip "$_mac" "$CLIENT_IP" >/dev/null 2>&1 || true
  gate_heal
}

session_token() {
  printf '%s' "$RNS_COOKIE" | "$BB" tr ';' '\n' | "$BB" sed 's/^ *//' \
    | "$BB" sed -n 's/^rns=//p' | "$BB" head -n 1 | "$BB" tr -cd '0-9a-f'
}

wants_json() {
  printf '%s' "$RNS_ACCEPT" | "$BB" grep -q 'application/json'
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
  # drop trailing slash except root
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
  if [ "$RNS_CL" -gt 8192 ]; then RNS_CL=8192; fi
  if [ "$RNS_CL" -gt 0 ]; then
    RNS_BODY=$("$BB" dd bs=1 count="$RNS_CL" 2>/dev/null)
  fi
  return 0
}

require_admin() {
  if ! is_local_ip "$CLIENT_IP"; then
    send_json "403 Forbidden" '{"ok":false,"error":"Admin opens on the shop phone only."}'
    exit 0
  fi
  _tok=$(session_token)
  if ! auth_session_ok "$_tok"; then
    send_json "401 Unauthorized" '{"ok":false,"error":"Login required."}'
    exit 0
  fi
}

html_result() {
  _title=$1
  _msg=$2
  _ok=$3
  cat > "$RNS_DATA/body.$$" << EOF
<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${_title}</title>
<style>
body{margin:0;font-family:Trebuchet MS,Segoe UI,sans-serif;background:#f4efe4;color:#14211b}
main{max-width:420px;margin:12vh auto;padding:28px;background:#fffaf2;border:1px solid #e2d8c6}
h1{font-size:28px;margin:0 0 8px}
p{font-size:18px;line-height:1.4}
a{color:#1e6b45}
</style></head>
<body><main><h1>${_title}</h1><p>${_msg}</p><p><a href="/">Back</a></p></main></body></html>
EOF
  send_raw "200 OK" "text/html; charset=utf-8" "$RNS_DATA/body.$$"
  rm -f "$RNS_DATA/body.$$"
}

do_redeem() {
  _code=$(form_get code)
  _res=$(with_lock voucher_redeem "$_code" "$CLIENT_IP")
  _rc=$?
  _kind=$(printf '%s' "$_res" | "$BB" cut -d'|' -f1)
  if [ "$_rc" -eq 0 ] && [ "$_kind" = "ok" ]; then
    with_lock true
    fw_rebuild
    shape_apply
    _plan=$(printf '%s' "$_res" | "$BB" cut -d'|' -f2)
    _exp=$(printf '%s' "$_res" | "$BB" cut -d'|' -f3)
    _down=$(printf '%s' "$_res" | "$BB" cut -d'|' -f4)
    _up=$(printf '%s' "$_res" | "$BB" cut -d'|' -f5)
    _mac=$(printf '%s' "$_res" | "$BB" cut -d'|' -f6)
    _left=$((_exp - $(now_epoch)))
    [ "$_left" -lt 0 ] && _left=0
    if wants_json; then
      send_json "200 OK" "$(printf '{"ok":true,"plan":"%s","expires":%s,"left":%s,"down_kbps":%s,"up_kbps":%s,"mac":"%s"}' \
        "$(json_escape "$_plan")" "$_exp" "$_left" "${_down:-0}" "${_up:-0}" "$(json_escape "$_mac")")"
    else
      html_result "Internet is on" "$_plan is active on this phone. You can close this page."
    fi
    return
  fi
  _err="That code is not valid."
  case "$_kind" in
    used) _err="This code is already used on another phone." ;;
    slow) _err="Too many tries. Wait a few minutes." ;;
    nomac) _err="This phone is not visible yet. Wait 5 seconds and try again." ;;
    kicked) _err="This device was disconnected by staff." ;;
    banned) _err="This device is blocked by staff." ;;
  esac
  if wants_json; then
    send_json "200 OK" "$(printf '{"ok":false,"error":"%s","reason":"%s"}' "$(json_escape "$_err")" "$(json_escape "$_kind")")"
  else
    html_result "Not connected" "$_err"
  fi
}

do_me() {
  _mac=$(mac_for_ip "$CLIENT_IP" 2>/dev/null || true)
  _row=""
  [ -n "$_mac" ] && _row=$(voucher_for_mac "$_mac")
  if [ -z "$_row" ]; then
    send_json "200 OK" '{"ok":true,"bound":false}'
    return
  fi
  # The device reconnected (often with a new DHCP lease after a Wi-Fi
  # toggle) and is asking "am I connected?". Sync its lease and make sure
  # its firewall rules survived before we answer yes.
  bound_client_heal "$_mac" || true
  _plan=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $2}')
  _exp=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $10}')
  _down=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $4}')
  _up=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $5}')
  _left=$((_exp - $(now_epoch)))
  [ "$_left" -lt 0 ] && _left=0
  send_json "200 OK" "$(printf '{"ok":true,"bound":true,"plan":"%s","expires":%s,"left":%s,"down_kbps":%s,"up_kbps":%s}' \
    "$(json_escape "$_plan")" "${_exp:-0}" "$_left" "${_down:-0}" "${_up:-0}")"
}

status_public() {
  _lab=false
  _setup=false
  is_lab && _lab=true
  auth_needed && _setup=true
  _extra=""
  if is_lab; then
    _extra=',"lab_user":"admin","lab_pass":"rns-admin","lab_code":"4821-9033"'
  fi
  send_json "200 OK" "$(printf '{"ok":true,"lab":%s,"setup_required":%s,"brand":"%s","shop":"%s","ssid":"%s","channel":%s,"portal_port":%s%s}' \
    "$_lab" "$_setup" \
    "$(json_escape "$(cfg_get BRAND RNS)")" \
    "$(json_escape "$(cfg_get SHOP "RNS Internet")")" \
    "$(json_escape "$(cfg_get SSID RNS)")" \
    "$(cfg_get CHANNEL 6)" \
    "$(cfg_get PORTAL_PORT 8080)" \
    "$_extra")"
}

settings_json() {
  _paused=false
  [ -f "$RNS_DATA/PAUSE" ] && _paused=true
  printf '{"ok":true,"ssid":"%s","channel":%s,"hw_mode":"%s","max_sta":%s,"shop":"%s","admin_lan":%s,"down_1h":%s,"up_1h":%s,"down_3h":%s,"up_3h":%s,"down_1d":%s,"up_1d":%s,"down_7d":%s,"up_7d":%s,"price_1h":"%s","price_3h":"%s","price_1d":"%s","price_7d":"%s","paused":%s}' \
    "$(json_escape "$(cfg_get SSID RNS)")" \
    "$(cfg_get CHANNEL 6)" \
    "$(json_escape "$(cfg_get HW_MODE g)")" \
    "$(cfg_get MAX_STA 128)" \
    "$(json_escape "$(cfg_get SHOP "RNS Internet")")" \
    "$(cfg_get ADMIN_LAN 0)" \
    "$(cfg_get DOWN_1H 2048)" "$(cfg_get UP_1H 1024)" \
    "$(cfg_get DOWN_3H 2048)" "$(cfg_get UP_3H 1024)" \
    "$(cfg_get DOWN_1D 1024)" "$(cfg_get UP_1D 512)" \
    "$(cfg_get DOWN_7D 512)" "$(cfg_get UP_7D 256)" \
    "$(json_escape "$(cfg_get PRICE_1H "")")" \
    "$(json_escape "$(cfg_get PRICE_3H "")")" \
    "$(json_escape "$(cfg_get PRICE_1D "")")" \
    "$(json_escape "$(cfg_get PRICE_7D "")")" \
    "$_paused"
}

save_settings() {
  _ssid=$(sanitize_token "$(form_get ssid)")
  _shop=$(sanitize_token "$(form_get shop)")
  _ch=$(form_get channel)
  _max=$(form_get max_sta)
  case "$_ch" in ''|*[!0-9]*) _ch=$(cfg_get CHANNEL 6) ;; esac
  case "$_max" in ''|*[!0-9]*) _max=$(cfg_get MAX_STA 128) ;; esac
  [ -n "$_ssid" ] && cfg_set SSID "$_ssid"
  [ -n "$_shop" ] && cfg_set SHOP "$_shop"
  cfg_set CHANNEL "$_ch"
  cfg_set MAX_STA "$_max"
  cfg_set ADMIN_LAN "$(form_get admin_lan | "$BB" tr -cd '01')"
  for _pair in DOWN_1H:down_1h UP_1H:up_1h DOWN_3H:down_3h UP_3H:up_3h DOWN_1D:down_1d UP_1D:up_1d DOWN_7D:down_7d UP_7D:up_7d; do
    _key=${_pair%%:*}
    _field=${_pair#*:}
    _val=$(form_get "$_field" | "$BB" tr -cd '0-9')
    [ -n "$_val" ] && cfg_set "$_key" "$_val"
  done
  for _pair in PRICE_1H:price_1h PRICE_3H:price_3h PRICE_1D:price_1d PRICE_7D:price_7d; do
    _key=${_pair%%:*}
    _field=${_pair#*:}
    cfg_set "$_key" "$(sanitize_token "$(form_get "$_field")")"
  done
  log_event settings "ssid=$(cfg_get SSID RNS) channel=$(cfg_get CHANNEL 6)"
  ap_watch_once
}

save_package() {
  package_upsert "$(form_get id)" "$(form_get label)" "$(form_get seconds)" \
    "$(form_get down_kbps)" "$(form_get up_kbps)" "$(form_get price)"
}

health_json() {
  _db=0; _logs=0; _portal=0; _fw=1
  [ -r "$VFILE" ] && [ -r "$CFILE" ] && [ -r "$PFILE" ] && _db=1
  [ -d "$RNS_LOG_DIR" ] && [ -w "$RNS_LOG_DIR" ] && _logs=1
  [ -x "$RNS_HOME/bin/rns-http.sh" ] && _portal=1
  if ! is_lab && { ! command -v iptables >/dev/null 2>&1 || ! command -v ip6tables >/dev/null 2>&1; }; then _fw=0; fi
  printf '{"ok":true,"service":"rns","storage":"%s","database":%s,"logs":%s,"portal":%s,"firewall_tools":%s}' \
    "$(json_escape "$RNS_DATA")" "$_db" "$_logs" "$_portal" "$_fw"
}

# RNS_DELEGATED=1: the page shell already read the request and exported
# RNS_METHOD, RNS_PATH, RNS_QUERY, RNS_BODY, RNS_COOKIE, RNS_ACCEPT, RNS_HOST.
if [ "${RNS_DELEGATED:-0}" != "1" ]; then
  if ! read_request; then
    exit 0
  fi
fi

case "$RNS_PATH" in
  /favicon.ico)
    send_text "204 No Content" "text/plain" ""
    ;;
  /health)
    send_json "200 OK" "$(health_json)"
    ;;
  /api/status)
    status_public
    ;;
  /api/me)
    do_me
    ;;
  /api/redeem)
    do_redeem
    ;;
  /api/setup)
    if ! is_local_ip "$CLIENT_IP"; then
      send_json "403 Forbidden" '{"ok":false,"error":"Set the password on the shop phone."}'
      exit 0
    fi
    _msg=$(auth_setup "$(form_get password)")
    if [ $? -eq 0 ]; then
      RNS_EXTRA_HDR=""
      _remember=$(form_get remember)
      _tok=$(auth_login "$(form_get password)" "$_remember")
      _cookie='Set-Cookie: rns='"$_tok"'; Path=/; HttpOnly; SameSite=Lax'
      [ "$_remember" = "1" ] && _cookie="$_cookie; Max-Age=2592000"
      RNS_EXTRA_HDR=$_cookie
      send_json "200 OK" '{"ok":true}'
    else
      send_json "200 OK" "$(printf '{"ok":false,"error":"%s"}' "$(json_escape "$_msg")")"
    fi
    ;;
  /api/login)
    if ! is_local_ip "$CLIENT_IP"; then
      send_json "403 Forbidden" '{"ok":false,"error":"Admin opens on the shop phone only."}'
      exit 0
    fi
    _remember=$(form_get remember)
    _tok=$(auth_login "$(form_get password)" "$_remember")
    if [ $? -eq 0 ] && [ -n "$_tok" ]; then
      _cookie='Set-Cookie: rns='"$_tok"'; Path=/; HttpOnly; SameSite=Lax'
      [ "$_remember" = "1" ] && _cookie="$_cookie; Max-Age=2592000"
      RNS_EXTRA_HDR=$_cookie
      send_json "200 OK" '{"ok":true}'
    else
      send_json "200 OK" '{"ok":false,"error":"Wrong password."}'
    fi
    ;;
  /api/logout)
    auth_logout "$(session_token)"
    RNS_EXTRA_HDR=$(printf 'Set-Cookie: rns=; Path=/; Max-Age=0')
    send_json "200 OK" '{"ok":true}'
    ;;
  /api/admin/overview)
    require_admin
    send_json "200 OK" "$(printf '{"ok":true,"counts":%s}' "$(overview_json)")"
    ;;
  /api/admin/vouchers)
    require_admin
    _vf=$(form_get status)
    _vs=$(form_get search)
    [ -n "$_vf" ] || _vf=$(printf '%s' "$RNS_QUERY" | "$BB" sed -n 's/.*\(^\|&\)status=\([^&]*\).*/\2/p')
    [ -n "$_vs" ] || _vs=$(printf '%s' "$RNS_QUERY" | "$BB" sed -n 's/.*\(^\|&\)search=\([^&]*\).*/\2/p')
    _vf=$(urldecode "$_vf")
    _vs=$(urldecode "$_vs")
    send_json "200 OK" "$(printf '{"ok":true,"vouchers":%s}' "$(vouchers_json "$_vf" "$_vs")")"
    ;;
  /api/admin/packages)
    require_admin
    if [ "$RNS_METHOD" = "POST" ]; then
      _pkgmsg=$(with_lock save_package)
      _pkgrc=$?
      if [ "$_pkgrc" -ne 0 ]; then
        send_json "200 OK" "$(printf '{"ok":false,"error":"%s"}' "$(json_escape "$_pkgmsg")")"
        exit 0
      fi
    fi
    send_json "200 OK" "$(printf '{"ok":true,"packages":%s}' "$(packages_json)")"
    ;;
  /api/admin/backup)
    require_admin
    _backup=$(with_lock store_backup)
    _export=$(with_lock store_export)
    if [ -n "$_backup" ] && [ -n "$_export" ]; then
      send_json "200 OK" "$(printf '{"ok":true,"backup":"%s","export":"%s"}' "$(json_escape "$_backup")" "$(json_escape "$_export")")"
    else
      send_json "200 OK" '{"ok":false,"error":"Backup or export failed."}'
    fi
    ;;
  /api/admin/clients)
    require_admin
    send_json "200 OK" "$(printf '{"ok":true,"clients":%s}' "$(clients_json)")"
    ;;
  /api/admin/events)
    require_admin
    send_json "200 OK" "$(printf '{"ok":true,"events":%s}' "$(events_json)")"
    ;;
  /api/admin/settings)
    require_admin
    if [ "$RNS_METHOD" = "POST" ]; then
      save_settings
    fi
    send_json "200 OK" "$(settings_json)"
    ;;
  /api/admin/mint)
    require_admin
    _plan=$(form_get plan)
    _count=$(form_get count)
    _note=$(form_get note)
    [ -n "$_count" ] || _count=1
    _codes=$(with_lock voucher_mint "$_plan" "$_count" "$_note")
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
      send_json "200 OK" "$(printf '{"ok":false,"error":"%s"}' "$(json_escape "$_codes")")"
    else
      _jsonc=""
      for _c in $_codes; do
        [ -n "$_jsonc" ] && _jsonc="$_jsonc,"
        _jsonc="${_jsonc}\"$(json_escape "$_c")\""
      done
      send_json "200 OK" "{\"ok\":true,\"codes\":[${_jsonc}]}"
    fi
    ;;
  /api/admin/revoke)
    require_admin
    _msg=$(with_lock voucher_revoke "$(form_get code)")
    _rc=$?
    fw_rebuild
    if [ "$_rc" -ne 0 ]; then
      send_json "200 OK" "$(printf '{"ok":false,"error":"%s"}' "$(json_escape "$_msg")")"
    else
      send_json "200 OK" '{"ok":true}'
    fi
    ;;
  /api/admin/delete)
    require_admin
    _msg=$(with_lock voucher_delete "$(form_get code)")
    _rc=$?
    fw_rebuild
    if [ "$_rc" -ne 0 ]; then
      send_json "200 OK" "$(printf '{"ok":false,"error":"%s"}' "$(json_escape "$_msg")")"
    else
      send_json "200 OK" '{"ok":true}'
    fi
    ;;
  /api/admin/unbind)
    require_admin
    _code=$(sanitize_code "$(form_get code)")
    _row=$(_voucher_row "$_code")
    _mac=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $7}')
    _msg=$(with_lock voucher_unbind "$_code")
    _rc=$?
    [ -n "$_mac" ] && deauth_mac "$_mac"
    fw_rebuild
    if [ "$_rc" -ne 0 ]; then
      send_json "200 OK" "$(printf '{"ok":false,"error":"%s"}' "$(json_escape "$_msg")")"
    else
      send_json "200 OK" '{"ok":true,"history_retained":true}'
    fi
    ;;
  /api/admin/kick|/api/admin/client-status)
    require_admin
    _mac=$(sanitize_mac "$(form_get mac)")
    _state=$(form_get state)
    [ -n "$_state" ] || _state=kicked
    _msg=$(with_lock client_set_state "$_mac" "$_state")
    _rc=$?
    deauth_mac "$_mac"
    fw_rebuild
    if [ "$_rc" -ne 0 ]; then
      send_json "200 OK" "$(printf '{"ok":false,"error":"%s"}' "$(json_escape "$_msg")")"
    else
      send_json "200 OK" "$(printf '{"ok":true,"state":"%s"}' "$(json_escape "$_state")")"
    fi
    ;;
  /api/admin/pause)
    require_admin
    if [ -f "$RNS_DATA/PAUSE" ]; then
      rm -f "$RNS_DATA/PAUSE"
      fw_rebuild
      send_json "200 OK" '{"ok":true,"paused":false}'
    else
      printf '1\n' > "$RNS_DATA/PAUSE"
      fw_clear
      send_json "200 OK" '{"ok":true,"paused":true}'
    fi
    ;;
  /api/admin/password)
    require_admin
    _old=$(form_get old)
    _new=$(form_get new)
    _nlen=$(printf '%s' "$_new" | "$BB" wc -c | "$BB" tr -d ' ')
    if [ "$_nlen" -lt 6 ]; then
      send_json "200 OK" '{"ok":false,"error":"New password must be at least 6 characters."}'
      exit 0
    fi
    if ! auth_check_pass "$_old"; then
      send_json "200 OK" '{"ok":false,"error":"Current password is wrong."}'
      exit 0
    fi
    _set_pass admin "$_new"
    log_event password "admin password changed"
    send_json "200 OK" '{"ok":true}'
    ;;
  /admin)
    if ! is_local_ip "$CLIENT_IP"; then
      html_result "Staff only" "Open this page on the shop phone: http://127.0.0.1:8080/admin"
      exit 0
    fi
    send_html_file "$RNS_WWW/admin.html"
    ;;
  /)
    send_html_file "$RNS_WWW/portal.html"
    ;;
  /generate_204|/hotspot-detect.html|/ncsi.txt|/connecttest.txt|/success.txt|/canonical.html|/check_network_status.txt)
    # These are the Android, Windows, Apple, and vendor probe paths seen on
    # phones. A device without a voucher must get the portal as a direct
    # HTTP 200 HTML page: a redirect or an empty socket makes some
    # captive-login activities close immediately when the user taps the
    # notification. A device that already holds a valid voucher gets the
    # standard 204 "internet OK" answer after its gate rules are
    # re-confirmed, so the OS clears its "no internet" indicator after a
    # Wi-Fi toggle instead of re-showing the portal.
    _mac=$(mac_for_ip "$CLIENT_IP" 2>/dev/null || true)
    _row=""
    [ -n "$_mac" ] && _row=$(voucher_for_mac "$_mac")
    if [ -n "$_row" ] && bound_client_heal "$_mac"; then
      send_no_content
      exit 0
    fi
    send_html_file "$RNS_WWW/portal.html"
    ;;
  *)
    # Unknown plain-HTTP destinations are also captive until a voucher is
    # active. Never redirect to another port; the portal must be the 200 body.
    _mac=$(mac_for_ip "$CLIENT_IP" 2>/dev/null || true)
    _row=""
    [ -n "$_mac" ] && _row=$(voucher_for_mac "$_mac")
    if [ -n "$_row" ]; then
      # A vouchered device reached the portal for a normal web address: its
      # REDIRECT exemption rule was missing. Restore the gate and bounce the
      # browser back to the page it actually asked for (Host header).
      if bound_client_heal "$_mac"; then
        _host=$(printf '%s' "$RNS_HOST" | "$BB" tr -cd 'A-Za-z0-9.:_-' | "$BB" cut -c1-253)
        if [ -n "$_host" ]; then
          _u="http://${_host}${RNS_PATH}"
          [ -n "$RNS_QUERY" ] && _u="${_u}?${RNS_QUERY}"
          printf 'HTTP/1.0 302 Found\r\n'
          printf 'Location: %s\r\n' "$_u"
          printf 'Content-Length: 0\r\n'
          printf 'Connection: close\r\n'
          printf '\r\n'
          exit 0
        fi
      fi
    fi
    send_html_file "$RNS_WWW/portal.html"
    ;;
esac
