# Running RNS-OS in Oracle VirtualBox

## 1. What you need

| | |
|---|---|
| Oracle VirtualBox | 7.0 or newer (6.1 works) |
| Host RAM | 4 GB free for the VM |
| Disk | 20 GB for the VM |
| The ISO | `RNS-OS/dist/RNS-OS-1.0.0-amd64.iso` |
| Optional | a **USB Wi-Fi dongle with a Linux driver**, for `wifi` mode |

VirtualBox 7 also needs the **Extension Pack** for USB 2.0/3.0 passthrough.

## 2. Build the ISO (once, on any Linux/macOS/WSL machine)

```sh
cd RNS-OS/iso
./build-iso.sh                      # downloads Debian, writes dist/RNS-OS-1.0.0-amd64.iso
./build-iso.sh --base ~/debian-12.11.0-amd64-netinst.iso   # offline
```

Needs `xorriso` (`apt install xorriso isolinux syslinux-utils`) and internet
the first time. `--check` does everything except burn, so you can validate the
inputs without writing an image.

## 3. Create the VM

**Linux / macOS**

```sh
cd RNS-OS/iso/vm
./create-vm.sh --iso ../../dist/RNS-OS-1.0.0-amd64.iso --start
./create-vm.sh --iso FILE --lan bridged --bridge-if enp3s0     # real network
./create-vm.sh --iso FILE --name RNS-Test --memory 4096        # a second VM
```

**Windows (PowerShell)**

```powershell
cd RNS-OS\iso\vm
.\create-vm.ps1 -Iso ..\..\dist\RNS-OS-1.0.0-amd64.iso -Start
.\create-vm.ps1 -Iso FILE -Lan Bridged -BridgeIf "Ethernet"
```

Both create the same machine: Debian_64, 2 vCPU, 2 GB RAM, 20 GB VDI, boot
from DVD then disk, two adapters, USB 2.0 on.

**By hand in the GUI**, if you prefer: New → Linux/Debian (64-bit) → 2048 MB →
20 GB VDI → Settings → Network: Adapter 1 = NAT, Adapter 2 = Host-only
Adapter → Settings → Storage: attach the ISO to the SATA controller →
Settings → USB: enable USB 2.0 (EHCI).

## 4. Install

Start the VM. The installer is **fully automated** — no keypresses. It
partitions the disk, installs Debian plus `dnsmasq hostapd iptables iproute2
busybox iw`, copies the appliance in, enables the units and reboots. About
5–10 minutes depending on the mirror.

If it ever stops at a menu, choose **Install** — the automated arguments are
already on that entry.

## 5. First login

Console login: `root` / `rnsos`. **Change it at once:**

```sh
passwd
```

The banner prints the staff-panel URL and the generated panel password
(also in `/etc/rns/admin-password.txt`, mode 600):

```sh
rns os status          # platform + billing status
rns os setup           # SSID, channel, guest interface, wallet numbers
rns os diag            # one diagnostics bundle for a bug report
```

Open the staff panel from the **host** browser at the URL shown — with the
default host-only adapter that is `http://192.168.50.1:8080/admin` on the VM
side, reachable from the host through `vboxnet0`.

## 6. The three network modes

Set with `rns os config RNS_MODE=...` then `systemctl restart rns-ap rns-dhcp
rns-net`.

### `off` — billing only
No customer network is addressed. Panel, vouchers, packages, payments, sales
report all work. Start here to check the appliance is healthy.

### `wired` — customers over Ethernet
`rns os config GUEST_IF=enp0s8` (the VM's second adapter; check `ip -br link`).
Plug a cable from the VM's Adapter 2 to a switch or directly to a test
machine. That machine gets a DHCP lease, sees the captive portal on port 80,
and is gated until it redeems a code.

This is the mode to use when a **real** access point is doing the Wi-Fi and
RNS-OS is only the gateway behind it.

### `wifi` — the VM broadcasts the SSID
Needs a physical USB Wi-Fi adapter passed through, because a VM cannot use the
host's internal radio as an access point.

```
1. Plug the dongle into the host.
2. VM Settings → USB → add a filter for that device
   (or: VBoxManage usbfilter add --target RNS-OS --name wifi \
        --vendorid 0x0bda --productid 0x8179)
3. With the VM running: Devices → USB → tick the dongle.
4. Inside the VM:  lsusb          (it must appear)
                  ip -br link     (a wlan0 must appear)
5. rns os config GUEST_IF=wlan0
   rns os config RNS_MODE=wifi
   systemctl restart rns-net rns-dhcp rns-ap
6. rns os diag   →  the "radios" section must list wlan0
```

The dongle needs a **Linux** driver. Airtel/Jazz/TP-Link dongles based on
Realtek RTL8188/8192/8812 and Atheros AR9271 generally work; a Windows-only
dongle will never appear in `lsusb`. If `rns-ap.service` logs "is not a
wireless interface", VirtualBox has not handed the device to the guest —
unplug it, re-add the filter, plug it back in with the VM already running.

`rns-ap.service` exiting cleanly is normal in `wired`/`off` mode, and also
when no radio is present. It never blocks the portal or the billing system.

## 7. Testing the whole flow from the host

With Adapter 2 on host-only, give the host a second address on the customer
subnet and join it as if it were a customer:

```
host:  192.168.56.1 (vboxnet0 default)   VM guest side: 192.168.50.1
```

If they are on different subnets, either set `GUEST_IP=192.168.56.10`
(`rns os config GUEST_IP=192.168.56.10`) or add a 192.168.50.x address to
`vboxnet0`. Then from the host browser:

- `http://<guest-ip>:8080/` — the captive portal. Ask for a code, enter it,
  browsing must start.
- `http://<guest-ip>:8080/admin` — the staff panel. Sell, Codes, Clients,
  Sales, Payments, Settings.
- Buy Online needs a JazzCash or EasyPaisa number **and** at least one online
  package, otherwise the tab stays hidden.

## 8. Where things live

```
/var/lib/rns/            vouchers, clients, packages, payments, config.env
/var/lib/rns/database/   the TSV files (back these up)
/var/log/rns/            gateway log, dnsmasq log
/etc/rns/                env, defaults, rendered hostapd/dnsmasq configs
/usr/local/lib/rns/      the gateway engine (same files as the Magisk module)
```

Backups: `rns backup` writes to `/var/lib/rns/backups/`, or copy
`/var/lib/rns/database/` out of the VM. A VM snapshot before a change is the
fastest rollback.

## 9. When something is wrong

```sh
rns os diag                                  # paste the whole output
systemctl status rns-net rns-dhcp rns-ap rns-gateway
journalctl -u rns-gateway -n 100
tail -50 /var/log/rns/rns.log
rns verify                                   # the engine's own diagnostics
```

| Symptom | First thing to check |
|---|---|
| Portal never appears | `rns os diag` → is the guest interface up and addressed? Is `RNS_MODE` right? |
| Clients get no IP | `systemctl status rns-dhcp`; is `GUEST_IF` the right adapter? |
| SSID not visible | `lsusb` and `ip -br link` inside the VM; see section 6 |
| Code works but no internet | `rns verify` → firewall rules; is the uplink detected? |
| Payment says verification failed | `rns payments` → status of that record; `tail /var/log/rns/rns.log` |
| Panel blank | `systemctl status rns-gateway`; the page shell serves a built-in copy if the HTML is missing |

## 10. Honest limits

- **Do not run a real shop on VirtualBox NAT.** It is a test and development
  target. For production, install the same payload on the x86 mini-PC in
  `../RNS-Gateway/OPENWRT_RNS_DEPLOYMENT_PLAN.md`, or keep the phone as the
  access point.
- **Bridged Wi-Fi does not carry multiple MACs.** Customer devices will not
  get leases on a bridged wireless host adapter. Use a wired uplink.
- **One radio per VM.** A second SSID needs a second dongle.
