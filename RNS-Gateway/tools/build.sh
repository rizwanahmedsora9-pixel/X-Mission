#!/bin/sh
set -e
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
mkdir -p module/rns/bin

echo "compile listeners"
gcc -Os -s -o module/rns/bin/rns-httpd-x86_64 src/rns-httpd.c
# HOT 8 is arm64. Keep previously built phone listeners when a release machine
# does not have the optional cross compilers installed.
if command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
  aarch64-linux-gnu-gcc -static-pie -Os -s -o module/rns/bin/rns-httpd-arm64 src/rns-httpd.c
else
  echo "warning: aarch64-linux-gnu-gcc missing; retaining existing arm64 listener"
fi
if command -v arm-linux-gnueabihf-gcc >/dev/null 2>&1; then
  arm-linux-gnueabihf-gcc -static -Os -s -o module/rns/bin/rns-httpd-arm src/rns-httpd.c
else
  echo "warning: arm-linux-gnueabihf-gcc missing; retaining existing arm listener"
fi
chmod 755 module/rns/bin/rns-httpd-* module/rns/bin/*.sh module/*.sh 2>/dev/null || true
[ -x module/rns/bin/rns-httpd-arm64 ] || { echo "missing arm64 listener" >&2; exit 1; }
[ -x module/rns/bin/rns-httpd-arm ] || { echo "missing arm listener" >&2; exit 1; }

echo "zip"
rm -f RNS_Gateway.zip
(
  cd module
  zip -r -X ../RNS_Gateway.zip \
    module.prop service.sh post-fs-data.sh uninstall.sh action.sh OPERATOR.txt \
    rns/bin rns/www \
    -x 'rns/bin/rns-httpd-x86_64'
)
# Phone zip should include arm binaries, not the lab x86 binary.
# Rebuild including arm only — the command above excluded x86. Good.
unzip -l RNS_Gateway.zip
echo "built $ROOT/RNS_Gateway.zip"
