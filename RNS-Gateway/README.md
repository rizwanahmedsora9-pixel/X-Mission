# RNS Gateway

Magisk module for a rooted **Infinix HOT 8**: open hotspot **RNS**, voucher
captive portal, and a premium staff panel with package builder, client controls,
searchable codes, shared-storage backups, a reliable Action launcher,
recovery-safe runtime data, and **JazzCash/EasyPaisa auto-payment gateway**.

Flash `RNS_Gateway.zip`. Full plan: [PLAN.md](PLAN.md).
Operator notes are also inside the zip as `OPERATOR.txt`.

## Downloads (release folders)

Every counted release lives in its own folder so you can download any version
to test: `../releases/v3`, `../releases/v4`, `../releases/v5`, `../releases/v6`, ... New
releases count 3, 4, 5, ... (the two earlier builds that were merged before
this rule started are v1 and v2). Each folder has the flashable zip plus a
`NOTES.txt` with what changed and a test checklist.

- Current release: **v7.1** — [../releases/v7](../releases/v7/NOTES.txt)

## The staff panel and the sign-in page are isolated

Most of this project is UI and gateway functions (vouchers, firewall,
shaping). Those two things used to be able to blank the staff panel and the
customer captive portal, because one script served the pages *and* the
functions. They are now separated:

- `rns/bin/rns-front.sh` is the page shell. It serves `/admin`, `/`, the
  vendor connectivity probes, and `/health`. It never sources `store.sh`,
  `net.sh`, `common.sh`, or `rns-http.sh`, and it never touches `/sdcard`
  before answering. Every page response carries `X-RNS-Front: 1`.
- `rns/bin/rns-pages.sh` starts only that listener. It is the first thing
  `service.sh`, `action.sh`, and `rnsd.sh` run.
- `/api/*` is delegated to `rns-http.sh` in a timed-out child. If that child
  is slow, broken, or has a syntax error, the page still answers and says the
  gateway functions are not responding yet.
- `admin.html` / `portal.html` are served whenever they exist and are not
  empty. If they are missing or empty, a built-in copy of each page is served
  instead, so the screen is never blank.
- `tools/isolate-check.sh` fails the build if either page starts depending on
  the function scripts again. `tools/selftest.sh` runs it, and also breaks
  `rns-http.sh`, `store.sh`, `net.sh`, and both HTML files on purpose and
  asserts the pages still answer. It then runs a copy of `service.sh` (the
  boot path) against a private data directory and asserts the staff panel,
  the portal, the captive probe, and the delegated `/api/*` all come up.

Edit the HTML, the voucher code, or the firewall freely: the two pages stay up.

## Preview

The lab server on this machine is not the phone. Firewall rules are not
installed. Staff password is `rns-admin`. A sample customer code is
`4821-9033`.

- Customer page: `/`
- Staff panel: `/admin`

## Install on the phone

1. Copy `RNS_Gateway.zip` to the phone.
2. Magisk → Modules → Install from storage → reboot.
3. Turn the Android hotspot on.
4. Magisk → **RNS Gateway** → **Action**. v4 waits for the local listener
   before opening the browser. If Android does not launch a browser, open
   `http://127.0.0.1:8080/admin` manually.
5. Create a staff password. It is not shipped in the zip.

`module.prop` id is `RNS_Hotspot`, so this replaces the v1.0 patcher.

## Packages are built by you — nothing is preset

Gateway 6.0 ships **no packages at all**. A fresh install starts with an empty
package list and the operator builds every package they sell in
**Settings → Package builder**:

| Field | What you type |
|---|---|
| Name | what the customer sees, e.g. `Fast Hour` |
| Speed DL / Speed UL | Kbps (2048 = 2 Mbps) |
| Time | a number, then **Hours** or **Days** — no fixed 1/3/5/12 hour choices |
| Price | a number, then **per hour** or **per day** |
| Total price | computed from Time × Price, and **editable** before saving |

So `3` + `Hours` at `50` + `per hour` gives a 10800 s package priced Rs 150,
and `2` + `Days` at `300` + `per day` gives 172800 s for Rs 600. A cross-unit
rate works too: 3 hours at Rs 300/day is Rs 37.50. Whatever sits in the total
box is what the slip prints and what the sales report counts — the stored price
is never recomputed behind the operator's back. Each saved package gets **Edit**
and **Delete** buttons.

Upgrading from v5 keeps the seven stock packages you already had; v6 never
deletes an existing shop's packages. Delete the ones you do not want.

Packages are stored as `id|label|seconds|down|up|price|state|rate|rate_unit`.

## Sell

Tap a package on **Sell** and generate 1–100 codes at once. Codes are
eight-character numeric or alphanumeric slips; separators are optional when
customers enter them.

## Sales report

The **Sales** tab answers "how many did we sell?" for any date range. Pick
From/To, or tap **Today**, **Yesterday**, **Last 7 days**, **Last 30 days**,
**This month**.

"Sold" is ambiguous in a shop, so the report gives both readings side by side:

- **Generated** — codes minted in the range, and their rupee total
- **Redeemed** — codes customers actually used, and their rupee total

Generated minus redeemed is unsold stock. Breakdowns are given **by day** and
**by package**, and **Export CSV** writes the same range as
`scope,key,generated,redeemed,revenue_rupees`.

Rupees are summed in **paisa as integers**, so a long month never drifts.
Two things are printed on the report rather than hidden: codes with no price
(revenue understated) and pre-v6 codes with no sale date (not counted).

Same numbers on the CLI:

```sh
su -c 'sh /data/adb/modules/RNS_Hotspot/rns/bin/rns-ctl.sh packages'
su -c 'sh /data/adb/modules/RNS_Hotspot/rns/bin/rns-ctl.sh sales'
su -c 'sh /data/adb/modules/RNS_Hotspot/rns/bin/rns-ctl.sh sales 2026-09-01 2026-09-26'
```

API: `GET /api/admin/sales?from=YYYY-MM-DD&to=YYYY-MM-DD` and
`GET /api/admin/sales.csv?from=…&to=…`, both login-gated. A date upper bound is
inclusive (it becomes the next local midnight internally); day boundaries
follow the phone's local time, converted in awk because busybox `date -d` is
not dependable across ROMs.

The customer joins Wi-Fi `RNS` (no Wi-Fi password) and types the code. One
code binds to one device. Android, Windows, and vendor captive-login probe
URLs all receive the portal as a direct HTTP 200 page; no probe is redirected
to the app's private port. **Codes** supports search, filters, Unbind, Revoke,
and Delete. **Clients** supports Kick, Ban, and Unban.

### Time, kick and ban (v7.1)

Voucher time runs **by the clock from the moment the code is entered**, not
by usage: a 1 Hour code redeemed at 13:00 ends at 14:00 whether the phone was
online for 3 minutes or 60. The portal and the Codes tab show the exact end
time. Expiry is enforced by the 15-second supervisor sweep, by
`rns-expire.sh` (fired from the page shell whenever an unpaid device probes),
and by a watchdog that restarts the supervisor if it dies. On expiry the
device's firewall rules are removed first, its flows are cut, and it is
disassociated so Android re-runs its captive check and shows "Sign in to
network" again.

- **Kick** ends the current session only. The device drops to the sign-in
  page and the next valid code (counter or online) connects it again; the
  "kicked" mark clears itself.
- **Ban** blocks the device (counter and online) until **Unban**.
- CLI: `rns-ctl.sh clients | kick <mac> | ban <mac> | unban <mac> | expire`.

If a customer turns their Wi-Fi off and on, the portal reconnects them
automatically: the portal re-checks the device's firewall rules and lease IP
the moment it reappears, so the "no internet" mark clears without re-entering
the code. The staff panel is navigated by tapping the tab buttons (no swipe).

Vouchers are stored as 13 columns:
`code|label|seconds|down|up|status|mac|ip|activated|expiry|created|note|price`.
`created` is the mint time and is the authoritative "date sold" for the report.
Stores written by v5 and earlier are migrated once on first boot (marker
`.schema13`, backup `vouchers.pre-schema13.bak`).

Runtime data is kept in `/sdcard/HotspotBilling/` when shared storage is
available, with `/data/adb/rns` as the early-boot fallback:

```text
HotspotBilling/
├── database/
├── logs/
├── backups/
└── exports/
```

If a customer's sign-in notification was dismissed, turn Wi-Fi off and on
once and tap the notification again. Use plain HTTP for the sign-in flow;
Gateway rejects guest HTTPS rather than presenting a fake certificate.

CLI, if the browser will not open:

```sh
su -c 'sh /data/adb/modules/RNS_Hotspot/rns/bin/rns-ctl.sh status'
su -c 'sh /data/adb/modules/RNS_Hotspot/rns/bin/rns-ctl.sh mint 1h 5'
su -c 'sh /data/adb/modules/RNS_Hotspot/rns/bin/rns-ctl.sh verify'
```

## Online Payment Gateway (JazzCash / EasyPaisa)

Customers without a paper voucher can pay via **JazzCash** or **EasyPaisa**
directly from the captive portal. The operator configures wallet numbers and
builds dedicated **Online Packages** in Settings.

### Auto-verify flow (default)

```
Customer joins Wi-Fi RNS → captive portal
  → taps "Buy Online"
  → picks a package
  → pays via JazzCash/EasyPaisa (exact amount)
  → enters Transaction ID (TID) from payment SMS
  → system auto-verifies:
      ✓ TID format valid (JazzCash: 8-12 digits, EasyPaisa: 8-15 digits)
      ✓ TID not already used
      ✓ Amount matches the package price
  → INTERNET ACTIVATES INSTANTLY
  → Voucher PDF receipt downloads
```

No admin intervention needed. The operator can audit payments in the
**Payments** tab and revoke any suspicious voucher later.

### Online Packages (separate from counter packages)

- **Settings → Online packages**: dedicated builder for self-service packages
- These are the ONLY packages customers see on Buy Online
- **Counter packages** (Settings → Package builder) are never exposed to customers
- Each catalogue has its own names, speeds, durations, and prices

### Configuration

| Setting | Purpose |
|---|---|
| `JAZZCASH_NUMBER` | Operator's JazzCash mobile number |
| `JAZZCASH_NAME` | Account holder name (shown to customer) |
| `EASYPAISA_NUMBER` | Operator's EasyPaisa mobile number |
| `EASYPAISA_NAME` | Account holder name (shown to customer) |
| `PAY_AUTO_VERIFY` | `1` = auto-verify (default), `0` = manual confirm |

Buy Online tab appears only when at least one wallet number AND at least one
online package are configured.

### Payment records

Stored in `payments.tsv` (16 columns):
```
pay_id | package_id | label | amount | method | tid | status | mac | ip |
created | confirmed | voucher_code | seconds | note | down | up
```

### CLI

```sh
su -c 'sh .../rns-ctl.sh payments'            # list all payments
su -c 'sh .../rns-ctl.sh pay-confirm PAY-X'   # manual confirm
su -c 'sh .../rns-ctl.sh pay-reject PAY-X'    # manual reject
```

### API endpoints

| Endpoint | Access | Purpose |
|---|---|---|
| `GET /api/pay/packages` | public | Online packages + wallet numbers |
| `POST /api/pay/submit` | public | Submit TID → auto-verify → activate |
| `GET /api/pay/status` | public | Poll payment status |
| `GET /api/pay/receipt` | device+admin | Download PDF receipt |
| `GET /api/admin/payments` | admin | List all payments |
| `POST /api/admin/pay-confirm` | admin | Manual confirm |
| `POST /api/admin/pay-reject` | admin | Manual reject |
| `GET /api/admin/online-packages` | admin | List online packages |
| `POST /api/admin/online-packages` | admin | Create/update/delete |

## Build

```sh
./tools/build.sh
./tools/selftest.sh
```

The zip's `module.prop` is at the zip root. A nested folder is what made
Magisk say "This zip is not a Magisk module!" on the first v1.0 attempt.
