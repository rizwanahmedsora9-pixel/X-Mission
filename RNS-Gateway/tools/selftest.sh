#!/bin/sh
# Lab self-test. Does not touch iptables.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export BB=/usr/bin/busybox
export RNS_BB=$BB
export RNS_HOME="$ROOT/module/rns"
export RNS_DATA="/tmp/rns-selftest-$$"
export RNS_LAB=1
PORT=18990
rm -rf "$RNS_DATA"
mkdir -p "$RNS_DATA"
fail=0
say() { printf '%s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fail=1; }
ok() { printf 'OK   %s\n' "$*"; }

. "$RNS_HOME/bin/common.sh"
. "$RNS_HOME/bin/store.sh"
store_init

# unit: decode
got=$(urldecode 'RNS%20ok')
[ "$got" = "RNS ok" ] && ok "urldecode" || bad "urldecode got=$got"

got=$(le_hex_to_ip 0100007F)
[ "$got" = "127.0.0.1" ] && ok "ip decode" || bad "ip decode got=$got"

codes=$(with_lock voucher_mint 1h 2 demo)
n=$(printf '%s' "$codes" | wc -w)
[ "$n" -eq 2 ] && ok "mint 2" || bad "mint got=$codes"

# redeem the seeded lab code as if we were a client
CLIENT_IP=10.1.2.3
res=$(voucher_redeem 48219033 10.1.2.3)
case "$res" in
  ok*) ok "redeem $res" ;;
  *) bad "redeem $res" ;;
esac
res2=$(voucher_redeem 48219033 10.9.9.9)
case "$res2" in
  used*) ok "second device blocked" ;;
  *) bad "second device $res2" ;;
esac

# expire the active seeded voucher by rewriting expiry
now=$(now_epoch)
"$BB" awk -F'|' -v OFS='|' -v now="$now" '
  $1=="90001122" { $10=now-5 }
  { print }
' "$VFILE" > "$VFILE.tmp" && mv "$VFILE.tmp" "$VFILE"
kicked=$(voucher_sweep)
printf '%s' "$kicked" | grep -q 'aa:bb:cc:dd:ee:01' && ok "sweep kicked $kicked" || bad "sweep kicked=[$kicked]"

# HTTP
BIN="$RNS_HOME/bin/rns-httpd-x86_64"
if [ ! -x "$BIN" ]; then
  gcc -Os -s -o "$BIN" "$ROOT/src/rns-httpd.c"
fi
"$BIN" --check >/dev/null && ok "httpd check" || bad "httpd check"
"$BIN" "$PORT" "$RNS_HOME/bin/rns-http.sh" >/tmp/rns-httpd-self.log 2>&1 &
HPID=$!
sleep 0.3
cleanup() { kill "$HPID" 2>/dev/null || true; wait "$HPID" 2>/dev/null || true; }
trap cleanup EXIT

health=$(curl -sS -m 3 "http://127.0.0.1:$PORT/health" || true)
printf '%s' "$health" | grep -q '"ok":true' && ok "health" || bad "health $health"

probe=$(curl -sS -D /tmp/rns-probe.hdr -m 3 -o /tmp/rns-probe.body "http://127.0.0.1:$PORT/generate_204" || true)
grep -q '200' /tmp/rns-probe.hdr && ok "probe status" || bad "probe header $(head -1 /tmp/rns-probe.hdr)"
grep -q 'Welcome online' /tmp/rns-probe.body && ok "probe is portal html" || bad "probe body"
grep -qi 'Microsoft Connect Test' /tmp/rns-probe.body && bad "probe leaked windows success token" || ok "no windows success token"

st=$(curl -sS -m 3 "http://127.0.0.1:$PORT/api/status")
printf '%s' "$st" | grep -q '"lab":true' && ok "status lab" || bad "status $st"

# login
curl -sS -m 3 -c /tmp/rns.cj -b /tmp/rns.cj -o /tmp/rns-login.json \
  -H 'Accept: application/json' \
  -d 'password=rns-admin' \
  "http://127.0.0.1:$PORT/api/login"
grep -q '"ok":true' /tmp/rns-login.json && ok "login" || bad "login $(cat /tmp/rns-login.json)"

ov=$(curl -sS -m 3 -b /tmp/rns.cj -H 'Accept: application/json' "http://127.0.0.1:$PORT/api/admin/overview")
printf '%s' "$ov" | grep -q '"unused"' && ok "overview $ov" || bad "overview $ov"

mint=$(curl -sS -m 3 -b /tmp/rns.cj -H 'Accept: application/json' \
  -d 'plan=3h&count=1' "http://127.0.0.1:$PORT/api/admin/mint")
printf '%s' "$mint" | grep -q '"ok":true' && ok "http mint $mint" || bad "http mint $mint"

pkg=$(curl -sS -m 3 -b /tmp/rns.cj -H 'Accept: application/json' \
  -d 'id=5m-1d&label=5 Mbps 1 Day&seconds=86400&down_kbps=5120&up_kbps=1024&price=Rs%20300' \
  "http://127.0.0.1:$PORT/api/admin/packages")
printf '%s' "$pkg" | grep -q '5m-1d' && ok "custom package" || bad "custom package $pkg"

custom=$(curl -sS -m 3 -b /tmp/rns.cj -H 'Accept: application/json' \
  -d 'plan=5m-1d&count=1' "http://127.0.0.1:$PORT/api/admin/mint")
printf '%s' "$custom" | grep -q '"ok":true' && ok "custom package mint" || bad "custom package mint $custom"

# unauthenticated admin
code=$(curl -sS -m 3 -o /tmp/rns-noauth.json -w '%{http_code}' "http://127.0.0.1:$PORT/api/admin/vouchers")
[ "$code" = "401" ] && ok "admin locked" || bad "admin lock code=$code body=$(cat /tmp/rns-noauth.json)"

# redeem over HTTP
red=$(curl -sS -m 3 -H 'Accept: application/json' -d 'code=11002233' "http://127.0.0.1:$PORT/api/redeem")
printf '%s' "$red" | grep -q '"ok":true' && ok "http redeem $red" || bad "http redeem $red"

filtered=$(curl -sS -m 3 -b /tmp/rns.cj -H 'Accept: application/json' \
  "http://127.0.0.1:$PORT/api/admin/vouchers?status=active&search=1100")
printf '%s' "$filtered" | grep -q '1100' && ok "voucher search/filter" || bad "voucher search/filter $filtered"

state=$(curl -sS -m 3 -b /tmp/rns.cj -H 'Accept: application/json' \
  -d 'mac=02:00:00:00:00:01&state=kicked' "http://127.0.0.1:$PORT/api/admin/client-status")
printf '%s' "$state" | grep -q '"state":"kicked"' && ok "client kick state" || bad "client kick state $state"

backup=$(curl -sS -m 3 -b /tmp/rns.cj -H 'Accept: application/json' \
  -d 'x=1' "http://127.0.0.1:$PORT/api/admin/backup")
printf '%s' "$backup" | grep -q '"ok":true' && ok "backup/export" || bad "backup/export $backup"

if [ "$fail" -eq 0 ]; then
  say "ALL PASSED"
  exit 0
fi
say "FAILED"
exit 1
