#!/bin/sh
# build-iso.sh — build the bootable RNS-OS installer ISO for Oracle VirtualBox.
#
# What it does:
#   1. takes a Debian 12 amd64 netinst ISO (downloads it, or uses --base)
#   2. lays out the RNS-OS payload with tools/install-payload.sh
#   3. adds preseed.cfg (unattended install) and the payload to the ISO
#   4. patches the installer's boot menus so the automated entry is used
#   5. writes a hybrid ISO that boots in VirtualBox (BIOS + UEFI) and from USB
#
# The result installs itself with no keypresses: partition, install, copy the
# appliance in, enable the units, reboot.
#
# Usage:
#   ./build-iso.sh                      download Debian, build the ISO
#   ./build-iso.sh --base debian.iso    offline: use a local netinst ISO
#   ./build-iso.sh --check              do everything except burn the ISO
#   ./build-iso.sh --patch-menu DIR     only patch the installer boot menus in
#                                       DIR (used by tools/os-selftest.sh)
#
# Needs: xorriso, and (to download) curl or wget. Run it as a normal user;
# root is not required.

set -eu

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OS_ROOT=$(CDPATH= cd -- "$SELF_DIR/.." && pwd)

VERSION=$(cat "$OS_ROOT/VERSION" 2>/dev/null || echo 0.0.0)
OUT="$OS_ROOT/dist/RNS-OS-${VERSION}-amd64.iso"
BASE=""
CHECK=0
KEEP=0
# Any Debian 12 (bookworm) amd64 netinst image works. "current" on the Debian
# CD image server moves with each point release, so if this 404s, list
# https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/ and pass the
# current filename with --url, or download it yourself and use --base.
URL=${DEBIAN_ISO_URL:-https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-12.11.0-amd64-netinst.iso}
SHA256=${DEBIAN_ISO_SHA256:-}
WORK=""
PATCH_MENU_DIR=""

die() { printf 'build-iso: %s\n' "$*" >&2; exit 1; }
say() { printf 'build-iso: %s\n' "$*"; }

# ---------------------------------------------------------------------------
# patch_menus — point the installer's boot entries at our preseed.
#
# Defined up here, and exposed as --patch-menu <dir>, so tools/os-selftest.sh
# can run this exact code against a synthetic Debian boot tree. Everything
# else in this script needs xorriso and a real base image; this is the step
# where a mistake silently produces an ISO that installs plain Debian instead
# of RNS-OS, so it is the step worth testing.
# ---------------------------------------------------------------------------
patch_menus() {
  _dir=$1
  [ -d "$_dir" ] || die "patch_menus: not a directory: $_dir"
  # The arguments have to land BEFORE the `---` separator: everything after it
  # is handed to the installed system's shell, not to debian-installer, and a
  # preseed argument placed there is silently ignored.
  _args="auto=true priority=critical preseed/file=/cdrom/preseed.cfg"
  _patched=0
  for _f in "$_dir"/isolinux/txt.cfg "$_dir"/isolinux/adtxt.cfg \
            "$_dir"/isolinux/menu.cfg "$_dir"/boot/grub/grub.cfg
  do
    [ -f "$_f" ] || continue
    cp "$_f" "$_f.rns.bak"
    if grep -q -- ' ---' "$_f"; then
      sed -i "s| ---| ${_args} ---|g" "$_f"
    else
      sed -i -E "s|^([[:space:]]*(append|linux)[[:space:]].*)$|\1 ${_args}|" "$_f"
    fi
    if cmp -s "$_f" "$_f.rns.bak"; then
      say "  $(basename "$_f"): no boot line matched (left alone)"
      mv "$_f.rns.bak" "$_f"
    else
      say "  $(basename "$_f"): automated install arguments added"
      rm -f "$_f.rns.bak"
      _patched=$((_patched + 1))
    fi
  done
  [ "$_patched" -gt 0 ] || die "no installer boot menu was patched — the ISO would install plain Debian"

  # Make the automated entry the one that runs when nobody presses a key.
  if [ -f "$_dir/isolinux/isolinux.cfg" ]; then
    grep -q '^timeout' "$_dir/isolinux/isolinux.cfg" || \
      printf 'timeout 50\n' >> "$_dir/isolinux/isolinux.cfg"
  fi
  say "boot menus patched ($_patched file(s))"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --out)     OUT=${2:?}; shift 2 ;;
    --base)    BASE=${2:?}; shift 2 ;;
    --url)     URL=${2:?}; shift 2 ;;
    --sha256)  SHA256=${2:?}; shift 2 ;;
    --check)   CHECK=1; shift ;;
    --patch-menu) PATCH_MENU_DIR=${2:?}; shift 2 ;;
    --keep)    KEEP=1; shift ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *)         die "unknown argument: $1" ;;
  esac
done

cleanup() {
  if [ -n "$WORK" ] && [ -d "$WORK" ] && [ "$KEEP" -eq 0 ]; then
    rm -rf "$WORK"
  elif [ -n "$WORK" ]; then
    say "work dir kept at $WORK"
  fi
}
trap cleanup EXIT

# --patch-menu runs only the boot-menu step against a directory that already
# exists: a real extracted ISO tree, or the synthetic one the test suite
# builds. It needs neither a base image nor xorriso, so it is handled before
# either of those is touched.
if [ -n "$PATCH_MENU_DIR" ]; then
  patch_menus "$PATCH_MENU_DIR"
  exit 0
fi

# ---------------------------------------------------------------------------
# 1. base ISO
# ---------------------------------------------------------------------------
if [ -z "$BASE" ]; then
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || \
    die "need curl or wget to download the base image (or pass --base FILE)"
  BASE="$OS_ROOT/dist/$(basename "$URL")"
  mkdir -p "$OS_ROOT/dist"
  if [ -f "$BASE" ]; then
    say "using cached base image $BASE"
  else
    say "downloading $URL"
    if command -v curl >/dev/null 2>&1; then
      curl -fL --retry 3 -o "$BASE.part" "$URL" || die "download failed: $URL"
    else
      wget -O "$BASE.part" "$URL" || die "download failed: $URL"
    fi
    mv "$BASE.part" "$BASE"
  fi
  if [ -n "$SHA256" ]; then
    printf '%s  %s\n' "$SHA256" "$BASE" | sha256sum -c - || \
      die "base image checksum mismatch"
    say "checksum ok"
  else
    say "WARNING: no --sha256 given, base image not verified"
  fi
fi
[ -f "$BASE" ] || die "base image not found: $BASE"

# A 404 page saved as .iso is the classic way this goes wrong quietly, so
# check the ISO9660 primary volume descriptor magic where the standard puts it.
_magic=$(dd if="$BASE" bs=1 skip=32769 count=5 2>/dev/null || true)
[ "$_magic" = "CD001" ] || die "$BASE is not an ISO9660 image (got '$_magic')"
say "base image ok: $BASE"

command -v xorriso >/dev/null 2>&1 || \
  die "xorriso is required (Debian: apt install xorriso isolinux syslinux-utils)"

# ---------------------------------------------------------------------------
# 2. extract the base ISO
# ---------------------------------------------------------------------------
WORK=$(mktemp -d "${TMPDIR:-/tmp}/rns-os-iso.XXXXXX")
ISO_DIR="$WORK/iso"
mkdir -p "$ISO_DIR"
say "extracting base image"
xorriso -osirrox on -indev "$BASE" -extract / "$ISO_DIR" >/dev/null 2>&1 || \
  die "could not extract $BASE"
chmod -R u+w "$ISO_DIR"

# ---------------------------------------------------------------------------
# 3. payload + preseed into the image
# ---------------------------------------------------------------------------
say "staging RNS-OS $VERSION payload"
RNS_OS_VERSION="$VERSION" sh "$OS_ROOT/tools/install-payload.sh" \
  --dest "$ISO_DIR/rns-payload" || die "payload staging failed"

cp "$SELF_DIR/preseed.cfg" "$ISO_DIR/preseed.cfg" || die "cannot add preseed.cfg"
chmod 644 "$ISO_DIR/preseed.cfg" "$ISO_DIR/rns-payload" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 4. boot menus -> automated install
# ---------------------------------------------------------------------------
patch_menus "$ISO_DIR"

# ---------------------------------------------------------------------------
# 5. burn
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$OUT")"

ISOHYBRID=""
for _p in /usr/lib/ISOLINUX/isohdpfx.bin /usr/lib/syslinux/isohdpfx.bin \
          /usr/share/syslinux/isohdpfx.bin
do
  [ -f "$_p" ] && { ISOHYBRID=$_p; break; }
done

ELTORITO_ALT=""
[ -f "$ISO_DIR/boot/grub/efi.img" ] && ELTORITO_ALT=1

set -- -as mkisofs -r -J -joliet-long -l -cache-inodes
[ -n "$ISOHYBRID" ] && set -- "$@" -isohybrid-mbr "$ISOHYBRID"
set -- "$@" -b isolinux/isolinux.bin -c isolinux/boot.cat \
           -boot-info-table -boot-load-size 4 -no-emul-boot
if [ -n "$ELTORITO_ALT" ]; then
  set -- "$@" -eltorito-alt-boot -e boot/grub/efi.img -no-emul-boot
fi
[ -n "$ISOHYBRID" ] && set -- "$@" -isohybrid-gpt-basdat
set -- "$@" -o "$OUT" "$ISO_DIR"

if [ "$CHECK" -eq 1 ]; then
  say "--check: everything validated, ISO not written."
  say "  payload   $ISO_DIR/rns-payload"
  say "  preseed   $ISO_DIR/preseed.cfg"
  say "  command   xorriso $*"
  KEEP=1
  exit 0
fi

say "building $OUT (this takes a minute)"
xorriso "$@" 2>&1 | tail -n 5
[ -s "$OUT" ] || die "xorriso produced no output"

say "done: $OUT"
say "      $(du -h "$OUT" | awk '{print $1}')  sha256 $(sha256sum "$OUT" | awk '{print $1}')"
say ""
say "Next: create the VM with iso/vm/create-vm.sh (or .ps1 on Windows) — see"
say "iso/vm/VirtualBox.md"
