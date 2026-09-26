#!/bin/sh
# os-selftest.sh — test the RNS-OS appliance that actually ships.
#
# This is not a mock of the appliance. It runs tools/install-payload.sh (the
# same code path build-iso.sh uses), so the tree under test is byte-for-byte
# the tree that goes into the ISO, and then it:
#
#   A. checks the image is structurally sound (units, executables, shims)
#   B. proves the engine inside it is identical to the Magisk module's
#   C. runs the platform controller: render, firstboot, net-up, prestart
#   D. boots the page listener from the staged image and drives the captive
#      portal, the staff panel and the WHOLE v7 payment gateway over HTTP
#
# Section D exists because the Magisk suite has no payment coverage at all:
# v7 added nine API endpoints, TID validation, auto-verify and a PDF receipt,
# and none of it was tested. RNS-OS ships that same code, so it tests it here.
#
# Nothing here needs root, a VM, or a network.

set -u

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OS_ROOT=$(CDPATH= cd -- "$SELF_DIR/.." && pwd)
REPO_ROOT=$(CDPATH= cd -- "$OS_ROOT/.." && pwd)
ENGINE_SRC=${RNS_ENGINE_SRC:-$REPO_ROOT/RNS-Gateway/module/rns}

export BB=${BB:-/usr/bin/busybox}
command -v "$BB" >/dev/null 2>&1 || BB=$(command -v busybox || true)
[ -n "$BB" ] || { echo "os-selftest: busybox is required"; exit 1; }
export BB RNS_BB=$BB

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/rns-os-stage.XXXXXX")
DATA="$STAGE/var/lib/rns"
fails=0
ran=0

ok()   { ran=$((ran + 1)); printf 'OK   %s\n' "$*"; }
bad()  { ran=$((ran + 1)); fails=$((fails + 1)); printf 'FAIL %s\n' "$*"; }
note() { printf '     %s\n' "$*"; }
chk()  { if eval "$2"; then ok "$1"; else bad "$1"; fi }

cleanup() {
  if [ -n "${HPID:-}" ]; then kill "$HPID" 2>/dev/null || true; fi
  if [ -f "$STAGE/var/lib/rns/httpd.pid" ]; then
    kill "$(cat "$STAGE/var/lib/rns/httpd.pid" 2>/dev/null)" 2>/dev/null || true
  fi
  [ -n "${KEEP:-}" ] || rm -rf "$STAGE"
  [ -n "${KEEP:-}" ] || rm -rf "${FAKESYS:-}" "${FAKEBIN:-}"
}
trap cleanup EXIT

# NOTE: takes the document as $2, not on stdin. Piping into it would put this
# function in a subshell, and the ok/bad counters incremented there would be
# lost — the suite would print more OK lines than it actually counted.
json_ok() {
  _doc=$2
  if command -v python3 >/dev/null 2>&1; then
    _err=$(printf '%s' "$_doc" | python3 -c 'import json,sys
try:
    json.load(sys.stdin)
except Exception as e:
    print(e)' 2>&1)
    [ -z "$_err" ] && ok "$1" || bad "$1 invalid JSON: $_err :: $(printf '%s' "$_doc" | head -c 200)"
  else
    case "$_doc" in
      \{*\}|*\[*\]) ok "$1 (unverified: no python3)" ;;
      *) bad "$1 malformed: $(printf '%s' "$_doc" | head -c 160)" ;;
    esac
  fi
}

printf '\n=== RNS-OS selftest ===\n'
printf 'engine source  %s\n' "$ENGINE_SRC"
printf 'staging to     %s\n\n' "$STAGE"

# ---------------------------------------------------------------------------
# Stage the appliance exactly as build-iso.sh does.
# ---------------------------------------------------------------------------
if RNS_OS_VERSION="$(cat "$OS_ROOT/VERSION")" \
   RNS_ENGINE_SRC="$ENGINE_SRC" \
   sh "$OS_ROOT/tools/install-payload.sh" --dest "$STAGE" >/dev/null 2>"$STAGE.install.err"; then
  ok "payload staged by the same code path the ISO uses"
else
  bad "payload staging failed: $(cat "$STAGE.install.err")"
  exit 1
fi

HOME_LIB="$STAGE/usr/local/lib/rns"
CTL="$STAGE/usr/local/sbin/rns-os-ctl"

# ===========================================================================
printf '\n--- A. image structure ---\n'
# ===========================================================================

for f in \
  etc/rns/env etc/rns/defaults.env \
  etc/rns/hostapd.conf.tmpl etc/rns/dnsmasq.conf.tmpl \
  etc/systemd/system/rns-net.service \
  etc/systemd/system/rns-dhcp.service \
  etc/systemd/system/rns-ap.service \
  etc/systemd/system/rns-gateway.service \
  etc/systemd/system/rns-firstboot.service \
  etc/profile.d/rns-os.sh etc/network/interfaces.d/rns-guest \
  usr/local/bin/rns usr/local/sbin/rns-os-ctl \
  usr/share/rns-os/VERSION
do
  chk "$f present" "[ -e '$STAGE/$f' ]"
done

# systemd EnvironmentFile is not a shell script: KEY=VALUE only, no `export`,
# no command substitution. A line it cannot parse makes the unit fail to load.
_envbad=$(grep -vE '^[A-Za-z_][A-Za-z0-9_]*=' "$STAGE/etc/rns/env" | grep -vE '^\s*#' | grep -vE '^\s*$' || true)
if [ -z "$_envbad" ]; then
  ok "etc/rns/env is valid systemd EnvironmentFile syntax"
else
  bad "etc/rns/env has non KEY=VALUE lines: $_envbad"
fi

for s in "$CTL" "$STAGE/usr/local/bin/rns" "$HOME_LIB"/bin/*.sh; do
  if sh -n "$s" 2>/dev/null; then
    ok "syntax: ${s##*/}"
  else
    bad "syntax: ${s##*/}"
    sh -n "$s"
  fi
done

chk "rns-os-ctl is executable" "[ -x '$CTL' ]"
chk "rns cli is executable" "[ -x '$STAGE/usr/local/bin/rns' ]"
chk "listener is executable" "[ -x '$HOME_LIB/bin/rns-httpd-x86_64' ]"
chk "listener --check passes" "'$HOME_LIB/bin/rns-httpd-x86_64' --check >/dev/null 2>&1"

# The engine calls "$BB" <applet> for all of its text processing, and Debian's
# busybox does not ship every applet it uses (flock, which holds the store lock
# around every voucher mint, redeem, payment confirm, backup and export). The
# image therefore hands the engine a shim, not bare busybox.
chk "the busybox shim is in the image" "[ -x '$HOME_LIB/bin/rns-bb' ]"
chk "syntax: rns-bb" "sh -n '$HOME_LIB/bin/rns-bb'"
chk "the appliance hands the engine the shim, not bare busybox" \
    "grep -qx 'BB=/usr/local/lib/rns/bin/rns-bb' '$STAGE/etc/rns/env'"


# The Android-path shim: the shared engine still reads /data/adb/rns/page.env
# and mirrors its log to /data/local/tmp. Without these two links the page
# shell cannot tell the shop's own machine from a customer on Linux.
chk "shim /data/adb/rns -> /var/lib/rns" \
    "[ \"\$(readlink '$STAGE/data/adb/rns')\" = '/var/lib/rns' ]"
chk "shim /data/local/tmp -> /var/log/rns" \
    "[ \"\$(readlink '$STAGE/data/local/tmp')\" = '/var/log/rns' ]"

# Every unit must reference only programs that exist in the image or come from
# the base system. install-payload checks this; assert it independently here
# because a typo in a unit is a VM that boots into a dead shop.
_missing=""
for u in "$STAGE"/etc/systemd/system/*.service; do
  for p in $(grep -hE '^Exec(Start|Stop|StartPre|Reload)=' "$u" \
             | sed -E 's/^Exec[A-Za-z]+=//; s/^[-+!@:]+//' | awk '{print $1}'); do
    case "$p" in
      /bin/*|/usr/bin/*|/sbin/*|/usr/sbin/*) continue ;;
    esac
    [ -e "$STAGE$p" ] || _missing="$_missing ${u##*/}:$p"
  done
done
if [ -z "$_missing" ]; then
  ok "every unit ExecStart path exists in the image"
else
  bad "units reference missing programs:$_missing"
fi

# Ordering: the supervisor must come after the network, and the pages must be
# started by the supervisor rather than by a unit that waits on the network.
chk "rns-gateway ordered after rns-net" \
    "grep -q 'After=rns-net.service' '$STAGE/etc/systemd/system/rns-gateway.service'"
chk "rns-dhcp requires rns-net" \
    "grep -q 'Requires=rns-net.service' '$STAGE/etc/systemd/system/rns-dhcp.service'"
chk "gateway runs the supervisor, not a copy of it" \
    "grep -q 'bin/rnsd.sh' '$STAGE/etc/systemd/system/rns-gateway.service'"
chk "firstboot is gated on a marker so it runs once" \
    "grep -q 'ConditionPathExists=!/var/lib/rns/.firstboot-done' '$STAGE/etc/systemd/system/rns-firstboot.service'"

# ===========================================================================
printf '\n--- B. engine parity with the Magisk module ---\n'
# ===========================================================================

if [ -d "$ENGINE_SRC" ]; then
  _diff=""
  for f in common.sh store.sh net.sh rns-http.sh rns-front.sh rns-pages.sh \
           rnsd.sh rns-worker.sh rns-gate-min.sh rns-heal.sh rns-bound.sh \
           rns-apwatch.sh rns-ctl.sh; do
    if ! cmp -s "$ENGINE_SRC/bin/$f" "$HOME_LIB/bin/$f"; then
      _diff="$_diff $f"
    fi
  done
  for f in admin.html portal.html; do
    cmp -s "$ENGINE_SRC/www/$f" "$HOME_LIB/www/$f" || _diff="$_diff www/$f"
  done
  if [ -z "$_diff" ]; then
    ok "engine is byte-identical to the Magisk module (no fork, no drift)"
  else
    bad "engine differs from the Magisk module:$_diff"
  fi
else
  note "engine source not present — parity check skipped"
fi

# The engine calls "$BB" <applet> everywhere. If busybox on the appliance is
# built without one of them, that call fails at runtime in a way no syntax
# check can see.
# inotifyd is not in Debian's busybox, and it must not be: rns-apwatch.sh
# probes for it at runtime and falls back to a polling loop when it is absent.
# Assert that guard exists rather than letting a missing applet pass silently.
chk "apwatch guards the inotifyd applet it may not have" \
    "grep -q 'grep -qx inotifyd' '$HOME_LIB/bin/rns-apwatch.sh'"
_applets=$(grep -ohE '"\$BB" [a-z0-9_]+' "$HOME_LIB"/bin/*.sh "$CTL" 2>/dev/null \
           | awk '{print $2}' | sort -u | grep -vx inotifyd)
_blist=$("$BB" --list 2>/dev/null | tr '\n' ' ')
_nobusy=""
_shimmed=""
for a in $_applets; do
  case " $_blist " in
    *" $a "*) continue ;;
  esac
  # Not in this build of busybox. The platform shim has to cover it, and the
  # tool it maps to has to exist — a mapping to a tool that is not installed is
  # the same silent failure with an extra step.
  if grep -q "^  $a)" "$HOME_LIB/bin/rns-bb" 2>/dev/null && command -v "$a" >/dev/null 2>&1; then
    _shimmed="$_shimmed $a"
    continue
  fi
  _nobusy="$_nobusy $a"
done
if [ -z "$_nobusy" ]; then
  ok "busybox (or the rns-bb shim) provides every applet the engine calls ($(printf '%s\n' $_applets | wc -l | tr -d ' ') applets)"
  [ -n "$_shimmed" ] && note "the shim covers:$_shimmed"
else
  bad "no busybox applet and no shim mapping for:$_nobusy"
fi

# The shim exists to make the store lock work, so prove the lock works through
# it: lock a file descriptor, and unlock it.
_shim="$HOME_LIB/bin/rns-bb"
_lockout=$(sh -c '
  exec 9>"$1" || exit 1
  "$2" flock -x 9 || exit 2
  echo locked
  "$2" flock -u 9 || exit 3
' _ "$STAGE/store.lock.probe" "$_shim" 2>&1)
if [ "$_lockout" = "locked" ]; then
  ok "the shim's flock locks and unlocks (the store lock the engine takes)"
else
  bad "the shim's flock does not work: $_lockout"
fi
if [ "$(printf 'a=1\n' | "$_shim" sed -n 's/^a=//p')" = "1" ]; then
  ok "the shim still passes ordinary applets to busybox"
else
  bad "the shim does not pass ordinary applets to busybox"
fi
rm -f "$STAGE/store.lock.probe"

# ===========================================================================
printf '\n--- C. platform controller ---\n'
# ===========================================================================

# guest_if_detect reads /sys/class/net, which a test cannot change. The
# controller takes that prefix from RNS_SYS_NET, so the suite points it at
# synthetic trees: one with nothing but loopback (a box with no spare NIC), one
# that looks like a VirtualBox VM (enp0s3 uplink + enp0s8 customer side).
# Between them the detection is tested on any machine, whatever real NICs this
# build host happens to have.
FAKESYS=$(mktemp -d "${TMPDIR:-/tmp}/rns-os-sys.XXXXXX")
FAKESYS_NET="$FAKESYS/lo-only"
FAKESYS_VM="$FAKESYS/vbox"
mkdir -p "$FAKESYS_NET/lo" "$FAKESYS_VM/lo" "$FAKESYS_VM/enp0s3" "$FAKESYS_VM/enp0s8"

# A fake `ip` so "which interface owns the default route" is known: enp0s3, the
# uplink, which the detection must never hand to a customer.
FAKEBIN=$(mktemp -d "${TMPDIR:-/tmp}/rns-os-bin.XXXXXX")
cat > "$FAKEBIN/ip" <<'FAKEIP'
#!/bin/sh
case "$*" in
  "route show default") printf 'default via 10.0.2.2 dev enp0s3\n' ;;
esac
exit 0
FAKEIP
chmod 755 "$FAKEBIN/ip"

run_ctl() {
  PATH="${RNS_PATH_PREFIX:+$RNS_PATH_PREFIX:}$PATH" \
  RNS_OS_ROOT="$STAGE" RNS_HOME="$HOME_LIB" RNS_DATA="$DATA" \
  RNS_LAB="${RNS_LAB_OVERRIDE:-0}" BB="$BB" RNS_BB="$BB" \
  RNS_SYS_NET="${RNS_SYS_NET_OVERRIDE:-$FAKESYS_NET}" \
  sh "$CTL" "$@"
}

run_ctl help | grep -q 'rns-os-ctl' && ok "rns-os-ctl help" || bad "rns-os-ctl help"

# render, with a config the engine itself would have written
mkdir -p "$DATA"
cat > "$DATA/config.env" << 'EOF'
SSID=RNS-Test
CHANNEL=11
HW_MODE=g
MAX_STA=64
LAN_IF=wlan0
WAN_IF=auto
PORTAL_PORT=8080
SHOP=Test Shop
GUEST_IF=wlan0
GUEST_IP=10.9.8.1
GUEST_MASK=255.255.255.0
DHCP_START=10.9.8.50
DHCP_END=10.9.8.99
DHCP_LEASE=6h
RNS_MODE=wifi
EOF

if run_ctl render >/dev/null 2>&1; then
  ok "render"
else
  bad "render"
  run_ctl render
fi
chk "hostapd.conf ssid"   "grep -qx 'ssid=RNS-Test' '$STAGE/etc/rns/hostapd.conf'"
chk "hostapd.conf channel" "grep -qx 'channel=11' '$STAGE/etc/rns/hostapd.conf'"
chk "hostapd.conf interface" "grep -qx 'interface=wlan0' '$STAGE/etc/rns/hostapd.conf'"
chk "dnsmasq dhcp-range"  "grep -q '^dhcp-range=10.9.8.50,10.9.8.99,255.255.255.0,6h' '$STAGE/etc/rns/dnsmasq.conf'"
chk "dnsmasq gateway option" "grep -q '^dhcp-option=3,10.9.8.1' '$STAGE/etc/rns/dnsmasq.conf'"
chk "no unsubstituted placeholders in hostapd.conf" \
    "! grep -q '\${' '$STAGE/etc/rns/hostapd.conf'"
chk "no unsubstituted placeholders in dnsmasq.conf" \
    "! grep -q '\${' '$STAGE/etc/rns/dnsmasq.conf'"

# Re-render must be idempotent: the earlier version of render consumed the
# template's placeholders on the first pass, after which every later render
# silently produced nothing.
_before=$(cat "$STAGE/etc/rns/hostapd.conf")
run_ctl render >/dev/null 2>&1
_after=$(cat "$STAGE/etc/rns/hostapd.conf")
if [ "$_before" = "$_after" ]; then
  ok "render is idempotent"
else
  bad "render changed the output on a second pass"
fi

# A missing interface must be a warning and a success, not a failed boot unit.
if RNS_OS_ROOT="$STAGE" RNS_HOME="$HOME_LIB" RNS_DATA="$DATA" RNS_LAB=0 BB="$BB" \
   RNS_SYS_NET="$FAKESYS_NET" sh "$CTL" net-up >/dev/null 2>&1; then
  ok "net-up survives a missing guest interface"
else
  bad "net-up failed on a missing guest interface (would fail the unit at boot)"
fi
run_ctl config RNS_MODE=off >/dev/null 2>&1
chk "config writes through to config.env" \
    "grep -qx 'RNS_MODE=off' '$DATA/config.env'"
run_ctl config RNS_MODE=wifi >/dev/null 2>&1

# ap-start with no radio must exit 0 so the rest of the appliance still runs.
if RNS_OS_ROOT="$STAGE" RNS_HOME="$HOME_LIB" RNS_DATA="$DATA" RNS_LAB=0 BB="$BB" \
   RNS_SYS_NET="$FAKESYS_NET" sh "$CTL" ap-start >/dev/null 2>&1; then
  ok "ap-start exits cleanly when there is no radio/hostapd"
else
  bad "ap-start failed with no radio (would fail the unit at boot)"
fi

# A stale supervisor pid from an unclean shutdown must not wedge the restart.
printf '999999\n' > "$DATA/rnsd.pid"
run_ctl gateway-prestart >/dev/null 2>&1
chk "gateway-prestart clears a stale rnsd.pid" "[ ! -f '$DATA/rnsd.pid' ]"

# firstboot: the engine creates its own store, the OS overlays its keys.
rm -f "$DATA/.firstboot-done"
if run_ctl firstboot >"$STAGE.firstboot.log" 2>&1; then
  ok "firstboot"
else
  bad "firstboot: $(tail -n 3 "$STAGE.firstboot.log")"
fi
chk "firstboot wrote its marker"      "[ -f '$DATA/.firstboot-done' ]"
chk "firstboot created the store"     "[ -f '$DATA/database/vouchers.tsv' ]"
chk "firstboot created admin.auth"    "[ -f '$DATA/database/admin.auth' ]"
chk "firstboot wrote the password file" "[ -s '$STAGE/etc/rns/admin-password.txt' ]"
_pw=$(sed -n 's/^password: //p' "$STAGE/etc/rns/admin-password.txt" 2>/dev/null)
chk "generated password is usable length" "[ \${#_pw} -ge 6 ]"
chk "firstboot pointed LAN_IF at the guest interface" \
    "grep -qx 'LAN_IF=wlan0' '$DATA/config.env'"
chk "firstboot kept the operator's SSID" "grep -qx 'SSID=RNS-Test' '$DATA/config.env'"
chk "firstboot created no preset packages" "[ ! -s '$DATA/database/packages.tsv' ]"
chk "firstboot rendered the network configs" "[ -s '$STAGE/etc/rns/hostapd.conf' ]"

# The engine calls "$BB" <applet> for every piece of text processing it does.
# If /etc/rns/env names a busybox that is not there, those calls fail in a way
# that looks like the gateway being broken rather than a missing tool. First
# boot must find a busybox that runs and record it.
BBSTAGE=$(mktemp -d "${TMPDIR:-/tmp}/rns-os-bb.XXXXXX")
RNS_OS_VERSION=test RNS_ENGINE_SRC="$ENGINE_SRC" \
  sh "$OS_ROOT/tools/install-payload.sh" --dest "$BBSTAGE" >/dev/null 2>&1
if RNS_OS_ROOT="$BBSTAGE" RNS_HOME="$BBSTAGE/usr/local/lib/rns" \
   RNS_DATA="$BBSTAGE/var/lib/rns" RNS_LAB=0 \
   BB=/nonexistent/busybox RNS_BB=/nonexistent/busybox \
   sh "$BBSTAGE/usr/local/sbin/rns-os-ctl" firstboot >/dev/null 2>&1; then
  ok "firstboot recovers from a wrong busybox path"
else
  bad "firstboot failed when /etc/rns/env named a missing busybox"
fi
_newbb=$(sed -n 's/^BB=//p' "$BBSTAGE/etc/rns/env")
if [ -n "$_newbb" ] && "$_newbb" --list >/dev/null 2>&1; then
  ok "firstboot recorded a busybox that actually runs ($_newbb)"
else
  bad "firstboot left an unusable busybox in etc/rns/env: '$_newbb'"
fi
chk "store still built after busybox recovery" \
    "[ -s '$BBSTAGE/var/lib/rns/database/admin.auth' ]"
rm -rf "$BBSTAGE"

# ===========================================================================
printf '\n--- C2. installer boot menus and legacy payment repair ---\n'
# ===========================================================================

# The ISO step that decides whether the VM installs RNS-OS or plain Debian.
# Runs the real build-iso.sh code against a synthetic Debian boot tree, with
# both boot formats Debian 12 ships (isolinux for BIOS, grub for UEFI).
FAKE=$(mktemp -d "${TMPDIR:-/tmp}/rns-os-fakeiso.XXXXXX")
mkdir -p "$FAKE/isolinux" "$FAKE/boot/grub"
printf 'default install\nlabel install\n\tmenu label ^Install\n\tlinux /install.amd/vmlinuz\n\tappend vmlinuz initrd=initrd.gz --- quiet\n' > "$FAKE/isolinux/txt.cfg"
printf 'include txt.cfg\nprompt 0\n' > "$FAKE/isolinux/isolinux.cfg"
printf "menuentry 'Graphical install' {\n\tlinux /install.amd/vmlinuz video=vesa ywrap --- quiet\n\tinitrd /install.amd/gtk/initrd.gz\n}\n" > "$FAKE/boot/grub/grub.cfg"
# Debian also ships isolinux/menu.cfg, which has no ` ---` line at all: it takes
# the other branch of patch_menus. That branch used a (append|linux)
# alternation inside an s||| command, so sed read the `|` as its delimiter and
# died with "unknown option to `s'". The first real ISO build died here, on
# menu.cfg, and this synthetic tree was too small to notice.
printf 'menu label ^Help\n\tappend vga=788\nmenu label ^Install\n\tlinux /install.amd/vmlinuz\n' > "$FAKE/isolinux/menu.cfg"

if sh "$OS_ROOT/iso/build-iso.sh" --patch-menu "$FAKE" >/dev/null 2>&1; then
  ok "build-iso.sh --patch-menu"
else
  bad "build-iso.sh --patch-menu failed"
fi
# An argument after `---` goes to the installed system, not to
# debian-installer, and the preseed would be silently ignored.
chk "isolinux entry passes the preseed BEFORE the --- separator" \
    "grep -q 'preseed/file=/cdrom/preseed.cfg ---' '$FAKE/isolinux/txt.cfg'"
chk "grub entry passes the preseed BEFORE the --- separator" \
    "grep -q 'preseed/file=/cdrom/preseed.cfg ---' '$FAKE/boot/grub/grub.cfg'"
chk "install runs unattended" "grep -q 'auto=true' '$FAKE/isolinux/txt.cfg'"
chk "boot menu does not hang waiting for a keypress" \
    "grep -q '^timeout' '$FAKE/isolinux/isolinux.cfg'"
chk "grub entry keeps its initrd line" "grep -q 'initrd /install.amd/gtk/initrd.gz' '$FAKE/boot/grub/grub.cfg'"
# The branch for boot files with no ` ---` line: it must add the preseed
# arguments, not kill the build.
chk "a boot file with no --- line still gets the preseed (append line)" \
    "grep -q 'append vga=788 auto=true' '$FAKE/isolinux/menu.cfg'"
chk "a boot file with no --- line still gets the preseed (linux line)" \
    "grep -q 'linux /install.amd/vmlinuz auto=true' '$FAKE/isolinux/menu.cfg'"
# 644 on a directory clears its execute bit, and then xorriso cannot read the
# payload and the work dir cannot be cleaned up.
chk "the ISO builder does not chmod the payload directory to 644" \
    "! grep -q 'chmod 644 \"\$ISO_DIR/preseed.cfg\" \"\$ISO_DIR/rns-payload\"' '$OS_ROOT/iso/build-iso.sh'"
chk "the ISO builder keeps the payload directory traversable" \
    "grep -q 'chmod 755 \"\$ISO_DIR/rns-payload\"' '$OS_ROOT/iso/build-iso.sh'"
rm -rf "$FAKE"

# Rows written by the v7 build had 17 columns, which is why no payment could
# be confirmed. The repair has to turn them back into 16 with the duration in
# slot 13, and keep a rollback backup.
LEG=$(mktemp -d "${TMPDIR:-/tmp}/rns-os-legacy.XXXXXX")
mkdir -p "$LEG/database"
printf 'PAY-AAAA1111|net1h|Net 1 Hour|150|jazzcash|2456789012|pending|02:00:00:00:00:01|10.0.0.5|1790000000||||3600||2048|1024\n' \
  > "$LEG/database/payments.tsv"
RNS_HOME="$HOME_LIB" RNS_DATA="$LEG" RNS_LAB=1 BB="$BB" RNS_BB="$BB" \
  sh -c '. "$1/bin/common.sh"; . "$1/bin/store.sh"; store_init' _ "$HOME_LIB" >/dev/null 2>&1
_nf=$(awk -F'|' 'NR==1{print NF}' "$LEG/database/payments.tsv")
chk "legacy 17-column payment row repaired to 16" "[ \"$_nf\" = '16' ]"
_s=$(awk -F'|' 'NR==1{print $13}' "$LEG/database/payments.tsv")
chk "repaired row has its duration in slot 13" "[ \"$_s\" = '3600' ]"
_d=$(awk -F'|' 'NR==1{print $15}' "$LEG/database/payments.tsv")
chk "repaired row keeps its download speed" "[ \"$_d\" = '2048' ]"
chk "repair keeps a rollback backup" "[ -f '$LEG/database/payments.tsv.pre-16col.bak' ]"
# A row whose duration was overwritten by a note (the old layout wrote the
# note into the same slot) must survive with the note and no invented
# duration. 17 columns, exactly as the v7 build wrote them.
printf 'PAY-BBBB2222|net1h|Net 1 Hour|150|easypaisa|8800112233|rejected|02:00:00:00:00:01|10.0.0.6|1790000000|1790000100|||not in statement||2048|1024\n' \
  > "$LEG/database/payments.tsv"
rm -f "$LEG/database/.pay16"
RNS_HOME="$HOME_LIB" RNS_DATA="$LEG" RNS_LAB=1 BB="$BB" RNS_BB="$BB" \
  sh -c '. "$1/bin/common.sh"; . "$1/bin/store.sh"; store_init' _ "$HOME_LIB" >/dev/null 2>&1
chk "note-clobbered legacy row is still 16 columns" \
    "[ \"\$(awk -F'|' 'NR==1{print NF}' '$LEG/database/payments.tsv')\" = '16' ]"
chk "note-clobbered legacy row keeps its note" \
    "awk -F'|' 'NR==1{exit !(\$14==\"not in statement\")}' '$LEG/database/payments.tsv'"
rm -rf "$LEG"

# ===========================================================================
printf '\n--- C3. customer interface and mode ---\n'
# ===========================================================================

# A configured customer interface that exists is left alone.
run_ctl config GUEST_IF=enp0s8 >/dev/null 2>&1
rm -f "$DATA/.firstboot-done"
if RNS_PATH_PREFIX="$FAKEBIN" RNS_SYS_NET_OVERRIDE="$FAKESYS_VM" \
   run_ctl firstboot >/dev/null 2>&1; then
  ok "firstboot runs against a VM-like interface tree"
else
  bad "firstboot failed with a VM-like interface tree"
fi
chk "firstboot keeps the customer interface when it exists" \
    "grep -qx 'GUEST_IF=enp0s8' '$DATA/config.env'"
chk "firstboot points the engine's LAN_IF at it as well" \
    "grep -qx 'LAN_IF=enp0s8' '$DATA/config.env'"

# A VM whose NICs came out with other names, or whose customer adapter is not
# up yet, must not come up with a customer interface that does not exist: the
# portal would be up and no customer could ever get a lease.
run_ctl config GUEST_IF=wlan0 >/dev/null 2>&1
rm -f "$DATA/.firstboot-done"
RNS_PATH_PREFIX="$FAKEBIN" RNS_SYS_NET_OVERRIDE="$FAKESYS_VM" \
  run_ctl firstboot >"$STAGE.firstboot2.log" 2>&1 || true
chk "firstboot finds the spare wired adapter when GUEST_IF is missing" \
    "grep -qx 'GUEST_IF=enp0s8' '$DATA/config.env'"
chk "the detected interface also becomes the engine's LAN_IF" \
    "grep -qx 'LAN_IF=enp0s8' '$DATA/config.env'"
chk "firstboot says which interface it chose" \
    "grep -q 'is not on this box — using enp0s8' '$STAGE.firstboot2.log'"

# The uplink owns the default route and must never be taken for a customer
# port: with only the uplink in the tree, nothing is invented.
run_ctl config GUEST_IF=wlan0 >/dev/null 2>&1
rm -f "$DATA/.firstboot-done"
RNS_PATH_PREFIX="$FAKEBIN" RNS_SYS_NET_OVERRIDE="$FAKESYS_NET" \
  run_ctl firstboot >/dev/null 2>&1 || true
chk "firstboot invents nothing when there is no spare adapter" \
    "grep -qx 'GUEST_IF=wlan0' '$DATA/config.env'"

# `rns os mode` — one command instead of editing two keys and restarting four
# units at a shop counter.
RNS_PATH_PREFIX="$FAKEBIN" RNS_SYS_NET_OVERRIDE="$FAKESYS_VM" run_ctl mode wired >/dev/null 2>&1
chk "rns os mode wired records the mode" "grep -qx 'RNS_MODE=wired' '$DATA/config.env'"
chk "rns os mode wired picks the customer adapter" \
    "grep -qx 'GUEST_IF=enp0s8' '$DATA/config.env'"
if RNS_PATH_PREFIX="$FAKEBIN" RNS_SYS_NET_OVERRIDE="$FAKESYS_VM" run_ctl mode off >/dev/null 2>&1 &&
   grep -qx 'RNS_MODE=off' "$DATA/config.env"; then
  ok "rns os mode off leaves the customer side unaddressed"
else
  bad "rns os mode off"
fi
if RNS_PATH_PREFIX="$FAKEBIN" RNS_SYS_NET_OVERRIDE="$FAKESYS_VM" run_ctl mode nonsense >/dev/null 2>&1; then
  bad "rns os mode accepted a mode that does not exist"
else
  ok "rns os mode rejects an unknown mode"
fi
if RNS_PATH_PREFIX="$FAKEBIN" RNS_SYS_NET_OVERRIDE="$FAKESYS_VM" run_ctl mode wifi >/dev/null 2>&1 &&
   grep -qx 'RNS_MODE=wifi' "$DATA/config.env"; then
  ok "rns os mode wifi works with no radio attached (it starts when one appears)"
else
  bad "rns os mode wifi"
fi
run_ctl mode wired >/dev/null 2>&1

# ===========================================================================
printf '\n--- C4. installer defaults, VM packaging, CI ---\n'
# ===========================================================================

# The shipped defaults must describe a VM that works with no extra hardware.
# A default of `wifi` with no passed-through dongle leaves the customer side
# dead on first boot, which looks exactly like a broken install.
chk "the shipped default mode needs no extra hardware" \
    "grep -qx 'RNS_MODE=wired' '$STAGE/etc/rns/defaults.env' || grep -qx 'RNS_MODE=off' '$STAGE/etc/rns/defaults.env'"
chk "the shipped customer interface is the VM's second NIC (enp0s8)" \
    "grep -qx 'GUEST_IF=enp0s8' '$STAGE/etc/rns/defaults.env'"
# The engine writes ADMIN_LAN=0 into its own config template, so the defaults
# copy cannot change it: firstboot has to apply this build's value explicitly,
# or the staff panel is unreachable from the PC the operator is actually on.
chk "firstboot applies the RNS-OS ADMIN_LAN default over the engine's" \
    "grep -q 'dflt ADMIN_LAN' '$CTL'"
chk "the panel is reachable from the operator's machine by default" \
    "grep -qx 'ADMIN_LAN=1' '$STAGE/etc/rns/defaults.env'"

# The base image URL used to be one hard-coded /debian-cd/current/ path, which
# stopped serving Debian 12 the day Debian 13 was released. A single dead URL
# is a build that cannot be reproduced by anybody.
chk "build-iso.sh has the current-stable trap removed" \
    "! grep -q 'debian-cd/current/amd64/iso-cd/debian-12' '$OS_ROOT/iso/build-iso.sh'"
chk "build-iso.sh knows the 12.15.0 archive image" \
    "grep -q 'archive/12.15.0/amd64/iso-cd/debian-12.15.0-amd64-netinst.iso' '$OS_ROOT/iso/build-iso.sh'"
chk "build-iso.sh knows the 12.11.0 archive image" \
    "grep -q 'archive/12.11.0/amd64/iso-cd/debian-12.11.0-amd64-netinst.iso' '$OS_ROOT/iso/build-iso.sh'"
chk "the candidates carry Debian's published sha256" \
    "grep -q 'cd4462c06aa8892e692c0c4b9c17802f38c8ab8690e85cbfb5ccaa5956e9af17' '$OS_ROOT/iso/build-iso.sh' && grep -q '30ca12a15cae6a1033e03ad59eb7f66a6d5a258dcf27acd115c2bd42d22640e8' '$OS_ROOT/iso/build-iso.sh'"
chk "build-iso.sh syntax" "sh -n '$OS_ROOT/iso/build-iso.sh'"

# The base-image checks themselves, driven with real files (no network, no
# xorriso needed: both fire before any of that).
NOTISO=$(mktemp "${TMPDIR:-/tmp}/rns-os-notiso.XXXXXX")
printf '<html>404 Not Found</html>\n' > "$NOTISO"
_out=$(sh "$OS_ROOT/iso/build-iso.sh" --base "$NOTISO" --out "$NOTISO.iso" 2>&1 || true)
if printf '%s' "$_out" | grep -q 'not an ISO9660 image'; then
  ok "build-iso.sh refuses a 404 page saved as .iso"
else
  bad "build-iso.sh accepted a file that is not an ISO: $_out"
fi
# A file with the ISO9660 magic but the wrong contents: the checksum path has
# to catch it before an hour of VM install.
FAKEISO=$(mktemp "${TMPDIR:-/tmp}/rns-os-fakeiso.XXXXXX")
"$BB" dd if=/dev/zero of="$FAKEISO" bs=1024 count=40 2>/dev/null
printf 'CD001' | "$BB" dd of="$FAKEISO" bs=1 seek=32769 conv=notrunc 2>/dev/null
_out=$(sh "$OS_ROOT/iso/build-iso.sh" --base "$FAKEISO" --out "$FAKEISO.out" \
        --sha256 0000000000000000000000000000000000000000000000000000000000000000 2>&1 || true)
if printf '%s' "$_out" | grep -q 'checksum mismatch'; then
  ok "build-iso.sh refuses a base image whose sha256 does not match"
else
  bad "build-iso.sh did not verify the base image: $_out"
fi
rm -f "$NOTISO" "$NOTISO.iso" "$FAKEISO" "$FAKEISO.out"

# create-vm.sh / .ps1: the settings are what make the appliance reachable from
# the operator's PC, so assert them where they cannot be checked by running.
chk "create-vm.sh syntax" "sh -n '$OS_ROOT/iso/vm/create-vm.sh'"
# The docs tell the operator to run these directly (./build-iso.sh,
# ./create-vm.sh). A rewrite that drops the executable bit makes both fail with
# "Permission denied" on a machine that cannot be debugged from here, so it is
# asserted rather than assumed.
chk "build-iso.sh is executable" "[ -x '$OS_ROOT/iso/build-iso.sh' ]"
chk "create-vm.sh is executable" "[ -x '$OS_ROOT/iso/vm/create-vm.sh' ]"
chk "create-vm.sh forwards the panel to the host browser" \
    "grep -q 'panel,tcp,127.0.0.1' '$OS_ROOT/iso/vm/create-vm.sh'"
chk "the forwarded panel is bound to 127.0.0.1, not the whole LAN" \
    "grep -q '127.0.0.1,\$PANEL_HOST,,8080' '$OS_ROOT/iso/vm/create-vm.sh'"
chk "create-vm.sh checks the host port before forwarding it" \
    "grep -q 'port_busy' '$OS_ROOT/iso/vm/create-vm.sh'"
chk "create-vm.sh puts the host-only side on the appliance's subnet" \
    "grep -q 'HOSTONLY_IP=192.168.50.2' '$OS_ROOT/iso/vm/create-vm.sh'"
chk "create-vm.sh checks the ISO before creating a VM" \
    "grep -q 'CD001' '$OS_ROOT/iso/vm/create-vm.sh'"
chk "create-vm.ps1 has the same panel forward" \
    "grep -q 'natpf1 \"panel,tcp,127.0.0.1,\$PanelHost,,8080\"' '$OS_ROOT/iso/vm/create-vm.ps1'"
chk "create-vm.ps1 has the same host-only subnet" \
    "grep -q 'HostOnlyIp = \"192.168.50.2\"' '$OS_ROOT/iso/vm/create-vm.ps1'"

# The CI workflow is how somebody without a Linux box gets an ISO at all.
WF="$REPO_ROOT/.github/workflows/build-iso.yml"
chk "a CI workflow builds the ISO" "[ -f '$WF' ]"
chk "CI runs the appliance test suite before building" "grep -q 'os-selftest.sh' '$WF'"
chk "CI builds with the same script that verifies the base image" \
    "grep -q 'build-iso.sh' '$WF'"
chk "CI uploads the ISO as an artifact" "grep -q 'upload-artifact' '$WF'"
chk "CI publishes a release for a version tag" "grep -q 'refs/tags/rns-os-' '$WF'"
# CI once gated the build on the runner's busybox having every applet the engine
# calls. That was backwards twice over: the runner's busybox is not the
# appliance's, and the appliance's (Debian 12) has no flock at all. The gate had
# to go; the shim is what covers the gap, and the workflow has to check the shim
# inside the finished image instead of the toolchain that built it.
chk "CI does not fail the build over a host busybox applet" \
    "! grep -q 'grep -qx flock. || {' '$WF'"
chk "CI checks the shim inside the built image" "grep -q 'rns-bb' '$WF'"
# Every run: block is shell, and a stray quote in one costs a whole CI round
# trip - the raw step log cannot even be downloaded from here.
if command -v python3 >/dev/null 2>&1; then
  python3 - "$WF" > "$STAGE/ci-steps.sh" <<'CIPY'
import re, sys
lines = open(sys.argv[1]).read().split('\n')
i = 0
n = 0
while i < len(lines):
    m = re.match(r'^(\s*)run:\s*\|[+-]?\s*$', lines[i])
    if m:
        ki = len(m.group(1))
        j = i + 1
        body = []
        while j < len(lines):
            bl = lines[j]
            if bl.strip() == '':
                body.append('')
                j += 1
                continue
            ind = len(bl) - len(bl.lstrip(' '))
            if ind <= ki:
                break
            body.append(bl[min(ind, ki + 2):])
            j += 1
        n += 1
        print('# ---- run block %d (line %d) ----' % (n, i + 1))
        print('\n'.join(body))
        i = j
    else:
        i += 1
CIPY
  chk "the CI workflow has shell to check" "[ -s '$STAGE/ci-steps.sh' ]"
  chk "every CI run block parses as shell" "sh -n '$STAGE/ci-steps.sh'"
fi

# ===========================================================================
printf '\n--- D. running appliance: portal, panel, payments ---\n'
# ===========================================================================

PORT=""
for p in 18991 18992 18993 18994 18995; do
  # A port is free when nothing answers on it. Done with curl rather than
  # /dev/tcp, which only exists in bash and this suite runs under /bin/sh.
  if ! curl -sS -m 1 -o /dev/null "http://127.0.0.1:$p/health" 2>/dev/null; then
    PORT=$p
    break
  fi
done
[ -n "$PORT" ] || { bad "no free port for the page listener"; exit 1; }

# Start the listener the way the appliance does: through the engine's own
# rns-pages.sh, which picks the binary, records the engine and detaches.
# RNS_LAB=1 because this box has no iptables and no radio.
rm -f "$DATA/.labseed"
# rns-pages.sh takes its port from config.env, not from an argument — that is
# the appliance's real behaviour, so drive it that way instead of inventing a
# test-only override.
RNS_OS_ROOT="$STAGE" RNS_HOME="$HOME_LIB" RNS_DATA="$DATA" RNS_LAB=0 BB="$BB" \
  sh "$CTL" config "PORTAL_PORT=$PORT" >/dev/null 2>&1
RNS_HOME="$HOME_LIB" RNS_DATA="$DATA" RNS_LAB=1 BB="$BB" RNS_BB="$BB" \
  sh "$HOME_LIB/bin/rns-pages.sh" >"$STAGE.pages.log" 2>&1
HPID=$(cat "$DATA/httpd.pid" 2>/dev/null || true)
sleep 1
if [ -n "$HPID" ] && kill -0 "$HPID" 2>/dev/null; then
  ok "page listener started by rns-pages.sh (engine=$(cat "$DATA/httpd.engine" 2>/dev/null))"
else
  bad "page listener did not start: $(tail -n 5 "$STAGE.pages.log" 2>/dev/null)"
  exit 1
fi

U="http://127.0.0.1:$PORT"
CJ="$STAGE.cookies"

_chk_http() { # _chk_http label url grep-pattern
  _b=$(curl -sS -m 5 "$2" 2>/dev/null || true)
  if printf '%s' "$_b" | grep -q "$3"; then ok "$1"; else bad "$1 (got: $(printf '%s' "$_b" | head -c 160))"; fi
}

_chk_http "health" "$U/health" '"ok":true'
_chk_http "staff panel serves" "$U/admin" 'Staff login'
_chk_http "captive portal serves" "$U/" 'Welcome online'
_probe=$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "$U/generate_204" 2>/dev/null || true)
chk "android probe answers 200 (portal, not a redirect)" "[ \"$_probe\" = '200' ]"

# --- admin login -----------------------------------------------------------
_login=$(curl -sS -m 5 -c "$CJ" -b "$CJ" -H 'Accept: application/json' \
         -d 'password=rns-admin' "$U/api/login" 2>/dev/null || true)
printf '%s' "$_login" | grep -q '"ok":true' && ok "staff login" || bad "staff login: $_login"

# --- v7 payment gateway: the part the Magisk suite never tested ------------
_pkgs=$(curl -sS -m 5 "$U/api/pay/packages" 2>/dev/null || true)
json_ok "GET /api/pay/packages is valid JSON" "$_pkgs"
printf '%s' "$_pkgs" | grep -q '"packages":\[\]' && ok "no online packages before setup" \
  || note "online packages: $_pkgs"

# configure the wallets the way the operator does in Settings
curl -sS -m 5 -b "$CJ" -H 'Accept: application/json' \
  -d 'jazzcash_number=03001234567&jazzcash_name=Test Shop&easypaisa_number=03451234567&easypaisa_name=Test Shop&pay_auto_verify=1' \
  "$U/api/admin/settings" >/dev/null 2>&1 || true
_pkgs=$(curl -sS -m 5 "$U/api/pay/packages" 2>/dev/null || true)
printf '%s' "$_pkgs" | grep -q '03001234567' && ok "wallet number reaches the captive portal" \
  || bad "wallet number missing from /api/pay/packages: $_pkgs"

# build an online package (the customer-facing catalogue, separate from counter)
_op=$(curl -sS -m 5 -b "$CJ" -H 'Accept: application/json' \
  -d 'id=net1h&label=Net 1 Hour&seconds=3600&down_kbps=2048&up_kbps=1024&price=150&rate=150&rate_unit=hour' \
  "$U/api/admin/online-packages" 2>/dev/null || true)
printf '%s' "$_op" | grep -q 'net1h' && ok "online package created" || bad "online package create: $_op"
json_ok "online-packages response is valid JSON" "$_op"

# counter packages must not leak into the self-service catalogue
curl -sS -m 5 -b "$CJ" -H 'Accept: application/json' \
  -d 'id=ctr1h&label=Counter Hour&seconds=3600&down_kbps=2048&up_kbps=1024&price=100&rate=100&rate_unit=hour' \
  "$U/api/admin/packages" >/dev/null 2>&1 || true
_pkgs=$(curl -sS -m 5 "$U/api/pay/packages" 2>/dev/null || true)
printf '%s' "$_pkgs" | grep -q 'Counter Hour' \
  && bad "counter package leaked into the public Buy Online catalogue" \
  || ok "counter packages stay out of the customer catalogue"

# --- auto-verify payment flow ---------------------------------------------
_pay() { # _pay tid method pkg -> body
  curl -sS -m 8 -H 'Accept: application/json' \
    --data-urlencode "package_id=$3" --data-urlencode "method=$2" \
    --data-urlencode "tid=$1" "$U/api/pay/submit" 2>/dev/null || true
}

_r=$(_pay 2456789012 jazzcash net1h)
printf '%s' "$_r" | grep -q '"status":"confirmed"' \
  && ok "auto-verify activates on a valid JazzCash TID" \
  || bad "auto-verify did not confirm: $_r"
json_ok "pay/submit response is valid JSON" "$_r"
_code=$(printf '%s' "$_r" | sed -n 's/.*"voucher_code":"\([^"]*\)".*/\1/p')
_payid=$(printf '%s' "$_r" | sed -n 's/.*"pay_id":"\([^"]*\)".*/\1/p')
chk "a voucher code came back" "[ -n \"$_code\" ]"
chk "payment id came back" "[ -n \"$_payid\" ]"

# the voucher must be active for this device, not merely minted
_v=$(curl -sS -m 5 -b "$CJ" -H 'Accept: application/json' "$U/api/admin/vouchers" 2>/dev/null || true)
printf '%s' "$_v" | grep -q "\"code\":\"$_code\"" && ok "paid voucher is in the store" \
  || bad "paid voucher missing from /api/admin/vouchers"
printf '%s' "$_v" | grep -q '"status":"active"' && ok "paid voucher is active" \
  || bad "paid voucher not active: $(printf '%s' "$_v" | head -c 200)"
printf '%s' "$_v" | grep -q 'online 2456789012' && ok "voucher is tagged with its TID" \
  || bad "voucher not tagged 'online <TID>'"

# --- PDF receipt -----------------------------------------------------------
curl -sS -m 8 -b "$CJ" -o "$STAGE/receipt.pdf" "$U/api/pay/receipt?pay_id=$_payid" 2>/dev/null || true
if [ -s "$STAGE/receipt.pdf" ]; then
  _hdr=$(head -c 5 "$STAGE/receipt.pdf")
  chk "receipt starts with %PDF-" "[ \"$_hdr\" = '%PDF-' ]"
  chk "receipt has a trailer" "grep -qa '%%EOF' '$STAGE/receipt.pdf'"
  chk "receipt carries the voucher code" "grep -qa '$_code' '$STAGE/receipt.pdf'"
  chk "receipt carries the TID" "grep -qa '2456789012' '$STAGE/receipt.pdf'"
else
  bad "receipt download was empty (pay_id=$_payid)"
fi

# --- TID validation --------------------------------------------------------
_r=$(_pay 2456789012 jazzcash net1h)
printf '%s' "$_r" | grep -q 'duplicate_tid' && ok "duplicate TID rejected" \
  || bad "duplicate TID accepted: $_r"

_r=$(_pay 123 jazzcash net1h)
printf '%s' "$_r" | grep -q 'invalid_tid_format' && ok "short TID rejected" \
  || bad "short TID accepted: $_r"

_r=$(_pay 1234567 jazzcash net1h)
printf '%s' "$_r" | grep -q 'invalid_tid_format' \
  && ok "7-digit JazzCash TID rejected (needs 8-12)" \
  || bad "7-digit JazzCash TID accepted: $_r"

_r=$(_pay 1234567890123 jazzcash net1h)
printf '%s' "$_r" | grep -q 'invalid_tid_format' \
  && ok "13-digit JazzCash TID rejected (needs 8-12)" \
  || bad "13-digit JazzCash TID accepted: $_r"

_r=$(_pay 1234567890123 easypaisa net1h)
printf '%s' "$_r" | grep -q '"status":"confirmed"' \
  && ok "13-digit EasyPaisa TID accepted (needs 8-15)" \
  || bad "13-digit EasyPaisa TID rejected: $_r"

_r=$(_pay ABCDEF paypal net1h)
printf '%s' "$_r" | grep -q 'bad_method' && ok "unknown wallet rejected" \
  || bad "unknown wallet accepted: $_r"

_r=$(_pay 9988776655 jazzcash nopackage)
printf '%s' "$_r" | grep -q 'unknown_package' && ok "unknown package rejected" \
  || bad "unknown package accepted: $_r"

# --- rate limit ------------------------------------------------------------
# The auto-verify path counts every payment record for this IP in the last 10
# minutes and stops at 5. Two records already exist, so three more must go
# through and the sixth attempt must be refused.
for t in 3300112233 4400112233 5500112233; do
  _pay "$t" jazzcash net1h >/dev/null 2>&1
done
_r=$(_pay 6600112233 jazzcash net1h)
printf '%s' "$_r" | grep -q 'rate_limited' && ok "rate limit stops the 6th payment in 10 minutes" \
  || bad "rate limit not enforced on the 6th attempt: $_r"

# --- manual mode -----------------------------------------------------------
# Clear the payment history so the rate limiter does not mask this test.
: > "$DATA/database/payments.tsv"
curl -sS -m 5 -b "$CJ" -H 'Accept: application/json' -d 'pay_auto_verify=0&jazzcash_number=03001234567&easypaisa_number=03451234567' \
  "$U/api/admin/settings" >/dev/null 2>&1 || true
_r=$(_pay 7700112233 easypaisa net1h)
printf '%s' "$_r" | grep -q '"status":"pending"' && ok "manual mode leaves the payment pending" \
  || bad "manual mode did not leave it pending: $_r"
_pid2=$(printf '%s' "$_r" | sed -n 's/.*"pay_id":"\([^"]*\)".*/\1/p')

_st=$(curl -sS -m 5 "$U/api/pay/status?pay_id=$_pid2" 2>/dev/null || true)
printf '%s' "$_st" | grep -q '"status":"pending"' && ok "customer can poll a pending payment" \
  || bad "pay/status wrong for pending: $_st"

_c=$(curl -sS -m 8 -b "$CJ" -H 'Accept: application/json' -d "pay_id=$_pid2&note=checked statement" \
     "$U/api/admin/pay-confirm" 2>/dev/null || true)
printf '%s' "$_c" | grep -q '"ok":true' && ok "staff confirm activates a pending payment" \
  || bad "pay-confirm failed: $_c"
_st=$(curl -sS -m 5 "$U/api/pay/status?pay_id=$_pid2" 2>/dev/null || true)
printf '%s' "$_st" | grep -q '"status":"confirmed"' && ok "confirmed status reaches the customer" \
  || bad "pay/status wrong after confirm: $_st"

_r=$(_pay 8800112233 easypaisa net1h)
_pid3=$(printf '%s' "$_r" | sed -n 's/.*"pay_id":"\([^"]*\)".*/\1/p')
_j=$(curl -sS -m 8 -b "$CJ" -H 'Accept: application/json' -d "pay_id=$_pid3&note=not in statement" \
     "$U/api/admin/pay-reject" 2>/dev/null || true)
printf '%s' "$_j" | grep -q '"ok":true' && ok "staff reject" || bad "pay-reject failed: $_j"
_st=$(curl -sS -m 5 "$U/api/pay/status?pay_id=$_pid3" 2>/dev/null || true)
printf '%s' "$_st" | grep -q '"status":"rejected"' && ok "rejected status reaches the customer" \
  || bad "pay/status wrong after reject: $_st"

curl -sS -m 5 -b "$CJ" -H 'Accept: application/json' -d 'pay_auto_verify=1&jazzcash_number=03001234567&easypaisa_number=03451234567' \
  "$U/api/admin/settings" >/dev/null 2>&1 || true

# --- payments tab data + CLI ------------------------------------------------
_pl=$(curl -sS -m 5 -b "$CJ" -H 'Accept: application/json' "$U/api/admin/payments" 2>/dev/null || true)
json_ok "GET /api/admin/payments is valid JSON" "$_pl"
# The history was truncated before the manual-mode test, so assert on a record
# that is still there — and on the voucher code the confirm wrote back.
printf '%s' "$_pl" | grep -q '7700112233' && ok "payments tab lists the confirmed TID" \
  || bad "payments list missing the confirmed TID: $(printf '%s' "$_pl" | head -c 200)"

# The admin endpoints must stay locked without a session.
_c=$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "$U/api/admin/payments" 2>/dev/null || true)
chk "payments list is admin-only (401 anonymous)" "[ \"$_c\" = '401' ]"

_cli=$(RNS_HOME="$HOME_LIB" RNS_DATA="$DATA" RNS_LAB=1 BB="$BB" RNS_BB="$BB" \
       sh "$HOME_LIB/bin/rns-ctl.sh" payments 2>&1 || true)
printf '%s' "$_cli" | grep -q '7700112233' && ok "rns payments CLI lists records" \
  || bad "rns payments CLI: $(printf '%s' "$_cli" | head -c 200)"
printf '%s' "$_cli" | grep -q 'confirmed' && ok "CLI shows the confirmed status" \
  || bad "CLI does not show a confirmed payment: $(printf '%s' "$_cli" | head -c 200)"

_ver=$(RNS_HOME="$HOME_LIB" RNS_DATA="$DATA" RNS_LAB=1 BB="$BB" RNS_BB="$BB" \
       sh "$HOME_LIB/bin/rns-ctl.sh" verify 2>&1 || true)
printf '%s' "$_ver" | grep -qi 'payment' && ok "rns verify reports the payment summary" \
  || bad "rns verify has no payment summary"

# ===========================================================================
printf '\n--- result ---\n'
if [ "$fails" -eq 0 ]; then
  printf 'ALL PASSED (%s checks)\n' "$ran"
  exit 0
fi
printf '%s of %s checks FAILED\n' "$fails" "$ran"
exit 1
