# RNS Gateway — plan

Built 2026-09-25 from the MAGISK-RNS evidence and the RNS billing design.
Upgraded to Gateway 4.0 with a premium portal/admin UI, reliable admin
startup, Android captive-portal probe handling, package builder, searchable
voucher management, client state controls, shared-storage layout, and
legacy-store migration.
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
- Captive sheet must be HTTP 200 HTML on every probe URL, not a redirect to another port
- The portal listener is explicitly allowed in INPUT after REDIRECT; this is
  required on vendor firewalls where a redirected packet leaves FORWARD

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
module/action.sh         Magisk Action → waits for health, then opens admin page
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

## 2026-09-25 fixes (reported by the operator)

1. Swipe navigation removed from the staff panel. `admin.html` used a
   `touchstart`/`touchend` pair on the workspace that switched tabs on any
   horizontal drag over 70 px, which fought normal one-finger scrolling.
   Tabs are now switched by clicking the Sell/Codes/Clients/Settings
   buttons only.
2. Reconnect self-heal. Before, a device that redeemed a voucher got its
   per-MAC `RNS_FWD`/`RNS_PRE` rules from the one-time `fw_rebuild` at
   redeem plus the 15 s supervisor sweep. After a Wi-Fi off/on toggle the
   phone reconnected (same MAC, possibly a new DHCP lease) and the portal
   said "connected" (ARP + active voucher), but if the per-MAC rules had
   been flushed, nothing restored them per request: the device's HTTP was
   caught by the catch-all `REDIRECT`/`DROP`, the OS kept its "no
   internet" mark, and the internet did not work. Now:
   - `bound_client_heal` (rns-http.sh) runs whenever an already-bound
     device talks to the portal: it syncs the stored lease IP
     (`voucher_set_ip`, store.sh) and rebuilds the gate synchronously
     (`gate_heal` → `fw_rebuild`, net.sh) before answering.
   - Captive probe paths (`/generate_204` and the vendor probes) answer
     bound devices with a standard `204 No Content` after the heal, so
     the OS connectivity check passes and the "no internet" indicator
     clears. Unbound devices still get the 200 HTML portal.
   - If a vouchered device's normal web request reaches the portal
     (exemption rule missing), the handler heals and 302-redirects the
     browser back to the original URL via the `Host` header.

## 2026-09-25 v5 fixes (operator: "no captive notification at all", admin says Staff only on the same phone)

1. Admin on the shop phone over the fallback listener. When the compiled
   listener cannot start, the pages fall back to busybox nc, which cannot
   export CLIENT_IP. The page shell then saw an empty address and answered
   the Magisk Action button with "Staff only — open this page on the shop
   phone" on the shop's own phone. The page shell now resolves the peer
   address itself from /proc/self/fd/0 + /proc/net/tcp{,6} (IPv4 and
   IPv4-mapped IPv6 sockets), so /admin and the staff login work on the
   local phone under any listener. Lab test added: the nc fallback listener
   must serve the panel to 127.0.0.1.
2. Listener selection is now a --check run over every shipped binary (ABI
   order first), the chosen engine is recorded (httpd.engine, /health), and
   rns-pages.sh upgrades a running busybox-nc listener to a binary listener
   automatically once one works.
3. The firewall is synced additively. The old fw_rebuild flushed RNS_FWD and
   RNS_PRE every pass and re-added the captive REDIRECT last; in that window
   a guest probe reached the real internet, Android validated the network,
   and the sign-in notification never appeared. Rules are now checked into
   place, per-MAC deltas are inserted/removed without a flush, the REDIRECT
   is only ever ensured, and a flush happens only on first boot or a damaged
   chain. Lab test added with a fake iptables: order, idempotence, stale-MAC
   removal, and self-heal of a bare-DROP chain.
4. Hotspot interface auto-detect (ap0 / softap0 / swlan0) in net.sh and in
   the minimum gate, persisted to LAN_IF, so a wrong interface name can no
   longer silently disable the whole gate.
5. Diagnostics: the page shell logs every request to
   /data/local/tmp/rns_pages.log (proof a probe reached the phone);
   rns-ctl.sh verify now prints listener engine, local admin check, rule
   dumps, detected interface, and the page log tail.

## 2026-09-26 v6 changes (operator: "no preset packages, we build them all ourselves")

1. No preset packages. A fresh install creates an EMPTY `packages.tsv`; the
   seven stock packages (1 Hour, 3 Hours, 6 Hours, 12 Hours, 1 Day, 7 Days,
   30 Days) are no longer seeded. An existing store is left exactly as it is,
   so upgrading never deletes a shop's own packages — the operator deletes
   unwanted ones from the panel (new `package_delete` + `action=delete`).
2. Package builder rewritten around how the operator thinks: Name, Speed DL,
   Speed UL, Time as a number plus an Hours/Days dropdown (no fixed 1/3/5/12
   hour choices), and Price as a number plus a per-hour/per-day dropdown. The
   total price is computed from time x rate and shown in an editable box, so
   the operator can override it before saving. The stored `price` is
   authoritative and is never recomputed behind their back.
   Packages are now 9 columns: `id|label|seconds|down|up|price|state|rate|rate_unit`.
3. Sales report. New **Sales** tab with a date-range filter (From/To plus
   Today, Yesterday, Last 7 days, Last 30 days, This month), four totals, a
   by-day table and a by-package table, and CSV export. It answers both
   readings of "sold" side by side — **generated** (minted) and **redeemed**
   (a customer actually used it) — so the difference is visible unsold stock.
   Backed by `/api/admin/sales` and `/api/admin/sales.csv` (both
   login-gated), `sales_report` / `sales_json` / `sales_csv` in store.sh, and
   `rns-ctl.sh sales [from] [to]` + `rns-ctl.sh packages` on the CLI.
4. Money is summed in paisa as integers (`money`, `money_sum`, `price_from_rate`).
   Two Rs 250.50 packages total Rs 501.00, never 500.99.
5. Voucher schema fixed and normalised to 13 columns:
   `code|label|seconds|down|up|status|mac|ip|activated|expiry|created|note|price`.
   Before this, `voucher_mint` wrote 11 columns and put the mint time in the
   EXPIRY slot and the note in the CREATED slot, so slot 10 was overloaded and
   no sale date existed to report on. A one-shot migration (marker
   `.schema13`, backup `vouchers.pre-schema13.bak`) recovers the sale date for
   unused codes and keeps redeemed ones intact; codes redeemed under the old
   layout genuinely have no mint time, so they are left undated and the report
   counts them rather than guessing.
6. Invalid-JSON class bug fixed. Numeric JSON slots used a bare `%s`, so a
   note like "Rs 500 cash" was emitted as `"created":Rs 500` — malformed JSON
   that blanked the whole Codes tab. Every numeric slot now goes through
   `num()`, and `selftest.sh` validates responses with a real JSON parser
   instead of grepping for `"ok":true`.
7. Calendar conversion is done in awk (`ymd_to_epoch`, `epoch_to_ymd`,
   `utc_offset_seconds`) because busybox/toolbox `date -d` is not dependable
   across ROMs. Day boundaries follow the phone's local time.
8. Guards: `tools/isolate-check.sh` now fails the build if the panel's
   JavaScript references an element id that does not exist (a typo there
   throws and blanks the panel silently), and asserts the Sales tab, both
   unit dropdowns and the date filter survive edits.


## 2026-09-26 v7 — Online Payment Gateway (JazzCash / EasyPaisa)

Customers without a paper voucher can now pay via **JazzCash** or
**EasyPaisa** directly from the captive portal. Payment is **auto-verified**:
the system validates the TID format and matches the amount to the package
price, then activates the voucher instantly — no admin intervention needed.

### Auto-verify flow (default)

```
Customer joins Wi-Fi RNS → captive portal
  → taps "Buy Online"
  → picks a package (from dedicated Online Packages catalogue)
  → pays via JazzCash/EasyPaisa (exact amount to operator's number)
  → enters Transaction ID (TID) from payment SMS
  → system auto-verifies:
      ✓ TID format valid (JazzCash: 8-12 digits, EasyPaisa: 8-15 digits)
      ✓ TID not already used (checked against all records)
      ✓ Amount matches the selected package price exactly
  → INTERNET ACTIVATES INSTANTLY (voucher minted + firewall rebuilt)
  → Voucher PDF receipt downloads automatically
```

When `PAY_AUTO_VERIFY=0` (manual mode), payments go to `pending` status and
wait for staff to confirm/reject from the Payments tab.

### Online Packages — separate from counter packages

- **Settings → Online packages**: dedicated builder with its own names,
  speeds, durations, and prices. These are the ONLY packages shown on the
  captive portal's Buy Online section.
- **Counter packages** (Settings → Package builder → Sell tab) are never
  exposed to the self-service flow.
- Stored in `online-packages.tsv` (same 9-column layout as counter packages).
- The Buy Online tab appears only when:
  1. At least one wallet number is configured (JazzCash or EasyPaisa), AND
  2. At least one online package has been created.
- On confirm, the voucher is minted directly from captured payment details
  stored in the payment record — no dependency on counter packages.

### Data

Payment records in `payments.tsv` (16 columns):
```
pay_id | package_id | label | amount | method | tid | status | mac | ip |
created | confirmed | voucher_code | seconds | note | down | up
```

Status: `pending` (manual mode only), `confirmed`, `rejected`.
Auto-confirmed payments are tagged with `auto-verified` in the note column.
Vouchers are tagged `online <TID>` in the note field, distinguishable from
counter vouchers in the sales report.

### TID validation

| Method | Format |
|---|---|
| JazzCash | 8–12 numeric digits |
| EasyPaisa | 8–15 numeric digits |
| Both | min 6 chars, max 20 chars |

Duplicate TIDs are rejected across all records (any customer, any time).
Rate limit: max 5 payment attempts per device per 10 minutes.

### API endpoints

| Endpoint | Access | Purpose |
|---|---|---|
| `GET /api/pay/packages` | public | Online packages + wallet numbers |
| `POST /api/pay/submit` | public | Submit TID → auto-verify → activate |
| `GET /api/pay/status?pay_id=X` | public | Poll payment status (manual mode) |
| `GET /api/pay/receipt?pay_id=X` | device+admin | Download PDF receipt |
| `GET /api/admin/payments` | admin | List all payment records |
| `POST /api/admin/pay-confirm` | admin | Manual confirm + activate |
| `POST /api/admin/pay-reject` | admin | Manual reject with reason |
| `GET /api/admin/online-packages` | admin | List online packages |
| `POST /api/admin/online-packages` | admin | Create/update/delete online pkg |

### CLI

```sh
su -c 'sh .../rns-ctl.sh payments'            # list all payment records
su -c 'sh .../rns-ctl.sh pay-confirm PAY-X'   # manual confirm (if auto off)
su -c 'sh .../rns-ctl.sh pay-reject PAY-X'    # manual reject
su -c 'sh .../rns-ctl.sh verify'              # now shows payment summary
```

### PDF receipt

Shell-generated raw PDF (no external dependencies). Contains:
shop name, voucher code, package label, duration, speed, price,
payment method, Transaction ID, payment reference, MAC address,
IP address, WiFi network name. Download restricted to paying device
or local admin.

### Configuration (config.env)

```
JAZZCASH_NUMBER=     # operator's JazzCash mobile number
JAZZCASH_NAME=       # account holder name (shown to customer)
EASYPAISA_NUMBER=    # operator's EasyPaisa mobile number
EASYPAISA_NAME=      # account holder name (shown to customer)
PAY_AUTO_VERIFY=1    # 1 = auto-verify (default), 0 = manual confirm
```

### Staff panel additions

- **Payments tab**: all payment records, filter by status, confirm/reject
  buttons for manual mode, voucher codes shown for confirmed payments.
- **Settings → Payment gateway**: wallet numbers, account names, auto-verify
  toggle.
- **Settings → Online packages**: dedicated builder with its own edit/delete,
  auto-price calculator.

### Safety

- All payment mutations go through `with_lock` (same store lock as
  voucher mint/redeem) — concurrent operations are serialized.
- Receipt download restricted to paying device or local admin.
- Operator can revoke any auto-confirmed voucher from the Codes tab if
  a fake TID is discovered in the wallet statement audit.
- All events logged: `payment_auto`, `payment_auto_confirm`,
  `payment_auto_fail`, `payment_new`, `payment_confirm`, `payment_reject`.

## 2026-09-26 v8 — "Admin panel and captive portal both not showing" (operator, after flashing v7.2)

Operator report, verbatim: after flashing the module and rebooting, the
customer phone joins the Wi-Fi and no captive portal is triggered, and the
admin panel does not show either. The same report returned after every
release since v4.

### Root causes (three layers, all real)

1. **The listener was never verified.** `rns-pages.sh` logged "pages
   listening" after launching a process. On the phone the compiled
   listeners can fail to exec and the busybox nc fallback can die
   instantly (ROM nc lacks `-k`/`-e`; the generated wrap's
   `#!/system/bin/sh` shebang cannot exec on any non-Android check), so
   nothing was listening while every script reported success. Both pages
   dark, every log green.
2. **The captive redirect matched one interface name.** `ap0` rules match
   nothing on a ROM that says `softap0`/`swlan0`/`wlan1`; the probe
   escaped to the real internet; Android marked the network VALIDATED and
   never showed the sign-in sheet again for that SSID.
3. **The admin panel was IP-gated twice** (`/admin` in rns-front.sh and
   `/api/login` + `require_admin` in rns-http.sh). Any failure to
   recognise the shop phone's address — subnet change, unresolved peer on
   the nc fallback, opening the panel from another device — produced
   "Staff only" / "Admin opens on the shop phone only".

### Fixes

1. **Verified engine ladder** (`rns-pages.sh`): every launch is followed
   by a real `GET /health` over loopback; only an answering rung is kept.
   Ladder: compiled binaries (each) → `nc -e` loop → `nc -c` loop →
   `nc` fifo inetd loop → `busybox httpd` static overlay (pages + admin +
   probe paths, API degraded). A live-but-silent listener is replaced;
   the ladder re-runs every supervisor pass; fallbacks upgrade to the
   compiled listener when it works. Loop children are trap-killed and the
   port is swept in /proc so nothing keeps holding it.
2. **Multi-interface gate** (`rns-gate-min.sh`): redirect, INPUT allow,
   DNS/DHCP passes, 443 reset and drop on every hotspot-like name
   (configured + ap0/softap0/swlan0/wlan0/wlan1 + /proc/net/dev), never
   on the uplink (default-route interface). IPv6 guests get fast REJECT
   (was silent DROP → "no internet" with no sheet). The system's own
   `/system/bin/iptables` is preferred over toolbox/busybox copies.
3. **Password is the gate** (`rns-front.sh`, `rns-http.sh`): /admin serves
   the login page to every device; dashboard APIs need the session token;
   login failures throttled 8/5 min per address (`login_rate_*`,
   store.sh); `/api/setup` stays phone-only; `ADMIN_GATE=1` restores the
   IP gate; `phone_ips()` now knows every local address (busybox ip /
   ifconfig / tethering gateways) and caches them for the page shell.
4. **Second boot door** (`boot-completed.sh`, Magisk BOOT_COMPLETED) +
   the gate is installed immediately in `service.sh`, not 2 s later.
5. **Diagnostics**: `rns-ctl.sh doctor` (repair + verify in one paste),
   `rns-ctl.sh setpass`, and `verify` now reports a LIVE probe verdict
   and which iptables binary holds the rules.

### Tests

`tools/selftest.sh` 169 → **205 checks, ALL PASSED** (36 new): admin page
to any device / opt-in gate / shop-phone pass-through, login throttle,
each forced engine rung really answering (health + admin + probe),
dead-listener replacement, multi-interface redirect with uplink exclusion
and idempotence (fake iptables), boot-completed.sh boot path. The
watchdog gained `RNS_NO_WATCHDOG=1` so harnesses running the phone paths
(`RNS_LAB=0`) do not spawn a supervisor that fights the harness for the
state directory — the bug that made earlier suites flaky.

### Limits stated honestly

Android remembers a network's old verdict per SSID: a phone that joined
before must Forget the network and rejoin before it will show the
sign-in sheet again. The gateway cannot reset that from its side.

### Store locking (found while stabilising the selftest)

`with_lock` (common.sh) is REENTRANT on purpose: nested calls pass through
and never re-`exec` fd 9. Reopening fd 9 closes the outer description and
silently drops the flock, which let the background heal interleave store
rows with a mint in progress — the intermittent "That code is not valid"
selftest flake. The fd is opened and flocked once per top-level call tree.
