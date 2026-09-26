# Running RNS-OS in Oracle VirtualBox

This is the whole path, end to end: **get an ISO → create the VM → install →
log in → reach the panel → test a customer.** Everything below has been checked
against `create-vm.sh`, `create-vm.ps1`, `preseed.cfg` and the appliance
defaults in this repository, so the numbers here are the numbers you will see.

If you looked in the repository for an ISO and did not find one, that is
expected — read the next section.

---

## 0. There is no ISO in the repository (and how to get one)

`RNS-OS/dist/` and `*.iso` are in `.gitignore` on purpose: the Debian base
image alone is ~700 MB and git is the wrong place for it. The ISO is **built** —
and since 1.0.1 it is built for you by CI and attached to a release, so the
normal path is to download it rather than build it.

Pick one of these three routes. Route A drops the file wherever your browser
puts downloads; routes B and C leave it in the repository at:

```
RNS-OS/dist/RNS-OS-1.0.1-amd64.iso
```

### Route A — download the ISO (nothing to install)

A release is already published:

**<https://github.com/rizwanahmedsora9-pixel/X-Mission/releases/tag/rns-os-1.0.1>**

Download `RNS-OS-1.0.1-amd64.iso` (about 840 MiB) and the `SHA256SUMS` beside
it, then compare the hash — a truncated download wastes an hour of installing:

```
sha256sum -c SHA256SUMS                                # Linux / macOS
certutil -hashfile RNS-OS-1.0.1-amd64.iso SHA256       # Windows
```

To cut a fresh one yourself, push a tag and the workflow does the rest:

```
git tag -f rns-os-1.0.1 && git push -f origin rns-os-1.0.1
```

`.github/workflows/build-iso.yml` runs the appliance test suite, builds the
ISO, opens the finished image and proves the preseed and payload are inside it
(including the `rns-bb` shim the engine locks its store with), writes
`SHA256SUMS`, uploads the artifact and updates the release.

### Route B — build it on Linux or WSL

Needs `xorriso` and one download.

```
sudo apt install xorriso isolinux syslinux-utils     # Debian/Ubuntu

git clone https://github.com/rizwanahmedsora9-pixel/X-Mission.git
cd X-Mission/RNS-OS/iso
./build-iso.sh                     # downloads Debian 12 (12.15.0), verifies
                                   # it against Debian's published sha256,
                                   # builds ../dist/RNS-OS-1.0.1-amd64.iso
```

On Windows, WSL is the easy path (Windows 10/11):

```powershell
wsl --install -d Ubuntu          # once, in an Administrator PowerShell
```

then in the Ubuntu shell do the block above, but clone into your Windows
filesystem so VirtualBox can see the result:

```
cd /mnt/c/Users/<you>/Downloads
git clone https://github.com/rizwanahmedsora9-pixel/X-Mission.git
cd X-Mission/RNS-OS/iso && ./build-iso.sh
```

### Route C — build it in Docker (no toolchain on the host)

```sh
cd X-Mission
docker run --rm -v "$PWD:/w" -w /w debian:12 bash -lc '
  apt-get update -qq &&
  apt-get install -y -qq xorriso isolinux syslinux-utils curl ca-certificates >/dev/null &&
  cd RNS-OS/iso && ./build-iso.sh'
```

The result lands in `RNS-OS/dist/` on your machine.

### Why the base image is a specific Debian 12 point release

RNS-OS is built on Debian 12 (bookworm). Debian only keeps the *current*
stable in `debian-cd/current/`, and moves every older release to
`cdimage/archive/` — Debian 13 is current now, so the old
`.../current/amd64/iso-cd/debian-12.11.0-amd64-netinst.iso` URL is a 404. The
build therefore tries the archive images in order (12.15.0, then 12.11.0),
checks each download against the sha256 Debian publishes in the `SHA256SUMS`
beside it, and refuses a file that is not an ISO9660 image. You can override
all of it:

```
./build-iso.sh --base ~/debian-12.15.0-amd64-netinst.iso   # your own copy
./build-iso.sh --url https://…/debian-12.x.y-amd64-netinst.iso --sha256 <hash>
./build-iso.sh --check                                     # validate, don't burn
```

---

## 1. What you need

| | |
|---|---|
| Oracle VirtualBox | 7.0 or newer (6.1 works) |
| Host RAM | 4 GB free for the VM |
| Disk | 20 GB for the VM + ~900 MB for the ISO |
| The ISO | `RNS-OS-1.0.1-amd64.iso` — downloaded, or built into `RNS-OS/dist/` (section 0) |
| Optional | a **USB Wi-Fi dongle with a Linux driver**, for `wifi` mode |

VirtualBox 7 wants the **Extension Pack** for USB 2.0/3.0 passthrough (it is
free for personal use). Everything except Wi-Fi mode works without it.

---

## 2. Create the VM

The appliance is a router, so it gets **two** network adapters: Adapter 1 is
the internet uplink, Adapter 2 is the customer side.

### With the script (one command)

**Linux / macOS**

```sh
cd RNS-OS/iso/vm
./create-vm.sh --iso ../../dist/RNS-OS-1.0.1-amd64.iso --start
```

**Windows (PowerShell)**

```powershell
cd RNS-OS\iso\vm
.\create-vm.ps1 -Iso ..\..\dist\RNS-OS-1.0.1-amd64.iso -Start
```

Either one creates exactly this machine:

| Setting | Value |
|---|---|
| Type / version | Linux · Debian (64-bit) |
| Memory | 2048 MB (4 GB if you like; it is not needed) |
| CPUs | 2 |
| Disk | 20 GB VDI, dynamically allocated |
| Boot order | DVD, then hard disk |
| Adapter 1 | **NAT** — the internet uplink |
| Adapter 2 | **Host-only** `vboxnet0` — the customer side, on 192.168.50.2/24 so your PC sits next to the appliance |
| Port forwards | `127.0.0.1:8080 → :8080` (panel/portal) and `127.0.0.1:2222 → :22` (SSH), bound to localhost so the panel is not published to your LAN |
| USB | enabled (2.0/EHCI) for a Wi-Fi dongle later |
| ISO | attached to the SATA DVD drive |

Useful variations:

```sh
./create-vm.sh --iso FILE --lan bridged --bridge-if enp3s0   # VM on your real LAN
./create-vm.sh --iso FILE --name RNS-Test --memory 4096     # a second VM
./create-vm.sh --iso FILE --no-forward                      # no port forwards
./create-vm.sh --iso FILE --panel-port 8081                 # 8080 taken? move it
```

### By hand in the GUI

1. **New** → Name `RNS-OS` → Type *Linux*, Version *Debian (64-bit)* → Next.
2. Memory **2048 MB** → Next. (Do not pick 32-bit.)
3. **Create a virtual hard disk now** → VDI → Dynamically allocated → **20 GB**.
4. Select the VM → **Settings**:
   - *System → Motherboard*: Boot Order — keep **Optical** first, Hard Disk second.
   - *Storage*: click the CD icon → **Choose a disk file…** → your
     `RNS-OS-1.0.1-amd64.iso`.
   - *Network → Adapter 1*: **Attached to: NAT**.
   - *Network → Adapter 2*: **Attached to: Host-only Adapter**, name
     `vboxnet0` (create it if the list is empty). Take note of the name.
   - *USB*: tick **Enable USB Controller → USB 2.0 (EHCI)**.
   - *Port forwarding* (optional but recommended): *Network → Adapter 1 →
     Advanced → Port Forwarding* → add
     `panel, TCP, 127.0.0.1, 8080, , 8080` and
     `ssh, TCP, 127.0.0.1, 2222, , 22`.
5. Give the host a customer-side address. VirtualBox usually makes
   `vboxnet0` **192.168.56.1**, but the appliance serves customers on
   **192.168.50.1**, so put the host on the same subnet:

   ```
   VBoxManage hostonlyif ipconfig vboxnet0 --ip 192.168.50.2 --netmask 255.255.255.0
   ```

   (The scripts do this for you. If `vboxnet0` already existed with another
   subnet and you do not want to move it, either give your PC a second address
   `192.168.50.2/24`, or set the appliance's customer subnet to match — see
   section 6. The NAT port forwarding in step 4 works either way.)

---

## 3. Install (unattended — no keypresses)

Start the VM. `preseed.cfg` inside the ISO answers every installer question:
locale, clock (`Asia/Karachi`), disk layout (one ext4 filesystem on
`/dev/sda`), accounts, the Debian mirror, and the package list
(`dnsmasq hostapd iptables iproute2 busybox iw wireless-tools tcpdump curl …`).
At the end it copies the appliance out of the ISO into `/target`, creates the
two Android-path symlinks the shared engine still uses
(`/data/adb/rns → /var/lib/rns`, `/data/local/tmp → /var/log/rns`), enables the
five `rns-*` units and reboots.

**5–10 minutes**, depending on the mirror. When it reboots you get a login
prompt on the console.

If it ever stops at a menu, choose **Install** — the automated arguments are
already on that entry. If it boots to `FATAL: No bootable medium`, the ISO was
not attached or the disk was never installed; check *Storage* and boot order.

---

## 4. First login

```
rns-os login: root
Password:     rnsos
```

There is also a user account `rns` / `rnsos`.

**Change both immediately:**

```sh
passwd            # root
passwd rns        # the operator account
```

The first boot has already:

- created `/var/lib/rns` and the engine's store,
- generated a random **staff panel password** — printed on the console
  (`rns-firstboot` writes to the console on purpose) and stored root-only in
  `/etc/rns/admin-password.txt`,
- chosen the customer interface and written the network config,
- printed the URLs.

Three commands to know:

```sh
rns os status     # mode, interfaces, portal/panel URLs, what is running
rns os setup      # SSID, wallet numbers, shop name, customer interface
rns os diag       # one bundle (kernel, radios, units, engine verify, log tail)
```

`rns status | packages | sales | payments | mint | verify` is the billing
engine itself, the same CLI the phone build has.

---

## 5. Open the staff panel from your PC

Two independent paths — use whichever you like; both are set up by
`create-vm.sh` / step 2 above.

**A. Through NAT port forwarding (works from the machine running VirtualBox)**

```
http://127.0.0.1:8080/admin
```

If you did not add the forward, add it now in *Settings → Network → Adapter 1 →
Advanced → Port Forwarding*, or:

```
VBoxManage controlvm RNS-OS natpf1 "panel,tcp,127.0.0.1,8080,,8080"
```

**B. From the customer subnet** (your PC is `192.168.50.2`, the appliance is
`192.168.50.1`):

```
http://192.168.50.1:8080/admin     the staff panel
http://192.168.50.1:8080/          the captive portal a customer sees
```

Quick check from a terminal before you open a browser:

```sh
curl -s http://127.0.0.1:8080/health       # {"ok":true,...}
```

Log in with the generated password. Change it in *Settings → Password*.

> **Why `ADMIN_LAN=1` matters.** The panel is only served to addresses that are
> either the box itself or on the customer LAN. Through VirtualBox NAT your
> browser arrives with an address that is *not* the box, so with the phone's
> default (`ADMIN_LAN=0`) you would get *"Staff only — open this page on the
> shop phone"*. RNS-OS therefore ships `ADMIN_LAN=1`; the panel still needs the
> password. Set it to `0` if you want `/admin` to answer only from the VM
> console (`rns os config ADMIN_LAN=0`).

---

## 6. The three network modes

```sh
rns os mode wired      # customers over Ethernet on Adapter 2   (default)
rns os mode wifi       # hostapd broadcasts the SSID on a USB radio
rns os mode off        # no customer network: panel, vouchers, payments only
rns os status          # what it chose, and the URLs
```

`rns os mode` writes the setting, re-renders `hostapd.conf` / `dnsmasq.conf`
and restarts `rns-net`, `rns-dhcp` and `rns-ap`.

### `wired` (the default, and what a VM can do with no extra hardware)

Adapter 2 is the customer port, addressed `192.168.50.1/24`, DHCP
`192.168.50.20–250`. Because the host-only adapter puts your PC on the same
subnet, your PC behaves like a customer laptop — that is the mode to use for
testing the portal end to end, and it is also the right mode for a real
deployment where a separate access point does the Wi-Fi and RNS-OS is the
gateway behind it.

Check it:

```sh
ip -br addr show enp0s8        # 192.168.50.1/24
systemctl status rns-dhcp      # dnsmasq serving leases
```

### `wifi` — the VM broadcasts the SSID

A VM cannot use the laptop's built-in Wi-Fi card as an access point, so this
needs a **USB Wi-Fi dongle that Linux supports** passed through to the VM.

```
1. Plug the dongle into the host.
2. VM Settings → USB → add a filter for it, or:
     VBoxManage usbfilter add --target RNS-OS --name wifi \
       --vendorid 0x0bda --productid 0x8179
3. With the VM running: Devices → USB → tick the dongle.
4. In the VM:
     lsusb                 # it must appear
     ip -br link           # a wlan0 must appear
5. rns os mode wifi
6. rns os status          # "mode wifi", guest wlan0
   rns os diag            # the "radios" section must list wlan0
```

Realtek RTL8188/8192/8812 and Atheros AR9271 based dongles generally work. A
Windows-only dongle will never appear in `lsusb`. If `rns-ap.service` logs
"is not a wireless interface", VirtualBox has not handed the device over:
unplug it, re-add the filter, plug it back in with the VM already running.

`wifi` with no radio present is not an error — `rns-ap` logs why and exits
cleanly, and the portal, vouchers and payments keep working.

### `off`

Nothing is addressed on the customer side. Use it to work on packages,
vouchers, payments, reports and settings without touching any network.

---

## 7. Test the whole flow from your PC

With `wired` mode and the host-only adapter on 192.168.50.x, your PC is a
customer.

1. In the panel (*Settings → Package builder*) build a package — name, speed,
   a time (number + Hours/Days) and a price per hour or per day → **Save**.
2. *Sell* → pick the package → **Generate code**. Note the code.
3. From your PC open `http://192.168.50.1:8080/` — the captive portal.
4. Enter the code → browsing should start (in a VM that means the portal and
   the billing flow; gating of real internet traffic needs the uplink, which
   Adapter 1 provides).
5. *Sales* tab: the code is under Today with the right rupee total.
6. Optional, the payment gateway: *Settings → Payment gateway* → set a
   JazzCash number; *Settings → Online packages* → build one; then from the
   portal **Buy Online → pick the package → enter a TID** → internet starts and
   a PDF receipt downloads. The *Payments* tab shows it confirmed, with the
   voucher code it issued. (Auto-verify accepts 8–12 digit JazzCash TIDs and
   8–15 digit EasyPaisa TIDs, rejects a TID it has already seen, and rate-limits
   to 5 attempts per device per 10 minutes.)

---

## 8. Where things live

```
/var/lib/rns/            vouchers, clients, packages, payments, config.env
/var/lib/rns/database/   the TSV files — back these up
/etc/rns/                env, defaults, admin-password.txt, rendered confs
/var/log/rns/            gateway and dnsmasq logs
/usr/local/lib/rns/      the gateway engine (byte-identical to the Magisk module)
/etc/rns/admin-password.txt   the generated staff password (mode 600)
```

`rns backup` writes to `/var/lib/rns/backups/`, or copy
`/var/lib/rns/database/` out of the VM. A VirtualBox snapshot before a change is
the fastest rollback.

---

## 9. When something is wrong

```sh
rns os diag                                    # paste this whole output
systemctl status rns-net rns-dhcp rns-ap rns-gateway
journalctl -u rns-gateway -n 100
tail -50 /var/log/rns/rns.log
rns verify
```

| Symptom | First thing to check |
|---|---|
| VM boots to "No bootable medium" | ISO attached to the DVD drive; boot order DVD first |
| Installer stops at a menu | choose **Install** — the preseed arguments are on that entry |
| `curl: connection refused` on `127.0.0.1:8080` | is the port forward there? `VBoxManage showvminfo RNS-OS \| grep -i natpf` |
| "Staff only" instead of the panel | `grep ADMIN_LAN /var/lib/rns/config.env` — needs `1` for a browser that is not on the box |
| Panel blank | `systemctl status rns-gateway`; the page shell serves a built-in copy if the HTML is missing |
| No portal from the host | `rns os status` → is the guest interface up and addressed? Is `RNS_MODE` right? |
| Customer gets no IP | `systemctl status rns-dhcp`; is `GUEST_IF` the right adapter (`ip -br link`)? |
| SSID not visible | `lsusb` and `ip -br link` in the VM; see section 6 |
| Code works, no internet | `rns verify` → firewall rules; is there an uplink (`ip route show default`)? |
| Payment says verification failed | `rns payments` → that record's status; `tail /var/log/rns/rns.log` |

---

## 10. Honest limits

- **Do not run a real shop on VirtualBox NAT.** It is a test and development
  target. For production use the x86 mini-PC the deployment plan describes
  (`../RNS-Gateway/OPENWRT_RNS_DEPLOYMENT_PLAN.md`), or keep the phone as the
  access point.
- **Bridging a Wi-Fi host adapter does not carry multiple MAC addresses.**
  Customer devices on a bridged wireless NIC will not get leases. Use a wired
  uplink, or `wifi` mode with a passed-through dongle.
- **One radio per VM** — a second SSID needs a second dongle.
- **`preseed.cfg` ships well-known default passwords** (`root`/`rnsos`,
  `rns`/`rnsos`). Change them. The staff-panel password is generated randomly,
  but the Linux passwords are yours to change. Do not expose this VM's SSH port
  to the internet — including the `127.0.0.1:2222` forward, which is at least
  bound to your own machine.
- The guest is Debian 12 with unattended upgrades **off** (`pkgsel/upgrade
  none`); patch it yourself with `apt update && apt upgrade` if the VM lives
  long enough to matter.
