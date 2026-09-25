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

# Strict JSON validation. Grepping a response for '"ok":true' cannot tell
# valid JSON from `{"created":Rs 500,...}`, and that is exactly how a note
# containing a space once broke the whole Codes tab without any test noticing.
JSON_CHECK=""
if command -v python3 >/dev/null 2>&1; then
  JSON_CHECK=python3
elif command -v jq >/dev/null 2>&1; then
  JSON_CHECK=jq
fi
json_ok() {
  # $1 = label, stdin = document
  _doc=$(cat)
  if [ -z "$JSON_CHECK" ]; then
    # No validator available: fall back to the crude structural check rather
    # than silently skipping, so the suite still says something.
    case "$_doc" in
      \{*\<\}|\[*\]) ok "$1 (unverified: no python3/jq)" ;;
      *) bad "$1 malformed: $(printf '%s' "$_doc" | head -c 160)" ;;
    esac
    return 0
  fi
  if [ "$JSON_CHECK" = python3 ]; then
    _err=$(printf '%s' "$_doc" | python3 -c 'import json,sys
try:
    json.load(sys.stdin)
except Exception as e:
    print(e)' 2>&1)
  else
    _err=$(printf '%s' "$_doc" | jq -e . >/dev/null 2>&1 || echo "jq rejected document")
  fi
  [ -z "$_err" ] && ok "$1" || bad "$1 invalid JSON: $_err :: $(printf '%s' "$_doc" | head -c 200)"
}

. "$RNS_HOME/bin/common.sh"
. "$RNS_HOME/bin/store.sh"
store_init

# The admin panel and captive portal must never depend on voucher or firewall
# code. Fail here if they start to.
if sh "$ROOT/tools/isolate-check.sh"; then
  ok "isolation"
else
  bad "isolation"
fi

# unit: decode
got=$(urldecode 'RNS%20ok')
[ "$got" = "RNS ok" ] && ok "urldecode" || bad "urldecode got=$got"

got=$(le_hex_to_ip 0100007F)
[ "$got" = "127.0.0.1" ] && ok "ip decode" || bad "ip decode got=$got"

codes=$(with_lock voucher_mint lab1h 2 demo)
n=$(printf '%s' "$codes" | wc -w)
# Two words is not proof of two codes: "unknown plan" is also two words, which
# is how this check passed while the mint was actually failing.
if [ "$n" -eq 2 ] && printf '%s' "$codes" | grep -Eq '^[0-9A-F]{4}-[0-9A-F]{4} [0-9A-F]{4}-[0-9A-F]{4}$'; then
  ok "mint 2 ($codes)"
else
  bad "mint got=$codes"
fi

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

# reconnection: a bound device's stored lease can change after a Wi-Fi
# toggle. voucher_set_ip keeps it current, and a re-redeem from the same
# device restores the IP the device is using right now.
with_lock voucher_set_ip 02:00:00:00:02:03 10.6.6.6
ip3=$("$BB" awk -F'|' -v c="48219033" '$1==c {print $8}' "$VFILE")
[ "$ip3" = "10.6.6.6" ] && ok "lease ip updated" || bad "lease ip update got=$ip3"
res4=$(voucher_redeem 48219033 10.1.2.3)
case "$res4" in
  ok*) ok "re-redeem same device $res4" ;;
  *) bad "re-redeem $res4" ;;
esac
ip4=$("$BB" awk -F'|' -v c="48219033" '$1==c {print $8}' "$VFILE")
[ "$ip4" = "10.1.2.3" ] && ok "re-redeem lease ip" || bad "re-redeem lease ip got=$ip4"

# HTTP
# The listener serves the isolated page shell (rns-front.sh), exactly like the
# phone does. Everything under /api is delegated to the function handler.
BIN="$RNS_HOME/bin/rns-httpd-x86_64"
if [ ! -x "$BIN" ]; then
  gcc -Os -s -o "$BIN" "$ROOT/src/rns-httpd.c"
fi
"$BIN" --check >/dev/null && ok "httpd check" || bad "httpd check"
"$BIN" "$PORT" "$RNS_HOME/bin/rns-front.sh" >/tmp/rns-httpd-self.log 2>&1 &
HPID=$!
sleep 0.3
cleanup() {
  kill "$HPID" 2>/dev/null || true
  wait "$HPID" 2>/dev/null || true
  restore_broken
  command -v boot_kill >/dev/null 2>&1 && boot_kill
}
trap cleanup EXIT

health=$(curl -sS -m 3 "http://127.0.0.1:$PORT/health" || true)
printf '%s' "$health" | grep -q '"ok":true' && ok "health" || bad "health $health"

probe=$(curl -sS -D /tmp/rns-probe.hdr -m 3 -o /tmp/rns-probe.body "http://127.0.0.1:$PORT/generate_204" || true)
grep -q '200' /tmp/rns-probe.hdr && ok "probe status" || bad "probe header $(head -1 /tmp/rns-probe.hdr)"
grep -q 'Welcome online' /tmp/rns-probe.body && ok "probe is portal html" || bad "probe body"
grep -qi 'Microsoft Connect Test' /tmp/rns-probe.body && bad "probe leaked windows success token" || ok "no windows success token"

# Android may issue HEAD first, and the notification can open one of several
# vendor probe URLs. Every one must be a real 200 portal response.
head_code=$(curl -sS -X HEAD -m 3 -D /tmp/rns-head.hdr -o /tmp/rns-head.body -w '%{http_code}' "http://127.0.0.1:$PORT/generate_204" 2>/dev/null || true)
[ "$head_code" = "200" ] && ok "probe HEAD status" || bad "probe HEAD status=$head_code"
[ ! -s /tmp/rns-head.body ] && ok "probe HEAD body empty" || bad "probe HEAD body was not empty"
vendor_probe=$(curl -sS -D /tmp/rns-vendor.hdr -m 3 -o /tmp/rns-vendor.body "http://127.0.0.1:$PORT/connecttest.txt" || true)
grep -q '200' /tmp/rns-vendor.hdr && grep -q 'Welcome online' /tmp/rns-vendor.body && ok "vendor probe portal" || bad "vendor probe"

admin_page=$(curl -sS -m 3 "http://127.0.0.1:$PORT/admin" || true)
printf '%s' "$admin_page" | grep -q 'Staff login' && ok "admin page serves" || bad "admin page"

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
  -d 'plan=lab3h&count=1' "http://127.0.0.1:$PORT/api/admin/mint")
printf '%s' "$mint" | grep -q '"ok":true' && ok "http mint $mint" || bad "http mint $mint"

pkg=$(curl -sS -m 3 -b /tmp/rns.cj -H 'Accept: application/json' \
  -d 'id=5m-1d&label=5 Mbps 1 Day&seconds=86400&down_kbps=5120&up_kbps=1024&price=Rs%20300' \
  "http://127.0.0.1:$PORT/api/admin/packages")
printf '%s' "$pkg" | grep -q '5m-1d' && ok "custom package" || bad "custom package $pkg"
printf '%s' "$pkg" | json_ok "packages response is valid JSON"

custom=$(curl -sS -m 3 -b /tmp/rns.cj -H 'Accept: application/json' \
  -d 'plan=5m-1d&count=1' "http://127.0.0.1:$PORT/api/admin/mint")
printf '%s' "$custom" | grep -q '"ok":true' && ok "custom package mint" || bad "custom package mint $custom"

# unauthenticated admin
code=$(curl -sS -m 3 -o /tmp/rns-noauth.json -w '%{http_code}' "http://127.0.0.1:$PORT/api/admin/vouchers")
[ "$code" = "401" ] && ok "admin locked" || bad "admin lock code=$code body=$(cat /tmp/rns-noauth.json)"

# redeem over HTTP
red=$(curl -sS -m 3 -H 'Accept: application/json' -d 'code=11002233' "http://127.0.0.1:$PORT/api/redeem")
printf '%s' "$red" | grep -q '"ok":true' && ok "http redeem $red" || bad "http redeem $red"

# A captive-login WebView with JavaScript disabled still gets a usable POST
# form rather than a blank page.
fallback=$(curl -sS -m 3 -d 'code=55550001' "http://127.0.0.1:$PORT/api/redeem")
printf '%s' "$fallback" | grep -q 'Internet is on' && ok "no-JS redeem fallback" || bad "no-JS redeem fallback $fallback"

# Bound probe: this lab client (127.0.0.1, MAC 02:00:00:00:00:01) now holds
# an active voucher. Its captive probe must get the standard 204 "internet
# OK" answer (and the gate self-heals) instead of the portal page — that is
# what clears the phone's "no internet" mark after a Wi-Fi toggle.
pbound=$(curl -sS -m 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/generate_204")
[ "$pbound" = "204" ] && ok "bound probe 204" || bad "bound probe code=$pbound"

filtered=$(curl -sS -m 3 -b /tmp/rns.cj -H 'Accept: application/json' \
  "http://127.0.0.1:$PORT/api/admin/vouchers?status=active&search=1100")
printf '%s' "$filtered" | grep -q '1100' && ok "voucher search/filter" || bad "voucher search/filter $filtered"

state=$(curl -sS -m 3 -b /tmp/rns.cj -H 'Accept: application/json' \
  -d 'mac=02:00:00:00:00:01&state=kicked' "http://127.0.0.1:$PORT/api/admin/client-status")
printf '%s' "$state" | grep -q '"state":"kicked"' && ok "client kick state" || bad "client kick state $state"

# Kicked probe: once staff kicks the device, its probe falls back to the
# portal page again (no more 204).
pkick=$(curl -sS -m 3 -o /tmp/rns-probe-kicked.body -w '%{http_code}' "http://127.0.0.1:$PORT/generate_204")
[ "$pkick" = "200" ] && grep -q 'Welcome online' /tmp/rns-probe-kicked.body && ok "kicked probe back to portal" || bad "kicked probe code=$pkick body=$(head -c 80 /tmp/rns-probe-kicked.body)"

backup=$(curl -sS -m 3 -b /tmp/rns.cj -H 'Accept: application/json' \
  -d 'x=1' "http://127.0.0.1:$PORT/api/admin/backup")
printf '%s' "$backup" | grep -q '"ok":true' && ok "backup/export" || bad "backup/export $backup"


# ---------------------------------------------------------------------------
# PACKAGE BUILDER (v6). No stock presets: the operator builds every package.
# Duration is an amount plus a unit (3 hours / 2 days), price is a rate per
# hour or per day that computes a total the operator may still override.
# ---------------------------------------------------------------------------
note_mint=$(curl -sS -m 3 -b /tmp/rns.cj -H 'Accept: application/json' \
  -d 'plan=lab1h&count=1&note=Rs%20500%20cash' "http://127.0.0.1:$PORT/api/admin/mint")
printf '%s' "$note_mint" | grep -q '"ok":true' && ok "mint with a spaced note" || bad "mint with note $note_mint"

# The regression that motivated the 13-column schema: a note containing a
# space used to land in the numeric `created` slot and emit `"created":Rs 500`,
# which is invalid JSON and blanked the whole Codes tab. Grep cannot see this;
# a real parser can.
allv=$(curl -sS -m 3 -b /tmp/rns.cj -H 'Accept: application/json' \
  "http://127.0.0.1:$PORT/api/admin/vouchers")
printf '%s' "$allv" | json_ok "vouchers JSON valid with a spaced note"
printf '%s' "$allv" | grep -q '"note":"Rs 500 cash"' && ok "note survives intact" || bad "note lost: $allv"

# `created` must be a plausible mint epoch for the code just minted, not a
# number scraped out of the note. Under the old 11-column layout this came
# back as 500 — the digits of "Rs 500 cash".
_created=$(printf '%s' "$allv" | sed 's/},/}\n/g' | grep 'Rs 500 cash' \
  | sed -n 's/.*"created":\([0-9]*\).*/\1/p' | head -n 1)
_now=$(now_epoch)
if [ -n "$_created" ] && [ "$_created" -gt $((_now - 300)) ] && [ "$_created" -le $((_now + 60)) ]; then
  ok "minted code carries its real sale timestamp"
else
  bad "created is not a mint timestamp: got [$_created] now [$_now]"
fi

# 3 hours at Rs 50/hour => 10800 s and Rs 150.
dur_pkg=$(curl -sS -m 3 -b /tmp/rns.cj -H 'Accept: application/json' \
  -d 'id=t3h&label=Test 3 Hours&duration=3&duration_unit=hour&down_kbps=2048&up_kbps=1024&rate=50&rate_unit=hour' \
  "http://127.0.0.1:$PORT/api/admin/packages")
printf '%s' "$dur_pkg" | grep -q '"id":"t3h","label":"Test 3 Hours","seconds":10800' \
  && ok "duration 3 hours -> 10800 s" || bad "duration hours $dur_pkg"
printf '%s' "$dur_pkg" | grep -q '"price":"150"' \
  && ok "rate 50/hour x 3 hours -> Rs 150" || bad "rate math hours $dur_pkg"
printf '%s' "$dur_pkg" | grep -q '"rate":"50","rate_unit":"hour"' \
  && ok "rate stored for re-editing" || bad "rate not stored $dur_pkg"

# 2 days at Rs 300/day => 172800 s and Rs 600.
day_pkg=$(curl -sS -m 3 -b /tmp/rns.cj -H 'Accept: application/json' \
  -d 'id=t2d&label=Test 2 Days&duration=2&duration_unit=day&down_kbps=1024&up_kbps=512&rate=300&rate_unit=day' \
  "http://127.0.0.1:$PORT/api/admin/packages")
printf '%s' "$day_pkg" | grep -q '"seconds":172800' && ok "duration 2 days -> 172800 s" || bad "duration days $day_pkg"
printf '%s' "$day_pkg" | grep -q '"price":"600"' && ok "rate 300/day x 2 days -> Rs 600" || bad "rate math days $day_pkg"

# A cross-unit rate: 3 hours priced per day is a fraction, in paisa not floats.
cross_pkg=$(curl -sS -m 3 -b /tmp/rns.cj -H 'Accept: application/json' \
  -d 'id=tx&label=Cross&duration=3&duration_unit=hour&down_kbps=1024&up_kbps=512&rate=300&rate_unit=day' \
  "http://127.0.0.1:$PORT/api/admin/packages")
printf '%s' "$cross_pkg" | grep -q '"price":"37.50"' && ok "3 hours at Rs 300/day -> Rs 37.50" || bad "cross-unit rate $cross_pkg"

# The computed total is a suggestion: an explicit price must win.
ovr_pkg=$(curl -sS -m 3 -b /tmp/rns.cj -H 'Accept: application/json' \
  -d 'id=t3h&label=Test 3 Hours&duration=3&duration_unit=hour&down_kbps=2048&up_kbps=1024&rate=50&rate_unit=hour&price=120' \
  "http://127.0.0.1:$PORT/api/admin/packages")
printf '%s' "$ovr_pkg" | grep -q '"id":"t3h","label":"Test 3 Hours","seconds":10800,"down_kbps":2048,"up_kbps":1024,"price":"120"' \
  && ok "operator override beats the computed rate" || bad "price override $ovr_pkg"

# Validation still refuses nonsense.
zero_pkg=$(curl -sS -m 3 -b /tmp/rns.cj -H 'Accept: application/json' \
  -d 'id=tz&label=Zero&duration=0&duration_unit=hour&down_kbps=1024&up_kbps=512' \
  "http://127.0.0.1:$PORT/api/admin/packages")
printf '%s' "$zero_pkg" | grep -q '"ok":false' && ok "zero duration rejected" || bad "zero duration accepted $zero_pkg"

# Delete removes a package, and reports failure for one that was never there.
del_pkg=$(curl -sS -m 3 -b /tmp/rns.cj -H 'Accept: application/json' \
  -d 'action=delete&id=tx' "http://127.0.0.1:$PORT/api/admin/packages")
printf '%s' "$del_pkg" | grep -q '"ok":true' && ! printf '%s' "$del_pkg" | grep -q '"id":"tx"' \
  && ok "package deleted" || bad "package delete $del_pkg"
del_bogus=$(curl -sS -m 3 -b /tmp/rns.cj -H 'Accept: application/json' \
  -d 'action=delete&id=never-existed' "http://127.0.0.1:$PORT/api/admin/packages")
printf '%s' "$del_bogus" | grep -q '"ok":false' && ok "deleting a missing package fails honestly" || bad "bogus delete $del_bogus"

# The sales report is reachable and strictly valid.
sales=$(curl -sS -m 3 -b /tmp/rns.cj -H 'Accept: application/json' \
  "http://127.0.0.1:$PORT/api/admin/sales")
printf '%s' "$sales" | grep -q '"ok":true' && ok "sales endpoint answers" || bad "sales endpoint $sales"
printf '%s' "$sales" | json_ok "sales JSON valid"
printf '%s' "$sales" | grep -q '"by_day":\[' && printf '%s' "$sales" | grep -q '"by_package":\[' \
  && ok "sales has by_day and by_package" || bad "sales shape $sales"
sales_noauth=$(curl -sS -m 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/admin/sales")
[ "$sales_noauth" = "401" ] && ok "sales locked without login" || bad "sales auth code=$sales_noauth"

csv_hdr=$(curl -sS -m 5 -b /tmp/rns.cj -D /tmp/rns-sales.hdr -o /tmp/rns-sales.csv \
  "http://127.0.0.1:$PORT/api/admin/sales.csv?from=$(today_ymd)&to=$(today_ymd)")
grep -qi 'text/csv' /tmp/rns-sales.hdr && ok "csv content type" || bad "csv header $(head -1 /tmp/rns-sales.hdr)"
grep -qi 'Content-Disposition: attachment' /tmp/rns-sales.hdr && ok "csv downloads as a file" || bad "csv disposition"
head -n 1 /tmp/rns-sales.csv | grep -q '^scope,key,generated,redeemed,revenue_rupees$' \
  && ok "csv header row" || bad "csv header row $(head -n 1 /tmp/rns-sales.csv)"


# ---------------------------------------------------------------------------
# STORE-LAYER FIXTURES. These run against throwaway data directories so they
# cannot disturb the shared lab store the HTTP tests above depend on.
# ---------------------------------------------------------------------------
PRIVDIR="/tmp/rns-priv-$$"
rm -rf "$PRIVDIR"

# A fresh install must have ZERO packages. v5 and earlier seeded seven stock
# presets here; the operator now builds every package themselves. An existing
# store is left untouched, so upgrading never deletes a shop's own packages.
mkdir -p "$PRIVDIR/fresh"
fresh_out=$(RNS_DATA="$PRIVDIR/fresh" RNS_LAB=0 BB="$BB" RNS_BB="$BB" RNS_HOME="$RNS_HOME" sh -c '
  . "$RNS_HOME/bin/common.sh"; . "$RNS_HOME/bin/store.sh"; store_init
  printf "lines=%s\n" "$(wc -l < "$RNS_DB_DIR/packages.tsv" | tr -d " ")"
  printf "bytes=%s\n" "$(wc -c < "$RNS_DB_DIR/packages.tsv" | tr -d " ")"
' 2>&1)
printf '%s' "$fresh_out" | grep -q 'lines=0' && printf '%s' "$fresh_out" | grep -q 'bytes=0' \
  && ok "fresh install ships no preset packages" || bad "fresh install presets: $fresh_out"

# An upgrade keeps whatever the operator already had.
mkdir -p "$PRIVDIR/upgrade/database"
: > "$PRIVDIR/upgrade/database/vouchers.tsv"
printf '1h|1 Hour|3600|2048|1024||active\n7d|7 Days|604800|512|256||active\n' > "$PRIVDIR/upgrade/database/packages.tsv"
up_out=$(RNS_DATA="$PRIVDIR/upgrade" RNS_LAB=0 BB="$BB" RNS_BB="$BB" RNS_HOME="$RNS_HOME" sh -c '
  . "$RNS_HOME/bin/common.sh"; . "$RNS_HOME/bin/store.sh"; store_init
  wc -l < "$RNS_DB_DIR/packages.tsv" | tr -d " "
' 2>&1)
[ "$up_out" = "2" ] && ok "upgrade keeps the operator's existing packages" || bad "upgrade packages=$up_out"

# Legacy 7-column package rows still read, with empty rate fields.
leg_pkg=$(RNS_DATA="$PRIVDIR/upgrade" RNS_LAB=0 BB="$BB" RNS_BB="$BB" RNS_HOME="$RNS_HOME" sh -c '
  . "$RNS_HOME/bin/common.sh"; . "$RNS_HOME/bin/store.sh"; packages_json' 2>&1)
if printf '%s' "$leg_pkg" | grep -q '"id":"1h"' && printf '%s' "$leg_pkg" | grep -q '"rate":"","rate_unit":""'; then
  ok "legacy 7-column package rows still load"
else
  bad "legacy packages $leg_pkg"
fi
printf '%s' "$leg_pkg" | json_ok "legacy packages JSON valid"

# The 11/12 -> 13 column voucher migration. Slot 10 used to be overloaded:
# expiry for a redeemed code, mint time for an unused one.
mkdir -p "$PRIVDIR/mig/database"
cat > "$PRIVDIR/mig/database/vouchers.tsv" << 'EOF'
AAAA1111|1 Hour|3600|2048|1024|new||||1790000000|Rs 500
BBBB2222|1 Hour|3600|2048|1024|active|aa:bb:cc:dd:ee:01|192.168.43.20|1790001000|1790004600|1790001000|counter
CCCC3333|1 Day|86400|1024|512|new||||1790000000||
DDDD4444|7 Days|604800|512|256|expired|aa:bb:cc:dd:ee:09|192.168.43.9|1789900000|1789990000|1789900000|
EEEE5555|3 Hours|10800|2048|1024|revoked||||1790002000|walk-in
EOF
mig_out=$(RNS_DATA="$PRIVDIR/mig" RNS_LAB=0 BB="$BB" RNS_BB="$BB" RNS_HOME="$RNS_HOME" sh -c '
  . "$RNS_HOME/bin/common.sh"; . "$RNS_HOME/bin/store.sh"; store_init
  awk -F"|" "{printf \"%s nf=%d created=%s exp=[%s] note=[%s]\n\", \$1, NF, \$11, \$10, \$12}" "$RNS_DB_DIR/vouchers.tsv"
' 2>&1)
printf '%s' "$mig_out" | grep -q 'AAAA1111 nf=13 created=1790000000 exp=\[\] note=\[Rs 500\]' \
  && ok "migration: unused 11-column code recovers its sale date" || bad "migration AAAA: $mig_out"
printf '%s' "$mig_out" | grep -q 'BBBB2222 nf=13 created=1790001000 exp=\[1790004600\] note=\[counter\]' \
  && ok "migration: redeemed 12-column code keeps expiry and created" || bad "migration BBBB: $mig_out"
printf '%s' "$mig_out" | grep -q 'EEEE5555 nf=13 created=1790002000 exp=\[\] note=\[walk-in\]' \
  && ok "migration: revoked code keeps its note" || bad "migration EEEE: $mig_out"
[ "$(printf '%s' "$mig_out" | grep -c 'nf=13')" = "5" ] \
  && ok "migration: every row is 13 columns" || bad "migration column count: $mig_out"
[ -f "$PRIVDIR/mig/database/vouchers.pre-schema13.bak" ] \
  && ok "migration keeps a rollback backup" || bad "migration backup missing"

# Sales arithmetic against a known fixture, including the two honest gaps:
# a legacy code with no sale date, and a code with no price.
mkdir -p "$PRIVDIR/sales/database"
sales_out=$(RNS_DATA="$PRIVDIR/sales" RNS_LAB=0 BB="$BB" RNS_BB="$BB" RNS_HOME="$RNS_HOME" sh -c '
  . "$RNS_HOME/bin/common.sh"; . "$RNS_HOME/bin/store.sh"; store_init
  printf "13\n" > "$RNS_DB_DIR/.schema13"
  package_upsert a "Fast Hour" 3600 2048 1024 100 100 hour >/dev/null
  package_upsert b "Day Pass" 86400 1024 512 250.50 250.50 day >/dev/null
  D1=$(ymd_to_epoch 2026-09-24); D2=$(ymd_to_epoch 2026-09-25); D3=$(ymd_to_epoch 2026-09-26)
  {
    printf "AA000001|Fast Hour|3600|2048|1024|new|||||%s||100\n" "$((D1+3600))"
    printf "AA000002|Fast Hour|3600|2048|1024|new|||||%s||100\n" "$((D1+7200))"
    printf "AA000003|Day Pass|86400|1024|512|active|aa:bb:cc:dd:ee:01|192.168.43.5|%s|%s|%s||250.50\n" "$((D1+100))" "$((D1+86500))" "$((D1+100))"
    printf "BB000001|Fast Hour|3600|2048|1024|new|||||%s||100\n" "$((D2+3600))"
    printf "BB000002|Day Pass|86400|1024|512|new|||||%s||250.50\n" "$((D2+3700))"
    printf "CC000001|Fast Hour|3600|2048|1024|active|aa:bb:cc:dd:ee:02|192.168.43.6|%s|%s|||100\n" "$((D2+50))" "$((D2+3650))"
    printf "DD000001|Day Pass|86400|1024|512|new|||||%s||\n" "$((D2+900))"
  } >> "$RNS_DB_DIR/vouchers.tsv"
  printf "FULL=%s\n" "$(sales_json "$D1" "$(ymd_to_epoch 2026-09-26 end)")"
  printf "DAY2=%s\n" "$(sales_json "$D2" "$(ymd_to_epoch 2026-09-25 end)")"
  printf "CSV<<\n%s\n>>CSV\n" "$(sales_csv "$D1" "$(ymd_to_epoch 2026-09-26 end)")"
' 2>&1)
printf '%s' "$sales_out" | grep -q 'FULL=' || bad "sales fixture produced no output: $sales_out"
_full=$(printf '%s' "$sales_out" | sed -n 's/^FULL=//p')
_day2=$(printf '%s' "$sales_out" | sed -n 's/^DAY2=//p')
printf '%s\n' "$_full" | json_ok "sales report is valid JSON"
printf '%s' "$_full" | grep -q '"totals":{"minted":6,"minted_revenue":"801.00","redeemed":2,"redeemed_revenue":"350.50","unpriced":1,"undated":1}' \
  && ok "sales totals: 6 generated Rs 801.00, 2 redeemed Rs 350.50" || bad "sales totals $_full"
printf '%s' "$_full" | grep -q '{"day":"2026-09-24","minted":3,"redeemed":1,"revenue":"450.50"' \
  && ok "sales by day (24th: 3 generated, Rs 450.50)" || bad "sales by_day $_full"
printf '%s' "$_full" | grep -q '{"label":"Day Pass","minted":3,"redeemed":1,"revenue":"501.00"' \
  && ok "sales by package (Day Pass Rs 501.00)" || bad "sales by_package $_full"
# Money is summed in paisa as integers: 250.50 twice must not drift to 500.99.
printf '%s' "$_full" | grep -q '501.00' && ! printf '%s' "$_full" | grep -q '500\.9' \
  && ok "decimal money does not drift" || bad "money drift $_full"
printf '%s' "$_day2" | grep -q '"totals":{"minted":3,"minted_revenue":"350.50","redeemed":1' \
  && ok "date-range filter narrows to one day" || bad "sales day2 $_day2"
printf '%s' "$_day2" | grep -q '2026-09-24' && bad "range leaked the 24th: $_day2" || ok "range excludes days outside it"
# An undated legacy code is counted, never silently dropped.
printf '%s' "$_full" | grep -q '"undated":1' && ok "undated legacy code reported, not dropped" || bad "undated $_full"
printf '%s' "$_full" | grep -q '"unpriced":1' && ok "unpriced code reported, not dropped" || bad "unpriced $_full"
printf '%s' "$sales_out" | grep -q '^day,2026-09-24,3,1,450.50$' \
  && ok "csv day row" || bad "csv day row: $sales_out"
printf '%s' "$sales_out" | grep -q '^package,"Day Pass",3,1,501.00$' \
  && ok "csv package row" || bad "csv package row: $sales_out"

rm -rf "$PRIVDIR"


# ---------------------------------------------------------------------------
# NC FALLBACK LISTENER. On some phones the compiled listener cannot start and
# the pages fall back to busybox nc, which cannot export CLIENT_IP. The page
# shell must resolve the peer address itself from /proc — otherwise the
# Magisk Action button opens "Staff only" on the shop's own phone and the
# staff cannot even log in. This section runs the fallback exactly like the
# phone does: RNS_LAB=0, no CLIENT_IP in the wrapper environment.
# ---------------------------------------------------------------------------
FBPORT=$((PORT + 3))
FB_WRAP="$RNS_DATA/fb-wrap.sh"
cat > "$FB_WRAP" << EOF
#!/bin/sh
export RNS_HOME='$RNS_HOME'
export RNS_DATA='$RNS_DATA'
export RNS_LAB=0
export RNS_DATA_AUTO=0
export BB='$BB'
export RNS_BB='$BB'
exec '$BB' sh '$RNS_HOME/bin/rns-front.sh'
EOF
chmod 755 "$FB_WRAP"
"$BB" nc -lk -p "$FBPORT" -e "$FB_WRAP" >/tmp/rns-nc-fb.log 2>&1 &
FBPID=$!
sleep 0.5
fb_kill() { kill "$FBPID" 2>/dev/null || true; wait "$FBPID" 2>/dev/null || true; }

fb_admin=$(curl -sS -m 8 -D /tmp/rns-fb-admin.hdr -o /tmp/rns-fb-admin.body -w '%{http_code}' "http://127.0.0.1:$FBPORT/admin" || true)
[ "$fb_admin" = "200" ] && ok "fallback admin status" || bad "fallback admin status=$fb_admin"
grep -q 'X-RNS-Front: 1' /tmp/rns-fb-admin.hdr && ok "fallback admin served by page shell" || bad "fallback admin not from page shell"
if grep -q 'Staff only' /tmp/rns-fb-admin.body; then
  bad "admin refused the shop's own phone over the nc fallback listener"
else
  grep -q 'Staff login' /tmp/rns-fb-admin.body && ok "admin opens on the same phone (no CLIENT_IP listener)" || bad "fallback admin body unexpected"
fi

fb_login=$(curl -sS -m 8 -H 'Accept: application/json' -d 'password=rns-admin' "http://127.0.0.1:$FBPORT/api/login" || true)
printf '%s' "$fb_login" | grep -q '"ok":true' && ok "staff login on the same phone (fallback)" || bad "fallback login $fb_login"

fb_probe=$(curl -sS -m 8 -o /tmp/rns-fb-probe.body -w '%{http_code}' "http://127.0.0.1:$FBPORT/generate_204" || true)
[ "$fb_probe" = "200" ] && grep -q 'Welcome online' /tmp/rns-fb-probe.body \
  && ok "probe is portal over fallback" || bad "fallback probe code=$fb_probe"
fb_kill


# ---------------------------------------------------------------------------
# ADDITIVE FIREWALL SYNC. fw_rebuild must never leave a moment where the
# captive REDIRECT or the DROP gate is missing — that window let a guest's
# connectivity probe reach the real internet, Android validated the network,
# and the captive sign-in notification never appeared. A fake iptables keeps
# the rules in files so order, idempotence, and self-heal can be asserted.
# ---------------------------------------------------------------------------
FAKEDIR="$RNS_DATA/fakefw"
FAKESTATE="$RNS_DATA/fakefw-state"
mkdir -p "$FAKEDIR"
rm -rf "$FAKESTATE"
cat > "$FAKEDIR/iptables" << 'EOF'
#!/bin/sh
dir=${FAKE_IPT_DIR:-/tmp/fake-ipt}
mkdir -p "$dir"
table=filter
while [ "$1" = "-t" ]; do table=$2; shift 2; done
f=$dir/$table.rules
touch "$f"
cmd=$1; shift
case "$cmd" in
  -N)
    grep -Fxq "# chain $1" "$f" || printf '# chain %s\n' "$1" >> "$f"
    ;;
  -X)
    grep -Fxv "# chain $1" "$f" > "$f.tmp" || true
    grep -v "^-A $1 " "$f.tmp" > "$f" || true
    rm -f "$f.tmp"
    ;;
  -C)
    chain=$1; shift
    grep -Fxq -- "-A $chain $*" "$f"
    exit $?
    ;;
  -A)
    chain=$1; shift
    printf -- '-A %s %s\n' "$chain" "$*" >> "$f"
    ;;
  -I)
    chain=$1; shift
    pos=1
    case "$1" in
      ''|*[!0-9]*) ;;
      *) pos=$1; shift ;;
    esac
    awk -v ch="$chain" -v pos="$pos" -v new="-A $chain $*" '
      $1 == "-A" && $2 == ch {
        n++
        if (n == pos && !done) { print new; done = 1 }
      }
      { print }
      END { if (!done) print new }
    ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    ;;
  -D)
    chain=$1; shift
    awk -v target="-A $chain $*" '
      !done && $0 == target { done = 1; next }
      { print }
    ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    ;;
  -F)
    chain=$1
    if [ -n "$chain" ]; then
      awk -v ch="$chain" '!($1 == "-A" && $2 == ch)' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    else
      awk '$1 != "-A"' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    fi
    ;;
  -S)
    chain=$1
    if [ -n "$chain" ]; then
      grep -- "^-A $chain " "$f" || true
    else
      grep -- '^-A ' "$f" || true
    fi
    ;;
  *)
    :
    ;;
esac
exit 0
EOF
chmod 755 "$FAKEDIR/iptables"

fw_run() {
  (
    export RNS_FAKE_FW=1
    export FAKE_IPT_DIR="$FAKESTATE"
    PATH="$FAKEDIR:$PATH"
    . "$RNS_HOME/bin/net.sh"
    "$@"
  ) >/dev/null 2>&1
}

line_of() {
  grep -n -- "$2" "$1" 2>/dev/null | head -n 1 | cut -d: -f1
}

fw_run fw_rebuild
_filter="$FAKESTATE/filter.rules"
_nat="$FAKESTATE/nat.rules"

grep -q 'REDIRECT --to-ports 8080' "$_nat" && ok "fw: captive redirect installed" || bad "fw: no redirect $(cat "$_nat" 2>/dev/null)"
grep -q -- '--mac-source 02:00:00:00:02:03 -j RETURN' "$_filter" && ok "fw: active device allowed" || bad "fw: no per-mac allow"
_mac_ln=$(line_of "$_filter" 'mac-source 02:00:00:00:02:03')
_dns_ln=$(line_of "$_filter" '--dport 53 -j RETURN')
_drop_ln=$(line_of "$_filter" '-i ap0 -j DROP')
if [ -n "$_mac_ln" ] && [ -n "$_dns_ln" ] && [ -n "$_drop_ln" ] \
  && [ "$_mac_ln" -lt "$_dns_ln" ] && [ "$_dns_ln" -lt "$_drop_ln" ]; then
  ok "fw: rule order allows < base < drop"
else
  bad "fw: rule order mac=$_mac_ln dns=$_dns_ln drop=$_drop_ln"
fi
_rej_ln=$(line_of "$_filter" '--dport 443 -j REJECT')
[ -n "$_rej_ln" ] && [ "$_rej_ln" -lt "$_drop_ln" ] && ok "fw: https reset before drop" || bad "fw: reject order"

cp "$_filter" "$_filter.b1"; cp "$_nat" "$_nat.b1"
fw_run fw_rebuild
cmp -s "$_filter" "$_filter.b1" && cmp -s "$_nat" "$_nat.b1" \
  && ok "fw: rebuild is idempotent (no duplicate rules)" \
  || bad "fw: rebuild duplicated rules"

# The bound device expires: its allow rules disappear, gate stays intact.
"$BB" awk -F'|' -v OFS='|' -v c="48219033" '$1==c { $6="expired" } { print }' \
  "$VFILE" > "$VFILE.fw" && mv "$VFILE.fw" "$VFILE"
fw_run fw_rebuild
if grep -q -- '--mac-source 02:00:00:00:02:03' "$_filter" || grep -q -- '--mac-source 02:00:00:00:02:03' "$_nat"; then
  bad "fw: stale device allow not removed"
else
  ok "fw: expired device allow removed"
fi
grep -q 'REDIRECT --to-ports 8080' "$_nat" && ok "fw: redirect survives device churn" || bad "fw: redirect lost after churn"

# A damaged chain (only a bare DROP left) must self-heal with the base rules
# back in canonical order — DNS reachable before the drop.
printf -- '-A RNS_FWD -i ap0 -j DROP\n' > "$_filter"
fw_run fw_rebuild
_dns_ln=$(line_of "$_filter" '--dport 53 -j RETURN')
_drop_ln=$(line_of "$_filter" '-i ap0 -j DROP')
if [ -n "$_dns_ln" ] && [ -n "$_drop_ln" ] && [ "$_dns_ln" -lt "$_drop_ln" ]; then
  ok "fw: damaged chain self-heals in order"
else
  bad "fw: self-heal order dns=$_dns_ln drop=$_drop_ln"
fi


# ---------------------------------------------------------------------------
# ISOLATION. Break the function code and the page files, then prove the staff
# panel and the captive portal still open. This is the failure the operator
# reported: a change in voucher/firewall/UI code blanked both pages.
# restore_broken() is wired into the EXIT trap, so the working tree is put
# back even when an assertion below fails.
# ---------------------------------------------------------------------------
BROKEN=0
BROKEN_DIR="/tmp/rns-broken-$$"

break_functions() {
  [ "$BROKEN" = "1" ] && return 0
  BROKEN=1
  mkdir -p "$BROKEN_DIR" 2>/dev/null || true
  for _f in rns-http.sh store.sh net.sh; do
    cp -p "$RNS_HOME/bin/$_f" "$BROKEN_DIR/$_f" 2>/dev/null || true
  done
  for _f in admin.html portal.html; do
    cp -p "$RNS_HOME/www/$_f" "$BROKEN_DIR/$_f" 2>/dev/null || true
  done
  # A syntax error is the worst case: nothing in these files can run at all.
  printf 'if [ "$1" = "(" ]; then\n  echo "broken on purpose"\nfi\n' \
    > "$RNS_HOME/bin/rns-http.sh"
  printf 'this is not shell (\n' > "$RNS_HOME/bin/store.sh"
  printf 'this is not shell either )\n' > "$RNS_HOME/bin/net.sh"
  # The page files are empty too, so only the embedded fallbacks can answer.
  : > "$RNS_HOME/www/admin.html"
  : > "$RNS_HOME/www/portal.html"
}

restore_broken() {
  [ "$BROKEN" = "1" ] || return 0
  BROKEN=0
  for _f in rns-http.sh store.sh net.sh; do
    [ -f "$BROKEN_DIR/$_f" ] && cp -p "$BROKEN_DIR/$_f" "$RNS_HOME/bin/$_f"
  done
  for _f in admin.html portal.html; do
    [ -f "$BROKEN_DIR/$_f" ] && cp -p "$BROKEN_DIR/$_f" "$RNS_HOME/www/$_f"
  done
  rm -rf "$BROKEN_DIR"
}

BPORT=$((PORT + 1))
"$BIN" "$BPORT" "$RNS_HOME/bin/rns-front.sh" >/tmp/rns-httpd-iso.log 2>&1 &
BPID=$!
sleep 0.3
iso_kill() { kill "$BPID" 2>/dev/null || true; wait "$BPID" 2>/dev/null || true; }

# Sanity first: with the working tree intact, the isolated shell answers.
b_admin=$(curl -sS -m 5 "http://127.0.0.1:$BPORT/admin" || true)
printf '%s' "$b_admin" | grep -q 'Staff login' && ok "isolated admin before break" || bad "isolated admin before break"

break_functions

iso_admin=$(curl -sS -m 8 -D /tmp/rns-iso-admin.hdr -o /tmp/rns-iso-admin.body "http://127.0.0.1:$BPORT/admin" || true)
grep -q '200' /tmp/rns-iso-admin.hdr && ok "admin 200 with broken functions" || bad "admin header $(head -1 /tmp/rns-iso-admin.hdr)"
grep -q 'Staff login' /tmp/rns-iso-admin.body && ok "admin page with broken functions and no admin.html" || bad "admin body with broken functions"
grep -q 'X-RNS-Front: 1' /tmp/rns-iso-admin.hdr && ok "admin served by the isolated shell" || bad "admin not served by the isolated shell"

iso_home=$(curl -sS -m 8 -o /tmp/rns-iso-home.body -w '%{http_code}' "http://127.0.0.1:$BPORT/" || true)
[ "$iso_home" = "200" ] && ok "portal 200 with broken functions" || bad "portal code=$iso_home"
grep -q 'Welcome online' /tmp/rns-iso-home.body && ok "portal page with broken functions and no portal.html" || bad "portal body with broken functions"

iso_probe=$(curl -sS -m 8 -o /tmp/rns-iso-probe.body -w '%{http_code}' "http://127.0.0.1:$BPORT/generate_204" || true)
[ "$iso_probe" = "200" ] && grep -q 'Welcome online' /tmp/rns-iso-probe.body && ok "probe still portal with broken functions" || bad "probe with broken functions code=$iso_probe"

iso_health=$(curl -sS -m 8 "http://127.0.0.1:$BPORT/health" || true)
printf '%s' "$iso_health" | grep -q '"ok":true' && ok "health with broken functions" || bad "health with broken functions $iso_health"

iso_api=$(curl -sS -m 20 -H 'Accept: application/json' "http://127.0.0.1:$BPORT/api/status" || true)
[ -n "$iso_api" ] && printf '%s' "$iso_api" | grep -q '{' && ok "api answers json with broken functions" || bad "api with broken functions [$iso_api]"

restore_broken
iso_kill

# ---------------------------------------------------------------------------
# BOOT PATH. service.sh is what runs at boot, and it is the path that used to
# fail: a broken function script or an unwritable log directory stopped the
# pages from ever binding. Run a copy of it against a private data dir and
# prove the admin panel and the captive portal come up on their own.
# ---------------------------------------------------------------------------
BOOT=/tmp/rns-boot-$$
BOOT_DATA="$BOOT/data"
BOOT_PORT=$((PORT + 2))
rm -rf "$BOOT"
mkdir -p "$BOOT_DATA" "$BOOT/rns"
cp -r "$RNS_HOME/." "$BOOT/rns/"
cp "$ROOT/module/service.sh" "$BOOT/service.sh"
for _f in "$BOOT/service.sh" $(find "$BOOT/rns" -name '*.sh'); do
  sed -i "s|/data/adb/rns|$BOOT_DATA|g" "$_f" 2>/dev/null || true
done

boot_kill() {
  for _f in rnsd httpd apwatch; do
    if [ -f "$BOOT_DATA/$_f.pid" ]; then
      kill "$(cat "$BOOT_DATA/$_f.pid" 2>/dev/null)" 2>/dev/null || true
    fi
  done
  sleep 1
  for _f in rnsd httpd apwatch; do
    if [ -f "$BOOT_DATA/$_f.pid" ]; then
      kill -9 "$(cat "$BOOT_DATA/$_f.pid" 2>/dev/null)" 2>/dev/null || true
    fi
  done
  rm -rf "$BOOT"
}

RNS_PORT=$BOOT_PORT sh "$BOOT/service.sh" >/dev/null 2>&1 || true

boot_ok=0
_i=0
while [ "$_i" -lt 12 ]; do
  if curl -sS -m 2 "http://127.0.0.1:$BOOT_PORT/health" 2>/dev/null | grep -q 'rns-front'; then
    boot_ok=1
    break
  fi
  _i=$((_i + 1))
  sleep 1
done
[ "$boot_ok" = "1" ] && ok "boot service.sh starts the page server" || bad "boot service.sh did not start the page server"

boot_admin=$(curl -sS -m 5 "http://127.0.0.1:$BOOT_PORT/admin" || true)
printf '%s' "$boot_admin" | grep -q 'Staff login' && ok "boot admin page" || bad "boot admin page"

boot_home=$(curl -sS -m 5 -o /tmp/rns-boot-home.body -w '%{http_code}' "http://127.0.0.1:$BOOT_PORT/" || true)
[ "$boot_home" = "200" ] && grep -q 'Welcome online' /tmp/rns-boot-home.body && ok "boot portal page" || bad "boot portal code=$boot_home"

boot_probe=$(curl -sS -m 5 -o /tmp/rns-boot-probe.body -w '%{http_code}' "http://127.0.0.1:$BOOT_PORT/generate_204" || true)
[ "$boot_probe" = "200" ] && grep -q 'Welcome online' /tmp/rns-boot-probe.body && ok "boot captive probe" || bad "boot captive probe code=$boot_probe"

boot_api=$(curl -sS -m 15 -H 'Accept: application/json' "http://127.0.0.1:$BOOT_PORT/api/status" || true)
[ -n "$boot_api" ] && printf '%s' "$boot_api" | grep -q '"ok":true' && ok "boot delegated api" || bad "boot delegated api [$boot_api]"

boot_kill

if [ "$fail" -eq 0 ]; then
  say "ALL PASSED"
  exit 0
fi
say "FAILED"
exit 1
