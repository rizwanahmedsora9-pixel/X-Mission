# RNS Gateway

Magisk module for a rooted **Infinix HOT 8**: open hotspot **RNS**, voucher
captive portal, and a premium staff panel with package builder, client controls,
searchable codes, shared-storage backups, a reliable Action launcher, and
recovery-safe runtime data.

Flash `RNS_Gateway.zip`. Full plan: [PLAN.md](PLAN.md).
Operator notes are also inside the zip as `OPERATOR.txt`.

## Downloads (release folders)

Every counted release lives in its own folder so you can download any version
to test: `../releases/v3`, `../releases/v4`, `../releases/v5`, ... New
releases count 3, 4, 5, ... (the two earlier builds that were merged before
this rule started are v1 and v2). Each folder has the flashable zip plus a
`NOTES.txt` with what changed and a test checklist.

- Current release: **v4** — [../releases/v4](../releases/v4/NOTES.txt)

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
  asserts the pages still answer.

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

## Sell

Use **Sell** to choose any package. Gateway 4.0 includes 1 Hour, 3 Hours,
6 Hours, 12 Hours, 1 Day, 7 Days, and 30 Days. **Settings → Package builder**
can add a custom validity, download speed, upload speed, and price label.
Generate 1–100 codes at once. Codes are eight-character numeric or
alphanumeric slips; separators are optional when customers enter them.

The customer joins Wi-Fi `RNS` (no Wi-Fi password) and types the code. One
code binds to one device. Android, Windows, and vendor captive-login probe
URLs all receive the portal as a direct HTTP 200 page; no probe is redirected
to the app's private port. **Codes** supports search, filters, Unbind, Revoke,
and Delete. **Clients** supports Kick, Ban, and Unban.

If a customer turns their Wi-Fi off and on, the portal reconnects them
automatically: the portal re-checks the device's firewall rules and lease IP
the moment it reappears, so the "no internet" mark clears without re-entering
the code. The staff panel is navigated by tapping the tab buttons (no swipe).

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

## Build

```sh
./tools/build.sh
./tools/selftest.sh
```

The zip's `module.prop` is at the zip root. A nested folder is what made
Magisk say "This zip is not a Magisk module!" on the first v1.0 attempt.
