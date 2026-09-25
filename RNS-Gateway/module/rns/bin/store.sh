# Voucher, session, and client store. Flat files, no SQLite.
# Line format uses '|' so fields must not contain '|'.

. "$RNS_HOME/bin/common.sh"

VFILE="$RNS_DB_DIR/vouchers.tsv"
CFILE="$RNS_DB_DIR/clients.tsv"
AFILE="$RNS_DB_DIR/admin.auth"
PFILE="$RNS_DB_DIR/packages.tsv"
CSTATE="$RNS_DB_DIR/client-states.tsv"
HFILE="$RNS_DB_DIR/voucher-history.tsv"

_store_migrate_file() {
  _old="$RNS_DATA/$1"
  _new="$2/$1"
  if [ ! -f "$_new" ] && [ -f "$_old" ]; then
    cp "$_old" "$_new" 2>/dev/null || true
  fi
}

store_backup() {
  _stamp=$(now_epoch)
  _dir="$RNS_DATA/backups/$_stamp"
  mkdir -p "$_dir" || { printf 'backup directory is not writable'; return 1; }
  cp "$VFILE" "$CFILE" "$PFILE" "$CSTATE" "$HFILE" "$_dir/" 2>/dev/null || {
    printf 'backup copy failed'
    return 1
  }
  [ -f "$AFILE" ] && cp "$AFILE" "$_dir/" 2>/dev/null || true
  cp "$RNS_DATA/config.env" "$_dir/" 2>/dev/null || true
  log_event backup "created $_dir"
  printf '%s' "$_dir"
}

store_export() {
  _stamp=$(now_epoch)
  _out="$RNS_DATA/exports/vouchers-$_stamp.tsv"
  cp "$VFILE" "$_out" 2>/dev/null || { printf 'export failed'; return 1; }
  log_event export "created $_out"
  printf '%s' "$_out"
}

store_init() {
  mkdir -p "$RNS_DATA" "$RNS_DB_DIR" "$RNS_LOG_DIR" "$RNS_DATA/backups" "$RNS_DATA/exports" "$RNS_DATA/sessions" "$RNS_DATA/rl" "$RNS_DATA/ratelimit"
  _store_migrate_file vouchers.tsv "$RNS_DB_DIR"
  _store_migrate_file clients.tsv "$RNS_DB_DIR"
  _store_migrate_file admin.auth "$RNS_DB_DIR"
  _store_migrate_file events.log "$RNS_LOG_DIR"
  [ -f "$VFILE" ] || printf '' > "$VFILE"
  [ -f "$CFILE" ] || printf '' > "$CFILE"
  [ -f "$CSTATE" ] || printf '' > "$CSTATE"
  [ -f "$HFILE" ] || printf '' > "$HFILE"
  [ -f "$EVENTS_FILE" ] || printf '' > "$EVENTS_FILE"
  if [ ! -f "$PFILE" ]; then
    cat > "$PFILE" << 'EOF'
1h|1 Hour|3600|2048|1024||active
3h|3 Hours|10800|2048|1024||active
6h|6 Hours|21600|2048|1024||active
12h|12 Hours|43200|1024|512||active
1d|1 Day|86400|1024|512||active
7d|7 Days|604800|512|256||active
30d|30 Days|2592000|512|256||active
EOF
  fi
  if [ ! -f "$RNS_DATA/config.env" ]; then
    cat > "$RNS_DATA/config.env" << 'EOF'
SSID=RNS
CHANNEL=6
HW_MODE=g
MAX_STA=128
LAN_IF=ap0
WAN_IF=auto
PORTAL_PORT=8080
BRAND=RNS
SHOP=RNS Internet
DOWN_1H=2048
UP_1H=1024
DOWN_3H=2048
UP_3H=1024
DOWN_1D=1024
UP_1D=512
DOWN_7D=512
UP_7D=256
PRICE_1H=
PRICE_3H=
PRICE_1D=
PRICE_7D=
ADMIN_LAN=0
OPEN=1
EOF
  fi
  if is_lab && [ ! -f "$RNS_DATA/.labseed" ]; then
    _seed_lab
    printf '1\n' > "$RNS_DATA/.labseed"
  fi
}

_seed_lab() {
  _now=$(now_epoch)
  _exp=$((_now + 2400))
  cat > "$VFILE" << EOF
48219033|1 Hour|3600|2048|1024|new||||${_now}||
11002233|3 Hours|10800|2048|1024|new||||${_now}||
90001122|1 Hour|3600|2048|1024|active|aa:bb:cc:dd:ee:01|192.168.43.20|${_now}|${_exp}|${_now}|counter
70001122|1 Day|86400|1024|512|expired|aa:bb:cc:dd:ee:09|192.168.43.9|$((_now - 90000))|$((_now - 3600))|$((_now - 90000))|
55550001|7 Days|604800|512|256|new||||${_now}||
EOF
  cat > "$CFILE" << EOF
aa:bb:cc:dd:ee:01|192.168.43.20|Counter-Phone|${_now}|${_now}|Ali||active customer|90001122
bb:bb:bb:bb:bb:02|192.168.43.31|Waiting-Laptop|${_now}|${_now}|Walk-in|||
EOF
  _set_pass admin rns-admin
  log_event seed "lab vouchers and admin/rns-admin"
}

_hash_pass() {
  _salt=$1
  _pass=$2
  printf '%s' "${_salt}:${_pass}" | "$BB" sha256sum | "$BB" awk '{print $1}'
}

_set_pass() {
  _user=$1
  _pass=$2
  _salt=$("$BB" od -An -N8 -tx1 /dev/urandom | "$BB" tr -d ' \n')
  _hash=$(_hash_pass "$_salt" "$_pass")
  printf '%s %s %s\n' "$_user" "$_salt" "$_hash" > "$AFILE"
  chmod 600 "$AFILE" 2>/dev/null
}

auth_needed() {
  [ ! -f "$AFILE" ]
}

auth_setup() {
  _pass=$1
  _len=$(printf '%s' "$_pass" | "$BB" wc -c | "$BB" tr -d ' ')
  if [ "$_len" -lt 6 ]; then
    printf 'password must be at least 6 characters'
    return 1
  fi
  if [ -f "$AFILE" ]; then
    printf 'password already set'
    return 1
  fi
  _set_pass admin "$_pass"
  log_event setup "admin password created"
  return 0
}

auth_check_pass() {
  _pass=$1
  [ -f "$AFILE" ] || return 1
  _user=$( "$BB" awk '{print $1}' "$AFILE" )
  _salt=$( "$BB" awk '{print $2}' "$AFILE" )
  _want=$( "$BB" awk '{print $3}' "$AFILE" )
  _got=$(_hash_pass "$_salt" "$_pass")
  [ "$_got" = "$_want" ]
}

auth_login() {
  _pass=$1
  _remember=$2
  auth_check_pass "$_pass" || return 1
  _tok=$("$BB" od -An -N16 -tx1 /dev/urandom | "$BB" tr -d ' \n')
  _ttl=43200
  [ "$_remember" = "1" ] && _ttl=2592000
  _exp=$(( $(now_epoch) + _ttl ))
  printf '%s admin\n' "$_exp" > "$RNS_DATA/sessions/$_tok"
  printf '%s' "$_tok"
  log_event login "admin session ttl=$_ttl"
}

auth_logout() {
  _tok=$1
  case "$_tok" in
    *[!0-9a-f]*|"") return 0 ;;
  esac
  rm -f "$RNS_DATA/sessions/$_tok"
}

auth_session_ok() {
  _tok=$1
  case "$_tok" in
    *[!0-9a-f]*|"") return 1 ;;
  esac
  [ -f "$RNS_DATA/sessions/$_tok" ] || return 1
  _exp=$( "$BB" awk '{print $1}' "$RNS_DATA/sessions/$_tok" )
  _now=$(now_epoch)
  if [ "$_exp" -lt "$_now" ]; then
    rm -f "$RNS_DATA/sessions/$_tok"
    return 1
  fi
  return 0
}

package_id() {
  case "$1" in
    hour|1hour|1H) printf '1h' ;;
    3H) printf '3h' ;;
    6H) printf '6h' ;;
    12H) printf '12h' ;;
    day|1D) printf '1d' ;;
    week|7D) printf '7d' ;;
    month|30D) printf '30d' ;;
    *) printf '%s' "$1" ;;
  esac
}

package_row() {
  _id=$(package_id "$1")
  [ -f "$PFILE" ] || return 1
  "$BB" awk -F'|' -v id="$_id" '$1==id && ($7=="" || $7=="active") { print; exit }' "$PFILE"
}

plan_meta() {
  # echo "label seconds down up price" for both built-in and custom packages.
  _row=$(package_row "$1") || return 1
  [ -n "$_row" ] || return 1
  printf '%s' "$_row" | "$BB" awk -F'|' '{printf "%s %s %s %s %s",$2,$3,$4,$5,$6}'
}

package_upsert() {
  _id=$(printf '%s' "$1" | "$BB" tr -cd 'A-Za-z0-9_-')
  _label=$(sanitize_token "$2")
  _sec=$(printf '%s' "$3" | "$BB" tr -cd '0-9')
  _down=$(printf '%s' "$4" | "$BB" tr -cd '0-9')
  _up=$(printf '%s' "$5" | "$BB" tr -cd '0-9')
  _price=$(sanitize_token "$6")
  [ -n "$_id" ] && [ -n "$_label" ] && [ -n "$_sec" ] && [ -n "$_down" ] && [ -n "$_up" ] || {
    printf 'package requires id, label, duration, download and upload speed'
    return 1
  }
  [ "$_sec" -gt 0 ] && [ "$_down" -gt 0 ] && [ "$_up" -gt 0 ] || {
    printf 'duration and speeds must be greater than zero'
    return 1
  }
  _tmp="${PFILE}.tmp"
  "$BB" awk -F'|' -v OFS='|' -v id="$_id" '$1 != id { print }' "$PFILE" > "$_tmp" || return 1
  printf '%s|%s|%s|%s|%s|%s|active\n' "$_id" "$_label" "$_sec" "$_down" "$_up" "$_price" >> "$_tmp"
  mv "$_tmp" "$PFILE"
  log_event package "$_id $_label ${_sec}s ${_down}/${_up}kbps"
}

packages_json() {
  printf '['
  _first=1
  while IFS='|' read -r id label sec down up price state; do
    [ -n "$id" ] && [ "$state" != "disabled" ] || continue
    [ "$_first" = 1 ] || printf ','
    _first=0
    printf '{"id":"%s","label":"%s","seconds":%s,"down_kbps":%s,"up_kbps":%s,"price":"%s"}' \
      "$(json_escape "$id")" "$(json_escape "$label")" "${sec:-0}" "${down:-0}" "${up:-0}" "$(json_escape "$price")"
  done < "$PFILE"
  printf ']'
}

_rand_code() {
  # Eight printable characters keeps the original slip format while allowing
  # the larger alphanumeric code space requested by the new billing UI.
  "$BB" od -An -N4 -tx1 /dev/urandom | "$BB" tr -d ' \n' | "$BB" cut -c1-8 | "$BB" tr 'a-f' 'A-F'
}

_code_weak() {
  case "$1" in
    00000000|11111111|22222222|33333333|44444444|55555555|66666666|77777777|88888888|99999999|12345678|87654321|01234567)
      return 0 ;;
  esac
  return 1
}

_code_exists() {
  "$BB" awk -F'|' -v c="$1" '$1==c {found=1} END{exit !found}' "$VFILE"
}

fmt_code() {
  _c=$1
  printf '%s-%s' "$(printf '%s' "$_c" | "$BB" cut -c1-4)" "$(printf '%s' "$_c" | "$BB" cut -c5-8)"
}

voucher_mint() {
  _plan=$1
  _count=$2
  _note=$3
  plan_meta "$_plan" >/dev/null || { printf 'unknown plan'; return 1; }
  case "$_count" in
    ''|*[!0-9]*) _count=1 ;;
  esac
  if [ "$_count" -lt 1 ] || [ "$_count" -gt 100 ]; then
    printf 'count must be 1 to 100'
    return 1
  fi
  _row=$(package_row "$_plan")
  [ -n "$_row" ] || { printf 'unknown package'; return 1; }
  _label=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $2}')
  _sec=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $3}')
  _down=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $4}')
  _up=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $5}')
  _price=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $6}')
  _note=$(sanitize_token "$_note")
  [ -n "$_price" ] && [ -z "$_note" ] && _note=$(sanitize_token "$_price")
  _now=$(now_epoch)
  _out=""
  _i=0
  while [ "$_i" -lt "$_count" ]; do
    _try=0
    _code=""
    while [ "$_try" -lt 20 ]; do
      _code=$(_rand_code)
      if _code_weak "$_code"; then
        _try=$((_try + 1))
        continue
      fi
      if _code_exists "$_code"; then
        _try=$((_try + 1))
        continue
      fi
      break
    done
    printf '%s|%s|%s|%s|%s|new||||%s|%s\n' \
      "$_code" "$_label" "$_sec" "$_down" "$_up" "$_now" "$_note" >> "$VFILE"
    _shown=$(fmt_code "$_code")
    if [ -z "$_out" ]; then
      _out="$_shown"
    else
      _out="$_out $_shown"
    fi
    _i=$((_i + 1))
  done
  log_event mint "$_count x $_label"
  printf '%s' "$_out"
}

_voucher_row() {
  "$BB" awk -F'|' -v c="$1" '$1==c {print; exit}' "$VFILE"
}

voucher_set_status() {
  _code=$1
  _status=$2
  _tmp="${VFILE}.tmp"
  "$BB" awk -F'|' -v OFS='|' -v c="$_code" -v st="$_status" '
    $1==c { $6=st }
    { print }
  ' "$VFILE" > "$_tmp" && mv "$_tmp" "$VFILE"
}

voucher_revoke() {
  _code=$(sanitize_code "$1")
  [ -n "$_code" ] || { printf 'missing code'; return 1; }
  _row=$(_voucher_row "$_code")
  [ -n "$_row" ] || { printf 'not found'; return 1; }
  voucher_set_status "$_code" revoked
  log_event revoke "$_code"
  return 0
}

voucher_delete() {
  _code=$(sanitize_code "$1")
  _row=$(_voucher_row "$_code")
  [ -n "$_row" ] || { printf 'not found'; return 1; }
  printf '%s|delete|%s\n' "$(now_epoch)" "$_row" >> "$HFILE"
  _tmp="${VFILE}.tmp"
  "$BB" awk -F'|' -v c="$_code" '$1!=c {print}' "$VFILE" > "$_tmp" && mv "$_tmp" "$VFILE"
  log_event delete "$_code"
}

voucher_unbind() {
  _code=$(sanitize_code "$1")
  _row=$(_voucher_row "$_code")
  [ -n "$_row" ] || { printf 'not found'; return 1; }
  printf '%s|unbind|%s\n' "$(now_epoch)" "$_row" >> "$HFILE"
  _tmp="${VFILE}.tmp"
  "$BB" awk -F'|' -v OFS='|' -v c="$_code" '
    $1==c && ($6=="active" || $6=="expired") { $6="new"; $7=""; $8=""; $9=""; $10=""; }
    { print }
  ' "$VFILE" > "$_tmp" && mv "$_tmp" "$VFILE"
  log_event unbind "$_code (history retained)"
}

voucher_sweep() {
  _now=$(now_epoch)
  _tmp="${VFILE}.tmp"
  _kick="${VFILE}.kick"
  rm -f "$_kick"
  "$BB" awk -F'|' -v OFS='|' -v now="$_now" -v kick="$_kick" '
    $6=="active" && $10 != "" && $10+0 > 0 && ($10+0) <= (now+0) {
      print $7 >> kick
      $6="expired"
    }
    { print }
  ' "$VFILE" > "$_tmp" && mv "$_tmp" "$VFILE"
  if [ -f "$_kick" ]; then
    "$BB" sed '/^$/d' "$_kick"
    rm -f "$_kick"
  fi
}

rate_allow() {
  _ip=$1
  [ -n "$_ip" ] || _ip=unknown
  _safe=$(printf '%s' "$_ip" | "$BB" tr -cd '0-9.')
  [ -n "$_safe" ] || _safe=unknown
  _f="$RNS_DATA/ratelimit/$_safe"
  _now=$(now_epoch)
  _count=0
  _start=$_now
  if [ -f "$_f" ]; then
    _count=$( "$BB" awk '{print $1}' "$_f" )
    _start=$( "$BB" awk '{print $2}' "$_f" )
  fi
  if [ $((_now - _start)) -gt 300 ]; then
    _count=0
    _start=$_now
  fi
  if [ "$_count" -ge 8 ]; then
    return 1
  fi
  _count=$((_count + 1))
  printf '%s %s\n' "$_count" "$_start" > "$_f"
  return 0
}

arp_mac() {
  _ip=$1
  _mac=""
  if [ -f /proc/net/arp ]; then
    _mac=$( "$BB" awk -v ip="$_ip" '$1==ip && $4!="00:00:00:00:00:00" {print $4; exit}' /proc/net/arp )
  fi
  if [ -z "$_mac" ] && command -v ip >/dev/null 2>&1; then
    _mac=$(ip neigh show 2>/dev/null | "$BB" awk -v ip="$_ip" '$1==ip {print $5; exit}')
  fi
  sanitize_mac "$_mac"
}

lab_mac() {
  _ip=$1
  # Stable locally-administered MAC so the lab preview can bind a device.
  _a=$(printf '%s' "$_ip" | "$BB" awk -F. '{printf "%02x", $3+0}')
  _b=$(printf '%s' "$_ip" | "$BB" awk -F. '{printf "%02x", $4+0}')
  printf '02:00:00:00:%s:%s' "$_a" "$_b"
}

mac_for_ip() {
  _ip=$1
  _mac=$(arp_mac "$_ip")
  if [ -n "$_mac" ]; then
    printf '%s' "$_mac"
    return 0
  fi
  if is_lab; then
    lab_mac "$_ip"
    return 0
  fi
  return 1
}

client_state() {
  _mac=$(sanitize_mac "$1")
  _state=$("$BB" awk -F'|' -v m="$_mac" '$1==m {print $2; exit}' "$CSTATE" 2>/dev/null)
  [ -n "$_state" ] && printf '%s' "$_state" || printf 'active'
}

client_set_state() {
  _mac=$(sanitize_mac "$1")
  _state=$(printf '%s' "$2" | "$BB" tr -cd 'a-zA-Z')
  case "$_state" in active|kicked|banned) ;; *) printf 'invalid client state'; return 1 ;; esac
  [ -n "$_mac" ] || { printf 'missing mac'; return 1; }
  _tmp="${CSTATE}.tmp"
  "$BB" awk -F'|' -v OFS='|' -v m="$_mac" '$1!=m {print}' "$CSTATE" > "$_tmp" || return 1
  printf '%s|%s|%s\n' "$_mac" "$_state" "$(now_epoch)" >> "$_tmp"
  mv "$_tmp" "$CSTATE"
  log_event client_state "$_mac $_state"
}

client_touch() {
  _mac=$(sanitize_mac "$1")
  _ip=$2
  _host=$(sanitize_token "$3")
  [ -n "$_mac" ] || return 0
  _now=$(now_epoch)
  _tmp="${CFILE}.tmp"
  if "$BB" awk -F'|' -v m="$_mac" '$1==m {found=1} END{exit !found}' "$CFILE"; then
    "$BB" awk -F'|' -v OFS='|' -v m="$_mac" -v ip="$_ip" -v h="$_host" -v now="$_now" '
      $1==m {
        if (ip != "") $2=ip;
        if (h != "") $3=h;
        $5=now;
      }
      { print }
    ' "$CFILE" > "$_tmp" && mv "$_tmp" "$CFILE"
  else
    printf '%s|%s|%s|%s|%s||||\n' "$_mac" "$_ip" "$_host" "$_now" "$_now" >> "$CFILE"
  fi
}

voucher_redeem() {
  _code=$(sanitize_code "$1")
  _ip=$2
  _code_len=$(printf '%s' "$_code" | "$BB" wc -c | "$BB" tr -d ' ')
  case "$_code_len" in 8|9|10|11|12) ;; *) printf 'invalid'; return 1 ;; esac
  if ! rate_allow "$_ip"; then
    printf 'slow'
    return 1
  fi
  _mac=$(mac_for_ip "$_ip") || {
    printf 'nomac'
    return 1
  }
  case "$(client_state "$_mac")" in
    banned) printf 'banned'; return 1 ;;
    kicked) printf 'kicked'; return 1 ;;
  esac
  _row=$(_voucher_row "$_code")
  if [ -z "$_row" ]; then
    log_event redeem_fail "bad code from $_ip"
    printf 'invalid'
    return 1
  fi
  _status=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $6}')
  _vmac=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $7}')
  _sec=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $3}')
  _label=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $2}')
  _down=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $4}')
  _up=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $5}')
  _exp=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $10}')
  _now=$(now_epoch)
  case "$_status" in
    revoked|expired)
      printf 'invalid'
      return 1
      ;;
    active)
      if [ "$_vmac" = "$_mac" ]; then
        client_touch "$_mac" "$_ip" ""
        voucher_set_ip "$_mac" "$_ip"
        printf 'ok|%s|%s|%s|%s|%s' "$_label" "$_exp" "$_down" "$_up" "$_mac"
        return 0
      fi
      log_event redeem_fail "code $_code already bound $_vmac tried $_mac"
      printf 'used'
      return 1
      ;;
    new)
      _exp=$((_now + _sec))
      _tmp="${VFILE}.tmp"
      if ! "$BB" awk -F'|' -v OFS='|' -v c="$_code" -v mac="$_mac" -v ip="$_ip" -v now="$_now" -v ends="$_exp" '
        $1==c { $6="active"; $7=mac; $8=ip; $9=now; $10=ends; print; next }
        { print }
      ' "$VFILE" > "$_tmp"; then
        printf 'invalid'
        return 1
      fi
      mv "$_tmp" "$VFILE"
      client_touch "$_mac" "$_ip" ""
      log_event redeem "$_code -> $_mac $_ip until $_exp"
      printf 'ok|%s|%s|%s|%s|%s' "$_label" "$_exp" "$_down" "$_up" "$_mac"
      return 0
      ;;
    *)
      printf 'invalid'
      return 1
      ;;
  esac
}

voucher_set_ip() {
  # Keep the stored lease IP current when a bound device reconnects
  # (a Wi-Fi off/on toggle can hand the same MAC a new DHCP lease).
  _mac=$(sanitize_mac "$1")
  _ip=$(printf '%s' "$2" | "$BB" tr -cd '0-9.')
  [ -n "$_mac" ] || return 1
  [ -n "$_ip" ] || return 1
  _tmp="${VFILE}.tmp"
  "$BB" awk -F'|' -v OFS='|' -v m="$_mac" -v ip="$_ip" '
    $6=="active" && $7==m && $8 != ip { $8=ip }
    { print }
  ' "$VFILE" > "$_tmp" && mv "$_tmp" "$VFILE"
  return 0
}

voucher_for_mac() {
  _mac=$(sanitize_mac "$1")
  case "$(client_state "$_mac")" in banned|kicked) return 1 ;; esac
  _now=$(now_epoch)
  "$BB" awk -F'|' -v m="$_mac" -v now="$_now" '
    $6=="active" && $7==m && ($10=="" || $10+0 > now) { print; exit }
  ' "$VFILE"
}

mbps_label() {
  _kbps=$1
  if [ -z "$_kbps" ]; then
    printf ''
    return
  fi
  if [ "$_kbps" -ge 1024 ]; then
    _mb=$((_kbps / 1024))
    printf '%s Mb' "$_mb"
  else
    printf '%s Kb' "$_kbps"
  fi
}

vouchers_json() {
  _filter=$(printf '%s' "$1" | "$BB" tr 'A-Z' 'a-z')
  _search=$(printf '%s' "$2" | "$BB" tr 'A-Z' 'a-z')
  _now=$(now_epoch)
  printf '['
  _first=1
  while IFS='|' read -r code label sec down up status mac ip act exp created note; do
    [ -n "$code" ] || continue
    _hay=$(printf '%s %s %s %s' "$code" "$label" "$mac" "$ip" | "$BB" tr 'A-Z' 'a-z')
    case "$_filter" in
      ''|all) ;;
      used) [ "$status" = "active" ] || continue ;;
      *) [ "$status" = "$_filter" ] || continue ;;
    esac
    [ -z "$_search" ] || case "$_hay" in *"$_search"*) ;; *) continue ;; esac
    _left=""
    if [ "$status" = "active" ] && [ -n "$exp" ]; then
      _left=$((exp - _now))
      [ "$_left" -lt 0 ] && _left=0
    fi
    _shown=$(fmt_code "$code")
    [ "$_first" = 1 ] || printf ','
    _first=0
    printf '{"code":"%s","display":"%s","plan":"%s","seconds":%s,"down_kbps":%s,"up_kbps":%s,"status":"%s","mac":"%s","ip":"%s","activated":%s,"expires":%s,"created":%s,"note":"%s","left":%s}' \
      "$(json_escape "$code")" \
      "$(json_escape "$_shown")" \
      "$(json_escape "$label")" \
      "${sec:-0}" \
      "${down:-0}" \
      "${up:-0}" \
      "$(json_escape "$status")" \
      "$(json_escape "$mac")" \
      "$(json_escape "$ip")" \
      "${act:-0}" \
      "${exp:-0}" \
      "${created:-0}" \
      "$(json_escape "$note")" \
      "${_left:-0}"
  done < "$VFILE"
  printf ']'
}

clients_json() {
  _now=$(now_epoch)
  printf '['
  _first=1
  while IFS='|' read -r mac ip host first last name phone note voucher; do
    [ -n "$mac" ] || continue
    _online=0
    if [ -n "$last" ] && [ $((_now - last)) -lt 90 ]; then
      _online=1
    fi
    _vrow=$(voucher_for_mac "$mac")
    _state=$(client_state "$mac")
    _st="waiting"
    case "$_state" in
      kicked|banned) _st=$_state ;;
      *) [ -n "$_vrow" ] && _st=active ;;
    esac
    _vcode=""; _vplan=""; _vdown=0; _vup=0; _vexp=0
    if [ -n "$_vrow" ]; then
      _vcode=$(printf '%s' "$_vrow" | "$BB" awk -F'|' '{print $1}')
      _vplan=$(printf '%s' "$_vrow" | "$BB" awk -F'|' '{print $2}')
      _vdown=$(printf '%s' "$_vrow" | "$BB" awk -F'|' '{print $4}')
      _vup=$(printf '%s' "$_vrow" | "$BB" awk -F'|' '{print $5}')
      _vexp=$(printf '%s' "$_vrow" | "$BB" awk -F'|' '{print $10}')
    fi
    [ "$_first" = 1 ] || printf ','
    _first=0
    printf '{"mac":"%s","ip":"%s","host":"%s","first":%s,"last":%s,"name":"%s","phone":"%s","note":"%s","voucher":"%s","plan":"%s","down_kbps":%s,"up_kbps":%s,"expires":%s,"online":%s,"state":"%s"}' \
      "$(json_escape "$mac")" "$(json_escape "$ip")" "$(json_escape "$host")" \
      "${first:-0}" "${last:-0}" "$(json_escape "$name")" "$(json_escape "$phone")" \
      "$(json_escape "$note")" "$(json_escape "$_vcode")" "$(json_escape "$_vplan")" \
      "${_vdown:-0}" "${_vup:-0}" "${_vexp:-0}" "$_online" "$_st"
  done < "$CFILE"
  printf ']'
}

count_status() {
  _st=$1
  "$BB" awk -F'|' -v s="$_st" '$6==s {n++} END{print n+0}' "$VFILE"
}

overview_json() {
  _now=$(now_epoch)
  _active=$(count_status active)
  _new=$(count_status new)
  _expired=$(count_status expired)
  _revoked=$(count_status revoked)
  _waiting=0
  _online=0
  while IFS='|' read -r mac ip host first last name phone note voucher; do
    [ -n "$mac" ] || continue
    if [ -n "$last" ] && [ $((_now - last)) -lt 90 ]; then
      if [ -n "$(voucher_for_mac "$mac")" ]; then
        _online=$((_online + 1))
      else
        _waiting=$((_waiting + 1))
      fi
    fi
  done < "$CFILE"
  printf '{"active":%s,"unused":%s,"expired":%s,"revoked":%s,"online":%s,"waiting":%s}' \
    "$_active" "$_new" "$_expired" "$_revoked" "$_online" "$_waiting"
}

events_json() {
  "$BB" tail -n 40 "$EVENTS_FILE" 2>/dev/null | "$BB" awk -F'|' '
    function esc(s) {
      gsub(/\\/, "\\\\", s)
      gsub(/"/, "\\\"", s)
      return s
    }
    BEGIN { printf "[" ; comma="" }
    $1 ~ /^[0-9]+$/ {
      printf "%s{\"t\":%s,\"action\":\"%s\",\"detail\":\"%s\"}", comma, $1, esc($2), esc($3)
      comma=","
    }
    END { printf "]" }
  '
}

active_macs() {
  _now=$(now_epoch)
  while IFS='|' read -r _code _label _sec _down _up _status _mac _ip _act _exp _created _note; do
    [ "$_status" = "active" ] && [ -n "$_mac" ] || continue
    [ -z "$_exp" ] || [ "$_exp" -gt "$_now" ] || continue
    case "$(client_state "$_mac")" in banned|kicked) continue ;; esac
    printf '%s|%s|%s|%s\n' "$_mac" "$_ip" "$_down" "$_up"
  done < "$VFILE"
}
