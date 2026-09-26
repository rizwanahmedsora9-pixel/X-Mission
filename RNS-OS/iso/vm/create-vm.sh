#!/bin/sh
# create-vm.sh — create the RNS-OS virtual machine in Oracle VirtualBox.
#
# Linux / macOS hosts. On Windows use create-vm.ps1 (same settings).
#
#   ./create-vm.sh --iso ../../dist/RNS-OS-1.0.0-amd64.iso
#   ./create-vm.sh --iso FILE --lan bridged --bridge-if enp3s0
#   ./create-vm.sh --iso FILE --start
#
# Two network adapters, because the appliance is a router:
#
#   NIC1  uplink    NAT by default — the VM reaches the internet, customers
#                   cannot reach the VM. Use --lan bridged to put the VM on
#                   your real network.
#   NIC2  customers host-only (vboxnet0) by default — YOUR PC sits on the
#                   customer side, so you can open the captive portal and the
#                   staff panel from the host browser and test the whole flow.
#
# The customer side of a fresh RNS-OS install is 192.168.50.1, so the host-only
# adapter is configured to sit on that same subnet when this script creates it.
#
# NAT port forwarding is added as well, because it is the one path that works
# with no network configuration at all — including when the host-only adapter
# already existed with a different subnet:
#
#   host 127.0.0.1:8080  ->  guest :8080   the staff panel and the portal
#   host 127.0.0.1:2222  ->  guest :22     SSH (root/rnsos until you change it)
#
# Both forwards bind to 127.0.0.1 on purpose: the billing panel is not exposed
# to your LAN. Use --no-forward to skip them, --panel-port to move the host
# side if 8080 is taken.
#
# A Wi-Fi adapter for the access point is a separate step: VirtualBox has to
# pass a physical USB Wi-Fi dongle through (see VirtualBox.md). Without one,
# leave the appliance in its default `wired` mode or use `off`.

set -eu

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OS_ROOT=$(CDPATH= cd -- "$SELF_DIR/.." && pwd)

NAME="RNS-OS"
ISO=""
DISK_SIZE=20480          # MB
MEM=2048                 # MB
CPUS=2
LAN_MODE=hostonly        # hostonly | bridged
BRIDGE_IF=""
DISKDIR=""
START=0
FORCE=0
FORWARD=1
PANEL_PORT=8080
SSH_PORT=2222
HOSTONLY_IP=192.168.50.2  # this PC's address on the customer subnet

die() { printf 'create-vm: %s\n' "$*" >&2; exit 1; }
say() { printf 'create-vm: %s\n' "$*"; }

port_busy() { # port_busy PORT — best effort; 0 means "something is listening"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1$"
  elif command -v netstat >/dev/null 2>&1; then
    netstat -an 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1$"
  elif command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
  else
    return 1
  fi
}

free_port() { # free_port WANTED -> prints the first free port at/above it
  _p=$1
  while [ "$_p" -lt $((_p + 20)) ]; do
    port_busy "$_p" || { printf '%s' "$_p"; return 0; }
    _p=$((_p + 1))
  done
  printf '%s' "$1"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --name)       NAME=${2:?}; shift 2 ;;
    --iso)        ISO=${2:?}; shift 2 ;;
    --size)       DISK_SIZE=${2:?}; shift 2 ;;
    --memory)     MEM=${2:?}; shift 2 ;;
    --cpus)       CPUS=${2:?}; shift 2 ;;
    --lan)        LAN_MODE=${2:?}; shift 2 ;;
    --bridge-if)  BRIDGE_IF=${2:?}; shift 2 ;;
    --disk-dir)   DISKDIR=${2:?}; shift 2 ;;
    --hostonly-ip) HOSTONLY_IP=${2:?}; shift 2 ;;
    --panel-port) PANEL_PORT=${2:?}; shift 2 ;;
    --ssh-port)   SSH_PORT=${2:?}; shift 2 ;;
    --no-forward) FORWARD=0; shift ;;
    --start)      START=1; shift ;;
    --force)      FORCE=1; shift ;;
    -h|--help)    sed -n '2,38p' "$0"; exit 0 ;;
    *)            die "unknown argument: $1" ;;
  esac
done

VBM=$(command -v VBoxManage || true)
if [ -z "$VBM" ]; then
  for _p in /usr/lib/virtualbox/VBoxManage \
            /Applications/VirtualBox.app/Contents/MacOS/VBoxManage; do
    [ -x "$_p" ] && { VBM=$_p; break; }
  done
fi
[ -n "$VBM" ] || die "VBoxManage not found — is Oracle VirtualBox installed?"
say "VBoxManage: $VBM"

[ -n "$ISO" ] || die "pass --iso path/to/RNS-OS-*-amd64.iso  (build it first: cd ../.. && iso/build-iso.sh)"
[ -f "$ISO" ] || die "ISO not found: $ISO"
ISO=$(CDPATH= cd -- "$(dirname -- "$ISO")" && pwd)/$(basename "$ISO")

# An ISO9660 primary volume descriptor sits at offset 32769. Catching a wrong
# file here beats watching VirtualBox boot into "FATAL: No bootable medium".
_magic=$(dd if="$ISO" bs=1 skip=32769 count=5 2>/dev/null || true)
[ "$_magic" = "CD001" ] || die "$ISO is not an ISO9660 image — did you point --iso at the built RNS-OS ISO?"
_isz=$(du -h "$ISO" | awk '{print $1}')
say "installer ISO ok: $ISO ($_isz)"

if [ -z "$DISKDIR" ]; then
  _mb=$("$VBM" list systemproperties 2>/dev/null | sed -n 's/^Default machine folder:[[:space:]]*//p')
  DISKDIR=${_mb:-$HOME/VirtualBox VMs}/$NAME
fi

# ---------------------------------------------------------------------------
# refuse to clobber an existing VM unless asked
# ---------------------------------------------------------------------------
if "$VBM" showvminfo "$NAME" >/dev/null 2>&1; then
  if [ "$FORCE" -eq 1 ]; then
    say "removing existing VM $NAME (--force)"
    "$VBM" controlvm "$NAME" poweroff >/dev/null 2>&1 || true
    sleep 2
    "$VBM" unregistervm "$NAME" --delete >/dev/null 2>&1 || \
      "$VBM" unregistervm "$NAME" >/dev/null 2>&1 || true
  else
    die "a VM named $NAME already exists. Use --force to replace it, or --name."
  fi
fi

# ---------------------------------------------------------------------------
# host-only network for the customer side
# ---------------------------------------------------------------------------
HOSTONLY_IF=""
HOSTONLY_OK=0
if [ "$LAN_MODE" = "hostonly" ]; then
  HOSTONLY_IF=$("$VBM" list hostonlyifs 2>/dev/null | sed -n 's/^Name:[[:space:]]*//p' | head -n 1)
  if [ -z "$HOSTONLY_IF" ]; then
    say "creating a host-only network"
    _out=$("$VBM" hostonlyif create 2>&1) || die "could not create host-only interface: $_out"
    HOSTONLY_IF=$(printf '%s' "$_out" | sed -n "s/.*'\(vboxnet[0-9]*\)'.*/\1/p" | head -n 1)
    [ -n "$HOSTONLY_IF" ] || HOSTONLY_IF=vboxnet0
    "$VBM" hostonlyif ipconfig "$HOSTONLY_IF" --ip "$HOSTONLY_IP" --netmask 255.255.255.0 >/dev/null 2>&1 || true
    say "customer side on host-only interface $HOSTONLY_IF ($HOSTONLY_IP)"
    HOSTONLY_OK=1
  fi
  if [ "$HOSTONLY_OK" -eq 0 ]; then
    _hip=$("$VBM" list hostonlyifs 2>/dev/null | sed -n 's/^IPAddress:[[:space:]]*//p' | head -n 1)
    say "customer side on existing host-only interface $HOSTONLY_IF (${_hip:-no address})"
    case "$_hip" in
      192.168.50.*) HOSTONLY_OK=1 ;;
      *) say "  NOTE: $_HOSTONLY_IF is not on the 192.168.50.x subnet the appliance uses,"
         say "  so your PC cannot browse to the customer side yet. Either move it:"
         say "      VBoxManage hostonlyif ipconfig $HOSTONLY_IF --ip $HOSTONLY_IP --netmask 255.255.255.0"
         say "  or tell the appliance to use this subnet instead (in the VM):"
         say "      rns os config GUEST_IP=${_hip%.*}.1 GUEST_MASK=255.255.255.0"
         say "      rns os config DHCP_START=${_hip%.*}.20 DHCP_END=${_hip%.*}.250"
         say "      systemctl restart rns-net rns-dhcp"
         say "  The NAT port forwarding below works either way." ;;
    esac
  fi
elif [ "$LAN_MODE" = "bridged" ]; then
  [ -n "$BRIDGE_IF" ] || die "--lan bridged needs --bridge-if <interface>"
  say "customer side bridged to $BRIDGE_IF"
else
  die "--lan must be hostonly or bridged"
fi

# ---------------------------------------------------------------------------
# the VM
# ---------------------------------------------------------------------------
say "creating VM $NAME"
"$VBM" createvm --name "$NAME" --ostype Debian_64 --register >/dev/null

"$VBM" modifyvm "$NAME" \
  --memory "$MEM" --cpus "$CPUS" --vram 16 \
  --graphicscontroller vmsvga --accelerate3d off \
  --boot1 dvd --boot2 disk --boot3 none --boot4 none \
  --rtc-use-utc on \
  --nic1 nat --nictype1 82540EM --cableconnected1 on \
  --nic2 "$LAN_MODE" --nictype2 82540EM --cableconnected2 on \
  --usb on --usbehci on >/dev/null
if [ "$LAN_MODE" = "hostonly" ]; then
  "$VBM" modifyvm "$NAME" --host-only-adapter2 "$HOSTONLY_IF" >/dev/null
else
  "$VBM" modifyvm "$NAME" --bridge-adapter2 "$BRIDGE_IF" >/dev/null
fi

# NAT port forwarding: the zero-configuration way to reach the appliance from
# this PC. Bound to 127.0.0.1 so the panel is not published to the LAN.
PANEL_HOST=$PANEL_PORT
SSH_HOST=$SSH_PORT
if [ "$FORWARD" -eq 1 ]; then
  if port_busy "$PANEL_HOST"; then
    _new=$(free_port $((PANEL_HOST + 1)))
    say "host port $PANEL_HOST is in use — using $_new for the panel"
    PANEL_HOST=$_new
  fi
  if port_busy "$SSH_HOST"; then
    _new=$(free_port $((SSH_HOST + 1)))
    say "host port $SSH_HOST is in use — using $_new for SSH"
    SSH_HOST=$_new
  fi
  "$VBM" modifyvm "$NAME" \
    --natpf1 "panel,tcp,127.0.0.1,$PANEL_HOST,,8080" \
    --natpf1 "ssh,tcp,127.0.0.1,$SSH_HOST,,22" >/dev/null
fi

# USB passthrough is how a physical Wi-Fi adapter reaches the guest. The filter
# is created empty on purpose: add the dongle's vendor/product with
#   VBoxManage usbfilter add --target RNS-OS --name wifi --vendorid 0xXXXX --productid 0xYYYY
# (see VirtualBox.md) so the exact adapter is claimed on plug-in.

say "creating ${DISK_SIZE}MB disk"
mkdir -p "$DISKDIR"
DISK="$DISKDIR/$NAME.vdi"
if [ -f "$DISK" ]; then
  "$VBM" closemedium disk "$DISK" --delete >/dev/null 2>&1 || rm -f "$DISK"
fi
"$VBM" createmedium disk --filename "$DISK" --size "$DISK_SIZE" --format VDI >/dev/null

"$VBM" storagectl "$NAME" --name SATA --add sata --controller IntelAhci --portcount 2 >/dev/null
"$VBM" storageattach "$NAME" --storagectl SATA --port 0 --device 0 --type hdd --medium "$DISK" >/dev/null
"$VBM" storageattach "$NAME" --storagectl SATA --port 1 --device 0 --type dvddrive --medium "$ISO" >/dev/null

say ""
say "VM ready: $NAME"
say "  disk    $DISK"
say "  iso     $ISO"
say "  uplink  NIC1 nat"
say "  guests  NIC2 $LAN_MODE ${HOSTONLY_IF:-$BRIDGE_IF}"
if [ "$FORWARD" -eq 1 ]; then
  say "  panel   http://127.0.0.1:$PANEL_HOST/admin   (VirtualBox NAT forward)"
  say "  ssh     ssh -p $SSH_HOST rns@127.0.0.1"
fi
say ""
if [ "$START" -eq 1 ]; then
  say "starting (the installer runs unattended, about 5-10 minutes)"
  "$VBM" startvm "$NAME"
else
  say "start it with:  VBoxManage startvm \"$NAME\"   (or the VirtualBox GUI)"
fi
say ""
say "Then:"
say "  1. the installer partitions the disk and reboots by itself — no keypresses"
say "  2. log in on the VM console as root / rnsos  (then run: passwd)"
say "  3. rns os status          what is running, and the portal URL"
if [ "$FORWARD" -eq 1 ]; then
  say "  4. from this PC:  curl -s http://127.0.0.1:$PANEL_HOST/health"
  say "     then open        http://127.0.0.1:$PANEL_HOST/admin"
fi
say "  Full walkthrough: $SELF_DIR/VirtualBox.md"
