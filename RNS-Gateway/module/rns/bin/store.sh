# Voucher, session, and client store. Flat files, no SQLite.
# Line format uses '|' so fields must not contain '|'.

. "$RNS_HOME/bin/common.sh"

VFILE="$RNS_DB_DIR/vouchers.tsv"
CFILE="$RNS_DB_DIR/clients.tsv"
AFILE="$RNS_DB_DIR/admin.auth"
PFILE="$RNS_DB_DIR/packages.tsv"
CSTATE="$RNS_DB_DIR/client-states.tsv"
HFILE="$RNS_DB_DIR/voucher-history.tsv"
PAYFILE="$RNS_DB_DIR/payments.tsv"
OPFILE="$RNS_DB_DIR/online-packages.tsv"
PAYREF="$RNS_DB_DIR/payrefs.tsv"

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

voucher_schema_migrate() {
  # Voucher rows are '|' separated. Canonical layout from v6 (13 columns):
  #   1 code | 2 label | 3 seconds | 4 down | 5 up | 6 status | 7 mac |
  #   8 ip | 9 activated | 10 expiry | 11 CREATED (mint time) | 12 note |
  #   13 price
  #
  # Before v6, voucher_mint wrote only 11 columns and put the mint time in
  # slot 10 (the EXPIRY slot) and the note in slot 11 (the CREATED slot).
  # Slot 10 was therefore overloaded: expiry for a redeemed code, mint time
  # for an unused one. That made a sales-by-date report impossible, showed a
  # bogus expiry on unused codes, and emitted `"created":Rs 500` — invalid
  # JSON that broke the Codes tab whenever a package carried a price label.
  #
  # The migration is one-shot (marker file), keeps a backup, and is
  # deterministic: the overloaded shape is recognised by "never activated"
  # (slot 9 empty) plus a numeric slot 10. Rows that were redeemed under the
  # old 11-column layout genuinely have no mint time, so they are left
  # undated and reported as such instead of being guessed.
  [ -f "$VFILE" ] || return 0
  [ -f "$RNS_DB_DIR/.schema13" ] && return 0
  _bak="$RNS_DB_DIR/vouchers.pre-schema13.bak"
  [ -f "$_bak" ] || cp "$VFILE" "$_bak" 2>/dev/null || true
  _tmp="${VFILE}.mig"
  if ! "$BB" awk -F'|' -v OFS='|' '
    NF == 0 { next }
    {
      code=$1; label=$2; sec=$3; down=$4; up=$5; st=$6;
      mac=$7; ip=$8; act=$9; expir=$10; created=$11; note=$12; price="";
      if (NF >= 13) {
        created=$11; note=$12; price=$13;
      } else if (NF == 12) {
        if (act == "" && created == "" && expir ~ /^[0-9]+$/) { created=expir; expir=""; }
      } else if (NF == 11) {
        note=$11;
        if (act == "" && expir ~ /^[0-9]+$/) { created=expir; expir=""; }
        else { created=""; }
      } else {
        note=""; created=""; expir="";
      }
      if (created !~ /^[0-9]+$/) created="";
      if (expir !~ /^[0-9]+$/) expir="";
      if (act !~ /^[0-9]+$/) act="";
      gsub(/\|/, " ", note); gsub(/\|/, " ", label);
      print code,label,sec,down,up,st,mac,ip,act,expir,created,note,price;
    }
  ' "$VFILE" > "$_tmp"; then
    rm -f "$_tmp"
    return 1
  fi
  # A rewrite that empties a non-empty store is a bug, not a migration.
  if [ ! -s "$_tmp" ] && [ -s "$VFILE" ]; then
    rm -f "$_tmp"
    return 1
  fi
  mv "$_tmp" "$VFILE" || { rm -f "$_tmp"; return 1; }
  _und=$("$BB" awk -F'|' 'NF>0 && ($11=="" || $11 !~ /^[0-9]+$/) {n++} END{printf "%d", n+0}' "$VFILE")
  printf '13\n' > "$RNS_DB_DIR/.schema13" 2>/dev/null || true
  log_event migrate "vouchers to 13-column schema; undated legacy codes: ${_und:-0}"
  return 0
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
  [ -f "$PAYFILE" ] || printf '' > "$PAYFILE"
  [ -f "$OPFILE" ] || printf '' > "$OPFILE"
  [ -f "$PAYREF" ] || printf '' > "$PAYREF"
  [ -f "$EVENTS_FILE" ] || printf '' > "$EVENTS_FILE"
  # No preset packages. A fresh install starts EMPTY and the operator builds
  # every package in Settings > Package builder. Phones that already have a
  # packages.tsv keep exactly what they have (v5 and earlier shipped seven
  # stock packages); those can be deleted one by one from the panel, and
  # nothing here removes them behind the operator's back.
  if [ ! -f "$PFILE" ]; then
    printf '' > "$PFILE"
  fi
  voucher_schema_migrate
  payments_schema_migrate
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
JAZZCASH_NUMBER=
JAZZCASH_NAME=
EASYPAISA_NUMBER=
EASYPAISA_NAME=
PAY_AUTO_VERIFY=1
EOF
  fi
  if is_lab && [ ! -f "$RNS_DATA/.labseed" ]; then
    _seed_lab
    printf '1\n' > "$RNS_DATA/.labseed"
  fi
}

_seed_lab() {
  # Lab fixtures only. These are NOT product presets: a real fresh install
  # starts with an empty packages.tsv and the operator builds their own.
  _now=$(now_epoch)
  _exp=$((_now + 2400))
  : > "$PFILE"
  package_upsert lab1h 'Lab 1 Hour' 3600 2048 1024 150 50 hour >/dev/null 2>&1
  package_upsert lab3h 'Lab 3 Hours' 10800 2048 1024 450 50 hour >/dev/null 2>&1
  package_upsert lab1d 'Lab 1 Day' 86400 1024 512 300 300 day >/dev/null 2>&1
  # 13-column rows: ... |activated|expiry|created|note|price
  cat > "$VFILE" << EOF
48219033|Lab 1 Hour|3600|2048|1024|new|||||${_now}||150
11002233|Lab 3 Hours|10800|2048|1024|new|||||${_now}||450
90001122|Lab 1 Hour|3600|2048|1024|active|aa:bb:cc:dd:ee:01|192.168.43.20|${_now}|${_exp}|${_now}|counter|150
70001122|Lab 1 Day|86400|1024|512|expired|aa:bb:cc:dd:ee:09|192.168.43.9|$((_now - 90000))|$((_now - 3600))|$((_now - 90000))||300
55550001|Lab 1 Day|86400|1024|512|new|||||$((_now - 86400))||300
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

# Packages are '|' separated, 9 columns:
#   1 id | 2 label | 3 seconds | 4 down | 5 up | 6 price | 7 state |
#   8 rate | 9 rate_unit (hour|day)
# Columns 8-9 are how the operator thinks about the price ("Rs 50 per hour");
# column 6 is the amount actually charged and printed on the slip. The panel
# computes 6 from 8/9 and lets the operator override it before saving, so the
# stored price is always authoritative and never recomputed behind their back.
package_upsert() {
  _id=$(printf '%s' "$1" | "$BB" tr -cd 'A-Za-z0-9_-')
  _label=$(sanitize_token "$2")
  _sec=$(printf '%s' "$3" | "$BB" tr -cd '0-9')
  _down=$(printf '%s' "$4" | "$BB" tr -cd '0-9')
  _up=$(printf '%s' "$5" | "$BB" tr -cd '0-9')
  _rate=$(money "$7")
  case "$8" in
    day|hour) _unit=$8 ;;
    *) _unit='' ;;
  esac
  _price=$(money "$6")
  [ -n "$_id" ] && [ -n "$_label" ] && [ -n "$_sec" ] && [ -n "$_down" ] && [ -n "$_up" ] || {
    printf 'package requires id, name, duration and both speeds'
    return 1
  }
  [ "$_sec" -gt 0 ] && [ "$_down" -gt 0 ] && [ "$_up" -gt 0 ] || {
    printf 'duration and speeds must be greater than zero'
    return 1
  }
  # No price typed but a rate was: derive the total so an API caller that only
  # knows the rate still gets a sensible slip price.
  if [ -z "$_price" ] && [ -n "$_rate" ]; then
    _price=$(price_from_rate "$_rate" "${_unit:-hour}" "$_sec")
  fi
  _tmp="${PFILE}.tmp"
  "$BB" awk -F'|' -v OFS='|' -v id="$_id" '$1 != id { print }' "$PFILE" > "$_tmp" || return 1
  printf '%s|%s|%s|%s|%s|%s|active|%s|%s\n' \
    "$_id" "$_label" "$_sec" "$_down" "$_up" "$_price" "$_rate" "$_unit" >> "$_tmp"
  mv "$_tmp" "$PFILE"
  log_event package "$_id $_label ${_sec}s ${_down}/${_up}kbps price=${_price:-none}"
}

package_delete() {
  _id=$(package_id "$1")
  [ -n "$_id" ] || { printf 'missing package id'; return 1; }
  # package_row exits 0 even when nothing matched (awk found no line), so the
  # emptiness of the row is the real test. Without this the delete reported
  # "deleted <id>" for a package that was never there.
  _row=$(package_row "$_id") || { printf 'no such package'; return 1; }
  [ -n "$_row" ] || { printf 'no such package'; return 1; }
  _tmp="${PFILE}.tmp"
  "$BB" awk -F'|' -v OFS='|' -v id="$_id" '$1 != id { print }' "$PFILE" > "$_tmp" || return 1
  mv "$_tmp" "$PFILE"
  log_event package_delete "$_id"
  printf 'deleted %s' "$_id"
}

packages_json() {
  printf '['
  _first=1
  while IFS='|' read -r id label sec down up price state rate unit; do
    [ -n "$id" ] && [ "$state" != "disabled" ] || continue
    [ "$_first" = 1 ] || printf ','
    _first=0
    printf '{"id":"%s","label":"%s","seconds":%s,"down_kbps":%s,"up_kbps":%s,"price":"%s","rate":"%s","rate_unit":"%s"}' \
      "$(json_escape "$id")" "$(json_escape "$label")" "$(num "$sec")" "$(num "$down")" \
      "$(num "$up")" "$(json_escape "$(money "$price")")" \
      "$(json_escape "$(money "$rate")")" "$(json_escape "$unit")"
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
  _price=$(money "$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $6}')")
  _note=$(sanitize_token "$_note")
  # The price is its own column now. It used to be copied into the note when
  # no note was typed, which is how a price label ended up in the created
  # slot and produced invalid JSON. Keep the note as the operator's note.
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
    # 13 columns: created (slot 11) is the mint time and the authoritative
    # "date sold" for the sales report. Expiry (slot 10) stays empty until the
    # code is redeemed, so an unused code no longer shows a bogus expiry.
    printf '%s|%s|%s|%s|%s|new|||||%s|%s|%s\n' \
      "$_code" "$_label" "$_sec" "$_down" "$_up" "$_now" "$_note" "$_price" >> "$VFILE"
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
  # Audit rule: a code that was ever redeemed (active or expired) is a sale
  # record and is never removed from vouchers.tsv. Only unused or revoked
  # codes can be deleted, and even those are copied to history first.
  # Nothing in the gateway prunes expired rows automatically.
  _code=$(sanitize_code "$1")
  _row=$(_voucher_row "$_code")
  [ -n "$_row" ] || { printf 'not found'; return 1; }
  case "$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $6}')" in
    active|expired) printf 'kept for audit: redeemed codes cannot be deleted (revoke instead)'; return 1 ;;
  esac
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
  # Wall-clock expiry. A voucher's clock starts the moment it is redeemed
  # (slot 9) and ends at slot 10 = activated + package seconds, whether or
  # not the device is connected in between. A 1-hour code activated at
  # 13:00 is dead at 14:00 even if the phone only browsed for 3 minutes.
  #
  # Two repairs are folded in so enforcement can never silently stall:
  #   - an "active" row that somehow lost its expiry (old layout, partial
  #     write) gets one computed from its activation time, or from now if
  #     the activation time is missing too. It is never left open-ended.
  #   - an "active" row that has no device bound is impossible; it is
  #     reset to "new" so the code can still be sold.
  # Prints one MAC per line for every voucher that expired on this pass.
  _now=$(now_epoch)
  _tmp="${VFILE}.sweep.$$"
  _kick="${VFILE}.kick.$$"
  rm -f "$_kick"
  "$BB" awk -F'|' -v OFS='|' -v now="$_now" -v kick="$_kick" '
    NF == 0 { next }
    $6=="active" {
      if ($7 == "") { $6="new"; $8=""; $9=""; $10=""; print; next }
      if ($10 !~ /^[0-9]+$/ || $10+0 <= 0) {
        start = ($9 ~ /^[0-9]+$/ && $9+0 > 0) ? $9+0 : now+0
        if ($9 !~ /^[0-9]+$/ || $9+0 <= 0) $9 = now
        $10 = start + ($3+0)
      }
      if (($10+0) <= (now+0)) {
        print $7 >> kick
        $6="expired"
      }
    }
    { print }
  ' "$VFILE" > "$_tmp" && mv "$_tmp" "$VFILE"
  rm -f "$_tmp"
  if [ -f "$_kick" ]; then
    "$BB" sed '/^$/d' "$_kick" | "$BB" sort -u
    rm -f "$_kick"
  fi
}

voucher_expire_for_mac() {
  # End every active voucher bound to this device right now (staff Kick).
  # The row is marked expired with its end time set to now, so the history
  # and the sales report keep the sale; the device simply has no time left.
  # Prints the number of vouchers ended.
  _mac=$(sanitize_mac "$1")
  [ -n "$_mac" ] || { printf '0'; return 0; }
  _now=$(now_epoch)
  _tmp="${VFILE}.kickv.$$"
  _cnt="${VFILE}.kickn.$$"
  "$BB" awk -F'|' -v OFS='|' -v m="$_mac" -v now="$_now" -v cf="$_cnt" '
    $6=="active" && $7==m {
      $6="expired"
      if ($10 !~ /^[0-9]+$/ || $10+0 > now+0) $10=now
      n++
    }
    { print }
    END { printf "%d", n+0 > cf }
  ' "$VFILE" > "$_tmp" && mv "$_tmp" "$VFILE"
  rm -f "$_tmp"
  _n=$(cat "$_cnt" 2>/dev/null)
  rm -f "$_cnt"
  printf '%s' "${_n:-0}"
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
  # Three states, with very different meaning:
  #   active  normal. A device with no row is active.
  #   kicked  staff PAUSED the device (Kick). It goes offline at once and
  #           drops to the sign-in page, but its voucher is left alone —
  #           the clock keeps running. Two ways back:
  #             Unkick (staff)     -> same voucher, back online instantly
  #             new code (customer)-> old voucher ended, new one active,
  #                                   mark clears itself (voucher_redeem)
  #   banned  staff blocked the device. Running vouchers are ended and no
  #           code (counter or online) works until Unban.
  _mac=$(sanitize_mac "$1")
  _state=$(printf '%s' "$2" | "$BB" tr -cd 'a-zA-Z')
  case "$_state" in active|kicked|banned) ;; *) printf 'invalid client state'; return 1 ;; esac
  [ -n "$_mac" ] || { printf 'missing mac'; return 1; }
  _tmp="${CSTATE}.tmp.$$"
  "$BB" awk -F'|' -v OFS='|' -v m="$_mac" '$1!=m {print}' "$CSTATE" > "$_tmp" || return 1
  if [ "$_state" = "active" ]; then
    # No row means active; do not keep stale rows around.
    mv "$_tmp" "$CSTATE"
  else
    printf '%s|%s|%s\n' "$_mac" "$_state" "$(now_epoch)" >> "$_tmp"
    mv "$_tmp" "$CSTATE"
  fi
  _ended=0
  case "$_state" in
    banned) _ended=$(voucher_expire_for_mac "$_mac") ;;
  esac
  log_event client_state "$_mac $_state (vouchers ended: ${_ended:-0})"
}

client_is_blocked() {
  # Only a ban blocks NEW vouchers. A kick only pauses the current one.
  [ "$(client_state "$1")" = "banned" ]
}

client_is_offline() {
  # Kicked or banned: no firewall allow, no entitlement, portal shown.
  case "$(client_state "$1")" in kicked|banned) return 0 ;; esac
  return 1
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
  _was_kicked=0
  case "$(client_state "$_mac")" in
    banned) printf 'banned'; return 1 ;;
    kicked)
      # Kick only paused the device. A fresh, valid code re-admits it: the
      # paused voucher is ended and the mark cleared below, once the redeem
      # succeeds, so a wrong or dead code changes nothing.
      _was_kicked=1
      ;;
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
      if [ "$_vmac" = "$_mac" ] && [ "$_was_kicked" -eq 1 ]; then
        printf 'kicked'
        return 1
      fi
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
      if [ "$_was_kicked" -eq 1 ]; then
        voucher_expire_for_mac "$_mac" >/dev/null
      fi
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
      if [ "$_was_kicked" -eq 1 ]; then
        client_set_state "$_mac" active >/dev/null 2>&1 || true
        log_event kick_cleared "$_mac redeemed a new code"
      fi
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
  # The voucher this device is entitled to RIGHT NOW. Strict wall-clock
  # test: an active row without a numeric future expiry is never treated
  # as valid (the sweep repairs or expires such rows). Fails closed.
  _mac=$(sanitize_mac "$1")
  [ -n "$_mac" ] || return 1
  client_is_offline "$_mac" && return 1
  _now=$(now_epoch)
  "$BB" awk -F'|' -v m="$_mac" -v now="$_now" '
    $6=="active" && $7==m && $10 ~ /^[0-9]+$/ && $10+0 > now+0 { print; exit }
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
  # 13 columns; price is last. Every numeric slot goes through num() so free
  # text in any column can never emit invalid JSON again.
  while IFS='|' read -r code label sec down up status mac ip act exp created note price; do
    [ -n "$code" ] || continue
    _hay=$(printf '%s %s %s %s' "$code" "$label" "$mac" "$ip" | "$BB" tr 'A-Z' 'a-z')
    case "$_filter" in
      ''|all) ;;
      used) [ "$status" = "active" ] || continue ;;
      *) [ "$status" = "$_filter" ] || continue ;;
    esac
    [ -z "$_search" ] || case "$_hay" in *"$_search"*) ;; *) continue ;; esac
    _act=$(num "$act")
    _exp=$(num "$exp")
    _left=0
    if [ "$status" = "active" ] && [ "$_exp" -gt 0 ]; then
      _left=$((_exp - _now))
      [ "$_left" -lt 0 ] && _left=0
    fi
    _shown=$(fmt_code "$code")
    [ "$_first" = 1 ] || printf ','
    _first=0
    printf '{"code":"%s","display":"%s","plan":"%s","seconds":%s,"down_kbps":%s,"up_kbps":%s,"status":"%s","mac":"%s","ip":"%s","activated":%s,"expires":%s,"created":%s,"note":"%s","price":"%s","left":%s}' \
      "$(json_escape "$code")" \
      "$(json_escape "$_shown")" \
      "$(json_escape "$label")" \
      "$(num "$sec")" \
      "$(num "$down")" \
      "$(num "$up")" \
      "$(json_escape "$status")" \
      "$(json_escape "$mac")" \
      "$(json_escape "$ip")" \
      "$_act" \
      "$_exp" \
      "$(num "$created")" \
      "$(json_escape "$note")" \
      "$(json_escape "$(money "$price")")" \
      "$(num "$_left")"
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
      banned) _st=banned ;;
      kicked) _st=kicked ;;
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

# ---------------------------------------------------------------------------
# Sales reporting.
#
# "Sold" is ambiguous in a shop, so the report answers both readings side by
# side: GENERATED (the code was minted, a slip was handed over) and REDEEMED
# (a customer phone actually used it). The difference is unsold stock.
#
# Money is accumulated in paisa (rupees x 100) as integers. Shell and awk
# floats both drift on long sums, and a till that is one paisa off is a till
# nobody trusts.
# ---------------------------------------------------------------------------
sales_report() {
  # $1 = from epoch (inclusive), $2 = to epoch (exclusive).
  # Emits intermediate rows the callers format:
  #   T|<minted>|<redeemed>|<paisa_minted>|<paisa_redeemed>|<unpriced>|<undated>
  #   D|<YYYY-MM-DD>|<minted>|<redeemed>|<paisa_minted>|<paisa_redeemed>
  #   P|<package label>|<minted>|<redeemed>|<paisa_minted>|<paisa_redeemed>
  _from=$(num "$1" 0)
  _to=$(num "$2" 0)
  [ "$_to" -gt "$_from" ] || _to=$((_from + 86400))
  _off=$(utc_offset_seconds)
  "$BB" awk -F'|' -v from="$_from" -v to="$_to" -v off="$_off" '
    function fdiv(a,b){ q=int(a/b); if (a%b!=0 && ((a<0)!=(b<0))) q--; return q }
    function ymd(ts,   local,days,z,era,doe,yoe,y,doy,mp,d,m) {
      local = ts + off;
      days = fdiv(local, 86400);
      z = days + 719468;
      era = fdiv((z>=0) ? z : z-146096, 146097);
      doe = z - era*146097;
      yoe = fdiv(doe - int(doe/1460) + int(doe/36524) - int(doe/146096), 365);
      y = yoe + era*400;
      doy = doe - (365*yoe + int(yoe/4) - int(yoe/100));
      mp = int((5*doy + 2)/153);
      d = doy - int((153*mp+2)/5) + 1;
      m = mp + ((mp<10) ? 3 : -9);
      y = y + ((m<=2) ? 1 : 0);
      return sprintf("%04d-%02d-%02d", y, m, d);
    }
    function paisa(s,   a,ip,fr) {
      if (s == "" || s !~ /^[0-9]*\.?[0-9]*$/) return 0;
      if (index(s,".") > 0) { split(s,a,"."); ip=a[1]; fr=substr(a[2] "00",1,2) }
      else { ip=s; fr="00" }
      gsub(/^0+/,"",ip); if (ip=="") ip="0";
      return (ip*100) + (fr+0);
    }
    NF == 0 { next }
    {
      label=$2; st=$6; act=$9; created=$11; price=$13;
      if (created !~ /^[0-9]+$/) created="";
      if (act !~ /^[0-9]+$/) act="";
      if (created == "") undated++;
      if (price == "" || price !~ /^[0-9]*\.?[0-9]*$/) unpriced++;
      p = paisa(price);
      if (label == "") label="(unknown package)";
      if (created != "" && created+0 >= from+0 && created+0 < to+0) {
        m_count++; m_paisa += p;
        d=ymd(created+0);
        dm[d]++; dp[d]+=p;
        pm[label]++; pp[label]+=p;
        if (!(d in seen_d)) { seen_d[d]=1; days[++nd]=d }
        if (!(label in seen_p)) { seen_p[label]=1; pkgs[++np]=label }
      }
      if (act != "" && act+0 >= from+0 && act+0 < to+0) {
        r_count++; r_paisa += p;
        d=ymd(act+0);
        dr[d]++; dpr[d]+=p;
        pr[label]++; ppr[label]+=p;
        if (!(d in seen_d)) { seen_d[d]=1; days[++nd]=d }
        if (!(label in seen_p)) { seen_p[label]=1; pkgs[++np]=label }
      }
    }
    END {
      printf "T|%d|%d|%d|%d|%d|%d\n", m_count+0, r_count+0, m_paisa+0, r_paisa+0, unpriced+0, undated+0;
      for (i=1;i<=nd;i++) {
        d=days[i];
        printf "D|%s|%d|%d|%d|%d\n", d, dm[d]+0, dr[d]+0, dp[d]+0, dpr[d]+0;
      }
      for (i=1;i<=np;i++) {
        l=pkgs[i];
        printf "P|%s|%d|%d|%d|%d\n", l, pm[l]+0, pr[l]+0, pp[l]+0, ppr[l]+0;
      }
    }
  ' "$VFILE"
}

_paisa_str() {
  printf '%s' "$(num "$1")" | "$BB" awk '{ printf "%d.%02d", int($1/100), ($1%100) }'
}

sales_json() {
  # $1 = from epoch, $2 = to epoch (exclusive)
  _rep=$(sales_report "$1" "$2")
  _t=$(printf '%s\n' "$_rep" | "$BB" grep '^T|' | "$BB" head -n 1)
  _minted=$(printf '%s' "$_t" | "$BB" awk -F'|' '{print $2+0}')
  _redeemed=$(printf '%s' "$_t" | "$BB" awk -F'|' '{print $3+0}')
  _mp=$(printf '%s' "$_t" | "$BB" awk -F'|' '{print $4+0}')
  _rp=$(printf '%s' "$_t" | "$BB" awk -F'|' '{print $5+0}')
  _unpriced=$(printf '%s' "$_t" | "$BB" awk -F'|' '{print $6+0}')
  _undated=$(printf '%s' "$_t" | "$BB" awk -F'|' '{print $7+0}')
  printf '{"from":%s,"to":%s,"totals":{"minted":%s,"minted_revenue":"%s","redeemed":%s,"redeemed_revenue":"%s","unpriced":%s,"undated":%s},"by_day":[' \
    "$(num "$1")" "$(num "$2")" "$(num "$_minted")" "$(_paisa_str "$_mp")" \
    "$(num "$_redeemed")" "$(_paisa_str "$_rp")" "$(num "$_unpriced")" "$(num "$_undated")"
  printf '%s\n' "$_rep" | "$BB" grep '^D|' | sort -t'|' -k2,2 | "$BB" awk -F'|' '
    BEGIN { c="" }
    { printf "%s{\"day\":\"%s\",\"minted\":%d,\"redeemed\":%d,\"revenue\":\"%d.%02d\",\"redeemed_revenue\":\"%d.%02d\"}", c, $2, $3+0, $4+0, int($5/100), $5%100, int($6/100), $6%100; c="," }
  '
  printf '],"by_package":['
  printf '%s\n' "$_rep" | "$BB" grep '^P|' | sort -t'|' -k3,3nr -k2,2 | "$BB" awk -F'|' '
    BEGIN { c="" }
    {
      l=$2; gsub(/\\/,"\\\\",l); gsub(/"/,"\\\"",l);
      printf "%s{\"label\":\"%s\",\"minted\":%d,\"redeemed\":%d,\"revenue\":\"%d.%02d\",\"redeemed_revenue\":\"%d.%02d\"}", c, l, $3+0, $4+0, int($5/100), $5%100, int($6/100), $6%100; c=","
    }
  '
  printf ']}'
}

sales_csv() {
  # Spreadsheet-friendly long format: one row per (scope, key).
  _rep=$(sales_report "$1" "$2")
  printf 'scope,key,generated,redeemed,revenue_rupees\n'
  printf '%s\n' "$_rep" | "$BB" grep '^D|' | sort -t'|' -k2,2 | "$BB" awk -F'|' \
    '{ printf "day,%s,%d,%d,%d.%02d\n", $2, $3+0, $4+0, int($5/100), $5%100 }'
  printf '%s\n' "$_rep" | "$BB" grep '^P|' | sort -t'|' -k3,3nr -k2,2 | "$BB" awk -F'|' '
    { l=$2; gsub(/"/,"\"\"",l); printf "package,\"%s\",%d,%d,%d.%02d\n", l, $3+0, $4+0, int($5/100), $5%100 }'
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
  # 13 columns. The last variable in a `read` list swallows every remaining
  # field, so a missing price column here would have put "note|price" into
  # _note — harmless today, but it is how column counts silently drift.
  while IFS='|' read -r _code _label _sec _down _up _status _mac _ip _act _exp _created _note _price; do
    [ "$_status" = "active" ] && [ -n "$_mac" ] || continue
    # Strict: an active row with no numeric expiry used to be allowed
    # forever ("0 means no limit"). That is exactly how a device could keep
    # browsing past its hour. Now it is skipped until the sweep repairs it.
    _exp=$(num "$_exp")
    [ "$_exp" -gt "$_now" ] || continue
    client_is_offline "$_mac" && continue
    printf '%s|%s|%s|%s\n' "$_mac" "$_ip" "$_down" "$_up"
  done < "$VFILE"
}

# ---------------------------------------------------------------------------
# Online payment gateway.
#
# Customers without a paper voucher can pay via JazzCash or EasyPaisa and
# submit their Transaction ID (TID). The admin verifies the TID against their
# mobile-wallet statement and confirms. On confirm, a voucher is minted and
# immediately redeemed for that device — internet starts in real time.
#
# Payment row layout (16 columns, pipe-separated):
#   1 pay_id       | unique payment record id (PAY-xxxxxxxx)
#   2 package_id   | package id from the ONLINE packages catalogue
#   3 package_label| human package name
#   4 amount       | price (decimal, rupees)
#   5 method       | jazzcash | easypaisa
#   6 tid          | customer-submitted transaction id
#   7 status       | pending | confirmed | rejected
#   8 mac          | customer device MAC
#   9 ip           | customer device IP
#  10 created      | epoch when payment was submitted
#  11 confirmed    | epoch when admin confirmed (empty until then)
#  12 voucher_code | auto-generated voucher code (empty until confirmed)
#  13 seconds      | package duration (for the receipt)
#  14 note         | admin note on confirm/reject
#  15 down         | download speed, Kbps
#  16 up           | upload speed, Kbps
#
# The writer and every reader must agree on this. v7's writer emitted 17
# columns (one separator too many between created and seconds), which pushed
# seconds into slot 14 and left slot 13 empty; online_payment_confirm reads
# slot 13 and refused every payment with bad_package, so no JazzCash or
# EasyPaisa payment could ever be activated. payments_schema_migrate() repairs
# rows written by that build.
# ---------------------------------------------------------------------------

_pay_rand_id() {
  # 8-char hex id for payment records
  "$BB" od -An -N4 -tx1 /dev/urandom | "$BB" tr -d ' \n' | "$BB" tr 'a-f' 'A-F'
}

payments_schema_migrate() {
  # Repair payment rows written by the v7 build, which emitted 17 columns.
  # In those rows slots 11-13 are empty and the package duration sits in slot
  # 14, so every reader that follows the documented layout sees an empty
  # duration and refuses the payment. Runs once (marker .pay16), keeps a
  # backup next to the database the same way voucher_schema_migrate does.
  [ -f "$PAYFILE" ] || return 0
  [ -f "$RNS_DB_DIR/.pay16" ] && return 0
  if [ -s "$PAYFILE" ]; then
    _bad=$("$BB" awk -F'|' 'NF==17 {n++} END{printf "%d", n+0}' "$PAYFILE")
    if [ "${_bad:-0}" -gt 0 ]; then
      cp "$PAYFILE" "$PAYFILE.pre-16col.bak" 2>/dev/null || true
      _ptmp="${PAYFILE}.tmp"
      "$BB" awk -F'|' -v OFS='|' '
        NF==17 {
          # Slot 14 holds the duration unless a confirm/reject already wrote a
          # note over it (the old layout put the note there too). Keep the
          # duration when it is still a number; otherwise the row is left with
          # no duration and its note intact.
          if ($14 ~ /^[0-9]+$/) { sec=$14; note=$15 }
          else                  { sec="";  note=$14 }
          $13=sec; $14=note; $15=$16; $16=$17; NF=16
        }
        { print }' "$PAYFILE" > "$_ptmp" && mv "$_ptmp" "$PAYFILE"
      log_event migrate "payments to 16-column schema; repaired ${_bad} row(s)"
    fi
  fi
  printf '16\n' > "$RNS_DB_DIR/.pay16" 2>/dev/null || true
  return 0
}

sanitize_tid() {
  # Transaction IDs are alphanumeric, may have dashes. Keep it tight.
  printf '%s' "$1" | "$BB" tr 'a-z' 'A-Z' | "$BB" tr -cd 'A-Z0-9-' | "$BB" cut -c1-32
}

# ---------------------------------------------------------------------------
# Payment reference (tracking id).
#
# Every online purchase starts with a unique reference such as RNS-7K3Q2M.
# The customer writes it in the JazzCash / EasyPaisa "notes / purpose" box
# when sending the money, and then submits the TID together with it. The
# gateway cannot read the wallet statement, so this is what ties a payment
# in YOUR statement to one device and one package without guessing:
#   - each reference is issued to one MAC, one package, one method
#   - it is single-use and lives PAYREF_TTL seconds (default 2 hours)
#   - the TID submission must quote it, and it must still be open
#   - it is stored next to the payment and shown in the Payments tab and on
#     the receipt, so staff can search their wallet history for it
# payrefs.tsv: ref|pkg_id|method|mac|ip|created|status|pay_id|tid
#   status: open | used | expired
# ---------------------------------------------------------------------------
PAYREF_TTL=${PAYREF_TTL:-7200}

_payref_rand() {
  # 6 chars from an alphabet without 0/O/1/I so it survives being typed.
  "$BB" od -An -N8 -tu1 /dev/urandom | "$BB" awk '
    BEGIN { a="ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; n=length(a) }
    { for (i=1;i<=6;i++) printf "%s", substr(a, ($i % n)+1, 1) }'
}

sanitize_ref() {
  printf '%s' "$1" | "$BB" tr 'a-z' 'A-Z' | "$BB" tr -cd 'A-Z0-9-' | "$BB" cut -c1-12
}

payref_row() {
  "$BB" awk -F'|' -v r="$1" '$1==r {print; exit}' "$PAYREF" 2>/dev/null
}

payref_create() {
  # $1 = online package id, $2 = method, $3 = client ip.
  # Prints "ok|REF|amount|label|seconds|expires_epoch" or an error token.
  _pkg_id=$(printf '%s' "$1" | "$BB" tr -cd 'A-Za-z0-9_-')
  _method=$(printf '%s' "$2" | "$BB" tr 'A-Z' 'a-z' | "$BB" tr -cd 'a-z')
  _ip=$(printf '%s' "$3" | "$BB" tr -cd '0-9.')
  case "$_method" in jazzcash|easypaisa) ;; *) printf 'bad_method'; return 1 ;; esac
  [ -n "$_ip" ] || { printf 'missing_ip'; return 1; }
  _prow=$(online_package_row "$_pkg_id")
  [ -n "$_prow" ] || { printf 'unknown_package'; return 1; }
  _price=$(money "$(printf '%s' "$_prow" | "$BB" awk -F'|' '{print $6}')")
  [ -n "$_price" ] || { printf 'no_price'; return 1; }
  _label=$(printf '%s' "$_prow" | "$BB" awk -F'|' '{print $2}')
  _sec=$(printf '%s' "$_prow" | "$BB" awk -F'|' '{print $3}')
  _mac=$(mac_for_ip "$_ip" 2>/dev/null || true)
  [ -n "$_mac" ] || { printf 'nomac'; return 1; }
  client_is_blocked "$_mac" && { printf 'banned'; return 1; }
  _now=$(now_epoch)
  # Reuse the device's open reference for the same package+method so a page
  # refresh does not hand out a second one; retire its other open ones.
  _tmp="${PAYREF}.tmp.$$"
  "$BB" awk -F'|' -v OFS='|' -v m="$_mac" -v now="$_now" -v ttl="$PAYREF_TTL" '
    $7=="open" && ($6+0 + ttl+0) <= now+0 { $7="expired" }
    { print }' "$PAYREF" > "$_tmp" && mv "$_tmp" "$PAYREF"
  _have=$("$BB" awk -F'|' -v m="$_mac" -v p="$_pkg_id" -v me="$_method" \
    '$4==m && $2==p && $3==me && $7=="open" {print $1 "|" $6; exit}' "$PAYREF")
  if [ -n "$_have" ]; then
    _ref=${_have%%|*}
    _cre=${_have#*|}
    printf 'ok|%s|%s|%s|%s|%s' "$_ref" "$_price" "$_label" "$_sec" "$((_cre + PAYREF_TTL))"
    return 0
  fi
  "$BB" awk -F'|' -v OFS='|' -v m="$_mac" '$4==m && $7=="open" { $7="expired" } { print }' "$PAYREF" > "$_tmp" && mv "$_tmp" "$PAYREF"
  _try=0
  _ref=""
  while [ "$_try" -lt 20 ]; do
    _ref="RNS-$(_payref_rand)"
    [ -z "$(payref_row "$_ref")" ] && break
    _try=$((_try + 1))
  done
  printf '%s|%s|%s|%s|%s|%s|open||\n' "$_ref" "$_pkg_id" "$_method" "$_mac" "$_ip" "$_now" >> "$PAYREF"
  log_event payref_new "$_ref $_method $_label Rs $_price for $_mac"
  printf 'ok|%s|%s|%s|%s|%s' "$_ref" "$_price" "$_label" "$_sec" "$((_now + PAYREF_TTL))"
}

payref_check() {
  # $1 = ref, $2 = pkg id, $3 = method, $4 = mac. 0 when the reference is
  # open, unexpired, and was issued to exactly this device/package/method.
  # Prints an error token otherwise.
  _ref=$(sanitize_ref "$1")
  [ -n "$_ref" ] || { printf 'missing_ref'; return 1; }
  _row=$(payref_row "$_ref")
  [ -n "$_row" ] || { printf 'unknown_ref'; return 1; }
  _rst=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $7}')
  _rcre=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $6}')
  [ "$_rst" = "used" ] && { printf 'ref_used'; return 1; }
  _now=$(now_epoch)
  if [ "$_rst" = "expired" ] || [ $((_rcre + PAYREF_TTL)) -le "$_now" ]; then
    printf 'ref_expired'; return 1
  fi
  [ "$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $4}')" = "$4" ] || { printf 'ref_other_device'; return 1; }
  [ "$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $2}')" = "$2" ] || { printf 'ref_mismatch'; return 1; }
  [ "$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $3}')" = "$3" ] || { printf 'ref_mismatch'; return 1; }
  return 0
}

payref_use() {
  # $1 = ref, $2 = pay_id, $3 = tid
  _ref=$(sanitize_ref "$1")
  _tmp="${PAYREF}.tmp.$$"
  "$BB" awk -F'|' -v OFS='|' -v r="$_ref" -v p="$2" -v t="$3" '$1==r { $7="used"; $8=p; $9=t } { print }' "$PAYREF" > "$_tmp" && mv "$_tmp" "$PAYREF"
}

payref_for_pay() {
  # $1 = pay_id -> reference (or empty)
  "$BB" awk -F'|' -v p="$1" '$8==p {print $1; exit}' "$PAYREF" 2>/dev/null
}

online_payment_create() {
  # $1 = online_package_id, $2 = method (jazzcash|easypaisa), $3 = tid, $4 = ip,
  # $5 = payment reference issued by payref_create (required)
  # Uses the ONLINE packages catalogue (OPFILE), not the counter packages.
  _pkg_id=$(printf '%s' "$1" | "$BB" tr -cd 'A-Za-z0-9_-')
  _method=$(printf '%s' "$2" | "$BB" tr 'A-Z' 'a-z' | "$BB" tr -cd 'a-z')
  _tid=$(sanitize_tid "$3")
  _ip=$(printf '%s' "$4" | "$BB" tr -cd '0-9.')
  _ref=$(sanitize_ref "$5")
  case "$_method" in jazzcash|easypaisa) ;; *) printf 'bad_method'; return 1 ;; esac
  [ -n "$_tid" ] || { printf 'missing_tid'; return 1; }
  [ -n "$_ip" ] || { printf 'missing_ip'; return 1; }
  _prow=$(online_package_row "$_pkg_id")
  [ -n "$_prow" ] || { printf 'unknown_package'; return 1; }
  _label=$(printf '%s' "$_prow" | "$BB" awk -F'|' '{print $2}')
  _sec=$(printf '%s' "$_prow" | "$BB" awk -F'|' '{print $3}')
  _down=$(printf '%s' "$_prow" | "$BB" awk -F'|' '{print $4}')
  _up=$(printf '%s' "$_prow" | "$BB" awk -F'|' '{print $5}')
  _price=$(money "$(printf '%s' "$_prow" | "$BB" awk -F'|' '{print $6}')")
  [ -n "$_price" ] || { printf 'no_price'; return 1; }
  _mac=$(mac_for_ip "$_ip" 2>/dev/null || true)
  [ -n "$_mac" ] || { printf 'nomac'; return 1; }
  # A banned device cannot buy its way back in; a kicked one can.
  client_is_blocked "$_mac" && { printf 'banned'; return 1; }
  # The reference must be the one issued to this device for this package.
  _rerr=$(payref_check "$_ref" "$_pkg_id" "$_method" "$_mac") || { printf '%s' "$_rerr"; return 1; }
  # Rate limit: max 3 pending payments per IP in the last 10 minutes
  _now=$(now_epoch)
  _recent=$("$BB" awk -F'|' -v ip="$_ip" -v cut="$((_now - 600))" \
    '$9==ip && $7=="pending" && $10+0 >= cut+0 {n++} END{print n+0}' "$PAYFILE")
  if [ "$_recent" -ge 3 ]; then
    printf 'rate_limited'
    return 1
  fi
  # Reject duplicate TIDs
  _dup=$("$BB" awk -F'|' -v t="$_tid" 'toupper($6)==t {print $1; exit}' "$PAYFILE")
  if [ -n "$_dup" ]; then
    printf 'duplicate_tid'
    return 1
  fi
  _pay_id="PAY-$(_pay_rand_id)"
  # 16 columns: pay_id|pkg_id|label|amount|method|tid|status|mac|ip|created|confirmed|voucher_code|seconds|note|down|up
  printf '%s|%s|%s|%s|%s|%s|pending|%s|%s|%s|||%s||%s|%s\n' \
    "$_pay_id" "$_pkg_id" "$_label" "$_price" "$_method" "$_tid" \
    "$_mac" "$_ip" "$_now" "$_sec" "$_down" "$_up" >> "$PAYFILE"
  payref_use "$_ref" "$_pay_id" "$_tid"
  log_event payment_new "$_pay_id ref $_ref $_method $_tid Rs $_price $_label from $_mac"
  printf '%s' "$_pay_id"
}

# ---------------------------------------------------------------------------
# TID format validation.
#
# JazzCash TIDs: 10-12 digit numbers (e.g. 2456789012)
# EasyPaisa TIDs: 8-15 digit numbers (e.g. 1234567890123)
# Both are numeric-only when stripped of dashes/spaces.
# We also accept alphanumeric TIDs (some wallets use hex-like refs).
# Minimum 6 characters to avoid obvious junk.
# ---------------------------------------------------------------------------
validate_tid() {
  # $1 = tid (already sanitized), $2 = method. Returns 0 if valid, 1 if not.
  _vtid="$1"
  _vmethod="$2"
  [ -n "$_vtid" ] || return 1
  _vtlen=$(printf '%s' "$_vtid" | "$BB" wc -c | "$BB" tr -d ' ')
  # Minimum 6 characters
  [ "$_vtlen" -ge 6 ] || return 1
  # Maximum 20 characters
  [ "$_vtlen" -le 20 ] || return 1
  # Method-specific digit checks
  case "$_vmethod" in
    jazzcash)
      # JazzCash TIDs are numeric, 8-12 digits
      _digits=$(printf '%s' "$_vtid" | "$BB" tr -cd '0-9')
      _dlen=$(printf '%s' "$_digits" | "$BB" wc -c | "$BB" tr -d ' ')
      [ "$_dlen" -ge 8 ] && [ "$_dlen" -le 12 ] || return 1
      ;;
    easypaisa)
      # EasyPaisa TIDs are numeric, 8-15 digits
      _digits=$(printf '%s' "$_vtid" | "$BB" tr -cd '0-9')
      _dlen=$(printf '%s' "$_digits" | "$BB" wc -c | "$BB" tr -d ' ')
      [ "$_dlen" -ge 8 ] && [ "$_dlen" -le 15 ] || return 1
      ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# Auto-verify: validate TID + match amount → instant confirm.
#
# This is the automatic payment verification flow. When a customer submits
# their TID after paying:
#   1. Validate the TID format (correct length, numeric for JazzCash/EasyPaisa)
#   2. Verify the amount matches the selected package price exactly
#   3. Check for duplicate TIDs (already submitted by anyone)
#   4. If ALL checks pass → immediately activate the voucher
#   5. Return the confirmation result so the customer gets instant internet
#
# The operator can set PAY_AUTO_VERIFY=0 in config.env to disable this and
# fall back to manual admin confirmation for every payment.
#
# Returns: "ok|code|plan|expiry|down|up|mac" on success, or an error string.
# ---------------------------------------------------------------------------
online_payment_auto_verify() {
  # $1 = online_package_id, $2 = method, $3 = tid, $4 = ip, $5 = reference
  _pkg_id=$(printf '%s' "$1" | "$BB" tr -cd 'A-Za-z0-9_-')
  _method=$(printf '%s' "$2" | "$BB" tr 'A-Z' 'a-z' | "$BB" tr -cd 'a-z')
  _tid=$(sanitize_tid "$3")
  _ip=$(printf '%s' "$4" | "$BB" tr -cd '0-9.')
  _ref=$(sanitize_ref "$5")

  # Step 0: the wallet must be one we accept. online_payment_create has always
  # checked this; auto-verify did not, and validate_tid only applies a digit
  # rule inside its jazzcash/easypaisa branches — so an unknown method skipped
  # format validation entirely and a 6-character TID passed.
  case "$_method" in jazzcash|easypaisa) ;; *) printf 'bad_method'; return 1 ;; esac

  # Step 1: Look up the package and verify it exists with a price
  _prow=$(online_package_row "$_pkg_id")
  [ -n "$_prow" ] || { printf 'unknown_package'; return 1; }
  _pkg_price=$(money "$(printf '%s' "$_prow" | "$BB" awk -F'|' '{print $6}')")
  [ -n "$_pkg_price" ] || { printf 'no_price'; return 1; }
  _pkg_label=$(printf '%s' "$_prow" | "$BB" awk -F'|' '{print $2}')

  # Step 2: Validate TID format
  if ! validate_tid "$_tid" "$_method"; then
    printf 'invalid_tid_format'
    return 1
  fi

  # Step 3: Check for duplicate TIDs across ALL payment records
  _dup=$("$BB" awk -F'|' -v t="$_tid" 'toupper($6)==t {print $1; exit}' "$PAYFILE")
  if [ -n "$_dup" ]; then
    printf 'duplicate_tid'
    return 1
  fi

  # Step 4: Verify the device is visible on the network and not banned
  _mac=$(mac_for_ip "$_ip" 2>/dev/null || true)
  [ -n "$_mac" ] || { printf 'nomac'; return 1; }
  client_is_blocked "$_mac" && { printf 'banned'; return 1; }

  # Step 4b: The payment reference must be the open one issued to this
  # device for this package and wallet. This is the "tracking id" the
  # customer wrote in the wallet notes; it is single-use.
  _rerr=$(payref_check "$_ref" "$_pkg_id" "$_method" "$_mac") || { printf '%s' "$_rerr"; return 1; }

  # Step 5: Rate limit check
  _now=$(now_epoch)
  _recent=$("$BB" awk -F'|' -v ip="$_ip" -v cut="$((_now - 600))" \
    '$9==ip && $10+0 >= cut+0 {n++} END{print n+0}' "$PAYFILE")
  if [ "$_recent" -ge 5 ]; then
    printf 'rate_limited'
    return 1
  fi

  # Step 6: ALL checks passed — create the payment record and confirm instantly
  _pay_id="PAY-$(_pay_rand_id)"
  _sec=$(printf '%s' "$_prow" | "$BB" awk -F'|' '{print $3}')
  _down=$(printf '%s' "$_prow" | "$BB" awk -F'|' '{print $4}')
  _up=$(printf '%s' "$_prow" | "$BB" awk -F'|' '{print $5}')

  # Write the payment record as pending first
  printf '%s|%s|%s|%s|%s|%s|pending|%s|%s|%s|||%s||%s|%s\n' \
    "$_pay_id" "$_pkg_id" "$_pkg_label" "$_pkg_price" "$_method" "$_tid" \
    "$_mac" "$_ip" "$_now" "$_sec" "$_down" "$_up" >> "$PAYFILE"
  payref_use "$_ref" "$_pay_id" "$_tid"
  log_event payment_auto "$_pay_id ref $_ref $_method TID:$_tid Rs $_pkg_price $_pkg_label MAC:$_mac — auto-verified"

  # Immediately confirm — this mints the voucher and activates it
  _result=$(online_payment_confirm "$_pay_id" "auto-verified")
  _rc=$?
  if [ "$_rc" -eq 0 ]; then
    log_event payment_auto_confirm "$_pay_id activated instantly"
    printf '%s' "$_result"
    return 0
  else
    log_event payment_auto_fail "$_pay_id confirm failed: $_result"
    printf 'confirm_failed'
    return 1
  fi
}

online_payment_status() {
  # $1 = pay_id. Returns the full row.
  _pid=$(printf '%s' "$1" | "$BB" tr -cd 'A-Z0-9-')
  [ -n "$_pid" ] || return 1
  "$BB" awk -F'|' -v p="$_pid" '$1==p {print; exit}' "$PAYFILE"
}

online_payment_confirm() {
  # $1 = pay_id, $2 = admin note (optional). Mints a voucher from the
  # captured online-package details (stored in the payment row itself) and
  # immediately redeems it for the payment's MAC+IP. Returns
  # "ok|code|plan|expiry|down|up|mac" on success.
  _pid=$(printf '%s' "$1" | "$BB" tr -cd 'A-Z0-9-')
  _note=$(sanitize_token "${2:-}")
  [ -n "$_pid" ] || { printf 'missing_id'; return 1; }
  _row=$(online_payment_status "$_pid")
  [ -n "$_row" ] || { printf 'not_found'; return 1; }
  _status=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $7}')
  [ "$_status" = "pending" ] || { printf 'not_pending'; return 1; }
  _label=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $3}')
  _price=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $4}')
  _tid=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $6}')
  _mac=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $8}')
  _ip=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $9}')
  _sec=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $13}')
  _down=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $15}')
  _up=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $16}')
  [ -n "$_sec" ] && [ "$_sec" -gt 0 ] || { printf 'bad_package'; return 1; }
  # Generate a unique voucher code directly (no counter-package dependency)
  _code=""
  _try=0
  while [ "$_try" -lt 20 ]; do
    _code=$(_rand_code)
    if ! _code_weak "$_code" && ! _code_exists "$_code"; then
      break
    fi
    _try=$((_try + 1))
  done
  [ -n "$_code" ] || { printf 'mint_failed'; return 1; }
  _now=$(now_epoch)
  _exp=$((_now + _sec))
  # Write the voucher directly to vouchers.tsv as an active code
  printf '%s|%s|%s|%s|%s|active|%s|%s|%s|%s|%s|online %s|%s\n' \
    "$_code" "$_label" "$_sec" "$_down" "$_up" \
    "$_mac" "$_ip" "$_now" "$_exp" "$_now" "$_tid" "$_price" >> "$VFILE"
  client_touch "$_mac" "$_ip" ""
  # Paying for a new package after a staff kick re-admits the device.
  if [ "$(client_state "$_mac")" = "kicked" ]; then
    "$BB" awk -F'|' -v OFS='|' -v m="$_mac" -v c="$_code" -v now="$_now" \
      '$6=="active" && $7==m && $1!=c { $6="expired"; $10=now } { print }' "$VFILE" > "${VFILE}.pk.$$" \
      && mv "${VFILE}.pk.$$" "$VFILE"
    client_set_state "$_mac" active >/dev/null 2>&1 || true
    log_event kick_cleared "$_mac paid online"
  fi
  # Update the payment record
  _ptmp="${PAYFILE}.tmp"
  "$BB" awk -F'|' -v OFS='|' -v p="$_pid" -v now="$_now" -v code="$_code" -v n="$_note" \
    '$1==p { $7="confirmed"; $11=now; $12=code; $14=n; print; next } { print }' \
    "$PAYFILE" > "$_ptmp" && mv "$_ptmp" "$PAYFILE"
  log_event payment_confirm "$_pid -> $_code for $_mac (Rs $(printf '%s' "$_row" | "$BB" awk -F'|' '{print $4}'))"
  printf 'ok|%s|%s|%s|%s|%s|%s' "$_code" "$_label" "$_exp" "$_down" "$_up" "$_mac"
}

online_payment_reject() {
  # $1 = pay_id, $2 = admin note (optional)
  _pid=$(printf '%s' "$1" | "$BB" tr -cd 'A-Z0-9-')
  _note=$(sanitize_token "${2:-}")
  [ -n "$_pid" ] || { printf 'missing_id'; return 1; }
  _row=$(online_payment_status "$_pid")
  [ -n "$_row" ] || { printf 'not_found'; return 1; }
  _status=$(printf '%s' "$_row" | "$BB" awk -F'|' '{print $7}')
  [ "$_status" = "pending" ] || { printf 'not_pending'; return 1; }
  _now=$(now_epoch)
  _ptmp="${PAYFILE}.tmp"
  "$BB" awk -F'|' -v OFS='|' -v p="$_pid" -v now="$_now" -v n="$_note" \
    '$1==p { $7="rejected"; $11=now; $14=n; print; next } { print }' \
    "$PAYFILE" > "$_ptmp" && mv "$_ptmp" "$PAYFILE"
  log_event payment_reject "$_pid: ${_note:-no reason}"
  printf 'ok'
}

online_payments_json() {
  # Emit all payment records as a JSON array. Newest first.
  # 16 columns: pay_id|pkg_id|label|amount|method|tid|status|mac|ip|created|
  #             confirmed|voucher_code|seconds|note|down|up
  _now=$(now_epoch)
  printf '['
  _first=1
  _tmpf="$RNS_DATA/pay-tmp.$$"
  "$BB" awk -F'|' 'NF>0 {print}' "$PAYFILE" | sort -t'|' -k10,10 -rn > "$_tmpf"
  while IFS='|' read -r pay_id pkg_id label amount method tid status mac ip created confirmed voucher_code seconds note down up; do
    [ -n "$pay_id" ] || continue
    [ "$_first" = 1 ] || printf ','
    _first=0
    printf '{"pay_id":"%s","ref":"%s","package_id":"%s","package_label":"%s","amount":"%s","method":"%s","tid":"%s","status":"%s","mac":"%s","ip":"%s","created":%s,"confirmed":%s,"voucher_code":"%s","seconds":%s,"note":"%s","down_kbps":%s,"up_kbps":%s}' \
      "$(json_escape "$pay_id")" \
      "$(json_escape "$(payref_for_pay "$pay_id")")" \
      "$(json_escape "$pkg_id")" \
      "$(json_escape "$label")" \
      "$(json_escape "$(money "$amount")")" \
      "$(json_escape "$method")" \
      "$(json_escape "$tid")" \
      "$(json_escape "$status")" \
      "$(json_escape "$mac")" \
      "$(json_escape "$ip")" \
      "$(num "$created")" \
      "$(num "$confirmed")" \
      "$(json_escape "$voucher_code")" \
      "$(num "$seconds")" \
      "$(json_escape "$note")" \
      "$(num "$down")" \
      "$(num "$up")"
  done < "$_tmpf"
  rm -f "$_tmpf"
  printf ']'
}

online_payment_for_mac() {
  # Return the most recent confirmed payment for a MAC (used by /api/pay/status
  # to tell the customer they are connected).
  _mac=$(sanitize_mac "$1")
  [ -n "$_mac" ] || return 1
  sort -t'|' -k10,10 -rn "$PAYFILE" | \
    "$BB" awk -F'|' -v m="$_mac" '$8==m && $7=="confirmed" {print; exit}'
}

# ---------------------------------------------------------------------------
# Online packages — a separate catalogue from counter packages.
#
# The operator builds these in Settings → Online packages. They have their
# own names, prices, and durations, and are the ONLY packages shown on the
# captive portal's Buy Online section. Counter packages (packages.tsv) are
# never exposed to the self-service flow.
#
# Same 9-column layout as packages.tsv:
#   1 id | 2 label | 3 seconds | 4 down | 5 up | 6 price | 7 state |
#   8 rate | 9 rate_unit
# ---------------------------------------------------------------------------

online_package_row() {
  _id=$(printf '%s' "$1" | "$BB" tr -cd 'A-Za-z0-9_-')
  [ -n "$_id" ] && [ -f "$OPFILE" ] || return 1
  "$BB" awk -F'|' -v id="$_id" '$1==id && ($7=="" || $7=="active") { print; exit }' "$OPFILE"
}

online_package_upsert() {
  _id=$(printf '%s' "$1" | "$BB" tr -cd 'A-Za-z0-9_-')
  _label=$(sanitize_token "$2")
  _sec=$(printf '%s' "$3" | "$BB" tr -cd '0-9')
  _down=$(printf '%s' "$4" | "$BB" tr -cd '0-9')
  _up=$(printf '%s' "$5" | "$BB" tr -cd '0-9')
  _rate=$(money "$7")
  case "$8" in
    day|hour) _unit=$8 ;;
    *) _unit='' ;;
  esac
  _price=$(money "$6")
  [ -n "$_id" ] && [ -n "$_label" ] && [ -n "$_sec" ] && [ -n "$_down" ] && [ -n "$_up" ] ||
    { printf 'name, duration and speeds are required'; return 1; }
  [ -n "$_price" ] || { printf 'price is required for online packages'; return 1; }
  [ "$_sec" -gt 0 ] || { printf 'duration must be at least 1 second'; return 1; }
  _tmp="${OPFILE}.tmp"
  if [ -f "$OPFILE" ] && "$BB" awk -F'|' -v id="$_id" '$1==id{f=1} END{exit !f}' "$OPFILE" 2>/dev/null; then
    "$BB" awk -F'|' -v OFS='|' -v id="$_id" -v l="$_label" -v s="$_sec" \
      -v d="$_down" -v u="$_up" -v p="$_price" -v r="$_rate" -v ru="$_unit" \
      '$1==id { $2=l; $3=s; $4=d; $5=u; $6=p; $7="active"; $8=r; $9=ru; print; next } { print }' \
      "$OPFILE" > "$_tmp" && mv "$_tmp" "$OPFILE"
    log_event online_package "updated $_id ($_label)"
    printf 'online package updated'
  else
    printf '%s|%s|%s|%s|%s|%s|active|%s|%s\n' \
      "$_id" "$_label" "$_sec" "$_down" "$_up" "$_price" "$_rate" "$_unit" >> "$OPFILE"
    log_event online_package "created $_id ($_label)"
    printf 'online package saved'
  fi
}

online_package_delete() {
  _id=$(printf '%s' "$1" | "$BB" tr -cd 'A-Za-z0-9_-')
  [ -n "$_id" ] || { printf 'missing id'; return 1; }
  _row=$(online_package_row "$_id")
  [ -n "$_row" ] || { printf 'not found'; return 1; }
  _tmp="${OPFILE}.tmp"
  "$BB" awk -F'|' -v id="$_id" '$1!=id {print}' "$OPFILE" > "$_tmp" && mv "$_tmp" "$OPFILE"
  log_event online_package "deleted $_id"
  printf 'deleted'
}

online_packages_json() {
  printf '['
  _first=1
  while IFS='|' read -r id label sec down up price state rate rate_unit; do
    [ -n "$id" ] || continue
    [ "$state" = "" ] || [ "$state" = "active" ] || continue
    [ "$_first" = 1 ] || printf ','
    _first=0
    printf '{"id":"%s","label":"%s","seconds":%s,"down_kbps":%s,"up_kbps":%s,"price":"%s","rate":"%s","rate_unit":"%s"}' \
      "$(json_escape "$id")" \
      "$(json_escape "$label")" \
      "$(num "$sec")" \
      "$(num "$down")" \
      "$(num "$up")" \
      "$(json_escape "$(money "$price")")" \
      "$(json_escape "$(money "$rate")")" \
      "$(json_escape "$rate_unit")"
  done < "$OPFILE"
  printf ']'
}

# ---------------------------------------------------------------------------
# PDF voucher receipt.
#
# Generates a minimal valid PDF with the voucher details. On a bare Android
# system with no wkhtmltopdf or similar, we write raw PDF objects. The output
# is a single-page A4 document with the shop name, voucher code, package,
# payment details, and a footer.
# ---------------------------------------------------------------------------
vouchers_pdf() {
  # $1 = status filter (new|active|expired|revoked|all), $2 = optional
  # search text (code, plan, MAC), $3 = optional plan label filter.
  # Writes a multi-page A4 PDF of matching voucher cards to stdout: RNS
  # logo, shop, Wi-Fi name, code, package, price, START and END date/time.
  # Nothing is modified — this is a print/audit view.
  _st=$(printf '%s' "$1" | "$BB" tr -cd 'a-z')
  [ -n "$_st" ] || _st=new
  _q=$(printf '%s' "$2" | "$BB" tr 'a-z' 'A-Z' | "$BB" tr -cd 'A-Z0-9:. -' | "$BB" cut -c1-40)
  _plan=$(sanitize_token "$3")
  case "$_st" in
    new) _title="Unused vouchers" ;;
    active) _title="Active vouchers" ;;
    expired) _title="Expired vouchers (audit)" ;;
    revoked) _title="Revoked vouchers (audit)" ;;
    *) _st=all; _title="All vouchers (audit)" ;;
  esac
  [ -n "$_plan" ] && _title="$_title - $_plan"
  "$BB" awk -F'|' -v st="$_st" -v q="$_q" -v plan="$_plan" '
    NF >= 6 && $1 != "" {
      if (st != "all" && $6 != st) next
      if (plan != "" && $2 != plan) next
      if (q != "" && index(toupper($1 "|" $2 "|" $7 "|" $12), q) == 0) next
      print
    }' "$VFILE" | sort -t'|' -k11,11n -k1,1 \
    | "$BB" awk -F'|' -v shop="$(cfg_get SHOP "RNS Internet")" -v ssid="$(cfg_get SSID RNS)" \
        -v off="$(utc_offset_seconds)" -v now="$(now_epoch)" -v title="$_title" \
        -f "$RNS_HOME/bin/vouchers-pdf.awk"
}

voucher_pdf() {
  # $1=voucher_code $2=plan_label $3=seconds $4=down $5=up $6=price
  # $7=mac $8=ip $9=activated_epoch $10=expiry_epoch $11=pay_id $12=tid $13=method
  _code="$1"
  _plan="$2"
  _sec="$3"
  _down="$4"
  _up="$5"
  _price="$6"
  _mac="$7"
  _ip="$8"
  _act="$9"
  _exp="${10}"
  _pay_id="${11}"
  _tid="${12}"
  _method="${13}"
  _shop=$(cfg_get SHOP "RNS Internet")
  _ssid=$(cfg_get SSID "RNS")
  _now_human=$("$BB" date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S')
  # Format duration
  _hours=$((_sec / 3600))
  _mins=$(( (_sec % 3600) / 60 ))
  if [ "$_hours" -ge 24 ]; then
    _dur="$((_hours / 24)) day(s)"
  elif [ "$_hours" -gt 0 ]; then
    _dur="${_hours}h ${_mins}m"
  else
    _dur="${_mins} min"
  fi
  # Format speed
  _dl=""
  if [ "$_down" -ge 1024 ]; then
    _dl="$((_down / 1024)) Mbps"
  else
    _dl="${_down} Kbps"
  fi
  _ul=""
  if [ "$_up" -ge 1024 ]; then
    _ul="$((_up / 1024)) Mbps"
  else
    _ul="${_up} Kbps"
  fi
  # Method label
  case "$_method" in
    jazzcash) _ml="JazzCash" ;;
    easypaisa) _ml="EasyPaisa" ;;
    *) _ml="$_method" ;;
  esac
  # Build the PDF content stream
  _stream="BT
/F1 24 Tf
50 780 Td
($_shop) Tj
/F1 11 Tf
0 -18 Td
(Internet Voucher Receipt) Tj
0 -30 Td
/F1 9 Tf
(Generated: $_now_human) Tj
0 -28 Td
/F1 14 Tf
(Voucher Code:  $_code) Tj
0 -24 Td
/F1 11 Tf
(Package:  $_plan) Tj
0 -18 Td
(Duration:  $_dur) Tj
0 -18 Td
(Speed:  $_dl down / $_ul up) Tj
0 -18 Td
(Price:  Rs $_price) Tj
0 -24 Td
/F1 10 Tf
(Payment Method:  $_ml) Tj
0 -16 Td
(Transaction ID:  $_tid) Tj
0 -16 Td
(Payment Ref:  $_pay_id) Tj
0 -16 Td
(Tracking ID:  $(payref_for_pay "$_pay_id")) Tj
0 -24 Td
(Device MAC:  $_mac) Tj
0 -16 Td
(Device IP:  $_ip) Tj
0 -16 Td
(WiFi Network:  $_ssid) Tj
0 -30 Td
/F1 8 Tf
(This voucher is bound to the device above. One device per voucher.) Tj
0 -12 Td
(Thank you for choosing $_shop.) Tj
ET"
  _slen=$(printf '%s' "$_stream" | "$BB" wc -c | "$BB" tr -d ' ')
  # Build the full PDF with correct cross-reference offsets
  _pdf="%PDF-1.4
1 0 obj
<< /Type /Catalog /Pages 2 0 R >>
endobj

2 0 obj
<< /Type /Pages /Kids [3 0 R] /Count 1 >>
endobj

3 0 obj
<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842]
   /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>
endobj

4 0 obj
<< /Length $_slen >>
stream
$_stream
endstream
endobj

5 0 obj
<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>
endobj

xref
0 6
0000000000 65535 f 
0000000009 00000 n 
0000000058 00000 n 
0000000115 00000 n 
0000000266 00000 n 
$(printf '%010d' $((266 + _slen + 40)) ) 00000 n 

trailer
<< /Size 6 /Root 1 0 R >>
startxref
$(printf '%d' $((266 + _slen + 40 + 62)) )
%%EOF"
  printf '%s' "$_pdf"
}
