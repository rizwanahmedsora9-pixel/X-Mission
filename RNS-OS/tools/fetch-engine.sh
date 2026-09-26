#!/bin/sh
# fetch-engine.sh — copy the gateway engine into an RNS-OS payload tree.
#
# RNS-OS does not fork the billing code. It installs the SAME engine files
# the Magisk module ships (rns/bin/*.sh, rns/www/*.html) under
# /usr/local/lib/rns, and differs only in the platform layer around them.
# One source of truth, two delivery formats:
#
#     RNS-Gateway/  ->  Magisk zip   ->  rooted phone
#     RNS-OS/       ->  Debian ISO   ->  Oracle VirtualBox
#
# Usage: fetch-engine.sh <dest-rns-dir>
#   env RNS_ENGINE_SRC  path to the Magisk module's rns/ directory
#   env RNS_SRC_ROOT    path to RNS-Gateway/ (for src/rns-httpd.c)
#
# Exits non-zero if any required engine file is missing, so a half-copied
# engine can never end up inside an ISO.

set -eu

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OS_ROOT=$(CDPATH= cd -- "$SELF_DIR/.." && pwd)
REPO_ROOT=$(CDPATH= cd -- "$OS_ROOT/.." && pwd)

DEST=${1:-}
if [ -z "$DEST" ]; then
  echo "usage: fetch-engine.sh <dest-rns-dir>" >&2
  exit 2
fi

SRC=${RNS_ENGINE_SRC:-$REPO_ROOT/RNS-Gateway/module/rns}
SRC_ROOT=${RNS_SRC_ROOT:-$REPO_ROOT/RNS-Gateway}

if [ ! -d "$SRC" ]; then
  echo "fetch-engine: engine source not found: $SRC" >&2
  echo "fetch-engine: set RNS_ENGINE_SRC to the Magisk module's rns/ directory." >&2
  exit 1
fi

# The engine files RNS-OS must have. rns-httpd-arm/arm64 are deliberately not
# listed: the appliance is x86_64 only, and shipping them would only make the
# ISO bigger while pick_httpd probed binaries that cannot run.
REQUIRED="
bin/common.sh
bin/store.sh
bin/net.sh
bin/rns-http.sh
bin/rns-front.sh
bin/rns-pages.sh
bin/rnsd.sh
bin/rns-worker.sh
bin/rns-gate-min.sh
bin/rns-heal.sh
bin/rns-bound.sh
bin/rns-apwatch.sh
bin/rns-ctl.sh
www/admin.html
www/portal.html
"

missing=0
for f in $REQUIRED; do
  if [ ! -f "$SRC/$f" ]; then
    echo "fetch-engine: MISSING $SRC/$f" >&2
    missing=1
  fi
done
[ "$missing" -eq 0 ] || exit 1

mkdir -p "$DEST/bin" "$DEST/www"

for f in $REQUIRED; do
  cp "$SRC/$f" "$DEST/$f"
  case "$f" in
    bin/*.sh) chmod 755 "$DEST/$f" ;;
    *)        chmod 644 "$DEST/$f" ;;
  esac
done

# The compiled listener. Prefer the one in the source tree; if it is absent
# (the v7 Magisk zip ships only the arm builds) or will not execute here,
# build it from the same C source the phone's binaries came from.
BIN="$DEST/bin/rns-httpd-x86_64"
ok=0
if [ -f "$SRC/bin/rns-httpd-x86_64" ]; then
  cp "$SRC/bin/rns-httpd-x86_64" "$BIN"
  chmod 755 "$BIN"
  if "$BIN" --check >/dev/null 2>&1; then
    ok=1
  else
    echo "fetch-engine: shipped rns-httpd-x86_64 will not run here; rebuilding" >&2
  fi
fi
if [ "$ok" -eq 0 ]; then
  if [ ! -f "$SRC_ROOT/src/rns-httpd.c" ]; then
    echo "fetch-engine: no working rns-httpd-x86_64 and no $SRC_ROOT/src/rns-httpd.c" >&2
    exit 1
  fi
  if ! command -v cc >/dev/null 2>&1 && ! command -v gcc >/dev/null 2>&1; then
    echo "fetch-engine: need cc or gcc to build the listener" >&2
    exit 1
  fi
  _cc=$(command -v cc || command -v gcc)
  "$_cc" -Os -s -o "$BIN" "$SRC_ROOT/src/rns-httpd.c"
  chmod 755 "$BIN"
  "$BIN" --check >/dev/null 2>&1 || { echo "fetch-engine: built listener fails --check" >&2; exit 1; }
  echo "fetch-engine: built rns-httpd-x86_64 from src/rns-httpd.c"
fi

# Manifest: what exactly went in, and from where. Lets anyone prove later that
# the appliance's billing code is byte-identical to a given Magisk release.
{
  printf 'engine-source %s\n' "$SRC"
  printf 'fetched %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  if command -v sha256sum >/dev/null 2>&1; then
    ( cd "$DEST" && find bin www -type f | sort | xargs sha256sum )
  fi
} > "$DEST/ENGINE.manifest"

echo "fetch-engine: $(printf '%s\n' $REQUIRED | wc -l) engine files + listener -> $DEST"
