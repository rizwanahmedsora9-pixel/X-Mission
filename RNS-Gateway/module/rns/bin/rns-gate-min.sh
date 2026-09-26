#!/system/bin/sh
# Minimum captive-portal redirect.
# Does not source store.sh, net.sh, or common.sh. If those files are broken,
# guests can still be sent to the sign-in page.
# Rules are added only when missing. This script never flushes chains, so it
# cannot wipe per-device allows that the full firewall rebuild installed.
#
# v8: the gate is installed on EVERY hotspot-like interface except the uplink.
# A rule that names one interface matches nothing when the ROM calls the
# hotspot something else (ap0 / softap0 / swlan0 / wlan1), and that silently
# disabled the whole captive portal. Rules on a name that does not exist yet
# are harmless — they start matching the moment the interface appears.

_here=${0%/*}
RNS_HOME=${RNS_HOME:-${_here%/*}}
RNS_LAB=${RNS_LAB:-0}

# The lab exits unless the fake firewall test double is in play.
if [ "$RNS_LAB" = "1" ] && [ "${RNS_FAKE_FW:-0}" != "1" ]; then
  exit 0
fi

if [ -z "${BB:-}" ]; then
  if [ -x /data/adb/magisk/busybox ]; then
    BB=/data/adb/magisk/busybox
  elif [ -x /usr/bin/busybox ]; then
    BB=/usr/bin/busybox
  else
    BB=busybox
  fi
fi

# Which iptables? The one the system's netd uses is the one whose tables the
# packets actually traverse. Prefer /system/bin/iptables over any busybox or
# toolbox copy — on some builds two different iptables front-ends write two
# different rule stores and only one of them sees traffic. In the fake-fw lab
# the test double on PATH is used instead.
ipt() {
  if [ "${RNS_FAKE_FW:-0}" = "1" ]; then
    iptables "$@"
    return $?
  fi
  for _c in /system/bin/iptables /system/bin/iptables-legacy iptables; do
    if [ -x "$_c" ] || command -v "$_c" >/dev/null 2>&1; then
      "$_c" "$@"
      return $?
    fi
  done
  return 1
}

ip6t() {
  if [ "${RNS_FAKE_FW:-0}" = "1" ]; then
    command -v ip6tables >/dev/null 2>&1 || return 0
    ip6tables "$@"
    return $?
  fi
  for _c in /system/bin/ip6tables /system/bin/ip6tables-legacy ip6tables; do
    if [ -x "$_c" ] || command -v "$_c" >/dev/null 2>&1; then
      "$_c" "$@"
      return $?
    fi
  done
  return 0
}

if [ "${RNS_FAKE_FW:-0}" != "1" ]; then
  if ! command -v iptables >/dev/null 2>&1 && [ ! -x /system/bin/iptables ] && [ ! -x /system/bin/iptables-legacy ]; then
    exit 0
  fi
fi

PORT=8080
LAN=ap0
read_kv() {
  _f=$1
  _k=$2
  [ -f "$_f" ] || return 1
  "$BB" sed -n "s/^${_k}=//p" "$_f" 2>/dev/null | "$BB" head -n 1 | "$BB" tr -d '\r'
}
for _f in "${RNS_DATA:-/data/adb/rns}/config.env" /data/adb/rns/config.env "${RNS_DATA:-/data/adb/rns}/page.env" /data/adb/rns/page.env; do
  _p=$(read_kv "$_f" PORTAL_PORT || true)
  _l=$(read_kv "$_f" LAN_IF || true)
  case "$_p" in
    ''|*[!0-9]*) ;;
    *) PORT=$_p ;;
  esac
  case "$_l" in
    ''|*[!A-Za-z0-9._-]*) ;;
    *) LAN=$_l ;;
  esac
done

# The uplink interface must NEVER be gated: its port 80 belongs to the shop's
# own browsing. Default route says which one it is. Tests can pin it with
# RNS_FAKE_UPLINK.
uplink_if() {
  if [ -n "${RNS_FAKE_UPLINK:-}" ]; then
    printf '%s' "$RNS_FAKE_UPLINK"
    return 0
  fi
  if [ -r /proc/net/route ]; then
    "$BB" awk '$2=="00000000" && $1!="lo" {print $1; exit}' /proc/net/route 2>/dev/null
    return 0
  fi
  if command -v ip >/dev/null 2>&1; then
    ip route show default 2>/dev/null | "$BB" awk '{print $5; exit}'
    return 0
  fi
  printf ''
}

WAN=$(uplink_if)

# Every name a ROM might give the hotspot interface, plus the configured one.
# Only hotspot-like names are ever considered (wlan/ap/softap/swlan) — the
# cellular uplink (ccmni0, rmnet…) must never be gated or the shop's own
# internet dies with it. Names that do not exist yet still get rules (they
# start matching when the hotspot comes up); the uplink is skipped entirely.
lan_candidates() {
  printf '%s\n' "$LAN" ap0 softap0 swlan0 wlan0 wlan1
  if [ -r /proc/net/dev ]; then
    "$BB" awk -F: 'NR>2 {gsub(/ /,"",$1); print $1}' /proc/net/dev 2>/dev/null \
      | "$BB" grep -E '^(ap[0-9]+|softap[0-9]+|swlan[0-9]+|wlan[0-9]+)$'
  fi
}

install_gate_for() {
  _ifc=$1
  [ -n "$_ifc" ] || return 0
  [ "$_ifc" = "lo" ] && return 0
  [ "$_ifc" = "$WAN" ] && return 0

  # INPUT allow: after REDIRECT the packet traverses INPUT, not FORWARD.
  ipt -C RNS_IN -i "$_ifc" -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null \
    || ipt -A RNS_IN -i "$_ifc" -p tcp --dport "$PORT" -j ACCEPT

  # DNS and DHCP first, or the phone never opens the sign-in sheet.
  ipt -C RNS_FWD -i "$_ifc" -p udp --dport 53 -j RETURN 2>/dev/null \
    || ipt -I RNS_FWD 1 -i "$_ifc" -p udp --dport 53 -j RETURN
  ipt -C RNS_FWD -i "$_ifc" -p tcp --dport 53 -j RETURN 2>/dev/null \
    || ipt -I RNS_FWD 1 -i "$_ifc" -p tcp --dport 53 -j RETURN
  ipt -C RNS_FWD -i "$_ifc" -p udp --dport 67 -j RETURN 2>/dev/null \
    || ipt -I RNS_FWD 1 -i "$_ifc" -p udp --dport 67 -j RETURN
  ipt -C RNS_FWD -i "$_ifc" -p udp --sport 68 -j RETURN 2>/dev/null \
    || ipt -I RNS_FWD 1 -i "$_ifc" -p udp --sport 68 -j RETURN

  # THE captive redirect. Ensure-only: never removed, never reordered.
  ipt -t nat -C RNS_PRE -i "$_ifc" -p tcp --dport 80 -j REDIRECT --to-ports "$PORT" 2>/dev/null \
    || ipt -t nat -A RNS_PRE -i "$_ifc" -p tcp --dport 80 -j REDIRECT --to-ports "$PORT"

  # HTTPS is rejected with a TCP reset (never decrypted), then the catch-all
  # drop. Installed per interface so a chain repaired for one name cannot
  # leave another name wide open.
  ipt -C RNS_FWD -i "$_ifc" -p tcp --dport 443 -j REJECT --reject-with tcp-reset 2>/dev/null \
    || ipt -A RNS_FWD -i "$_ifc" -p tcp --dport 443 -j REJECT --reject-with tcp-reset
  ipt -C RNS_FWD -i "$_ifc" -j DROP 2>/dev/null \
    || ipt -A RNS_FWD -i "$_ifc" -j DROP

  # IPv6 on the guest side: a silent DROP makes dual-stack phones hang on
  # their probe and report "no internet" with no sign-in sheet. REJECT fails
  # fast so the client falls back to the IPv4 probe — the one we answer with
  # the portal. Scoped to this interface, never the uplink.
  ip6t -C RNS_FWD -i "$_ifc" -p tcp -j REJECT --reject-with tcp-reset 2>/dev/null \
    || ip6t -A RNS_FWD -i "$_ifc" -p tcp -j REJECT --reject-with tcp-reset
  ip6t -C RNS_FWD -i "$_ifc" -j REJECT 2>/dev/null \
    || ip6t -A RNS_FWD -i "$_ifc" -j REJECT
}

ipt -N RNS_FWD 2>/dev/null || true
ipt -t nat -N RNS_PRE 2>/dev/null || true
ipt -N RNS_IN 2>/dev/null || true
ipt -C FORWARD -j RNS_FWD 2>/dev/null || ipt -I FORWARD 1 -j RNS_FWD
ipt -t nat -C PREROUTING -j RNS_PRE 2>/dev/null || ipt -t nat -I PREROUTING 1 -j RNS_PRE
ipt -C INPUT -j RNS_IN 2>/dev/null || ipt -I INPUT 1 -j RNS_IN

ipt -C RNS_IN -i lo -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null \
  || ipt -A RNS_IN -i lo -p tcp --dport "$PORT" -j ACCEPT

# IPv6 chain first so the per-interface guest rejects below can attach to it.
if [ "${RNS_FAKE_FW:-0}" != "1" ]; then
  ip6t -N RNS_FWD 2>/dev/null || true
  ip6t -C FORWARD -j RNS_FWD 2>/dev/null || ip6t -I FORWARD 1 -j RNS_FWD
fi

# De-duplicate the candidate list, then gate every name except the uplink.
lan_candidates | "$BB" sort -u | while IFS= read -r _ifc; do
  install_gate_for "$_ifc"
done

if [ -d /data/local/tmp ] || mkdir -p /data/local/tmp 2>/dev/null; then
  printf '%s rns-gate-min portal redirect ensured port=%s lan=%s uplink=%s\n' \
    "$(date 2>/dev/null || echo now)" "$PORT" "$LAN" "${WAN:-none}" \
    >> /data/local/tmp/rns_hotspot.log 2>/dev/null || true
fi
exit 0
