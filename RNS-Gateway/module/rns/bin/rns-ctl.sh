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
    echo "===== RNS verify ====="
    echo "-- module --"
    echo "home $RNS_HOME"
    echo "-- config --"
    cat "$RNS_DATA/config.env" 2>/dev/null
    echo "-- counts --"
    overview_json; echo
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
      wget -qO- http://127.0.0.1:8080/health || true
    fi
    echo
    echo "-- log tail --"
    "$BB" tail -n 40 "$LOG" 2>/dev/null
    echo "-- also copy /data/local/tmp/rns_hotspot.log --"
    ;;
  *)
    echo "usage: rns-ctl.sh status|mint [package-id] [count]|list|pause|resume|verify"
    exit 1
    ;;
esac
