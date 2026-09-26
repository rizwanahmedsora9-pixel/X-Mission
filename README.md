# X-Mission

Two separate products live in this repository. They share one engine but are
versioned, released and tested independently:

| | What it is | Where |
|---|---|---|
| **RNS Gateway** | Magisk module for a rooted Android phone | [`RNS-Gateway/`](RNS-Gateway/), releases in [`releases/v3 … v8`](releases/) |
| **RNS-OS** | the same gateway as a bootable Debian ISO for Oracle VirtualBox | [`RNS-OS/`](RNS-OS/README.md) |

RNS-OS is **not** a new Magisk release. It has its own version
(`RNS-OS/VERSION`, currently 1.0.1), its own release notes
(`RNS-OS/NOTES.txt`) and its own test suite (163 checks).
`RNS-OS/tools/os-selftest.sh` asserts the billing engine inside the appliance
is byte-identical to the Magisk module's, so the two product lines cannot
drift apart.

## Running RNS-OS in VirtualBox — start here

**There is no `.iso` in the repository** — `RNS-OS/dist/` and `*.iso` are
gitignored, because the Debian base image alone is ~700 MB. The ISO is built,
and the current one is published here:

**Download <https://github.com/rizwanahmedsora9-pixel/X-Mission/releases/tag/rns-os-1.0.1>**
(`RNS-OS-1.0.1-amd64.iso` + `SHA256SUMS`)

To build it yourself instead:

```sh
# A. Linux or WSL (sudo apt install xorriso isolinux syslinux-utils):
cd RNS-OS/iso && ./build-iso.sh        # -> RNS-OS/dist/RNS-OS-1.0.1-amd64.iso

# B. Docker, no host toolchain:
docker run --rm -v "$PWD:/w" -w /w/RNS-OS/iso debian:12 bash -lc \
  'apt-get update -qq && apt-get install -y -qq xorriso isolinux syslinux-utils curl ca-certificates >/dev/null && ./build-iso.sh'

# C. Let CI do it and attach the result to the release:
git tag -f rns-os-1.0.1 && git push -f origin rns-os-1.0.1
```

Then, with the ISO in `RNS-OS/dist/`:

```sh
cd RNS-OS/iso/vm
./create-vm.sh --iso ../../dist/RNS-OS-1.0.1-amd64.iso --start   # Windows: create-vm.ps1
```

The installer runs unattended (5–10 minutes), reboots by itself, and the
appliance comes up in `wired` mode on Adapter 2 — panel at
`http://127.0.0.1:8080/admin` from your PC, and on the customer side
`192.168.50.1`. Log in on the console as `root` / `rnsos` and run `passwd`.

Every GUI setting, both CLI paths, first login, Wi-Fi dongle passthrough and a
troubleshooting table: **[RNS-OS/iso/vm/VirtualBox.md](RNS-OS/iso/vm/VirtualBox.md)**.

The build pulls a specific Debian 12 point release from
`cdimage.debian.org/cdimage/archive/` (Debian moves older releases out of
`current/` the day a new stable ships — the reason the old build script could
not download anything) and verifies it against the sha256 Debian publishes.

## RNS Gateway (Magisk module)

RNS Gateway is the Magisk hotspot billing module in [`RNS-Gateway/`](RNS-Gateway/).
The source tree is kept alongside the installable `RNS_Gateway.zip` so the
module can be audited and rebuilt instead of editing an opaque archive.

Since **v8** the admin panel and the captive portal are **live-verified** at
every start: a listener that does not answer HTTP is killed and restarted on
the next working engine (compiled listener → busybox nc loops → busybox
httpd overlay), the captive redirect is installed on every hotspot interface
name at once, the staff panel opens on any device behind the password
(`ADMIN_GATE=1` restores the old IP gate), and
`su -c 'sh /data/adb/modules/RNS_Hotspot/rns/bin/rns-ctl.sh doctor'`
repairs and explains everything in one paste. Latest flashable build:
[`releases/v8/`](releases/v8/).

## Problem-solving guide

[`docs/PROBLEM-SOLVING-GUIDE.md`](docs/PROBLEM-SOLVING-GUIDE.md) records every
problem the operator reported across PRs #1–#5, the root cause we found, the
fix we shipped, and the test that now guards it — plus the problem-solving
skill set those fixes used, a playbook for the next report, and a
symptom → cause → fix triage table.

## Build and test

```sh
cd RNS-Gateway
./tools/selftest.sh
./tools/build.sh
```

`RNS_Gateway.zip` is a Magisk module for the rooted Infinix HOT 8. It provides
an Android captive portal, voucher/MAC binding, firewall gating, a responsive
staff dashboard, searchable codes, client state controls, backups, and
recovery-safe runtime storage.

Since v6 there are **no preset packages**: the operator builds every package in
Settings → Package builder — name, download/upload speed, a time entered as a
number plus an Hours/Days dropdown, and a price entered per hour or per day
that computes an editable total. A **Sales** tab reports codes generated and
codes redeemed with rupee totals for any date range, broken down by day and by
package, with CSV export.

The original uploaded workspace archive remains in the repository for
reference; active source and the rebuilt module are under `RNS-Gateway/`.
