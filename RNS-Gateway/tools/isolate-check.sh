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
grep -q 'id="gate"' "$ROOT/module/rns/www/admin.html" || bad "admin.html lost the visible login shell"
grep -q 'Welcome online' "$ROOT/module/rns/www/portal.html" || bad "portal.html lost the visible welcome"
grep -q 'action="/api/redeem"' "$ROOT/module/rns/www/portal.html" || bad "portal.html lost the no-JS voucher form"

if grep -E 'rns-http\.sh' "$ROOT/module/rns/bin/rnsd.sh" | grep -v '^[[:space:]]*#' >/dev/null; then
  bad "rnsd.sh still launches the function handler as the page server"
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi
printf 'isolation checks passed\n'
