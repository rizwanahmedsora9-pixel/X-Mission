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
# A Wi-Fi adapter for the access point is a separate step: VirtualBox has to
# pass a physical USB Wi-Fi dongle through (see VirtualBox.md). Without one,
# set RNS_MODE=wired or off and test over Ethernet.

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

die() { printf 'create-vm: %s\n' "$*" >&2; exit 1; }
say() { printf 'create-vm: %s\n' "$*"; }

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
    --start)      START=1; shift ;;
    --force)      FORCE=1; shift ;;
    -h|--help)    sed -n '2,22p' "$0"; exit 0 ;;
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

[ -n "$ISO" ] || die "pass --iso path/to/RNS-OS-*-amd64.iso"
[ -f "$ISO" ] || die "ISO not found: $ISO"
ISO=$(CDPATH= cd -- "$(dirname -- "$ISO")" && pwd)/$(basename "$ISO")

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
if [ "$LAN_MODE" = "hostonly" ]; then
  HOSTONLY_IF=$("$VBM" list hostonlyifs 2>/dev/null | sed -n 's/^Name:[[:space:]]*//p' | head -n 1)
  if [ -z "$HOSTONLY_IF" ]; then
    say "creating a host-only network"
    _out=$("$VBM" hostonlyif create 2>&1) || die "could not create host-only interface: $_out"
    HOSTONLY_IF=$(printf '%s' "$_out" | sed -n "s/.*'\(vboxnet[0-9]*\)'.*/\1/p" | head -n 1)
    [ -n "$HOSTONLY_IF" ] || HOSTONLY_IF=vboxnet0
    "$VBM" hostonlyif ipconfig "$HOSTONLY_IF" --ip 192.168.56.1 --netmask 255.255.255.0 >/dev/null 2>&1 || true
  fi
  say "customer side on host-only interface $HOSTONLY_IF"
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
say ""
if [ "$START" -eq 1 ]; then
  say "starting (the installer runs unattended, about 5-10 minutes)"
  "$VBM" startvm "$NAME"
else
  say "start it with:  VBoxManage startvm \"$NAME\"   (or the VirtualBox GUI)"
fi
say ""
say "When it reboots into RNS-OS, log in as root/rnsos (CHANGE IT: passwd) and run"
say "  rns os status        then open the staff panel URL it prints."
