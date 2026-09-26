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
#   ./build-iso.sh --url URL            use this base image URL (repeatable)
#   ./build-iso.sh --sha256 HASH        the hash the base image must have
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

# ---------------------------------------------------------------------------
# Where the base image comes from.
#
# Debian keeps only the CURRENT stable netinst in /debian-cd/current/ and moves
# every older point release to /cdimage/archive/. RNS-OS is built on Debian 12
# (bookworm), which stopped being "current" the day Debian 13 shipped — so the
# old href pointing at .../current/amd64/iso-cd/debian-12.11.0-amd64-netinst.iso
# returns 404 today, and a 404 page saved as .iso is the classic way this build
# fails quietly. The candidates below are the archive URLs, newest first, each
# pinned to the hash Debian publishes in the SHA256SUMS beside it. If Debian
# ever drops them, pass --url with whatever bookworm netinst you have, or
# download it yourself and pass --base.
#
# Verified 2026-09-26 against
#   https://cdimage.debian.org/cdimage/archive/<ver>/amd64/iso-cd/SHA256SUMS
# ---------------------------------------------------------------------------
DEFAULT_URLS="
https://cdimage.debian.org/cdimage/archive/12.15.0/amd64/iso-cd/debian-12.15.0-amd64-netinst.iso
https://cdimage.debian.org/cdimage/archive/12.11.0/amd64/iso-cd/debian-12.11.0-amd64-netinst.iso
"

# Published hashes for the pinned candidates, so a download is verified even
# when the checksum file cannot be reached. Unlisted images fall back to
# fetching SHA256SUMS from the same directory.
known_sha256() {
  case "${1##*/}" in
    debian-12.15.0-amd64-netinst.iso) printf '%s' cd4462c06aa8892e692c0c4b9c17802f38c8ab8690e85cbfb5ccaa5956e9af17 ;;
    debian-12.11.0-amd64-netinst.iso) printf '%s' 30ca12a15cae6a1033e03ad59eb7f66a6d5a258dcf27acd115c2bd42d22640e8 ;;
    *) printf '' ;;
  esac
}

URLS=""
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
      # Two patterns rather than one (append|linux) alternation: the `|` inside
      # an alternation is read as the s/// delimiter, and sed dies with
      # "unknown option to `s'". That is not hypothetical — it is what stopped
      # the first real ISO build, on menu.cfg, the one Debian boot file with no
      # ` ---` line to match. Only the synthetic tree in the test suite was
      # small enough to miss it.
      sed -i -E "s|^([[:space:]]*append[[:space:]].*)$|\1 ${_args}|" "$_f"
      sed -i -E "s|^([[:space:]]*linux[[:space:]].*)$|\1 ${_args}|" "$_f"
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
    --url)     URLS="$URLS ${2:?}"; shift 2 ;;
    --sha256)  SHA256=${2:?}; shift 2 ;;
    --check)   CHECK=1; shift ;;
    --patch-menu) PATCH_MENU_DIR=${2:?}; shift 2 ;;
    --keep)    KEEP=1; shift ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *)         die "unknown argument: $1" ;;
  esac
done

# --url / DEBIAN_ISO_URL beat the built-in candidates; the built-in ones stay
# as fallbacks so one dead URL is not a dead build.
[ -n "${DEBIAN_ISO_URL:-}" ] && URLS="$DEBIAN_ISO_URL $URLS"
[ -n "$URLS" ] || URLS=$DEFAULT_URLS

cleanup() {
  if [ -n "$WORK" ] && [ -d "$WORK" ] && [ "$KEEP" -eq 0 ]; then
    # A half-finished run can leave a directory that cannot be traversed, and
    # then rm -rf fails and litters /tmp on every retry.
    chmod -R u+rwX "$WORK" 2>/dev/null || true
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
# helpers: download, and prove the file is a real ISO
# ---------------------------------------------------------------------------
fetch_to() { # fetch_to URL FILE -> 0 on success
  _u=$1
  _f=$2
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 2 --connect-timeout 20 -o "$_f" "$_u" >/dev/null 2>&1
  else
    wget -q -T 20 -t 2 -O "$_f" "$_u" >/dev/null 2>&1
  fi
}

is_iso() { # is_iso FILE — ISO9660 primary volume descriptor magic
  _magic=$(dd if="$1" bs=1 skip=32769 count=5 2>/dev/null || true)
  [ "$_magic" = "CD001" ]
}

sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# What this base image must hash to: an explicit --sha256, else the published
# hash for a pinned candidate, else whatever ./SHA256SUMS beside the URL says.
expected_sha() { # expected_sha URL
  if [ -n "$SHA256" ]; then
    printf '%s' "$SHA256"
    return 0
  fi
  _k=$(known_sha256 "$1")
  if [ -n "$_k" ]; then
    printf '%s' "$_k"
    return 0
  fi
  _sums=$(mktemp)
  if fetch_to "$(dirname "$1")/SHA256SUMS" "$_sums"; then
    _h=$(awk -v n="$(basename "$1")" '$2 == n {print $1; exit}' "$_sums" 2>/dev/null || true)
    rm -f "$_sums"
    [ -n "$_h" ] && { printf '%s' "$_h"; return 0; }
  fi
  rm -f "$_sums"
  printf ''
}

# ---------------------------------------------------------------------------
# 1. base ISO
# ---------------------------------------------------------------------------
if [ -z "$BASE" ]; then
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || \
    die "need curl or wget to download the base image (or pass --base FILE)"
  mkdir -p "$OS_ROOT/dist"

  # A cached copy from an earlier run wins — but only if it still hashes right,
  # because a half-finished download is exactly what a cache hides.
  for _u in $URLS; do
    _c="$OS_ROOT/dist/$(basename "$_u")"
    [ -f "$_c" ] || continue
    if is_iso "$_c"; then
      _want=$(expected_sha "$_u")
      if [ -z "$_want" ] || [ "$(sha_of "$_c")" = "$_want" ]; then
        BASE=$_c
        say "using cached base image $BASE"
        break
      fi
      say "cached $(basename "$_c") does not verify — downloading again"
      rm -f "$_c"
    else
      say "cached $(basename "$_c") is not an ISO — downloading again"
      rm -f "$_c"
    fi
  done

  if [ -z "$BASE" ]; then
    for _u in $URLS; do
      _dest="$OS_ROOT/dist/$(basename "$_u")"
      say "downloading $_u"
      if ! fetch_to "$_u" "$_dest.part"; then
        say "  not available — trying the next candidate"
        rm -f "$_dest.part"
        continue
      fi
      if ! is_iso "$_dest.part"; then
        say "  that is not an ISO9660 image (404 page or proxy) — next candidate"
        rm -f "$_dest.part"
        continue
      fi
      _want=$(expected_sha "$_u")
      if [ -n "$_want" ]; then
        _got=$(sha_of "$_dest.part")
        if [ "$_got" != "$_want" ]; then
          say "  sha256 mismatch — expected $_want, got $_got"
          say "  (delete the file and retry, or pass --sha256 with the hash you trust)"
          rm -f "$_dest.part"
          continue
        fi
        say "  sha256 ok: $_want"
      else
        say "  WARNING: no published hash for $(basename "$_dest") — not verified"
      fi
      mv "$_dest.part" "$_dest"
      BASE=$_dest
      break
    done
  fi
  [ -n "$BASE" ] || die "no base image could be downloaded. Download a Debian 12 amd64 netinst ISO yourself and pass --base FILE, or give a working URL with --url URL"
fi

[ -f "$BASE" ] || die "base image not found: $BASE"

# A 404 page saved as .iso is the classic way this goes wrong quietly, so
# check the ISO9660 primary volume descriptor magic where the standard puts it.
is_iso "$BASE" || die "$BASE is not an ISO9660 image"
say "base image ok: $BASE ($(basename "$BASE"), $(du -h "$BASE" | awk '{print $1}'))"

# Verify a --base file too when a hash is known: the whole point of the check
# is to catch a truncated copy before an hour of installing on a bad image.
if [ -n "$SHA256" ] || [ -n "$(known_sha256 "$BASE")" ]; then
  _want=${SHA256:-$(known_sha256 "$BASE")}
  _got=$(sha_of "$BASE")
  [ "$_got" = "$_want" ] || die "base image checksum mismatch: expected $_want, got $_got"
  say "checksum ok"
fi

# ---------------------------------------------------------------------------
# 2. extract the base ISO
#
# xorriso is needed from here on. Checked after the base image, so a wrong or
# unverified download reports itself instead of hiding behind a missing tool.
# ---------------------------------------------------------------------------
command -v xorriso >/dev/null 2>&1 || \
  die "xorriso is required to burn the ISO (Debian/Ubuntu: sudo apt install xorriso isolinux syslinux-utils)"

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
# 644 on a DIRECTORY clears its execute bit, after which nothing can traverse
# it: xorriso cannot read the payload and the work dir cannot be removed. The
# payload directory stays 755; only the file is 644.
chmod 644 "$ISO_DIR/preseed.cfg" 2>/dev/null || true
chmod 755 "$ISO_DIR/rns-payload" 2>/dev/null || true

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
is_iso "$OUT" || die "the built file is not a bootable ISO9660 image"

say "done: $OUT"
say "      $(du -h "$OUT" | awk '{print $1}')  sha256 $(sha_of "$OUT")"
say ""
say "Next: create the VM with iso/vm/create-vm.sh (or .ps1 on Windows) — see"
say "iso/vm/VirtualBox.md"
