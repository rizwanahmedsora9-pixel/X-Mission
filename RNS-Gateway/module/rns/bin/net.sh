# Hotspot patch, firewall gate, and best-effort shaping.
# Rules are scoped to the hotspot interface (ap0). They never touch
# other people's networks and they do not intercept TLS logins.

. "$RNS_HOME/bin/common.sh"
. "$RNS_HOME/bin/store.sh"

_if_exists() {
  command -v ip >/dev/null 2>&1 || return 1
  ip link show "$1" >/dev/null 2>&1
}

lan_if() {
  _cfg=$(cfg_get LAN_IF ap0)
  if _if_exists "$_cfg"; then
    printf '%s' "$_cfg"
    return 0
  fi
  # The configured interface is not there. ROMs disagree about the hotspot
  # name (ap0 / softap0 / swlan0); with a wrong name every rule below would
  # match nothing and guests would never see the sign-in page. Detect the
  # real one and remember it.
  for _c in ap0 softap0 swlan0; do
    [ "$_c" = "$_cfg" ] && continue
    if _if_exists "$_c"; then
      cfg_set LAN_IF "$_c"
      log_line "hotspot interface detected $_c (config had $_cfg)"
      printf '%s' "$_c"
      return 0
    fi
  done
  printf '%s' "$_cfg"
}

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
  if is_lab && [ "${RNS_FAKE_FW:-0}" != "1" ]; then
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

_fw_sync_macs() {
  # $1 = extra ipt flag ("" or "-t nat")  $2 = chain  $3 = lan  $4 = file of
  # wanted MACs, one per line. Adds missing per-MAC RETURN rules at position
  # 1 (ahead of the base rules) and removes stale ones. Never flushes:
  # existing rules stay in place while the delta is applied.
  _tflag=$1; _chain=$2; _ifc=$3; _wantf=$4
  _havef="$RNS_DATA/fw-have.$$"
  # shellcheck disable=SC2086
  ipt $_tflag -S "$_chain" 2>/dev/null \
    | "$BB" sed -n 's/.*--mac-source \([0-9a-f:]*\).*/\1/p' > "$_havef"
  while read -r _m; do
    [ -n "$_m" ] || continue
    "$BB" grep -qx "$_m" "$_wantf" >/dev/null 2>&1 && continue
    # shellcheck disable=SC2086
    ipt $_tflag -D "$_chain" -i "$_ifc" -m mac --mac-source "$_m" -j RETURN 2>/dev/null || true
  done < "$_havef"
  while read -r _m; do
    [ -n "$_m" ] || continue
    "$BB" grep -qx "$_m" "$_havef" >/dev/null 2>&1 && continue
    # shellcheck disable=SC2086
    ipt $_tflag -I "$_chain" 1 -i "$_ifc" -m mac --mac-source "$_m" -j RETURN 2>/dev/null || true
  done < "$_wantf"
  rm -f "$_havef"
}

fw_rebuild() {
  # Additive sync. The old version flushed RNS_FWD/RNS_PRE on every pass and
  # re-appended the captive REDIRECT last. During that window a guest's
  # connectivity probe escaped to the real internet, Android marked the
  # network VALIDATED, and the captive sign-in notification never appeared
  # again. Here the redirect can never be missing: rules are checked into
  # place, per-device deltas are inserted/removed in place, and a flush only
  # happens on first boot or when the chain is damaged.
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

  if ! is_lab; then
    if ! ip link show "$_lan" >/dev/null 2>&1; then
      log_line "lan $_lan not up — gate chains empty"
      return 0
    fi
  fi

  # REDIRECT sends a guest's port-80 packet to the local listener, so it
  # traverses INPUT rather than FORWARD after NAT. Keep this rule narrow:
  # only the portal port on the hotspot interface (and loopback for the
  # operator) is admitted.
  ipt -C RNS_IN -i "$_lan" -p tcp --dport "$_port" -j ACCEPT 2>/dev/null \
    || ipt -A RNS_IN -i "$_lan" -p tcp --dport "$_port" -j ACCEPT
  ipt -C RNS_IN -i lo -p tcp --dport "$_port" -j ACCEPT 2>/dev/null \
    || ipt -A RNS_IN -i lo -p tcp --dport "$_port" -j ACCEPT
  # No IPv6 bypass around the voucher gate.
  ip6t -C RNS_FWD -i "$_lan" -j DROP 2>/dev/null || ip6t -A RNS_FWD -i "$_lan" -j DROP

  _base_ok=1
  for _spec in \
    "-i $_lan -p udp --dport 53 -j RETURN" \
    "-i $_lan -p tcp --dport 53 -j RETURN" \
    "-i $_lan -p udp --dport 67 -j RETURN" \
    "-i $_lan -p udp --sport 68 -j RETURN" \
    "-i $_lan -p tcp --dport 443 -j REJECT --reject-with tcp-reset" \
    "-i $_lan -j DROP"
  do
    # shellcheck disable=SC2086
    ipt -C RNS_FWD $_spec >/dev/null 2>&1 || { _base_ok=0; break; }
  done
  if [ "$_base_ok" != "1" ]; then
    # First boot, or a chain that lost rules. Rebuild once from scratch in
    # canonical order; the sync keeps it intact afterwards.
    ipt -F RNS_FWD
    for _spec in \
      "-i $_lan -p udp --dport 53 -j RETURN" \
      "-i $_lan -p tcp --dport 53 -j RETURN" \
      "-i $_lan -p udp --dport 67 -j RETURN" \
      "-i $_lan -p udp --sport 68 -j RETURN" \
      "-i $_lan -p tcp --dport 443 -j REJECT --reject-with tcp-reset" \
      "-i $_lan -j DROP"
    do
      # shellcheck disable=SC2086
      ipt -A RNS_FWD $_spec
    done
    log_line "forward chain rebuilt on $_lan"
  fi

  # The captive redirect itself: never flushed, only ensured.
  if ! ipt -t nat -C RNS_PRE -i "$_lan" -p tcp --dport 80 -j REDIRECT --to-ports "$_port" 2>/dev/null; then
    ipt -t nat -A RNS_PRE -i "$_lan" -p tcp --dport 80 -j REDIRECT --to-ports "$_port"
    log_line "captive redirect ensured $_lan:80 -> $_port"
  fi

  # Reset HTTPS so phones fall back to their plain HTTP probe. This is not a
  # TLS login interceptor — those packets are rejected, not decrypted. The
  # REJECT rule is part of the base set above.

  # Per-device allow rules, synced additively in both chains.
  _wantf="$RNS_DATA/fw-want.$$"
  active_macs | "$BB" cut -d'|' -f1 > "$_wantf"
  _fw_sync_macs "" RNS_FWD "$_lan" "$_wantf"
  _fw_sync_macs "-t nat" RNS_PRE "$_lan" "$_wantf"
  rm -f "$_wantf"

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
  log_line "firewall synced on $_lan"
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
  # Drop one station off the hotspot so its phone re-associates and runs its
  # captive check again. That re-check is what brings the "Sign in to
  # network" sheet back after a voucher ends or staff kicks the device — a
  # phone that stays associated keeps believing the network is "verified".
  # Always call this AFTER the device's allow rules are gone (fw_rebuild),
  # or the fresh probe escapes to the internet and the sheet never shows.
  _mac=$(sanitize_mac "$1")
  [ -n "$_mac" ] || return 0
  if is_lab; then
    log_line "lab deauth $_mac"
    return 0
  fi
  _ip=$( "$BB" awk -F'|' -v m="$_mac" '$1==m {print $2; exit}' "$CFILE" 2>/dev/null )
  # Kill the device's live flows first so an open download stops at once
  # instead of riding an established conntrack entry.
  if [ -n "$_ip" ]; then
    if command -v conntrack >/dev/null 2>&1; then
      conntrack -D -s "$_ip" >/dev/null 2>&1 || true
      conntrack -D -d "$_ip" >/dev/null 2>&1 || true
    fi
  fi
  _cli=""
  for _c in /vendor/bin/hostapd_cli /vendor/bin/hw/hostapd_cli /system/bin/hostapd_cli /system/vendor/bin/hostapd_cli; do
    [ -x "$_c" ] && _cli=$_c && break
  done
  if [ -z "$_cli" ]; then
    command -v hostapd_cli >/dev/null 2>&1 && _cli=hostapd_cli
  fi
  if [ -z "$_cli" ]; then
    log_line "deauth $_mac: hostapd_cli not found (gate rules still removed)"
    return 0
  fi
  _lan=$(lan_if)
  _done=0
  # ROMs keep the control socket in different places; try each until one
  # answers. "disassociate" is the softer request, "deauthenticate" the
  # firm one — send both so every supplicant reconnects.
  for _ctrl in /data/vendor/wifi/hostapd/ctrl /data/misc/wifi/hostapd /data/vendor/wifi/hostapd /var/run/hostapd; do
    [ -d "$_ctrl" ] || continue
    if "$_cli" -p "$_ctrl" -i "$_lan" disassociate "$_mac" >> "$LOG" 2>&1; then
      "$_cli" -p "$_ctrl" -i "$_lan" deauthenticate "$_mac" >> "$LOG" 2>&1 || true
      _done=1
      break
    fi
    if "$_cli" -p "$_ctrl" -i "$_lan" deauthenticate "$_mac" >> "$LOG" 2>&1; then
      _done=1
      break
    fi
  done
  if [ "$_done" -eq 1 ]; then
    log_line "deauth $_mac via $_cli on $_lan"
  else
    log_line "deauth $_mac: hostapd did not answer on any ctrl path"
  fi
  return 0
}

expire_enforce() {
  # Enforce wall-clock expiry right now. Safe to call from anywhere and as
  # often as needed: the sweep runs under the store lock, and the firewall
  # sync is additive. Order matters — remove the allow rules FIRST, then
  # knock the device off so its next captive probe hits the redirect.
  # Prints the MACs that expired on this pass.
  _kicked=$(with_lock voucher_sweep)
  if [ -n "$_kicked" ]; then
    fw_rebuild || true
    printf '%s\n' "$_kicked" | while read -r mac; do
      [ -n "$mac" ] || continue
      log_event expire "$mac"
      deauth_mac "$mac"
    done
    printf '%s\n' "$_kicked"
  fi
  return 0
}

client_disconnect() {
  # Staff kick/ban or an ended voucher: rules out, flows dead, station
  # dropped — in that order.
  _mac=$(sanitize_mac "$1")
  [ -n "$_mac" ] || return 0
  fw_rebuild || true
  deauth_mac "$_mac"
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
  expire_enforce >/dev/null
  neigh_scan
  fw_rebuild
  shape_apply
  # Heartbeat for the page shell's watchdog (see rns-front.sh). If this
  # stamp goes stale the supervisor is dead and the front door restarts it.
  printf '%s\n' "$(now_epoch)" > "$RNS_DATA/sweep.stamp" 2>/dev/null || true
}
