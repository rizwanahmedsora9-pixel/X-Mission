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
      send_json "200 OK" "$(printf '{"ok":true,"plan":"%s","expires":%s,"left":%s,"now":%s,"down_kbps":%s,"up_kbps":%s,"mac":"%s"}' \
        "$(json_escape "$_plan")" "$_exp" "$_left" "$(now_epoch)" "${_down:-0}" "${_up:-0}" "$(json_escape "$_mac")")"
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
    kicked) _err="Your connection was paused by staff. Ask the counter to restore it, or enter a new voucher code." ;;
    banned) _err="This device is blocked by staff. Please contact the counter." ;;
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
    # Tell the page WHY it is not connected so it can say "your time is
    # over" / "ended by staff" / "blocked" instead of a blank form.
    _why=""
    if [ -n "$_mac" ]; then
      case "$(client_state "$_mac")" in
        banned) _why=banned ;;
        kicked) _why=kicked ;;
        *)
          if "$BB" awk -F'|' -v m="$_mac" '$7==m && $6=="expired" {f=1} END{exit !f}' "$VFILE" 2>/dev/null; then
            _why=expired
          fi
          ;;
      esac
    fi
    send_json "200 OK" "$(printf '{"ok":true,"bound":false,"reason":"%s","now":%s}' "$_why" "$(now_epoch)")"
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
  send_json "200 OK" "$(printf '{"ok":true,"bound":true,"plan":"%s","expires":%s,"left":%s,"now":%s,"down_kbps":%s,"up_kbps":%s}' \
    "$(json_escape "$_plan")" "${_exp:-0}" "$_left" "$(now_epoch)" "${_down:-0}" "${_up:-0}")"
}

status_public() {
  _lab=false
  _setup=false
  _pay_online=false
  is_lab && _lab=true
  auth_needed && _setup=true
  # Online payments are available when the operator has configured at least
  # one wallet number.
  if [ -n "$(cfg_get JAZZCASH_NUMBER "")" ] || [ -n "$(cfg_get EASYPAISA_NUMBER "")" ]; then
    _pay_online=true
  fi
  _extra=""
  if is_lab; then
    _extra=',"lab_user":"admin","lab_pass":"rns-admin","lab_code":"4821-9033"'
  fi
  send_json "200 OK" "$(printf '{"ok":true,"lab":%s,"setup_required":%s,"pay_online":%s,"brand":"%s","shop":"%s","ssid":"%s","channel":%s,"portal_port":%s%s}' \
    "$_lab" "$_setup" "$_pay_online" \
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
  _op=0; online_pay_enabled && _op=1
  printf '{"ok":true,"ssid":"%s","channel":%s,"hw_mode":"%s","max_sta":%s,"shop":"%s","admin_lan":%s,"down_1h":%s,"up_1h":%s,"down_3h":%s,"up_3h":%s,"down_1d":%s,"up_1d":%s,"down_7d":%s,"up_7d":%s,"price_1h":"%s","price_3h":"%s","price_1d":"%s","price_7d":"%s","jazzcash_number":"%s","jazzcash_name":"%s","easypaisa_number":"%s","easypaisa_name":"%s","pay_auto_verify":%s,"online_pay":%s,"paused":%s}' \
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
    "$(json_escape "$(cfg_get JAZZCASH_NUMBER "")")" \
    "$(json_escape "$(cfg_get JAZZCASH_NAME "")")" \
    "$(json_escape "$(cfg_get EASYPAISA_NUMBER "")")" \
    "$(json_escape "$(cfg_get EASYPAISA_NAME "")")" \
    "$(cfg_get PAY_AUTO_VERIFY 1)" \
    "$_op" \
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
  # Payment gateway settings: JazzCash and EasyPaisa numbers and account names
  for _pair in JAZZCASH_NUMBER:jazzcash_number JAZZCASH_NAME:jazzcash_name EASYPAISA_NUMBER:easypaisa_number EASYPAISA_NAME:easypaisa_name; do
    _key=${_pair%%:*}
    _field=${_pair#*:}
    cfg_set "$_key" "$(sanitize_token "$(form_get "$_field")")"
  done
  cfg_set PAY_AUTO_VERIFY "$(form_get pay_auto_verify | "$BB" tr -cd '01')"
  log_event settings "ssid=$(cfg_get SSID RNS) channel=$(cfg_get CHANNEL 6)"
  ap_watch_once
}

save_package() {
  # action=delete removes a package. The panel uses this to clear out the
  # seven stock presets that v5 and earlier shipped, since v6 no longer
  # creates them but never deletes an existing operator's packages itself.
  if [ "$(form_get action)" = "delete" ]; then
    package_delete "$(form_get id)"
    return $?
  fi
  # Duration arrives either as raw seconds (old clients, CLI) or as an amount
  # plus a unit — "3 hours", "2 days" — which is how the operator thinks.
  _sec=$(form_get seconds)
  if [ -z "$_sec" ]; then
    _sec=$(duration_seconds "$(form_get duration)" "$(form_get duration_unit)")
  fi
  package_upsert "$(form_get id)" "$(form_get label)" "$_sec" \
    "$(form_get down_kbps)" "$(form_get up_kbps)" "$(form_get price)" \
    "$(form_get rate)" "$(form_get rate_unit)"
}

sales_range() {
  # Echoes "<from_epoch> <to_epoch>". Accepts YYYY-MM-DD (the date picker) or
  # raw epoch seconds. A DATE upper bound is inclusive to the operator, so it
  # becomes the exclusive next-local-midnight bound. A bare call means today,
  # which is the "how many did we sell today" question.
  _sf=$(_sales_bound "$(form_get from)" start)
  _st=$(_sales_bound "$(form_get to)" end)
  [ "$_st" -gt "$_sf" ] || _st=$((_sf + 86400))
  printf '%s %s' "$_sf" "$_st"
}

_sales_bound() {
  # $1 = "", YYYY-MM-DD, or epoch seconds. $2 = start|end.
  # Anything unparseable falls back to today rather than to epoch 0, so a
  # malformed query can never turn into a full-history scan.
  _in=$1
  case "$_in" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])
      _e=$(ymd_to_epoch "$_in" "$2")
      ;;
    ''|*[!0-9]*)
      _e=$(ymd_to_epoch "$(today_ymd)" "$2")
      ;;
    *)
      # Already epoch seconds: taken as an exact bound. Only a DATE upper
      # bound gets the inclusive-to-exclusive midnight shift, because
      # "to 2026-09-26" means "include the 26th" to an operator.
      _e=$(num "$_in")
      ;;
  esac
  _e=$(num "$_e" '')
  [ -n "$_e" ] || _e=$(ymd_to_epoch "$(today_ymd)" "$2")
  printf '%s' "$(num "$_e" 0)"
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

# ---------------------------------------------------------------------------
# Online payment gateway handlers.
# ---------------------------------------------------------------------------
do_pay_packages() {
  # Public endpoint: list ONLINE packages (from the dedicated online-packages
  # catalogue, not the counter packages) with the operator's wallet numbers.
  _jc=$(cfg_get JAZZCASH_NUMBER "")
  _ep=$(cfg_get EASYPAISA_NUMBER "")
  _jcn=$(cfg_get JAZZCASH_NAME "")
  _epn=$(cfg_get EASYPAISA_NAME "")
  _pkgs=$(online_packages_json)
  send_json "200 OK" "$(printf '{"ok":true,"jazzcash_number":"%s","jazzcash_name":"%s","easypaisa_number":"%s","easypaisa_name":"%s","packages":%s}' \
    "$(json_escape "$_jc")" "$(json_escape "$_jcn")" \
    "$(json_escape "$_ep")" "$(json_escape "$_epn")" "$_pkgs")"
}

do_pay_init() {
  # Customer picked a package and a wallet. Issue the tracking reference
  # they must write in the wallet's notes box before sending the money.
  _pkg=$(form_get package_id)
  _method=$(form_get method)
  _res=$(with_lock payref_create "$_pkg" "$_method" "$CLIENT_IP")
  _rc=$?
  _kind=$(printf '%s' "$_res" | "$BB" cut -d'|' -f1)
  if [ "$_rc" -eq 0 ] && [ "$_kind" = "ok" ]; then
    _ref=$(printf '%s' "$_res" | "$BB" cut -d'|' -f2)
    _amt=$(printf '%s' "$_res" | "$BB" cut -d'|' -f3)
    _lbl=$(printf '%s' "$_res" | "$BB" cut -d'|' -f4)
    _sec=$(printf '%s' "$_res" | "$BB" cut -d'|' -f5)
    _until=$(printf '%s' "$_res" | "$BB" cut -d'|' -f6)
    send_json "200 OK" "$(printf '{"ok":true,"ref":"%s","amount":"%s","plan":"%s","seconds":%s,"valid_until":%s,"now":%s}' \
      "$(json_escape "$_ref")" "$(json_escape "$_amt")" "$(json_escape "$_lbl")" "$(num "$_sec")" "$(num "$_until")" "$(now_epoch)")"
    return
  fi
  _err="Could not start the payment."
  case "$_res" in
    bad_method) _err="Choose JazzCash or EasyPaisa." ;;
    unknown_package) _err="That package is not available." ;;
    no_price) _err="That package has no price set." ;;
    nomac|missing_ip) _err="Your device is not visible on the network yet. Wait a few seconds and try again." ;;
    banned) _err="This device is blocked by staff. Please contact the counter." ;;
  esac
  send_json "200 OK" "$(printf '{"ok":false,"error":"%s","reason":"%s"}' "$(json_escape "$_err")" "$(json_escape "$_res")")"
}

pay_ref_error() {
  case "$1" in
    missing_ref) printf 'Start again from the package list so a Tracking ID is issued for this payment.' ;;
    unknown_ref) printf 'That Tracking ID is not known. Go back and start the payment again.' ;;
    ref_used) printf 'This Tracking ID was already used for a payment.' ;;
    ref_expired) printf 'This Tracking ID has expired. Go back, pick the package again and use the new one.' ;;
    ref_other_device) printf 'This Tracking ID was issued to a different phone.' ;;
    ref_mismatch) printf 'The Tracking ID does not match this package or wallet. Go back and start again.' ;;
    *) return 1 ;;
  esac
}

do_pay_submit() {
  # Customer submits: package_id, method (jazzcash|easypaisa), tid.
  # When PAY_AUTO_VERIFY is on (default), validates TID format + amount match
  # and activates the voucher instantly — no admin needed.
  _pkg=$(form_get package_id)
  _method=$(form_get method)
  _tid=$(form_get tid)
  _ref=$(form_get ref)
  _auto=$(cfg_get PAY_AUTO_VERIFY 1)
  if [ "$_auto" = "1" ]; then
    # === AUTO-VERIFY FLOW ===
    # Validate TID + match amount → instant confirm → voucher + internet
    _res=$(with_lock online_payment_auto_verify "$_pkg" "$_method" "$_tid" "$CLIENT_IP" "$_ref")
    _rc=$?
    _kind=$(printf '%s' "$_res" | "$BB" cut -d'|' -f1)
    if [ "$_rc" -eq 0 ] && [ "$_kind" = "ok" ]; then
      # Success — voucher activated, rebuild firewall
      with_lock true
      fw_rebuild
      shape_apply
      _code=$(printf '%s' "$_res" | "$BB" cut -d'|' -f2)
      _plan=$(printf '%s' "$_res" | "$BB" cut -d'|' -f3)
      _exp=$(printf '%s' "$_res" | "$BB" cut -d'|' -f4)
      _down=$(printf '%s' "$_res" | "$BB" cut -d'|' -f5)
      _up=$(printf '%s' "$_res" | "$BB" cut -d'|' -f6)
      _mac=$(printf '%s' "$_res" | "$BB" cut -d'|' -f7)
      _now=$(now_epoch)
      _left=$((_exp - _now))
      [ "$_left" -lt 0 ] && _left=0
      # Find the pay_id for the receipt download
      _pay_id=$("$BB" awk -F'|' -v c="$_code" '$12==c {print $1; exit}' "$PAYFILE")
      _tid_clean=$(sanitize_tid "$_tid")
      # Get the amount from the payment record
      _amt=$("$BB" awk -F'|' -v p="$_pay_id" '$1==p {print $4; exit}' "$PAYFILE")
      _refc=$(payref_for_pay "$_pay_id")
      send_json "200 OK" "$(printf '{"ok":true,"status":"confirmed","pay_id":"%s","ref":"%s","voucher_code":"%s","plan":"%s","expires":%s,"left":%s,"down_kbps":%s,"up_kbps":%s,"tid":"%s","method":"%s","amount":"%s","mac":"%s","ip":"%s"}' \
        "$(json_escape "$_pay_id")" \
        "$(json_escape "$_refc")" \
        "$(json_escape "$_code")" \
        "$(json_escape "$_plan")" \
        "$(num "$_exp")" "$(num "$_left")" \
        "$(num "$_down")" "$(num "$_up")" \
        "$(json_escape "$_tid_clean")" \
        "$(json_escape "$_method")" \
        "$(json_escape "$(money "$_amt")")" \
        "$(json_escape "$_mac")" \
        "$(json_escape "$CLIENT_IP")")"
      return
    fi
    # Auto-verify failed — return specific error
    _err="Payment could not be verified."
    _rerr=$(pay_ref_error "$_res") && _err=$_rerr
    case "$_res" in
      banned) _err="This device is blocked by staff. Please contact the counter." ;;
      unknown_package) _err="That package is not available." ;;
      no_price) _err="That package has no price set." ;;
      invalid_tid_format) _err="Invalid Transaction ID. Please check and enter the correct TID from your payment SMS." ;;
      duplicate_tid) _err="This Transaction ID was already used." ;;
      nomac) _err="Your device is not visible on the network yet. Wait a few seconds and try again." ;;
      rate_limited) _err="Too many attempts. Please wait a few minutes." ;;
      confirm_failed) _err="Payment verification failed. Please try again or contact the counter." ;;
      bad_method) _err="Choose JazzCash or EasyPaisa." ;;
      missing_tid) _err="Enter your Transaction ID (TID)." ;;
      missing_ip) _err="Your device is not visible yet." ;;
    esac
    send_json "200 OK" "$(printf '{"ok":false,"error":"%s","reason":"%s"}' "$(json_escape "$_err")" "$(json_escape "$_res")")"
    return
  fi
  # === MANUAL FLOW (PAY_AUTO_VERIFY=0) ===
  _res=$(with_lock online_payment_create "$_pkg" "$_method" "$_tid" "$CLIENT_IP" "$_ref")
  _rc=$?
  if [ "$_rc" -eq 0 ] && [ -n "$_res" ]; then
    send_json "200 OK" "$(printf '{"ok":true,"pay_id":"%s","ref":"%s","status":"pending"}' "$(json_escape "$_res")" "$(json_escape "$(payref_for_pay "$_res")")")"
    return
  fi
  _err="Could not submit payment."
  _rerr=$(pay_ref_error "$_res") && _err=$_rerr
  case "$_res" in
    bad_method) _err="Choose JazzCash or EasyPaisa." ;;
    missing_tid) _err="Enter your Transaction ID (TID)." ;;
    missing_ip) _err="Your device is not visible on the network yet." ;;
    unknown_package) _err="That package does not exist." ;;
    no_price) _err="That package has no price set." ;;
    nomac) _err="Your device is not visible yet. Wait a few seconds and try again." ;;
    banned) _err="This device is blocked by staff. Please contact the counter." ;;
    rate_limited) _err="Too many pending payments. Wait for the current one to be reviewed." ;;
    duplicate_tid) _err="This Transaction ID was already submitted." ;;
  esac
  send_json "200 OK" "$(printf '{"ok":false,"error":"%s","reason":"%s"}' "$(json_escape "$_err")" "$(json_escape "$_res")")"
}

do_pay_status() {
  # Customer polls this to check if their payment was confirmed. If confirmed,
  # the voucher is already active — heal the gate so internet starts now.
  _pid=$(form_get pay_id)
  [ -n "$_pid" ] || {
    send_json "200 OK" '{"ok":true,"status":"none"}'
    return
  }
  _row=$(online_payment_status "$_pid")
  if [ -z "$_row" ]; then
    send_json "200 OK" '{"ok":false,"error":"Payment not found."}'
    return
  fi
  _status=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $7}')
  _mac=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $8}')
  _code=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $12}')
  _label=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $3}')
  _exp=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $11}')
  _sec=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $13}')
  _tid=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $6}')
  _method=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $5}')
  _amount=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $4}')
  _pkg_id=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $2}')
  _ip=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $9}')
  _down=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $15}')
  _up=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $16}')
  if [ "$_status" = "confirmed" ] && [ -n "$_code" ]; then
    # Heal the gate so this device's internet starts immediately
    bound_client_heal "$_mac" >/dev/null 2>&1 || true
    fw_rebuild >/dev/null 2>&1 || true
    shape_apply >/dev/null 2>&1 || true
    # Get expiry from the voucher itself (the payment record's column 11 is
    # the confirmed time; column 10 of the voucher is the expiry)
    _vrow=$(_voucher_row "$_code")
    _vexp=$(printf '%s' "$_vrow" | "$BB" awk -F'|' '{print $10}')
    _now=$(now_epoch)
    _left=$((_vexp - _now))
    [ "$_left" -lt 0 ] && _left=0
    send_json "200 OK" "$(printf '{"ok":true,"status":"confirmed","ref":"%s","voucher_code":"%s","plan":"%s","expires":%s,"left":%s,"down_kbps":%s,"up_kbps":%s,"tid":"%s","method":"%s","amount":"%s","pay_id":"%s","mac":"%s","ip":"%s","seconds":%s}' \
      "$(json_escape "$(payref_for_pay "$_pid")")" \
      "$(json_escape "$_code")" "$(json_escape "$_label")" \
      "$(num "$_vexp")" "$(num "$_left")" \
      "$(num "$_down")" "$(num "$_up")" \
      "$(json_escape "$_tid")" "$(json_escape "$_method")" \
      "$(json_escape "$(money "$_amount")")" \
      "$(json_escape "$_pid")" "$(json_escape "$_mac")" \
      "$(json_escape "$_ip")" "$(num "$_sec")")"
  elif [ "$_status" = "rejected" ]; then
    send_json "200 OK" "$(printf '{"ok":true,"status":"rejected","note":"%s"}' \
      "$(json_escape "$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $14}')")")"
  else
    send_json "200 OK" "$(printf '{"ok":true,"status":"pending","ref":"%s","tid":"%s","method":"%s","amount":"%s","pay_id":"%s"}' \
      "$(json_escape "$(payref_for_pay "$_pid")")" \
      "$(json_escape "$_tid")" "$(json_escape "$_method")" \
      "$(json_escape "$(money "$_amount")")" "$(json_escape "$_pid")")"
  fi
}

do_pay_receipt() {
  # Generate and send a PDF receipt for a confirmed payment. The customer's
  # device must match the payment's MAC to prevent strangers from downloading
  # someone else's receipt.
  _pid=$(form_get pay_id)
  [ -n "$_pid" ] || { send_json "400 Bad Request" '{"ok":false,"error":"Missing pay_id"}'; return; }
  _row=$(online_payment_status "$_pid")
  [ -n "$_row" ] || { send_json "404 Not Found" '{"ok":false,"error":"Payment not found"}'; return; }
  _status=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $7}')
  [ "$_status" = "confirmed" ] || { send_json "200 OK" '{"ok":false,"error":"Payment not confirmed yet"}'; return; }
  _mac=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $8}')
  # Allow download from the paying device or from local admin
  _client_mac=$(mac_for_ip "$CLIENT_IP" 2>/dev/null || true)
  if [ "$_client_mac" != "$_mac" ] && ! is_local_ip "$CLIENT_IP"; then
    send_json "403 Forbidden" '{"ok":false,"error":"Receipt available on the paying device only"}'
    return
  fi
  _code=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $12}')
  _label=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $3}')
  _amount=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $4}')
  _method=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $5}')
  _tid=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $6}')
  _ip=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $9}')
  _sec=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $13}')
  _down=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $15}')
  _up=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $16}')
  # Get voucher timestamps for the PDF
  _vrow=$(_voucher_row "$_code")
  _act=$(printf '%s' "$_vrow" | "$BB" awk -F'|' '{print $9}')
  _vexp=$(printf '%s' "$_vrow" | "$BB" awk -F'|' '{print $10}')
  _pdff="$RNS_DATA/receipt-$$.pdf"
  voucher_pdf "$_code" "$_label" "$_sec" "$_down" "$_up" "$_amount" \
    "$_mac" "$_ip" "$_act" "$_vexp" "$_pid" "$_tid" "$_method" > "$_pdff"
  RNS_EXTRA_HDR="Content-Disposition: attachment; filename=\"RNS-Voucher-$(printf '%s' "$_code" | "$BB" cut -c1-8).pdf\""
  export RNS_EXTRA_HDR
  send_raw "200 OK" "application/pdf" "$_pdff"
  rm -f "$_pdff"
}

# RNS_DELEGATED=1: the page shell already read the request and exported
# RNS_METHOD, RNS_PATH, RNS_QUERY, RNS_BODY, RNS_COOKIE, RNS_ACCEPT, RNS_HOST.
if [ "${RNS_DELEGATED:-0}" != "1" ]; then
  if ! read_request; then
    exit 0
  fi
fi

case "$RNS_PATH" in
  /api/pay/*|/api/admin/payments|/api/admin/online-packages|/api/admin/pay-confirm|/api/admin/pay-reject)
    if ! online_pay_enabled; then
      send_json "404 Not Found" '{"ok":false,"error":"online_payments_disabled"}'
      exit 0
    fi
    ;;
esac
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
  /api/pay/packages)
    do_pay_packages
    ;;
  /api/pay/init)
    do_pay_init
    ;;
  /api/pay/submit)
    do_pay_submit
    ;;
  /api/pay/status)
    do_pay_status
    ;;
  /api/pay/receipt)
    do_pay_receipt
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
      send_json "200 OK" "$(printf '{"ok":true,"detail":"%s","packages":%s}' \
        "$(json_escape "$_pkgmsg")" "$(packages_json)")"
      exit 0
    fi
    send_json "200 OK" "$(printf '{"ok":true,"packages":%s}' "$(packages_json)")"
    ;;
  /api/admin/sales)
    require_admin
    _sr=$(sales_range)
    _sfrom=${_sr% *}
    _sto=${_sr#* }
    send_json "200 OK" "$(printf '{"ok":true,"sales":%s}' "$(sales_json "$_sfrom" "$_sto")")"
    ;;
  /api/admin/sales.csv)
    require_admin
    _sr=$(sales_range)
    _sfrom=${_sr% *}
    _sto=${_sr#* }
    _csvf="$RNS_DATA/sales-$$.csv"
    sales_csv "$_sfrom" "$_sto" > "$_csvf"
    # _sto is the exclusive next-midnight bound; the filename should read as
    # the last day the operator actually asked for.
    RNS_EXTRA_HDR="Content-Disposition: attachment; filename=\"rns-sales-$(epoch_to_ymd "$_sfrom")_to_$(epoch_to_ymd $((_sto - 1))).csv\""
    export RNS_EXTRA_HDR
    send_raw "200 OK" "text/csv; charset=utf-8" "$_csvf"
    rm -f "$_csvf"
    ;;
  /api/admin/payments)
    require_admin
    send_json "200 OK" "$(printf '{"ok":true,"payments":%s}' "$(online_payments_json)")"
    ;;
  /api/admin/online-packages)
    require_admin
    if [ "$RNS_METHOD" = "POST" ]; then
      if [ "$(form_get action)" = "delete" ]; then
        _opmsg=$(with_lock online_package_delete "$(form_get id)")
        _oprc=$?
      else
        _opsec=$(form_get seconds)
        if [ -z "$_opsec" ]; then
          _opsec=$(duration_seconds "$(form_get duration)" "$(form_get duration_unit)")
        fi
        _opmsg=$(with_lock online_package_upsert "$(form_get id)" "$(form_get label)" "$_opsec" \
          "$(form_get down_kbps)" "$(form_get up_kbps)" "$(form_get price)" \
          "$(form_get rate)" "$(form_get rate_unit)")
        _oprc=$?
      fi
      if [ "$_oprc" -ne 0 ]; then
        send_json "200 OK" "$(printf '{"ok":false,"error":"%s"}' "$(json_escape "$_opmsg")")"
        exit 0
      fi
      send_json "200 OK" "$(printf '{"ok":true,"detail":"%s","packages":%s}' \
        "$(json_escape "$_opmsg")" "$(online_packages_json)")"
      exit 0
    fi
    send_json "200 OK" "$(printf '{"ok":true,"packages":%s}' "$(online_packages_json)")"
    ;;
  /api/admin/pay-confirm)
    require_admin
    _pid=$(form_get pay_id)
    _note=$(form_get note)
    _res=$(with_lock online_payment_confirm "$_pid" "$_note")
    _rc=$?
    if [ "$_rc" -eq 0 ]; then
      _kind=$(printf '%s' "$_res" | "$BB" cut -d'|' -f1)
      if [ "$_kind" = "ok" ]; then
        # Rebuild the firewall so the newly-activated voucher takes effect
        with_lock true
        fw_rebuild
        shape_apply
        send_json "200 OK" '{"ok":true,"detail":"Payment confirmed. Voucher activated."}'
        exit 0
      fi
    fi
    _err="Could not confirm payment."
    case "$_res" in
      missing_id) _err="Missing payment ID." ;;
      not_found) _err="Payment not found." ;;
      not_pending) _err="This payment is not pending." ;;
      mint_failed) _err="Voucher generation failed." ;;
    esac
    send_json "200 OK" "$(printf '{"ok":false,"error":"%s"}' "$(json_escape "$_err")")"
    ;;
  /api/admin/pay-reject)
    require_admin
    _pid=$(form_get pay_id)
    _note=$(form_get note)
    _res=$(with_lock online_payment_reject "$_pid" "$_note")
    _rc=$?
    if [ "$_rc" -eq 0 ]; then
      send_json "200 OK" '{"ok":true,"detail":"Payment rejected."}'
    else
      send_json "200 OK" "$(printf '{"ok":false,"error":"%s"}' "$(json_escape "$_res")")"
    fi
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
  /api/admin/vouchers.pdf)
    require_admin
    _pdff="$RNS_DATA/vouchers-$$.pdf"
    _st=$(form_get status)
    [ -n "$_st" ] || _st=new
    vouchers_pdf "$_st" "$(form_get search)" "$(form_get plan)" > "$_pdff"
    _n=$("$BB" grep -c '/Type /Page ' "$_pdff" 2>/dev/null)
    log_event export "vouchers.pdf status=$_st pages=${_n:-0}"
    RNS_EXTRA_HDR="Content-Disposition: attachment; filename=\"RNS-vouchers-$_st-$(epoch_to_ymd "$(now_epoch)").pdf\""
    export RNS_EXTRA_HDR
    send_raw "200 OK" "application/pdf" "$_pdff"
    rm -f "$_pdff"
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
    case "$_state" in
      kicked|banned)
        # Rules out first, then drop the station so its next captive probe
        # lands on the sign-in page instead of escaping to the internet.
        client_disconnect "$_mac"
        ;;
      *)
        fw_rebuild
        ;;
    esac
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
