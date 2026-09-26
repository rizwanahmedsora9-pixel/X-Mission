#!/bin/sh
# install-payload.sh — lay out the complete RNS-OS filesystem payload.
#
# This is the ONE code path that produces the tree which goes into the ISO,
# and it is the same code path the test suite runs. build-iso.sh calls it and
# copies the result into /target; tools/os-selftest.sh calls it and boots the
# result. Nothing about the shipped image is assembled anywhere else, so what
# the tests exercise is what the installer installs.
#
# Usage: install-payload.sh --dest <dir>
#   env RNS_ENGINE_SRC  engine source (see fetch-engine.sh)
#   env RNS_SRC_ROOT    RNS-Gateway/ (for src/rns-httpd.c)
#   env RNS_OS_VERSION  version string written into the image

set -eu

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OS_ROOT=$(CDPATH= cd -- "$SELF_DIR/.." && pwd)

DEST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dest) DEST=${2:-}; shift 2 ;;
    --dest=*) DEST=${1#--dest=}; shift ;;
    *) echo "install-payload: unknown arg $1" >&2; exit 2 ;;
  esac
done
[ -n "$DEST" ] || { echo "usage: install-payload.sh --dest <dir>" >&2; exit 2; }

VERSION=${RNS_OS_VERSION:-$(cat "$OS_ROOT/VERSION" 2>/dev/null || echo 0.0.0)}

mkdir -p "$DEST"

# 1. Static payload (etc/, usr/) straight from the repository.
cp -a "$OS_ROOT/payload/." "$DEST/"

# 2. Gateway engine -> /usr/local/lib/rns
mkdir -p "$DEST/usr/local/lib/rns"
sh "$SELF_DIR/fetch-engine.sh" "$DEST/usr/local/lib/rns"

# 3. Runtime directories.
mkdir -p "$DEST/var/lib/rns" "$DEST/var/log/rns" "$DEST/etc/rns"

# 4. Android-path compatibility shim.
#
# The engine is shared with the phone and a handful of paths in it are
# hard-coded to Android: rns-worker.sh writes /data/adb/rns/page.env and
# /data/adb/rns/phone.ips, rns-front.sh reads them back to decide whether the
# caller is the shop's own device, and the page shell mirrors its log to
# /data/local/tmp. Rather than fork those files, RNS-OS points the Android
# paths at the real ones. The engine stays byte-identical to the Magisk
# release and every one of those code paths keeps working.
mkdir -p "$DEST/data/adb" "$DEST/data/local"
ln -sfn /var/lib/rns "$DEST/data/adb/rns"
ln -sfn /var/log/rns "$DEST/data/local/tmp"

# 5. Executable bits. cp -a preserves them from git, but a payload edited on
# a checkout that lost the mode would silently install a non-executable
# controller, so set them explicitly.
for f in \
  usr/local/bin/rns \
  usr/local/sbin/rns-os-ctl \
  usr/local/lib/rns/bin/rns-bb
do
  [ -f "$DEST/$f" ] && chmod 755 "$DEST/$f"
done
for f in "$DEST"/usr/local/lib/rns/bin/*.sh; do
  [ -f "$f" ] && chmod 755 "$f"
done
chmod 755 "$DEST/usr/local/lib/rns/bin/rns-httpd-x86_64" 2>/dev/null || true

# 6. Version + provenance inside the image.
mkdir -p "$DEST/usr/share/rns-os" "$DEST/usr/share/doc/rns-os"
printf '%s\n' "$VERSION" > "$DEST/usr/share/rns-os/VERSION"
cp "$OS_ROOT/README.md" "$DEST/usr/share/doc/rns-os/README.md" 2>/dev/null || true
{
  printf 'RNS-OS %s\n' "$VERSION"
  printf 'built %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'built-by %s\n' "$(uname -srm)"
  printf 'engine-source %s\n' "${RNS_ENGINE_SRC:-RNS-Gateway/module/rns}"
} > "$DEST/usr/share/rns-os/BUILD"

# 7. Sanity: fail the build rather than shipping a broken appliance.
fail=0
for f in \
  etc/rns/env \
  etc/rns/defaults.env \
  etc/rns/hostapd.conf.tmpl \
  etc/rns/dnsmasq.conf.tmpl \
  etc/systemd/system/rns-net.service \
  etc/systemd/system/rns-dhcp.service \
  etc/systemd/system/rns-ap.service \
  etc/systemd/system/rns-gateway.service \
  etc/systemd/system/rns-firstboot.service \
  usr/local/bin/rns \
  usr/local/sbin/rns-os-ctl \
  usr/local/lib/rns/bin/rnsd.sh \
  usr/local/lib/rns/bin/rns-bb \
  usr/local/lib/rns/bin/store.sh \
  usr/local/lib/rns/www/portal.html \
  usr/local/lib/rns/www/admin.html
do
  if [ ! -e "$DEST/$f" ]; then
    echo "install-payload: MISSING $f" >&2
    fail=1
  fi
done
[ "$fail" -eq 0 ] || exit 1

# Every ExecStart/ExecStop/ExecStartPre must point at something in the image.
# (The `while read` body runs in a subshell when piped, so collect the missing
# paths and test afterwards instead of trying to exit from inside the loop.)
_missing=""
for unit in "$DEST"/etc/systemd/system/*.service; do
  for _p in $(grep -hE '^Exec(Start|Stop|StartPre|Reload)=' "$unit" \
              | sed -E 's/^Exec[A-Za-z]+=//; s/^[-+!@:]+//' \
              | awk '{print $1}')
  do
    case "$_p" in
      "") continue ;;
      /bin/*|/usr/bin/*|/sbin/*|/usr/sbin/*) continue ;;  # from the base system
    esac
    if [ ! -e "$DEST$_p" ]; then
      _missing="$_missing $(basename "$unit"):$_p"
    fi
  done
done
if [ -n "$_missing" ]; then
  for _m in $_missing; do
    echo "install-payload: unit refers to missing ${_m#*:} (${_m%%:*})" >&2
  done
  exit 1
fi

echo "install-payload: RNS-OS $VERSION staged at $DEST"
