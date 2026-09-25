# X-Mission

RNS Gateway is the Magisk hotspot billing module in [`RNS-Gateway/`](RNS-Gateway/).
The source tree is kept alongside the installable `RNS_Gateway.zip` so the
module can be audited and rebuilt instead of editing an opaque archive.

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
