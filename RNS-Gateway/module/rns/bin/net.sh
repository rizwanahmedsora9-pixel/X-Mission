# Hotspot patch, firewall gate, and best-effort shaping.
# Rules are scoped to the hotspot interface (ap0). They never touch
# other people's networks and they do not intercept TLS logins.

. "$RNS_HOME/bin/common.sh"
. "$RNS_HOME/bin/store.sh"

lan_if() { cfg_get LAN_IF ap0; }

wan_if() {
  _w=$(cfg_get WAN_IF auto)
  if [ -z "$_w" ] || [ "$_w" = "auto" ]; then
    if command -v ip >/dev/null 2>&1; then
      ip route show default 2>/dev/null | "$BB" awk '{print $5; exit}'
      return
    fi
    printf ''
    return
  fi
  printf '%s' "$_w"
}

ipt() {
  if is_lab; then
    log_line "lab iptables $*"
    return 0
  fi
  if ! command -v iptables >/dev/null 2>&1; then
    log_line "iptables missing: $*"
    return 1
  fi
  iptables "$@"
}

ip6t() {
  if is_lab; then
    return 0
  fi
  command -v ip6tables >/dev/null 2>&1 || return 0
  ip6tables "$@"
}

fw_ensure() {
  if ! is_lab && ! command -v iptables >/dev/null 2>&1; then
    log_line "iptables missing — refusing to report a healthy gate"
    return 1
  fi
  if ! is_lab && ! command -v ip6tables >/dev/null 2>&1; then
    # Missing IPv6 tools must not hide the sign-in page. IPv4 redirect still
    # goes in. ip6t() below no-ops when the binary is absent.
    log_line "ip6tables missing — installing IPv4 portal gate anyway"
  fi
  ipt -N RNS_FWD 2>/dev/null || true
  ipt -t nat -N RNS_PRE 2>/dev/null || true
  # Android normally accepts local INPUT, but vendor firewall policies differ.
  # Explicitly admit the portal listener so a redirected captive request is
  # not discarded after REDIRECT changes it from FORWARD to INPUT.
  ipt -N RNS_IN 2>/dev/null || true
  ipt -C FORWARD -j RNS_FWD 2>/dev/null || ipt -I FORWARD 1 -j RNS_FWD
  ipt -t nat -C PREROUTING -j RNS_PRE 2>/dev/null || ipt -t nat -I PREROUTING 1 -j RNS_PRE
  ipt -C INPUT -j RNS_IN 2>/dev/null || ipt -I INPUT 1 -j RNS_IN
  ip6t -N RNS_FWD 2>/dev/null || true
  ip6t -C FORWARD -j RNS_FWD 2>/dev/null || ip6t -I FORWARD 1 -j RNS_FWD
}

fw_clear() {
  if is_lab; then
    log_line "lab firewall cleared"
    return 0
  fi
  ipt -D FORWARD -j RNS_FWD 2>/dev/null || true
  ipt -F RNS_FWD 2>/dev/null || true
  ipt -X RNS_FWD 2>/dev/null || true
  ipt -t nat -D PREROUTING -j RNS_PRE 2>/dev/null || true
  ipt -t nat -F RNS_PRE 2>/dev/null || true
  ipt -t nat -X RNS_PRE 2>/dev/null || true
  ipt -D INPUT -j RNS_IN 2>/dev/null || true
  ipt -F RNS_IN 2>/dev/null || true
  ipt -X RNS_IN 2>/dev/null || true
  ip6t -D FORWARD -j RNS_FWD 2>/dev/null || true
  ip6t -F RNS_FWD 2>/dev/null || true
  ip6t -X RNS_FWD 2>/dev/null || true
  log_line "firewall cleared"
}

fw_rebuild() {
  if [ -f "$RNS_DATA/PAUSE" ]; then
    fw_clear
    log_line "gate paused"
    return 0
  fi
  _lan=$(lan_if)
  _port=$(cfg_get PORTAL_PORT 8080)
  if ! fw_ensure; then
    log_line "firewall gate health check failed"
    return 1
  fi
  ipt -F RNS_FWD
  ipt -t nat -F RNS_PRE
  ipt -F RNS_IN
  ip6t -F RNS_FWD
  # REDIRECT sends a guest's port-80 packet to the local listener, so it
  # traverses INPUT rather than FORWARD after NAT. Keep this rule narrow:
  # only the portal port on the hotspot interface (and loopback for the
  # operator) is admitted.
  ipt -A RNS_IN -i "$_lan" -p tcp --dport "$_port" -j ACCEPT
  ipt -A RNS_IN -i lo -p tcp --dport "$_port" -j ACCEPT
  # No IPv6 bypass around the voucher gate.
  ip6t -A RNS_FWD -i "$_lan" -j DROP

  if ! is_lab; then
    if ! ip link show "$_lan" >/dev/null 2>&1; then
      log_line "lan $_lan not up — gate chains empty"
      return 0
    fi
  fi

  active_macs | while IFS='|' read -r mac ip down up; do
    [ -n "$mac" ] || continue
    ipt -A RNS_FWD -i "$_lan" -m mac --mac-source "$mac" -j RETURN
    ipt -t nat -A RNS_PRE -i "$_lan" -m mac --mac-source "$mac" -j RETURN
  done

  ipt -A RNS_FWD -i "$_lan" -p udp --dport 53 -j RETURN
  ipt -A RNS_FWD -i "$_lan" -p tcp --dport 53 -j RETURN
  ipt -A RNS_FWD -i "$_lan" -p udp --dport 67 -j RETURN
  ipt -A RNS_FWD -i "$_lan" -p udp --sport 68 -j RETURN
  # Reset HTTPS so phones fall back to their plain HTTP probe.
  # This is not a TLS login interceptor — those packets are rejected, not decrypted.
  ipt -A RNS_FWD -i "$_lan" -p tcp --dport 443 -j REJECT --reject-with tcp-reset
  ipt -A RNS_FWD -i "$_lan" -j DROP
  ipt -t nat -A RNS_PRE -i "$_lan" -p tcp --dport 80 -j REDIRECT --to-ports "$_port"

  if ! is_lab; then
    echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
    _wan=$(wan_if)
    if [ -n "$_wan" ]; then
      if ! iptables -t nat -S POSTROUTING 2>/dev/null | "$BB" grep -q MASQUERADE; then
        iptables -t nat -A POSTROUTING -o "$_wan" -j MASQUERADE 2>/dev/null || true
        log_line "added fallback MASQUERADE via $_wan"
      fi
    fi
  fi
  log_line "firewall rebuilt on $_lan"
}

gate_heal() {
  # Full gate rebuild, called from the portal when an already-authenticated
  # device talks to us (typically right after a Wi-Fi off/on toggle). If the
  # supervisor sweep is slow, or the per-MAC rules were flushed by the
  # vendor stack or a half-finished rebuild, this restores the device's
  # FORWARD/NAT rules before the response goes out, so its connectivity
  # check and browsing start working again. Idempotent: a normal rebuild
  # just re-adds the same rules. Returns non-zero while the gate is
  # deliberately paused.
  if [ -f "$RNS_DATA/PAUSE" ]; then
    return 1
  fi
  fw_rebuild
}

shape_apply() {
  if is_lab; then
    return 0
  fi
  command -v tc >/dev/null 2>&1 || return 0
  _lan=$(lan_if)
  ip link show "$_lan" >/dev/null 2>&1 || return 0
  tc qdisc del dev "$_lan" root 2>/dev/null || true
  tc qdisc del dev "$_lan" ingress 2>/dev/null || true
  tc qdisc add dev "$_lan" root handle 1: htb default 99 2>/dev/null || return 0
  tc class add dev "$_lan" parent 1: classid 1:99 htb rate 100mbit 2>/dev/null || true
  tc qdisc add dev "$_lan" handle ffff: ingress 2>/dev/null || true
  _id=10
  active_macs | while IFS='|' read -r mac ip down up; do
    [ -n "$ip" ] || continue
    [ -n "$down" ] || continue
    tc class add dev "$_lan" parent 1: classid "1:${_id}" htb rate "${down}kbit" ceil "${down}kbit" 2>/dev/null || true
    tc filter add dev "$_lan" protocol ip parent 1: prio 1 u32 match ip dst "$ip" flowid "1:${_id}" 2>/dev/null || true
    if [ -n "$up" ]; then
      tc filter add dev "$_lan" parent ffff: protocol ip prio 1 u32 match ip src "$ip" police rate "${up}kbit" burst 32k drop 2>/dev/null || true
    fi
    _id=$((_id + 1))
  done
}

deauth_mac() {
  _mac=$(sanitize_mac "$1")
  [ -n "$_mac" ] || return 0
  if is_lab; then
    log_line "lab deauth $_mac"
    return 0
  fi
  _cli=""
  for _c in /vendor/bin/hostapd_cli /vendor/bin/hw/hostapd_cli; do
    [ -x "$_c" ] && _cli=$_c && break
  done
  [ -n "$_cli" ] || return 0
  "$_cli" -p /data/vendor/wifi/hostapd/ctrl -i "$(lan_if)" deauthenticate "$_mac" >> "$LOG" 2>&1 || true
  if command -v conntrack >/dev/null 2>&1; then
    _ip=$( "$BB" awk -F'|' -v m="$_mac" '$1==m {print $2; exit}' "$CFILE" )
    [ -n "$_ip" ] && conntrack -D -s "$_ip" >/dev/null 2>&1 || true
  fi
}

ssid_hex() {
  printf '%s' "$1" | "$BB" od -An -tx1 | "$BB" tr -d ' \n'
}

ap_patch_file() {
  _conf=$1
  [ -f "$_conf" ] || return 1
  _ssid=$(cfg_get SSID RNS)
  _ch=$(cfg_get CHANNEL 6)
  _mode=$(cfg_get HW_MODE g)
  _max=$(cfg_get MAX_STA 128)
  _hex=$(ssid_hex "$_ssid")
  _tmp="${_conf}.rns"
  "$BB" sed \
    -e "s/^ssid2=.*/ssid2=${_hex}/" \
    -e "s/^ssid=.*/ssid=${_ssid}/" \
    -e "s/^channel=.*/channel=${_ch}/" \
    -e "s/^hw_mode=.*/hw_mode=${_mode}/" \
    -e "s/^max_num_sta=.*/max_num_sta=${_max}/" \
    -e '/^wpa=/d' \
    -e '/^wpa_passphrase=/d' \
    -e '/^wpa_key_mgmt=/d' \
    -e '/^rsn_pairwise=/d' \
    -e '/^wpa_pairwise=/d' \
    "$_conf" > "$_tmp" || return 1
  if ! "$BB" grep -q '^ssid2=' "$_tmp"; then
    printf 'ssid2=%s\n' "$_hex" >> "$_tmp"
  fi
  if ! "$BB" grep -q '^channel=' "$_tmp"; then
    printf 'channel=%s\n' "$_ch" >> "$_tmp"
  fi
  if ! "$BB" grep -q '^hw_mode=' "$_tmp"; then
    printf 'hw_mode=%s\n' "$_mode" >> "$_tmp"
  fi
  if ! "$BB" grep -q '^max_num_sta=' "$_tmp"; then
    printf 'max_num_sta=%s\n' "$_max" >> "$_tmp"
  fi
  if "$BB" cmp -s "$_conf" "$_tmp"; then
    rm -f "$_tmp"
    return 2
  fi
  cat "$_tmp" > "$_conf"
  rm -f "$_tmp"
  log_line "patched $_conf ssid2=${_hex} channel=${_ch} hw_mode=${_mode} max=${_max}"
  return 0
}

ap_reload() {
  if is_lab; then
    return 0
  fi
  _cli=""
  for _c in /vendor/bin/hostapd_cli /vendor/bin/hw/hostapd_cli; do
    [ -x "$_c" ] && _cli=$_c && break
  done
  if [ -z "$_cli" ]; then
    log_line "hostapd_cli not found — patch is on disk only"
    return 1
  fi
  _ctrl=/data/vendor/wifi/hostapd/ctrl
  _if=$(lan_if)
  "$_cli" -p "$_ctrl" -i "$_if" RELOAD >> "$LOG" 2>&1 || true
  "$_cli" -p "$_ctrl" -i "$_if" status >> "$RNS_DATA/ap-status.txt" 2>&1 || true
  log_line "hostapd_cli RELOAD attempted"
}

ap_firewall_sync() {
  # The old loop rebuilt the gate every 15 seconds. That left a short window
  # when the user enabled the hotspot after boot: Android showed a captive
  # notification, but its click arrived before PREROUTING was installed. Sync
  # once per ap0 up/down transition instead; voucher changes still call
  # fw_rebuild directly.
  _lan=$(lan_if)
  _state=down
  if command -v ip >/dev/null 2>&1 && ip link show "$_lan" >/dev/null 2>&1; then
    _state=up
  fi
  _state_file="$RNS_DATA/ap-firewall.state"
  _old_state=$(cat "$_state_file" 2>/dev/null)
  if [ "$_state" != "$_old_state" ]; then
    fw_rebuild
    _rc=$?
    if [ "$_rc" -eq 0 ]; then
      printf '%s\n' "$_state" > "$_state_file" 2>/dev/null || true
      log_line "ap firewall transition $_old_state -> $_state"
    fi
  fi
}

ap_watch_once() {
  _conf=/data/vendor/wifi/hostapd/hostapd_ap0.conf
  if is_lab; then
    return 0
  fi
  [ -f "$_conf" ] || return 0
  ap_patch_file "$_conf"
  _rc=$?
  if [ "$_rc" -eq 0 ]; then
    # Give hostapd a moment if it is still spawning, then reload.
    "$BB" usleep 200000 2>/dev/null || sleep 1
    ap_reload
  fi
  ap_firewall_sync
}

neigh_scan() {
  if is_lab; then
    return 0
  fi
  [ -f /proc/net/arp ] || return 0
  _lan=$(lan_if)
  "$BB" awk -v ifc="$_lan" '$6==ifc && $4 != "00:00:00:00:00:00" {print $4, $1}' /proc/net/arp \
    | while read -r mac ip; do
        client_touch "$mac" "$ip" ""
      done
}

housekeeping() {
  _kicked=$(voucher_sweep)
  if [ -n "$_kicked" ]; then
    printf '%s\n' "$_kicked" | while read -r mac; do
      [ -n "$mac" ] || continue
      log_event expire "$mac"
      deauth_mac "$mac"
    done
  fi
  neigh_scan
  fw_rebuild
  shape_apply
}
