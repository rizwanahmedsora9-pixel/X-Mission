#!/system/bin/sh
# Minimum captive-portal redirect.
# Does not source store.sh, net.sh, or common.sh. If those files are broken,
# guests can still be sent to the sign-in page.
# Rules are added only when missing. This script never flushes chains, so it
# cannot wipe per-device allows that the full firewall rebuild installed.

_here=${0%/*}
RNS_HOME=${RNS_HOME:-${_here%/*}}
RNS_LAB=${RNS_LAB:-0}

if [ "$RNS_LAB" = "1" ]; then
  exit 0
fi
if ! command -v iptables >/dev/null 2>&1; then
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

PORT=8080
LAN=ap0
read_kv() {
  _f=$1
  _k=$2
  [ -f "$_f" ] || return 1
  "$BB" sed -n "s/^${_k}=//p" "$_f" 2>/dev/null | "$BB" head -n 1 | "$BB" tr -d '\r'
}
for _f in /data/adb/rns/page.env /data/adb/rns/config.env; do
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

# A rule that names the wrong interface matches nothing and the guest never
# sees the sign-in page. If the configured name is absent, try the other
# hotspot names ROMs are known to use.
if command -v ip >/dev/null 2>&1; then
  if ! ip link show "$LAN" >/dev/null 2>&1; then
    for _c in ap0 softap0 swlan0; do
      if ip link show "$_c" >/dev/null 2>&1; then
        LAN=$_c
        break
      fi
    done
  fi
fi

ipt() { iptables "$@"; }

ipt -N RNS_FWD 2>/dev/null || true
ipt -t nat -N RNS_PRE 2>/dev/null || true
ipt -N RNS_IN 2>/dev/null || true
ipt -C FORWARD -j RNS_FWD 2>/dev/null || ipt -I FORWARD 1 -j RNS_FWD
ipt -t nat -C PREROUTING -j RNS_PRE 2>/dev/null || ipt -t nat -I PREROUTING 1 -j RNS_PRE
ipt -C INPUT -j RNS_IN 2>/dev/null || ipt -I INPUT 1 -j RNS_IN

ipt -C RNS_IN -i "$LAN" -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null \
  || ipt -A RNS_IN -i "$LAN" -p tcp --dport "$PORT" -j ACCEPT
ipt -C RNS_IN -i lo -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null \
  || ipt -A RNS_IN -i lo -p tcp --dport "$PORT" -j ACCEPT

# DNS and DHCP first, or the phone never opens the sign-in sheet.
ipt -C RNS_FWD -i "$LAN" -p udp --dport 53 -j RETURN 2>/dev/null \
  || ipt -I RNS_FWD 1 -i "$LAN" -p udp --dport 53 -j RETURN
ipt -C RNS_FWD -i "$LAN" -p tcp --dport 53 -j RETURN 2>/dev/null \
  || ipt -I RNS_FWD 1 -i "$LAN" -p tcp --dport 53 -j RETURN
ipt -C RNS_FWD -i "$LAN" -p udp --dport 67 -j RETURN 2>/dev/null \
  || ipt -I RNS_FWD 1 -i "$LAN" -p udp --dport 67 -j RETURN
ipt -C RNS_FWD -i "$LAN" -p udp --sport 68 -j RETURN 2>/dev/null \
  || ipt -I RNS_FWD 1 -i "$LAN" -p udp --sport 68 -j RETURN

ipt -t nat -C RNS_PRE -i "$LAN" -p tcp --dport 80 -j REDIRECT --to-ports "$PORT" 2>/dev/null \
  || ipt -t nat -A RNS_PRE -i "$LAN" -p tcp --dport 80 -j REDIRECT --to-ports "$PORT"

# Only install the captive drop when the full rebuild left the chain without one.
if ! ipt -S RNS_FWD 2>/dev/null | "$BB" grep -q -- '-j DROP'; then
  ipt -C RNS_FWD -i "$LAN" -p tcp --dport 443 -j REJECT --reject-with tcp-reset 2>/dev/null \
    || ipt -A RNS_FWD -i "$LAN" -p tcp --dport 443 -j REJECT --reject-with tcp-reset
  ipt -A RNS_FWD -i "$LAN" -j DROP
fi

if command -v ip6tables >/dev/null 2>&1; then
  ip6tables -N RNS_FWD 2>/dev/null || true
  ip6tables -C FORWARD -j RNS_FWD 2>/dev/null || ip6tables -I FORWARD 1 -j RNS_FWD
  ip6tables -C RNS_FWD -i "$LAN" -j DROP 2>/dev/null || ip6tables -A RNS_FWD -i "$LAN" -j DROP
fi

if [ -d /data/local/tmp ] || mkdir -p /data/local/tmp 2>/dev/null; then
  printf '%s rns-gate-min portal redirect ensured port=%s if=%s\n' "$(date 2>/dev/null || echo now)" "$PORT" "$LAN" >> /data/local/tmp/rns_hotspot.log 2>/dev/null || true
fi
exit 0
