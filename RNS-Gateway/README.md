# RNS Gateway

Magisk module for a rooted **Infinix HOT 8**: open hotspot **RNS**, voucher
captive portal, and a premium staff panel with package builder, client controls,
searchable codes, shared-storage backups, and recovery-safe runtime data.

Flash `RNS_Gateway.zip`. Full plan: [PLAN.md](PLAN.md).
Operator notes are also inside the zip as `OPERATOR.txt`.

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
4. Magisk → **RNS Gateway** → **Action**, or open `http://127.0.0.1:8080/admin`.
5. Create a staff password. It is not shipped in the zip.

`module.prop` id is `RNS_Hotspot`, so this replaces the v1.0 patcher.

## Sell

Use **Sell** to choose any package. Gateway 3.0 includes 1 Hour, 3 Hours,
6 Hours, 12 Hours, 1 Day, 7 Days, and 30 Days. **Settings → Package builder**
can add a custom validity, download speed, upload speed, and price label.
Generate 1–100 codes at once. Codes are eight-character numeric or
alphanumeric slips; separators are optional when customers enter them.

The customer joins Wi-Fi `RNS` (no Wi-Fi password) and types the code. One
code binds to one device. **Codes** supports search, filters, Unbind, Revoke,
and Delete. **Clients** supports Kick, Ban, and Unban.

Runtime data is kept in `/sdcard/HotspotBilling/` when shared storage is
available, with `/data/adb/rns` as the early-boot fallback:

```text
HotspotBilling/
├── database/
├── logs/
├── backups/
└── exports/
```

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
