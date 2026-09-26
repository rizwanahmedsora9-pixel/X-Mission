# RNS-OS — the RNS Gateway as a VirtualBox appliance

**Version 1.0.0** · Debian 12 (bookworm) amd64 · for Oracle VirtualBox

RNS-OS is the same hotspot billing system that runs as a Magisk module on the
shop phone — captive portal, voucher codes, package builder, sales report,
JazzCash / EasyPaisa auto-payment — packaged as a **bootable Linux operating
system for a virtual machine** instead of a phone module.

It is a **separate product line** from the Magisk releases:

| | Magisk line | RNS-OS |
|---|---|---|
| Ships as | `RNS_Gateway.zip` | `RNS-OS-<ver>-amd64.iso` |
| Runs on | rooted Android phone | Oracle VirtualBox VM / any x86-64 PC |
| Versioning | `releases/v3 … v7` | `RNS-OS/VERSION` (1.0.0) |
| Folder | `../RNS-Gateway/` | `RNS-OS/` |
| Config lives in | `/sdcard/HotspotBilling/` | `/var/lib/rns/` |

RNS-OS is **not** "v8". It has its own version number, its own release notes
([NOTES.txt](NOTES.txt)) and its own test suite. Nothing under `releases/` or
`../RNS-Gateway/` is versioned, numbered or released by this folder.

## Why it can share code without becoming a fork

The billing logic — `store.sh`, `net.sh`, `rns-http.sh`, `rns-front.sh`, the
portal and admin HTML — contains **no Android-specific code at all**. It reads
its paths from the environment (`RNS_HOME`, `RNS_DATA`, `BB`) and it already
has a lab mode for running off the phone. So RNS-OS installs those exact files
under `/usr/local/lib/rns` and changes only the platform around them:

```
             same engine files (bin/*.sh, www/*.html)
                    ┌──────────────┴──────────────┐
   RNS-Gateway/  Magisk zip                  RNS-OS/  Debian ISO
   Android: service.sh, action.sh,           Linux: systemd units, hostapd,
   Android hotspot (ap0), vendor hostapd     dnsmasq, ip/tc, rns-os-ctl
```

`tools/os-selftest.sh` asserts the engine inside the image is **byte-identical**
to `../RNS-Gateway/module/rns`, so the two cannot drift apart silently.

A handful of paths in the shared engine are hard-coded to Android
(`/data/adb/rns/page.env`, `/data/local/tmp`). Rather than fork those files,
the installer creates two symlinks that point them at the real locations:

```
/data/adb/rns    -> /var/lib/rns
/data/local/tmp  -> /var/log/rns
```

## Quick start

```sh
# 1. build the ISO          (needs xorriso; ~5 min, needs internet once)
cd iso && ./build-iso.sh

# 2. create the VM          (Linux/macOS; Windows: create-vm.ps1)
./vm/create-vm.sh --iso ../dist/RNS-OS-1.0.0-amd64.iso --start
```

The installer runs unattended (about 5–10 minutes), reboots, and RNS-OS starts
itself. Log in on the VM console as `root` / `rnsos` — **change it immediately**
(`passwd`) — and run:

```sh
rns os status        # where the panel is, what is running
rns os setup         # SSID, wallet numbers, guest interface
rns status           # the billing system itself
```

Full VM instructions, including Wi-Fi adapter passthrough:
[iso/vm/VirtualBox.md](iso/vm/VirtualBox.md).

## Three network modes

A VM cannot use the laptop's internal Wi-Fi card as an access point, so
RNS-OS is explicit about what it is driving (`RNS_MODE` in config):

| Mode | Customer side | Use it for |
|---|---|---|
| `wifi` | hostapd on a **USB Wi-Fi adapter passed through** to the VM | a real hotspot from the VM |
| `wired` | Ethernet on the second VM adapter | testing the portal with a cable, or a VM behind a real access point |
| `off` | nothing addressed | panel, vouchers, payments, reports only |

`wifi` needs a Linux-supported USB Wi-Fi dongle attached in
**VM Settings → USB**. Without one, `rns-ap.service` logs why it did not start
and exits cleanly — the portal, vouchers and payments keep working. It never
takes the billing system down with it.

## Commands

```sh
rns status | packages | sales | payments | mint | verify   # billing (engine)
rns os status | diag | setup | config KEY=VALUE | render   # platform
```

`rns os diag` prints one bundle — kernel, interfaces, radios, unit states, the
engine's own `verify`, and the log tail. Paste that when reporting a problem.

## Layout

```
RNS-OS/
├── VERSION                  this appliance's version (independent of Magisk)
├── NOTES.txt                release notes + operator test checklist
├── payload/                 the OS filesystem, as installed
│   ├── etc/rns/             env, defaults, hostapd + dnsmasq templates
│   ├── etc/systemd/system/  rns-net, rns-dhcp, rns-ap, rns-gateway, rns-firstboot
│   └── usr/local/           bin/rns, sbin/rns-os-ctl, lib/rns/<engine>
├── iso/
│   ├── build-iso.sh         Debian netinst + payload + preseed -> bootable ISO
│   ├── preseed.cfg          the unattended install
│   └── vm/                  create-vm.sh, create-vm.ps1, VirtualBox.md
└── tools/
    ├── fetch-engine.sh      copies the engine out of ../RNS-Gateway
    ├── install-payload.sh   THE code path that assembles the image
    └── os-selftest.sh       127 checks against that exact image
```

## Test it before you trust it

```sh
tools/os-selftest.sh
```

It stages the appliance with the same `install-payload.sh` the ISO build uses,
then checks the image structure, proves engine parity with the Magisk module,
runs the platform controller, patches a synthetic Debian boot tree with the
real `build-iso.sh --patch-menu`, repairs a legacy payment row, and finally
**boots the page listener from the staged image and drives the captive portal,
the staff panel and the entire payment gateway over HTTP** — auto-verify, PDF
receipt, duplicate/invalid TID rejection, rate limiting, manual confirm and
reject.

It needs no root, no VM and no network. It covers the payment gateway because
the Magisk suite covers none of it.

## Known limits — read before deploying a shop on this

- **A VM is not a router you can hang 50 customers on.** VirtualBox NAT and
  host-only networking are fine for testing and for a handful of wired
  clients. For a real shop, put RNS-OS on the x86 mini-PC the deployment plan
  already recommends, or keep the phone as the access point.
- **Bridging a Wi-Fi host adapter does not carry multiple MAC addresses.**
  Customer devices on a bridged Wi-Fi NIC will not get leases. Use a wired
  uplink, or `wifi` mode with a passed-through dongle.
- **The Wi-Fi adapter must be supported by Linux**, not by Windows. Check
  `lsusb` inside the VM; if the dongle never appears, VirtualBox has not
  claimed it (see VirtualBox.md).
- **`preseed.cfg` ships well-known default Linux passwords** (`root`/`rnsos`).
  The staff-panel password is generated randomly on first boot, but the system
  passwords are yours to change. Do not expose this VM's SSH port to the
  internet.
