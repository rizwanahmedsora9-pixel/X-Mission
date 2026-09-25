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
  mint)
    _plan=${1:-1h}
    _n=${2:-1}
    with_lock voucher_mint "$_plan" "$_n" ""
    echo
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
    echo "-- admin on this phone --"
    if command -v wget >/dev/null 2>&1; then
      _vadmin=$(wget -qO- "http://127.0.0.1:$_vport/admin" 2>/dev/null | "$BB" head -c 200)
      case "$_vadmin" in
        *'Staff only'*) echo "BROKEN: admin refused the local phone" ;;
        *'Staff login'*) echo "ok: staff panel opens locally" ;;
        '') echo "no answer from port $_vport" ;;
        *) echo "unexpected answer: $_vadmin" ;;
      esac
    fi
    echo "-- hotspot interface --"
    echo "detected $(lan_if)"
    if command -v ip >/dev/null 2>&1; then
      ip -o link show 2>/dev/null | "$BB" grep -E 'ap0|softap|swlan|wlan' || echo "no hotspot-like interface found"
    fi
    echo "-- captive gate rules --"
    if command -v iptables >/dev/null 2>&1; then
      echo "[nat RNS_PRE]"; iptables -t nat -S RNS_PRE 2>/dev/null | "$BB" head -n 20
      echo "[RNS_FWD]"; iptables -S RNS_FWD 2>/dev/null | "$BB" head -n 20
      echo "[RNS_IN]"; iptables -S RNS_IN 2>/dev/null | "$BB" head -n 10
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
    echo "-- log tail --"
    "$BB" tail -n 40 "$LOG" 2>/dev/null
    echo "-- also copy /data/local/tmp/rns_hotspot.log --"
    ;;
  *)
    echo "usage: rns-ctl.sh status|mint [package-id] [count]|list|pause|resume|verify"
    exit 1
    ;;
esac
