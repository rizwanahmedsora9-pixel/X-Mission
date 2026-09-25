# RNS Gateway — plan

Built 2026-09-25 from the MAGISK-RNS evidence and the RNS billing design.
Upgraded to Gateway 3.0 with a premium portal/admin UI, package builder,
searchable voucher management, client state controls, shared-storage layout,
and legacy-store migration.
This is the owner's own hotspot on a rooted Infinix HOT 8. Customers type a
voucher code. The portal does not ask for account passwords and does not
decrypt HTTPS.

## What the repository actually is

MAGISK-RNS is not an app. It is the Termux / logcat / dumpsys trail from
2026-09-23 to 2026-09-25, plus a v1.0 Magisk module that only tries to rename
the hotspot. The sister repo `rizwanahmedsora9-pixel/RNS` is a Kotlin app with
the same product idea. This module is the always-on engine plus the GUI, so
the shop still runs if that app is not open.

Proven device facts this build follows:

| Fact | Value |
|---|---|
| Phone | Infinix HOT 8, X650C, MT6765, Android 9 |
| Root | Magisk 30.7 |
| AP interface | `ap0` (`wifi.tethering.interface`). `wlan0` dies when the hotspot starts |
| Uplink | `ccmni0` (Jazz). Never hardcode `wlan0` |
| hostapd | `/vendor/bin/hw/hostapd` v2.7-devel |
| Reload tool | `/vendor/bin/hostapd_cli` exists. `kill -HUP` does not reload |
| Config file | `/data/vendor/wifi/hostapd/hostapd_ap0.conf` |
| Framework | `MtkSoftApManager` rewrites that file on every hotspot start |
| Window | file write → hostapd read is about 21 ms. A 1 second poll loses |
| DHCP | Android `dns_tether` dnsmasq on `192.168.43.x`. Do not replace it |
| Dead ends | `cmd wifi`, `cmd connectivity`, patching `services.jar` |

Target the owner already chose:

- SSID `RNS` (hex `524e53`), open, 2.4 GHz, channel 6, `max_num_sta=128`
- Keep Android's `192.168.43.x` address. Changing it caused "Obtaining IP"
- Voucher binds one MAC. Time ends → kick
- Captive sheet must be HTTP 200 HTML on the probe URL, not a redirect to another port

## What v1.0 got wrong

`infinix-hot-8-magisk-module/service.sh` polls every 1 second, rewrites the
conf every 10 seconds, and never calls `hostapd_cli RELOAD`. The zip installed.
Nothing in the repo proves the live SSID ever became `RNS`.

## Product

```
Customer joins open Wi-Fi "RNS"
        │
        ▼
Android DHCP on ap0  (we do not run a second DHCP server)
        │
        ▼
HTTP probe (generate_204 / hotspot-detect / ncsi)
        │  iptables REDIRECT tcp/80 → portal :8080
        │  tcp/443 from guests is reset, not decrypted
        ▼
Sign-in page. Customer types an 8-digit code
        │
        ▼
Code binds that MAC. FORWARD accept for that MAC only
        │
        ▼
Timer ends, or staff taps Kick → drop + deauth
```

Staff GUI is a web panel, not a second APK:

- On the phone: Magisk → RNS Gateway → **Action**
- or `http://127.0.0.1:8080/admin`
- Customers never get the admin page. It refuses non-local addresses unless
  `ADMIN_LAN=1` is turned on in settings.

## Phases

| Phase | Work | Status in this zip |
|---|---|---|
| 0 | Read the evidence, keep Android DHCP, stay on `ap0` | done |
| 1 | Patch `hostapd_ap0.conf` only when it differs, then `hostapd_cli -p /data/vendor/wifi/hostapd/ctrl -i ap0 RELOAD` | in the module, **not yet proven on the live AP** |
| 2 | Captive portal on port 8080, probe URLs return 200 HTML | built, lab-tested |
| 3 | Voucher mint, one-MAC bind, rate limit, expiry sweep, kick | built, lab-tested |
| 4 | Staff GUI: sell, codes, clients, settings | built, open the preview |
| 5 | Firewall only on `-i ap0`, IPv6 forward dropped so it cannot bypass the voucher | built, skipped in the lab |
| 6 | Best-effort `tc` cap per plan | built, no-op if `tc` is missing |
| 7 | Flash on the HOT 8 and paste `rns-ctl verify` | **you, on the phone** |

Phase 7 is the gap FINALANALYSIS already named. This zip cannot close it
from here. There is still no `iw dev ap0 info` showing `ssid RNS`.

## Files

```
RNS_Gateway.zip          flash this
module/module.prop       id RNS_Hotspot, so it replaces v1.0
module/service.sh        late_start, returns immediately
module/action.sh         Magisk Action → admin page
module/uninstall.sh      removes iptables chains, keeps vouchers
module/rns/bin/rnsd.sh   supervisor
module/rns/bin/rns-http.sh
module/rns/bin/store.sh  portable store in /sdcard/HotspotBilling/database
                             with /data/adb/rns fallback and migration
module/rns/bin/net.sh    patch, firewall, shaper
module/rns/www/portal.html
module/rns/www/admin.html
module/rns/bin/rns-httpd-arm64
module/rns/bin/rns-httpd-arm
```

Data lives in `/sdcard/HotspotBilling` when shared storage is mounted, with
`/data/adb/rns` as a safe fallback. It is not inside the module, so an update
does not wipe codes. Uninstall keeps the data unless a `PURGE` marker exists.

## Plans

| Button | Time | Default speed |
|---|---|---|
| 1 Hour | 3600 s | 2048 / 1024 kbps |
| 3 Hours | 10800 s | 2048 / 1024 kbps |
| 1 Day | 86400 s | 1024 / 512 kbps |
| 7 Days | 604800 s | 512 / 256 kbps |

Prices are blank until you type them. They are printed on the slip only.
There is no payment gateway.

## Phone checklist

1. Magisk → Modules → install `RNS_Gateway.zip` → reboot.
2. Turn the system hotspot ON.
3. Magisk → RNS Gateway → Action. Set a staff password.
4. Sell a 1 Hour code. Join `RNS` from another phone. The sign-in sheet
   should show the voucher page, not a certificate error.
5. Capture proof:

```sh
su -c 'sh /data/adb/modules/RNS_Hotspot/rns/bin/rns-ctl.sh verify'
su -c 'cat /data/vendor/wifi/hostapd/hostapd_ap0.conf'
su -c 'iw dev ap0 info'
```

Expect `ssid2=524e53`, `channel=6`, `hw_mode=g`, `max_num_sta=128`, and
`ssid RNS` from `iw`. If `hostapd_cli RELOAD` does nothing, paste the verify
output. That binary was confirmed present and was never tried with `-p`.

## If the hotspot misbehaves

- `rns-ctl.sh pause` removes the gate so clients are not stuck. Debug only.
- Remove the module and reboot. Stock tethering returns. No framework patch,
  so this is not a bootloop module.
- Do not edit `/data/misc/wifi/softap.conf` by hand. It is a 31-byte store
  and the format is not confirmed.

## Security

- Rules match `-i ap0` only. This is not an evil twin of someone else's SSID.
- Port 443 from guests is rejected until they have a voucher. It is not
  terminated or inspected.
- The page asks for a voucher code only.
- Admin is local to the phone unless you explicitly allow LAN admin.
- Eight wrong codes lock that IP for 5 minutes.
- The evidence repo contains a home Wi-Fi password in `config wifi.txt`.
  Rotate that password. It is not copied into this module.
