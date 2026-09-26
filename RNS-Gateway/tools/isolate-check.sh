#!/bin/sh
# Fail the build if the admin panel or captive portal starts depending on
# voucher, firewall, or other function scripts again.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fail=0
bad() { printf 'ISOLATION FAIL %s\n' "$*"; fail=1; }

for f in \
  module/rns/bin/rns-front.sh \
  module/rns/bin/rns-pages.sh \
  module/action.sh \
  module/service.sh \
  module/boot-completed.sh \
  module/rns/bin/rnsd.sh \
  module/rns/bin/rns-gate-min.sh
do
  if [ ! -f "$ROOT/$f" ]; then
    bad "missing $f"
    continue
  fi
  if grep -E '^[[:space:]]*\.[[:space:]]' "$ROOT/$f" | grep -E 'store\.sh|net\.sh|common\.sh|rns-http\.sh' >/dev/null; then
    bad "$f sources a function script"
  fi
done

grep -q 'admin.html' "$ROOT/module/rns/bin/rns-front.sh" || bad "front door does not serve admin.html"
grep -q 'portal.html' "$ROOT/module/rns/bin/rns-front.sh" || bad "front door does not serve portal.html"
grep -q 'Staff login' "$ROOT/module/rns/bin/rns-front.sh" || bad "front door has no admin fallback"
grep -q 'Welcome online' "$ROOT/module/rns/bin/rns-front.sh" || bad "front door has no portal fallback"
grep -q 'rns-front.sh' "$ROOT/module/rns/bin/rns-pages.sh" || bad "page starter does not use the front door"
grep -q 'rns-pages.sh' "$ROOT/module/service.sh" || bad "service.sh does not start pages directly"
grep -q 'rns-pages.sh' "$ROOT/module/action.sh" || bad "action.sh does not start pages directly"
grep -q 'service.sh' "$ROOT/module/boot-completed.sh" || bad "boot-completed.sh does not reach the boot start path"
# v8 architectural rule: a listener is only "up" when it ANSWERS HTTP.
# The engine ladder must live-probe the port — a pid file is not proof.
grep -q 'probe_pages' "$ROOT/module/rns/bin/rns-pages.sh" || bad "rns-pages.sh lost its live HTTP probe"
grep -q 'wait_for_pages' "$ROOT/module/rns/bin/rns-pages.sh" || bad "rns-pages.sh lost its verified engine ladder"
# v8 architectural rule: the captive redirect covers every hotspot name a
# ROM might use, not just one hardcoded interface.
grep -q 'swlan0' "$ROOT/module/rns/bin/rns-gate-min.sh" || bad "rns-gate-min.sh lost multi-interface coverage"
grep -q 'uplink' "$ROOT/module/rns/bin/rns-gate-min.sh" || bad "rns-gate-min.sh lost uplink protection"
grep -q 'id="gate"' "$ROOT/module/rns/www/admin.html" || bad "admin.html lost the visible login shell"
grep -q 'Welcome online' "$ROOT/module/rns/www/portal.html" || bad "portal.html lost the visible welcome"
grep -q 'action="/api/redeem"' "$ROOT/module/rns/www/portal.html" || bad "portal.html lost the no-JS voucher form"

if grep -E 'rns-http\.sh' "$ROOT/module/rns/bin/rnsd.sh" | grep -v '^[[:space:]]*#' >/dev/null; then
  bad "rnsd.sh still launches the function handler as the page server"
fi

# Every element the panel's JavaScript looks up by id must exist in the markup.
# A typo here does not throw a visible error: $('x') returns null, the next
# property access throws, and the operator gets a blank panel with no clue why.
# The Sales tab and the package builder added a lot of ids, so this is cheap
# insurance on every build.
_admin="$ROOT/module/rns/www/admin.html"
if [ -f "$_admin" ]; then
  _ids=$(grep -o 'id="[^"]*"' "$_admin" | sed 's/^id="//; s/"$//' | sort -u)
  _refs=$(grep -o "\$('[^']*')" "$_admin" | sed "s/^\$('//; s/')$//" | sort -u)
  _missing=""
  for _r in $_refs; do
    printf '%s\n' "$_ids" | grep -qx "$_r" || _missing="$_missing $_r"
  done
  if [ -n "$_missing" ]; then
    bad "admin.html JS references missing element ids:$_missing"
  fi
  # The v6 operator surface must survive edits.
  grep -q 'data-tab="sales"' "$_admin" || bad "admin.html lost the Sales tab"
  grep -q 'id="pkg_duration_unit"' "$_admin" || bad "package builder lost the time unit dropdown"
  grep -q 'id="pkg_rate_unit"' "$_admin" || bad "package builder lost the price unit dropdown"
  grep -q 'id="salesFrom"' "$_admin" || bad "sales report lost the date range filter"
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi
printf 'isolation checks passed\n'
