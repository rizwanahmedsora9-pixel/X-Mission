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
  exec 9>>"$RNS_DATA/store.lock"
  "$BB" flock -x 9
  "$@"
  _rc=$?
  "$BB" flock -u 9
  return $_rc
}

is_lab() {
  [ "$RNS_LAB" = "1" ]
}

phone_ips() {
  if command -v ip >/dev/null 2>&1; then
    ip -4 -o addr show 2>/dev/null | "$BB" awk '{print $4}' | "$BB" cut -d/ -f1
  fi
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
