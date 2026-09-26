# Shared helpers for the RNS gateway. Busybox ash and mksh.
# Do not read stdin here — the HTTP handler owns stdin.

if [ -z "$BB" ]; then
  if [ -x /data/adb/magisk/busybox ]; then
    BB=/data/adb/magisk/busybox
  elif [ -x /usr/bin/busybox ]; then
    BB=/usr/bin/busybox
  else
    BB=busybox
  fi
fi

if [ -z "$RNS_HOME" ]; then
  RNS_HOME=/data/adb/modules/RNS_Hotspot/rns
fi
if [ -z "$RNS_DATA" ]; then
  RNS_DATA=/data/adb/rns
  RNS_DATA_AUTO=1
fi
# Prefer removable/shared storage for shop data when Android has mounted it.
# Keep /data/adb/rns as a safe fallback for early boot and devices without
# accessible shared storage. Existing installs are migrated by store_init().
if [ "${RNS_DATA_AUTO:-0}" = "1" ] && [ "$RNS_DATA" = "/data/adb/rns" ] && [ -d /sdcard ]; then
  mkdir -p /sdcard/HotspotBilling 2>/dev/null
  if [ -w /sdcard/HotspotBilling ]; then
    RNS_DATA=/sdcard/HotspotBilling
  fi
fi
RNS_WWW="$RNS_HOME/www"
RNS_DB_DIR="$RNS_DATA/database"
RNS_LOG_DIR="$RNS_DATA/logs"
EVENTS_FILE="$RNS_LOG_DIR/events.log"
LOG="$RNS_LOG_DIR/rns.log"
MIRROR_LOG=/data/local/tmp/rns_hotspot.log

now_epoch() {
  "$BB" date +%s 2>/dev/null || date +%s
}

log_line() {
  _msg="$1"
  _ts=$(now_epoch)
  mkdir -p "$RNS_DATA" 2>/dev/null
  printf '%s %s\n' "$_ts" "$_msg" >> "$LOG" 2>/dev/null
  if [ -d /data/local/tmp ] || [ -w /data/local/tmp ]; then
    printf '%s %s\n' "$(_date_human)" "$_msg" >> "$MIRROR_LOG" 2>/dev/null
  fi
}

_date_human() {
  "$BB" date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S'
}

log_event() {
  # $1 action  $2 detail
  mkdir -p "$RNS_DATA" 2>/dev/null
  _d=$(printf '%s' "$2" | "$BB" tr '\t\r\n|' '    ')
  mkdir -p "$RNS_LOG_DIR" 2>/dev/null
  printf '%s|%s|%s\n' "$(now_epoch)" "$1" "$_d" >> "$EVENTS_FILE"
  log_line "$1 $_d"
}

json_escape() {
  # print JSON string contents, no surrounding quotes
  printf '%s' "$1" | "$BB" sed 's/\\/\\\\/g; s/"/\\"/g' | "$BB" tr -d '\r\n\t'
}

sanitize_token() {
  # keep a short safe token
  printf '%s' "$1" | "$BB" tr -cd 'A-Za-z0-9 .:_@+-#' | "$BB" cut -c1-64
}

sanitize_code() {
  # Voucher codes are case-insensitive and may be numeric (legacy) or
  # alphanumeric (new packages). Separators are intentionally ignored.
  printf '%s' "$1" | "$BB" tr 'a-z' 'A-Z' | "$BB" tr -cd 'A-Z0-9' | "$BB" cut -c1-12
}

sanitize_mac() {
  printf '%s' "$1" | "$BB" tr 'A-F' 'a-f' | "$BB" sed 's/[^0-9a-f:]//g' | "$BB" cut -c1-17
}

hex_byte() {
  # $1 = two hex digits. Use busybox printf so this works in dash, ash and mksh.
  case "$1" in
    [0-9A-Fa-f][0-9A-Fa-f]) "$BB" printf "\\x$1" ;;
    *) printf '?' ;;
  esac
}

urldecode() {
  _s=$(printf '%s' "$1" | "$BB" sed 's/+/ /g')
  _out=""
  while [ -n "$_s" ]; do
    case "$_s" in
      %??*)
        _hh=$(printf '%s' "$_s" | "$BB" cut -c2-3)
        _ch=$(hex_byte "$_hh" 2>/dev/null) || _ch="?"
        _out="$_out$_ch"
        _s=$(printf '%s' "$_s" | "$BB" cut -c4-)
        ;;
      *)
        _c=$(printf '%s' "$_s" | "$BB" cut -c1)
        _out="$_out$_c"
        _s=$(printf '%s' "$_s" | "$BB" cut -c2-)
        ;;
    esac
  done
  printf '%s' "$_out"
}

form_get() {
  _key=$1
  _blob="${RNS_QUERY}&${RNS_BODY}"
  _raw=$(printf '%s' "$_blob" | "$BB" tr '&' '\n' | "$BB" sed -n "s/^${_key}=//p" | "$BB" head -n 1)
  urldecode "$_raw"
}

cfg_path() {
  printf '%s/config.env' "$RNS_DATA"
}

cfg_get() {
  _k=$1
  _def=$2
  _f=$(cfg_path)
  _v=""
  if [ -f "$_f" ]; then
    _v=$( "$BB" sed -n "s/^${_k}=//p" "$_f" | "$BB" head -n 1 | "$BB" tr -d '\r' )
  fi
  if [ -z "$_v" ]; then
    printf '%s' "$_def"
  else
    printf '%s' "$_v"
  fi
}

cfg_set() {
  _k=$1
  _v=$2
  _f=$(cfg_path)
  mkdir -p "$RNS_DATA"
  touch "$_f"
  if "$BB" grep -q "^${_k}=" "$_f" 2>/dev/null; then
    _tmp="${_f}.tmp"
    "$BB" sed "s|^${_k}=.*|${_k}=${_v}|" "$_f" > "$_tmp" && mv "$_tmp" "$_f"
  else
    printf '%s=%s\n' "$_k" "$_v" >> "$_f"
  fi
}

with_lock() {
  mkdir -p "$RNS_DATA"
  # Reentrancy matters: a nested with_lock must NOT reopen fd 9 — that
  # closes the outer description and silently drops the outer flock, letting
  # a concurrent writer (the page listener, rns-expire.sh) interleave rows
  # and corrupt the store. Hold the lock once around the whole call tree.
  if [ "${RNS_LOCK_DEPTH:-0}" -gt 0 ]; then
    "$@"
    return $?
  fi
  exec 9>>"$RNS_DATA/store.lock"
  "$BB" flock -x 9
  RNS_LOCK_DEPTH=1
  "$@"
  _rc=$?
  RNS_LOCK_DEPTH=0
  "$BB" flock -u 9
  return $_rc
}

is_lab() {
  [ "$RNS_LAB" = "1" ]
}

phone_ips() {
  # Every address this phone owns. Used to recognise the shop phone even
  # when the hotspot subnet is not the usual 192.168.43.x, and even when
  # only busybox (not /system/bin/ip) is on PATH. The known tethering
  # gateways are always included; the per-interface addresses are best
  # effort on top. The list is also cached for the page shell, which
  # cannot source this file.
  {
    if command -v ip >/dev/null 2>&1; then
      ip -4 -o addr show 2>/dev/null | "$BB" awk '{print $4}' | "$BB" cut -d/ -f1
    elif "$BB" ip -4 -o addr show >/dev/null 2>&1; then
      "$BB" ip -4 -o addr show 2>/dev/null | "$BB" awk '{print $4}' | "$BB" cut -d/ -f1
    elif command -v ifconfig >/dev/null 2>&1; then
      ifconfig 2>/dev/null | "$BB" sed -n 's/.*inet addr:\([0-9][0-9.]*\).*/\1/p'
    fi
    printf '%s\n' 127.0.0.1 192.168.43.1 192.168.42.1 192.168.49.1
  } | "$BB" sort -u | "$BB" tee /data/adb/rns/phone.ips 2>/dev/null || true
}

is_local_ip() {
  _ip=$1
  if is_lab; then
    return 0
  fi
  case "$_ip" in
    127.*|::1) return 0 ;;
    "" ) return 1 ;;
  esac
  if [ "$(cfg_get ADMIN_LAN 0)" = "1" ]; then
    return 0
  fi
  phone_ips | "$BB" grep -qx "$_ip"
}

le_hex_to_ip() {
  # 8 hex chars, little-endian IPv4 as in /proc/net/tcp
  _h=$1
  _b1=$(printf '%s' "$_h" | "$BB" cut -c7-8)
  _b2=$(printf '%s' "$_h" | "$BB" cut -c5-6)
  _b3=$(printf '%s' "$_h" | "$BB" cut -c3-4)
  _b4=$(printf '%s' "$_h" | "$BB" cut -c1-2)
  printf '%d.%d.%d.%d' "0x$_b1" "0x$_b2" "0x$_b3" "0x$_b4"
}

peer_ip_from_proc() {
  _ino=$(ls -l /proc/self/fd/0 2>/dev/null | "$BB" sed -n 's/.*socket:\[\([0-9][0-9]*\)\].*/\1/p')
  [ -n "$_ino" ] || return 1
  _line=$( "$BB" awk -v ino="$_ino" '$10==ino {print; exit}' /proc/net/tcp /proc/net/tcp6 2>/dev/null )
  [ -n "$_line" ] || return 1
  _rem=$(printf '%s' "$_line" | "$BB" awk '{print $3}')
  _addr=${_rem%%:*}
  _len=$(printf '%s' "$_addr" | "$BB" wc -c)
  # wc -c counts the newline-less string's bytes plus? printf | wc -c has no newline if we use wc -c
  _len=$(printf '%s' "$_addr" | "$BB" wc -c | "$BB" tr -d ' ')
  if [ "$_len" -gt 8 ]; then
    _addr=$(printf '%s' "$_addr" | "$BB" tail -c 8)
  fi
  le_hex_to_ip "$_addr"
}

resolve_client_ip() {
  if [ -n "$CLIENT_IP" ]; then
    printf '%s' "$CLIENT_IP"
    return 0
  fi
  peer_ip_from_proc
}

# ---------------------------------------------------------------------------
# Numeric + money + calendar helpers.
#
# Every numeric slot in a JSON document must be sanitized. A bare printf '%s'
# of free text (a note like "Rs 500") produced `"created":Rs 500` — invalid
# JSON that broke the whole Codes tab. num() makes that class of bug
# impossible: digits only, empty and junk become the given default.
# ---------------------------------------------------------------------------
num() {
  # $1 = value, $2 = default (0)
  _v=$(printf '%s' "$1" | "$BB" tr -cd '0-9')
  [ -n "$_v" ] || _v=${2:-0}
  printf '%s' "$_v"
}

money() {
  # Accepts "150", "150.50", "Rs 150", " 150 ". Emits a plain decimal string
  # with at most 2 places, or '' when there is no number at all. Prices are
  # kept as text in the store so rupee amounts are never rounded by shell
  # integer arithmetic.
  _m=$(printf '%s' "$1" | "$BB" tr -cd '0-9.')
  case "$_m" in
    ''|*[!0-9.]*|.) printf ''; return 0 ;;
  esac
  printf '%s' "$_m" | "$BB" awk '{
    s=$0; n=split(s,p,".");
    out=p[1];
    if (n>1) { frac=substr(p[2],1,2); if (frac!="") out=out "." frac }
    gsub(/^0+/,"",out); if (out=="" || out ~ /^\./) out="0" out;
    print out
  }'
}

money_sum() {
  # Sum a list of decimal strings without floating point drift: scale to
  # paisa (x100) as integers, add, scale back.
  printf '%s\n' "$@" | "$BB" awk '
    /^[0-9]*\.?[0-9]*$/ && $0 != "" {
      v=$0; neg=0;
      if (index(v,".")>0) { split(v,a,"."); ip=a[1]; fr=substr(a[2] "00",1,2) }
      else { ip=v; fr="00" }
      gsub(/^0+/,"",ip); if (ip=="") ip="0";
      gsub(/^0+/,"",fr); if (fr=="") fr="0";
      total += (ip*100) + (fr+0);
      seen=1
    }
    END {
      if (!seen) { print "0"; exit }
      printf "%d.%02d\n", int(total/100), total%100
    }'
}

price_from_rate() {
  # $1 = rate, $2 = unit (hour|day), $3 = seconds. Total for that duration,
  # rounded to 2 decimals. A 3-hour package at 50/hour is 150; a 2-day
  # package at 300/day is 600; a 3-hour package at 300/day is 37.50.
  printf '%s %s %s' "$1" "$2" "$3" | "$BB" awk '{
    rate=$1+0; unit=$2; sec=$3+0;
    per = (unit=="day") ? 86400 : 3600;
    if (rate<=0 || sec<=0) { print ""; exit }
    t = rate * sec / per;
    printf "%.2f\n", t
  }' | "$BB" sed 's/\.00$//'
}

duration_seconds() {
  # $1 = amount, $2 = unit (hour|day|minute). Whole seconds.
  printf '%s %s' "$1" "$2" | "$BB" awk '{
    n=int($1+0); u=$2;
    if (n<=0) { print ""; exit }
    if (u=="day") print n*86400;
    else if (u=="minute") print n*60;
    else print n*3600
  }'
}

# ---------------------------------------------------------------------------
# Local-time calendar conversion.
#
# Busybox/toolbox `date -d` is not dependable across Android ROMs, and the
# sales report needs both directions (a date-picker day -> epoch, and an
# epoch -> the shop's local day). Done in awk with the civil-days algorithm
# so it is identical on the phone and in the lab, and testable offline.
# ---------------------------------------------------------------------------
utc_offset_seconds() {
  "$BB" date +%z 2>/dev/null | "$BB" awk '{
    s=$0;
    if (s !~ /^[+-][0-9][0-9][0-9][0-9]$/) { print 0; exit }
    sign=(substr(s,1,1)=="-") ? -1 : 1;
    hh=substr(s,2,2)+0; mm=substr(s,4,2)+0;
    print sign*(hh*3600+mm*60)
  }' || printf '0'
}

ymd_to_epoch() {
  # $1 = YYYY-MM-DD, $2 = "start" (default, local midnight) or "end"
  # (local midnight of the NEXT day, i.e. an exclusive upper bound).
  # Echoes seconds since 1970-01-01T00:00:00Z. Empty input echoes nothing.
  _d=$1
  case "$_d" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) printf ''; return 1 ;;
  esac
  _off=$(utc_offset_seconds)
  _e=$(printf '%s %s' "$_d" "$_off" | "$BB" awk '
    function fdiv(a,b){ q=int(a/b); if (a%b!=0 && ((a<0)!=(b<0))) q--; return q }
    {
      split($1,p,"-"); y=p[1]+0; m=p[2]+0; d=p[3]+0; off=$2+0;
      yy = y - ((m<=2) ? 1 : 0);
      era = fdiv((yy>=0) ? yy : yy-399, 400);
      yoe = yy - era*400;
      doy = int((153*(m + ((m>2) ? -3 : 9)) + 2)/5) + d - 1;
      doe = yoe*365 + int(yoe/4) - int(yoe/100) + doy;
      days = era*146097 + doe - 719468;
      print days*86400 - off
    }')
  [ -n "$_e" ] || return 1
  case "$2" in
    end|next) _e=$((_e + 86400)) ;;
  esac
  printf '%s' "$_e"
}

epoch_to_ymd() {
  # $1 = epoch seconds. Echoes the shop's LOCAL calendar day as YYYY-MM-DD.
  _ts=$(num "$1" '')
  [ -n "$_ts" ] || { printf ''; return 1; }
  _off=$(utc_offset_seconds)
  printf '%s %s' "$_ts" "$_off" | "$BB" awk '
    function fdiv(a,b){ q=int(a/b); if (a%b!=0 && ((a<0)!=(b<0))) q--; return q }
    {
      ts=$1+0; off=$2+0;
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
      printf "%04d-%02d-%02d\n", y, m, d
    }'
}

today_ymd() {
  "$BB" date '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d'
}
