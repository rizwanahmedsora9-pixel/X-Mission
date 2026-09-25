# X-Mission

RNS Gateway is the Magisk hotspot billing module in [`RNS-Gateway/`](RNS-Gateway/).
The source tree is kept alongside the installable `RNS_Gateway.zip` so the
module can be audited and rebuilt instead of editing an opaque archive.

## Build and test

```sh
cd RNS-Gateway
./tools/selftest.sh
./tools/build.sh
```

`RNS_Gateway.zip` is a Magisk module for the rooted Infinix HOT 8. It provides
an Android captive portal, voucher/MAC binding, firewall gating, a responsive
staff dashboard, custom speed/time packages, searchable codes, client state
controls, backups, and recovery-safe runtime storage.

The original uploaded workspace archive remains in the repository for
reference; active source and the rebuilt module are under `RNS-Gateway/`.
