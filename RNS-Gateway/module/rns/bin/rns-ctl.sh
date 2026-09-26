#!/system/bin/sh
# Operator CLI. On the phone: su -c 'sh /data/adb/modules/RNS_Hotspot/rns/bin/rns-ctl.sh status'

_here=${0%/*}
export RNS_HOME=${RNS_HOME:-${_here%/*}}
export RNS_DATA=${RNS_DATA:-/data/adb/rns}
export RNS_DATA_AUTO=${RNS_DATA_AUTO:-1}
export RNS_LAB=${RNS_LAB:-0}
if [ -z "$BB" ]; then
  if [ -x /data/adb/magisk/busybox ]; then BB=/data/adb/magisk/busybox
  elif [ -x /usr/bin/busybox ]; then BB=/usr/bin/busybox
  else BB=busybox; fi
fi
export BB
. "$RNS_HOME/bin/common.sh"
. "$RNS_HOME/bin/store.sh"
. "$RNS_HOME/bin/net.sh"
store_init

cmd=${1:-status}
shift 2>/dev/null || true

case "$cmd" in
  status)
    echo "shop $(cfg_get SHOP "RNS Internet")"
    echo "ssid $(cfg_get SSID RNS) channel $(cfg_get CHANNEL 6) max $(cfg_get MAX_STA 128)"
    echo "counts $(overview_json)"
    if [ -f "$RNS_DATA/PAUSE" ]; then echo "gate PAUSED"; else echo "gate armed"; fi
    if [ -f "$RNS_DATA/rnsd.pid" ]; then echo "rnsd pid $(cat "$RNS_DATA/rnsd.pid")"; fi
    if [ -f "$RNS_DATA/httpd.pid" ]; then echo "httpd pid $(cat "$RNS_DATA/httpd.pid")"; fi
    if [ -f "$RNS_DATA/httpd.mode" ]; then echo "pages $(cat "$RNS_DATA/httpd.mode")"; fi
    ;;
  packages)
    # There are no preset packages any more, so the ids cannot be guessed.
    if [ ! -s "$PFILE" ]; then
      echo "no packages yet - create them in the staff panel (Settings > Package builder)"
    else
      printf '%-14s %-18s %-10s %-14s %-9s %s\n' ID NAME TIME SPEED_DL/UL PRICE RATE
      "$BB" awk -F'|' '
        $7 != "disabled" {
          sec=$3+0;
          if (sec>0 && sec%86400==0) t=(sec/86400) "d";
          else if (sec>0 && sec%3600==0) t=(sec/3600) "h";
          else t=sec "s";
          rate=($8=="") ? "-" : ("Rs " $8 "/" ($9=="day" ? "day" : "hr"));
          printf "%-14s %-18s %-10s %-14s %-9s %s\n", $1, $2, t, $4 "/" $5, ($6=="" ? "-" : "Rs " $6), rate;
        }' "$PFILE"
    fi
    ;;
  mint)
    _plan=$1
    _n=${2:-1}
    if [ -z "$_plan" ]; then
      echo "usage: rns-ctl.sh mint <package-id> [count]"
      echo "package ids:"
      "$BB" awk -F'|' '$7!="disabled"{printf "  %s  (%s)\n", $1, $2}' "$PFILE"
      [ -s "$PFILE" ] || echo "  none - build one in Settings > Package builder first"
      exit 1
    fi
    with_lock voucher_mint "$_plan" "$_n" ""
    echo
    ;;
  sales)
    # sales [from] [to] with YYYY-MM-DD dates. No argument means today.
    _from=${1:-$(today_ymd)}
    _to=${2:-$_from}
    case "$_from" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) _fe=$(ymd_to_epoch "$_from") ;;
      *) echo "from must be YYYY-MM-DD"; exit 1 ;;
    esac
    case "$_to" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) _te=$(ymd_to_epoch "$_to" end) ;;
      *) echo "to must be YYYY-MM-DD"; exit 1 ;;
    esac
    echo "===== RNS sales $_from .. $_to ====="
    sales_report "$_fe" "$_te" | "$BB" awk -F'|' '
      function rs(p){ return sprintf("%d.%02d", int(p/100), p%100) }
      $1=="T" {
        printf "generated  %4s codes   Rs %s\n", $2, rs($4);
        printf "redeemed   %4s codes   Rs %s\n", $3, rs($5);
        if ($6+0>0) printf "note: %s code(s) have no price - revenue is understated\n", $6;
        if ($7+0>0) printf "note: %s older code(s) have no sale date - not counted\n", $7;
        print "";
        next
      }
      $1=="D" { printf "by day      %s   gen %3d   red %3d   Rs %10s\n", $2, $3, $4, rs($5); next }
      $1=="P" { printf "by package  %-18s gen %3d   red %3d   Rs %10s\n", $2, $3, $4, rs($5); next }
    '
    ;;
  list)
    "$BB" awk -F'|' '{printf "%s  %-8s %-8s %s\n", $1, $2, $6, $7}' "$VFILE"
    ;;
  pause)
    printf '1\n' > "$RNS_DATA/PAUSE"
    fw_clear
    echo paused
    ;;
  resume)
    rm -f "$RNS_DATA/PAUSE"
    fw_rebuild
    echo armed
    ;;
  payments)
    echo "===== RNS online payments ====="
    if [ ! -s "$PAYFILE" ]; then
      echo "no online payments yet"
      exit 0
    fi
    "$BB" awk -F'|' '
      function human(ts) {
        if (ts+0 <= 0) return "—"
        return strftime("%Y-%m-%d %H:%M", ts+0)
      }
      NF>0 {
        printf "%-12s  %-6s  %-18s  Rs %-6s  TID %-14s  MAC %-17s  %s  %s\n",
          $1, $5, $3, $4, $6, $8, $7, ($12 ? "voucher: "$12 : "")
      }' "$PAYFILE"
    ;;
  pay-confirm)
    _pid=$2
    if [ -z "$_pid" ]; then
      echo "usage: rns-ctl.sh pay-confirm <PAY-xxxxxxxx>"
      exit 1
    fi
    _res=$(with_lock online_payment_confirm "$_pid" "CLI")
    _rc=$?
    if [ "$_rc" -eq 0 ]; then
      echo "confirmed: $_res"
      fw_rebuild
      shape_apply
    else
      echo "failed: $_res"
      exit 1
    fi
    ;;
  pay-reject)
    _pid=$2
    if [ -z "$_pid" ]; then
      echo "usage: rns-ctl.sh pay-reject <PAY-xxxxxxxx> [reason]"
      exit 1
    fi
    _note=${3:-"CLI rejection"}
    _res=$(with_lock online_payment_reject "$_pid" "$_note")
    _rc=$?
    if [ "$_rc" -eq 0 ]; then
      echo "rejected"
    else
      echo "failed: $_res"
      exit 1
    fi
    ;;
  verify)
    _vport=$(cfg_get PORTAL_PORT 8080)
    echo "===== RNS verify ====="
    echo "-- module --"
    echo "home $RNS_HOME"
    echo "-- config --"
    cat "$RNS_DATA/config.env" 2>/dev/null
    echo "-- counts --"
    overview_json; echo
    echo "-- listener --"
    if [ -f "$RNS_DATA/httpd.pid" ]; then
      _vpid=$(cat "$RNS_DATA/httpd.pid" 2>/dev/null)
      if kill -0 "$_vpid" 2>/dev/null; then
        echo "pid $_vpid alive"
      else
        echo "pid $_vpid DEAD"
      fi
    else
      echo "no pid file"
    fi
    echo "mode $(cat "$RNS_DATA/httpd.mode" 2>/dev/null)"
    echo "engine $(cat "$RNS_DATA/httpd.engine" 2>/dev/null)"
    # v8: a pid is not proof. Show whether the pages actually ANSWER.
    echo "-- live probe (the only proof the pages are served) --"
    _vans=""
    if command -v wget >/dev/null 2>&1; then
      _vans=$(wget -q -T 3 -O - "http://127.0.0.1:$_vport/health" 2>/dev/null)
    fi
    if [ -z "$_vans" ] && command -v curl >/dev/null 2>&1; then
      _vans=$(curl -sS -m 3 "http://127.0.0.1:$_vport/health" 2>/dev/null)
    fi
    if [ -z "$_vans" ]; then
      _vans=$(printf 'GET /health HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n' | "$BB" nc -w 3 127.0.0.1 "$_vport" 2>/dev/null)
    fi
    case "$_vans" in
      *'"pages":true'*) echo "ok: pages answer on port $_vport" ;;
      *) echo "BROKEN: nothing answers HTTP on port $_vport — run: rns-ctl.sh doctor" ;;
    esac
    echo "-- admin on this phone --"
    if command -v wget >/dev/null 2>&1; then
      _vadmin=$(wget -qO- "http://127.0.0.1:$_vport/admin" 2>/dev/null | "$BB" head -c 200)
      case "$_vadmin" in
        *'Staff only'*) echo "ADMIN_GATE=1 is on: admin is IP-restricted (set ADMIN_GATE=0 to open staff login to any device)" ;;
        *'Staff login'*) echo "ok: staff panel opens locally" ;;
        '') echo "no answer from port $_vport" ;;
        *) echo "unexpected answer: $_vadmin" ;;
      esac
    fi
    echo "-- hotspot interface --"
    echo "detected $(lan_if)"
    echo "uplink $("$BB" awk '$2=="00000000" && $1!="lo" {print $1; exit}' /proc/net/route 2>/dev/null)"
    if command -v ip >/dev/null 2>&1; then
      ip -o link show 2>/dev/null | "$BB" grep -E 'ap0|softap|swlan|wlan' || echo "no hotspot-like interface found"
    fi
    echo "-- captive gate rules --"
    _vipt=""
    for _vc in /system/bin/iptables /system/bin/iptables-legacy iptables; do
      if [ -x "$_vc" ] || command -v "$_vc" >/dev/null 2>&1; then
        _vipt=$_vc
        break
      fi
    done
    if [ -n "$_vipt" ]; then
      echo "iptables binary: $_vipt"
      echo "[nat RNS_PRE]"; "$_vipt" -t nat -S RNS_PRE 2>/dev/null | "$BB" head -n 30
      echo "[RNS_FWD]"; "$_vipt" -S RNS_FWD 2>/dev/null | "$BB" head -n 30
      echo "[RNS_IN]"; "$_vipt" -S RNS_IN 2>/dev/null | "$BB" head -n 15
    else
      echo "iptables missing"
    fi
    echo "-- hostapd conf --"
    if [ -f /data/vendor/wifi/hostapd/hostapd_ap0.conf ]; then
      "$BB" grep -E '^(ssid2|ssid|channel|hw_mode|max_num_sta|wpa)=' /data/vendor/wifi/hostapd/hostapd_ap0.conf
    else
      echo "conf not present (hotspot off?)"
    fi
    echo "-- ap-status --"
    [ -f "$RNS_DATA/ap-status.txt" ] && "$BB" tail -n 30 "$RNS_DATA/ap-status.txt"
    echo "-- health --"
    if command -v wget >/dev/null 2>&1; then
      wget -qO- "http://127.0.0.1:$_vport/health" || true
    fi
    echo
    echo "-- page requests (client probes land here) --"
    "$BB" tail -n 30 /data/local/tmp/rns_pages.log 2>/dev/null || echo "no page log yet"
    echo "-- packages --"
    if [ -s "$PFILE" ]; then
      "$BB" awk -F'|' '$7!="disabled"{printf "%s  %s  %ss  %s/%s kbps  price=%s\n", $1,$2,$3,$4,$5,($6==""?"-":$6)}' "$PFILE"
    else
      echo "none (no presets ship any more; build them in the panel)"
    fi
    echo "-- sales today --"
    sales_report "$(ymd_to_epoch "$(today_ymd)")" "$(ymd_to_epoch "$(today_ymd)" end)" \
      | "$BB" awk -F'|' '$1=="T"{printf "generated %s (Rs %d.%02d), redeemed %s (Rs %d.%02d), unpriced %s, undated %s\n",$2,int($4/100),$4%100,$3,int($5/100),$5%100,$6,$7}'
    echo "-- online payments --"
    if [ -s "$PAYFILE" ]; then
      _pp=$("$BB" awk -F'|' '$7=="pending"{n++} $7=="confirmed"{c++} $7=="rejected"{r++} END{printf "pending %d, confirmed %d, rejected %d\n",n+0,c+0,r+0}' "$PAYFILE")
      echo "$_pp"
    else
      echo "none"
    fi
    echo "-- payment gateway --"
    echo "JazzCash: $(cfg_get JAZZCASH_NUMBER '(not set)') $(cfg_get JAZZCASH_NAME '')"
    echo "EasyPaisa: $(cfg_get EASYPAISA_NUMBER '(not set)') $(cfg_get EASYPAISA_NAME '')"
    echo "-- log tail --"
    "$BB" tail -n 40 "$LOG" 2>/dev/null
    echo "-- also copy /data/local/tmp/rns_hotspot.log --"
    ;;
  expire)
    # Enforce wall-clock expiry right now (also what rnsd does every 15 s).
    _gone=$(expire_enforce)
    if [ -n "$_gone" ]; then
      echo "expired and disconnected:"
      printf '%s\n' "$_gone"
    else
      echo "nothing to expire"
    fi
    ;;
  kick)
    # End this device's current session. It may redeem a NEW code at once.
    _mac=$(sanitize_mac "$1")
    [ -n "$_mac" ] || { echo "usage: rns-ctl.sh kick <mac>"; exit 1; }
    with_lock client_set_state "$_mac" kicked && client_disconnect "$_mac"
    echo "kicked $_mac (paused; 'rns-ctl.sh unkick $_mac' or a new voucher restores it)"
    ;;
  ban)
    _mac=$(sanitize_mac "$1")
    [ -n "$_mac" ] || { echo "usage: rns-ctl.sh ban <mac>"; exit 1; }
    with_lock client_set_state "$_mac" banned && client_disconnect "$_mac"
    echo "banned $_mac (no voucher will work until: rns-ctl.sh unban $_mac)"
    ;;
  unban|unkick|allow)
    _mac=$(sanitize_mac "$1")
    [ -n "$_mac" ] || { echo "usage: rns-ctl.sh unban <mac>"; exit 1; }
    with_lock client_set_state "$_mac" active && fw_rebuild
    echo "$_mac allowed again"
    ;;
  clients)
    printf '%-18s %-16s %-8s %-10s %s\n' MAC IP STATE VOUCHER EXPIRES
    clients_json | "$BB" tr '{' '\n' | "$BB" sed -n 's/.*"mac":"\([^"]*\)".*"ip":"\([^"]*\)".*"voucher":"\([^"]*\)".*"expires":\([0-9]*\).*"state":"\([^"]*\)".*/\1 \2 \5 \3 \4/p' \
      | while read -r m i st v e; do
          _when="-"
          if [ "${e:-0}" -gt 0 ] 2>/dev/null; then _when=$("$BB" date -d "@$e" '+%d %b %H:%M' 2>/dev/null || echo "$e"); fi
          printf '%-18s %-16s %-8s %-10s %s\n' "$m" "$i" "$st" "${v:--}" "$_when"
        done
    ;;
  doctor)
    # One paste, one command: repair first, then prove it. This is what the
    # operator runs when "admin panel and captive portal are not showing".
    echo "===== RNS doctor ====="
    echo "-- 1. relaunch the page listener (engine ladder, live-verified) --"
    RNS_SKIP="" "$BB" sh "$RNS_HOME/bin/rns-pages.sh" && echo "listener: ok" || echo "listener: FAILED to find a working engine"
    echo "-- 2. reinstall the captive redirect on every hotspot interface --"
    "$BB" sh "$RNS_HOME/bin/rns-gate-min.sh" && echo "gate: ok" || echo "gate: FAILED"
    echo "-- 3. restart the supervisor if it is dead --"
    _dpid=""
    [ -f "$RNS_DATA/rnsd.pid" ] && _dpid=$(cat "$RNS_DATA/rnsd.pid" 2>/dev/null)
    if [ -n "$_dpid" ] && kill -0 "$_dpid" 2>/dev/null; then
      echo "supervisor: running (pid $_dpid)"
    else
      echo "supervisor: restarting rnsd.sh"
      if command -v setsid >/dev/null 2>&1; then
        setsid "$BB" sh "$RNS_HOME/bin/rnsd.sh" >> /data/local/tmp/rns_hotspot.log 2>&1 < /dev/null &
      else
        ( trap '' HUP; exec "$BB" sh "$RNS_HOME/bin/rnsd.sh" ) >> /data/local/tmp/rns_hotspot.log 2>&1 < /dev/null &
      fi
    fi
    echo
    exec "$BB" sh "$0" verify
    ;;
  setpass)
    # Shell-side password recovery. The operator holding the rooted phone is
    # the owner of the panel: if the password is lost, this resets it.
    _np=$1
    _nlen=$(printf '%s' "$_np" | "$BB" wc -c | "$BB" tr -d ' ')
    if [ "$_nlen" -lt 6 ]; then
      echo "usage: rns-ctl.sh setpass <new-password-6+>"
      exit 1
    fi
    _set_pass admin "$_np"
    log_event password "admin password reset from shell"
    rm -f "$RNS_DATA"/sessions/* 2>/dev/null || true
    echo "admin password updated; existing sessions cleared"
    ;;
  *)
    echo "usage: rns-ctl.sh status|packages|mint <package-id> [count]|list|clients|kick <mac>|unkick <mac>|ban <mac>|unban <mac>|expire|sales [from] [to]|payments|pay-confirm <PAY-id>|pay-reject <PAY-id>|pause|resume|verify|doctor|setpass <new-password>"
    exit 1
    ;;
esac
