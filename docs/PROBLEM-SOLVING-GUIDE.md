# RNS Gateway — Problem-Solving Guide

Every problem the operator reported, the root cause we found, the fix we
shipped, and the test that now proves it — for **PRs #1 through #6**
(releases v1/v2 baseline → v4 → v3 → v4 → v5 → v6), **PR #11** (v7.x) and
**PR #12** (v8), plus the separate RNS-OS appliance line (**PR #10**,
RNS-OS 1.0.1).

Part 2 distills the **problem-solving skill set** those PRs actually
used. Part 3 is the playbook to follow for the *next* problem. Part 4 is the
symptom → cause → fix triage table.

Covers **PRs #1–#6**, **#10**, **#11** and **#12**. Last verified:
2026-09-26 on branch `arena/01a0dd77-x-mission`
(`cd RNS-Gateway && ./tools/selftest.sh` → **205 checks, ALL PASSED**;
`./tools/build.sh` → zip payload identical to `module/`, `module.prop` at
the zip root, x86 lab listener excluded).

RNS-OS, verified the same day on branch `arena/01a0dc4d-x-mission`
(`cd RNS-OS && sh tools/os-selftest.sh` → **163 checks, ALL PASSED**). The ISO
build and the VM creation are **not** covered end to end: see the PR #10 case
below for what is tested instead, and why.

---

## Part 0 — PR ↔ release map (read this first)

The release numbering and the PR numbering do **not** line up. PR #2 shipped
the *v4* module, and the very next PR (#3) introduced versioned release
folders starting at *v3*. That mismatch cost debugging time, so it is written
down here.

| PR | Title | Release shipped | Reported problem |
|---|---|---|---|
| [#1](https://github.com/rizwanahmedsora9-pixel/X-Mission/pull/1) | Upgrade RNS Gateway hotspot billing module | baseline (v1/v2 builds) | Opaque zip, no source, no tests |
| [#2](https://github.com/rizwanahmedsora9-pixel/X-Mission/pull/2) | RNS Gateway v4: fix admin launcher and captive portal | `4.0 / 40` | Action button does not open admin; captive page never appears |
| [#3](https://github.com/rizwanahmedsora9-pixel/X-Mission/pull/3) | RNS Gateway v3: release folders + swipe removal + reconnect self-heal | `releases/v3` (3.0) | Swipe fights scrolling; Wi-Fi toggle kills internet; no way to fetch an old build |
| [#4](https://github.com/rizwanahmedsora9-pixel/X-Mission/pull/4) | Isolate the admin panel and captive portal from voucher/firewall/UI code | `releases/v4` (4.0 / 40) | Both pages keep going blank after unrelated edits |
| [#5](https://github.com/rizwanahmedsora9-pixel/X-Mission/pull/5) | RNS Gateway v5: admin opens on the shop phone; captive notification fixed | `releases/v5` (5.0 / 50) | "Staff only" on the shop's own phone; no captive-portal notification on customer phones |
| #6 | No preset packages; package builder with time/price units; dated sales report | `releases/v6` (6.0 / 60) | Feature request — plus two latent bugs it uncovered |
| [#10](https://github.com/rizwanahmedsora9-pixel/X-Mission/pull/10) | RNS-OS 1.0.1: build the ISO in CI, and make a fresh VM install work unattended | RNS-OS `1.0.1` | "How to run RNS OS in VirtualBox — I can see no ISO image" |
| [#11](https://github.com/rizwanahmedsora9-pixel/X-Mission/pull/11) | RNS Gateway v7.2: clock-based expiry, kick/unkick, voucher PDF, sidebar UI | `releases/v7` (7.2 / 72) | Voucher time ran on use; no sign-in page after expiry; kick = ban |
| [#12](https://github.com/rizwanahmedsora9-pixel/X-Mission/pull/12) | RNS Gateway v8: live-verified pages, multi-interface gate, admin behind password | `releases/v8` (8.0 / 80) | "admin panel and captive portal both not showing … no captive portal triggered" — the recurring report |

Rule adopted in PR #3 and kept since: **every counted release gets its own
folder** `releases/vN/` containing the flashable zip **and** a `NOTES.txt`
with install steps + a test checklist, and `module.prop` carries the matching
`version` so the operator can see in Magisk which build is actually running.

---

# Part 1 — Case studies

Each case follows the same seven fields:
**Symptom → Evidence → Root cause → Fix → Test that proves it → Lesson → Guard.**

---

## PR #1 — From an opaque zip to an auditable source tree

**Symptom.** The whole product was a 550 KB `RNS_Gateway.zip` with no source
tree beside it. Nothing could be audited, diffed, tested, or rebuilt — every
change meant editing an archive by hand. The only earlier artifact,
`infinix-hot-8-magisk-module/service.sh`, polled every 1 s, rewrote the
hostapd conf every 10 s, and never called `hostapd_cli RELOAD`; nothing in
that repo ever proved the live SSID became `RNS`.

**Evidence.** `PLAN.md` records device facts taken from the actual
Termux / logcat / dumpsys trail of 2026-09-23 → 2026-09-25 instead of
assumption:

| Fact | Value |
|---|---|
| Phone | Infinix HOT 8, X650C, MT6765, Android 9 |
| Root | Magisk 30.7 |
| AP interface | `ap0` — `wlan0` **dies** when the hotspot starts |
| Uplink | `ccmni0` (Jazz). Never hardcode `wlan0` |
| hostapd | `/vendor/bin/hw/hostapd` v2.7-devel; `kill -HUP` does **not** reload |
| Reload tool | `/vendor/bin/hostapd_cli` with `-p /data/vendor/wifi/hostapd/ctrl -i ap0` |
| Config file | `/data/vendor/wifi/hostapd/hostapd_ap0.conf`, rewritten by `MtkSoftApManager` on **every** hotspot start |
| Race window | file write → hostapd read ≈ **21 ms**; a 1 s poll loses |
| DHCP | Android `dns_tether` dnsmasq on `192.168.43.x` — do not replace it |
| Dead ends | `cmd wifi`, `cmd connectivity`, patching `services.jar` |

**Root cause.** No source of truth and no test harness, so no claim about
behaviour could be checked. Also a packaging defect from the v1.0 attempt:
`module.prop` sat in a **nested folder** inside the zip, which is what made
Magisk say *"This zip is not a Magisk module!"*

**Fix.**
- Promoted the archive into a real tree: `module/` (flashable payload),
  `src/rns-httpd.c` (listener source), `tools/build.sh`, `tools/selftest.sh`,
  `lab-data/` (seeded vouchers, clients, sessions, logs).
- Product upgrades: responsive staff panel, package builder (custom
  time/speed), batch mint up to 100 codes, voucher search + filters, client
  state controls (Kick / Ban / Unban / Unbind with history preserved),
  shared-storage runtime layout `/sdcard/HotspotBilling/{database,logs,
  backups,exports}` with `/data/adb/rns` early-boot fallback and migration,
  health checks, recovery handling.
- `module.prop` id stays `RNS_Hotspot` so a new build **replaces** the v1.0
  patcher rather than installing beside it.
- `build.sh` zips from inside `module/` so `module.prop` lands at the zip
  root, and excludes the x86_64 lab listener from the phone zip.

**Test that proves it.** `./tools/selftest.sh` (lab mode, `RNS_LAB=1` — it
never touches real `iptables`), `./tools/build.sh`, `unzip -t`.

**Lesson.** *Make it auditable before making it better.* A lab harness that
runs on a laptop (`RNS_LAB=1`, `/usr/bin/busybox`) is what made every later
fix provable in minutes instead of a flash-and-pray cycle on the phone.

**Guard.** The zip layout is asserted at build time (`build.sh` refuses to
finish without arm + arm64 listeners, prints `unzip -l`); the PR states
plainly what was **not** verified: live hostapd / firewall behaviour still
needs the physical HOT 8. Cross-compilers are absent in the sandbox, so the
existing ARM listeners are deliberately retained instead of silently dropped.

---

## PR #2 — Admin launcher + captive portal on a real Android 9 ROM
*(shipped as module `4.0 / 40`)*

**Symptom.** Magisk → RNS Gateway → **Action** did not bring up the staff
panel; customer phones never saw a sign-in page; some probes got a redirect
to a private port and a certificate error instead of the portal.

**Evidence / root causes** (five separate ones — this was never a single bug):
1. `action.sh` opened the browser **before** anything was listening, and did
   not wait for `/health`.
2. The browser launch used the wrong user/intent flags for this ROM, and
   Android 9 / Infinix builds disagree about `--user` and the default browser.
3. Boot race: `service.sh` (late_start) could be missed entirely, and the
   supervisor had no pid handling.
4. **Firewall:** after `REDIRECT`, the packet traverses **INPUT**, not
   FORWARD. Without an explicit `RNS_IN` ACCEPT for the portal port on the
   hotspot interface, vendor firewalls dropped the redirected probe — the
   portal was listening and still unreachable.
5. **Probe contract:** captive probes must get **HTTP 200 HTML on the probe
   URL itself**. Redirecting a probe to another port/host makes the OS show a
   certificate error or mark the network "no internet". `HEAD` requests were
   also mishandled, and a captive-login WebView with JavaScript disabled had
   no way to submit a code.

**Fix.**
- `action.sh`: start the page listener first, poll `/health` (up to 8 × 1 s)
  with `curl` → `busybox wget` → `nc -z` fallbacks, then launch the browser as
  **user 0** with a chain of intents (`am start --user 0 -f 0x14000000 …`,
  then `-f 0x10000000`, then `cmd activity start-activity`, then four known
  browser components: Chrome, AOSP browser, Chrome IntentDispatcher, Via).
  If service startup was missed, recover by starting the guarded supervisor.
- Detach background work with `setsid` (or a `trap '' HUP` subshell when
  `setsid` is missing) so the Action returning cannot kill the listener.
- `net.sh`: explicit `-A RNS_IN -i <lan> -p tcp --dport <portal> -j ACCEPT`
  plus a loopback allow; fast `ap0` transition sync.
- `rns-http.sh`: serve Android (`generate_204`), Windows (`ncsi.txt`,
  `connecttest.txt`), Apple (`hotspot-detect.html`) and vendor probe paths as
  **direct 200 HTML**; correct `HEAD`; no-JS `<form action="/api/redeem">`
  fallback in `portal.html`.

**Test that proves it.** Shell syntax checks; `selftest.sh` gained admin-page,
HEAD-probe, vendor-probe, no-JS redeem, auth, mint, search, client-state and
backup tests; `build.sh`; `unzip -t`; and the zip payload was diffed against
the source tree to confirm it matched **and** excluded the x86 lab listener.

**Lesson.** *Read the platform's contract, not your intention of it.* Android
decides "captive" vs "verified" by a documented probe behaviour; and NAT'd
packets change chain traversal. Both are rules of the platform, discovered
from device evidence and written into `PLAN.md` so they stop being
rediscovered.

**Guard.** Probe-path handling and HEAD/no-JS paths are permanent selftest
checks; the INPUT allow is part of the rule set that later PRs assert by
order (`allow < base < drop`).

---

## PR #3 — Versioned releases, swipe removal, reconnect self-heal
*(shipped as `releases/v3`, module 3.0)*

**Symptom (three reports).**
1. Tabs in the staff panel jumped by themselves while scrolling a table or
   typing a code.
2. After a customer toggled Wi-Fi off/on, the phone said **connected**, the
   portal said the voucher was active — but the "no internet" mark stayed and
   nothing worked. The customer had to buy/enter a code again.
3. There was no way to download an older build to compare, and no way to tell
   from the phone which version was running.

**Root cause.**
1. `admin.html` bound `touchstart`/`touchend` on the workspace and switched
   tabs on any horizontal drag > 70 px — which fights normal one-finger
   scrolling on a phone.
2. A bound device got its per-MAC `RNS_FWD` / `RNS_PRE` rules from a
   **one-time** rebuild at redeem plus a 15 s supervisor sweep. If those rules
   were flushed in between (vendor stack, half-finished rebuild, DHCP lease
   change), *nothing restored them per request*: the device's HTTP hit the
   catch-all `REDIRECT`/`DROP`, the OS kept its "no internet" verdict, and the
   sweep was too slow to matter to the human watching the screen.
3. Process gap, not a code gap.

**Fix.**
1. Swipe navigation deleted. Tabs change **only** by tapping Sell / Codes /
   Clients / Settings.
2. **Synchronous self-heal on the request path**:
   - `bound_client_heal` (`rns-http.sh`) runs whenever an already-bound device
     talks to the portal: syncs the stored lease IP (`voucher_set_ip`,
     `store.sh`) and rebuilds the gate (`gate_heal` → `fw_rebuild`, `net.sh`)
     **before** answering.
   - Captive probes (`/generate_204` + vendor probes) from a bound device
     answer `204 No Content` after the heal → the OS connectivity check
     passes → the "no internet" mark clears. Unbound devices still get the
     200 HTML portal.
   - A vouchered device whose normal web request reaches the portal (proof its
     exemption rule is missing) gets healed and `302`-redirected back to the
     original URL via the `Host` header.
3. `releases/vN/` folders with zip + `NOTES.txt`; `module.prop` version bumped
   so the flashed release is visible in the Magisk module list.

**Test that proves it.** `selftest.sh` 31/31 (5 new reconnect checks), plus a
live lab run under the `rnsd` supervisor: redeem → connect → simulated Wi-Fi
toggle → reconnect (204 probe + `bound:true` + browse bounce-back), unbound
devices still captive, supervisor loop healthy, no errors in `rns.log`. Zip
contents verified against the source tree.

**Lesson.** *A background sweep is not a repair path.* The system has to heal
at the moment the user touches it — synchronously, on the request — because
that is the only instant the human can observe. And: *make the artefact
self-identifying* (version in `module.prop`) so "which build is on the phone?"
is never a question again.

**Guard.** Reconnect behaviour is a permanent selftest section; release
folders + `NOTES.txt` checklists are now the shipping convention.

**Known limit stated honestly.** Android **remembers** an old "verified"
verdict per network. If the sign-in sheet was already dismissed on a customer
phone, that phone must **forget** the network and rejoin. We cannot reset that
from our side, so it is written into the operator checklist instead of being
pretended away.

---

## PR #4 — Isolate the pages from the functions (blank panel / blank portal)

**Symptom.** The staff admin panel and the customer captive portal kept going
**blank** after unrelated work on the gateway — voucher edits, firewall edits,
UI edits.

**Evidence / root cause — shared fate.** Both pages were served by the *same*
script that handles vouchers, login and the firewall (`rns-http.sh`), and
`rnsd.sh`, `action.sh`, `service.sh` all sourced `store.sh` / `net.sh` /
`common.sh` **before** any HTML or browser launch. Therefore:
- a syntax error or runtime failure in any of those files ⇒ empty response;
- `/sdcard` `mkdir` / `[ -w ]` under `RNS_DATA_AUTO=1` could block *before*
  bind or `am start`;
- probe paths called voucher lookup and `fw_rebuild` before serving HTML;
- `fw_ensure` returned 1 when `ip6tables` was missing, so on such a phone the
  captive redirect was **never installed at all**.

**Fix — separated serving path.**
- New `rns/bin/rns-front.sh` **page shell**: serves `/admin`, `/`, the vendor
  probes, `/health`. It never sources `store.sh`, `net.sh`, `common.sh` or
  `rns-http.sh`, and never touches `/sdcard` before answering. Every response
  carries `X-RNS-Front: 1` so you can *see* which path answered.
- New `rns/bin/rns-pages.sh` starts **only** that listener, and is the
  **first** thing `service.sh`, `action.sh` and `rnsd.sh` run.
- `/api/*` is delegated to `rns-http.sh` in a **timed-out child**. If that
  child is slow, broken, or has a syntax error, the page still answers and
  shows "gateway functions are not answering yet" instead of going blank.
- **Never blank:** `admin.html` / `portal.html` are served whenever they exist
  and are non-empty (so editing HTML still works); if missing or empty, an
  **embedded copy** of each page is served.
- Specific blockers fixed: `fw_ensure` no longer aborts on missing
  `ip6tables` (IPv4 redirect goes in, the missing tool is only logged);
  `rns-gate-min.sh` **never flushes** and only adds the captive drop when one
  is missing, so the minimum gate cannot wipe a paying customer's allow rules
  while the full firewall rebuilds; the supervisor runs the worker **before**
  the min-gate in the same pass so the redirect is restored immediately.
- Defensive logging: `action.sh` / `service.sh` pick a log path that can
  actually be opened (`/data/local/tmp` else `$RNS_DATA`), and the page launch
  is retried with `>> /dev/null` — a log that cannot be opened must never stop
  the pages.

**Testing the boot path found three more real defects** (none of them the
reported symptom):
- `service.sh` ran `sh busybox script` — busybox was being read *as a script*,
  so the supervisor and the captive redirect **never started at boot**.
- `action.sh` / `service.sh` redirected to `/data/local/tmp/rns_hotspot.log`
  before starting the pages; an uncreatable directory made the redirect fail
  and the pages never launched.
- `rns-pages.sh` always used `/data/adb/rns` for pid/mode files, so an
  unwritable state dir made every supervisor pass try to relaunch the listener.

**Test that proves it.** `selftest.sh` — **49 checks, ALL PASSED** (10 new
isolation + boot-path checks). The harness **breaks things on purpose**:
it corrupts `rns-http.sh`, `store.sh`, `net.sh`, `admin.html`, `portal.html`
(restoring them on `EXIT`), then asserts both pages still answer, the probe
still returns the portal, `/health` still responds and the delegated API still
returns JSON. Finally it runs a **copy of `service.sh`** (the real boot path)
against a private data dir and asserts panel, portal, probe and API all come
up.

**Lesson.** *Isolate the blast radius.* The UI/observability plane must not
share fate with the function plane — a broken voucher script must never be
able to blank the page that reports it. And *deliberate breakage testing*
found three production defects that no amount of "does it work when nothing is
broken?" testing would have surfaced.

**Guard.** `tools/isolate-check.sh` **fails the build** if either page starts
depending on function code again (it greps for sourced function scripts, for
the embedded fallbacks `Staff login` / `Welcome online`, for the no-JS
`action="/api/redeem"` form, and that `rnsd.sh` no longer launches the
function handler as the page server). `build.sh` runs it first; `selftest.sh`
runs it too.

---

## PR #5 — Admin opens on the shop phone; captive notification restored
*(shipped as `releases/v5`, module 5.0 / 50)*

Two operator reports, verbatim:
> A. "The admin portal does not open from the Magisk Action button — my own
> phone shows *'Staff only — open this page on the shop phone'*."
> B. "The captive portal never gives a notification on the customer phone."

### Case A — "Staff only" on the shop's own phone

**Symptom.** `/admin` refused the device that *is* the shop phone, via the
Magisk Action button.

**Evidence.** `/health` and the new engine record showed the phone was not
running the compiled listener at all — it was on the **busybox `nc`
fallback**. The compiled listener could not start on this device, and
`pick_httpd` had only ever tried the binary matching `ro.product.cpu.abi`.

**Root cause (two layers).**
1. *Trust depended on the listener.* The page shell only knew the peer address
   when the listener exported `CLIENT_IP`. `busybox nc -e` cannot export it, so
   `CLIENT_IP` was empty, `is_shop_ip ""` was false, and the shell printed
   "Staff only" to its own device — and the staff **login API** used the same
   empty address, so signing in was impossible too.
2. *Capability detection trusted a property.* The ABI property can lie —
   32-bit userspace on a 64-bit kernel is common on budget phones — so the
   "matching" binary was the one that failed, and the working one was never
   tried.

**Fix.**
- `self_peer_ip()` in `rns-front.sh` resolves the peer **from the kernel**:
  read the socket inode from `/proc/self/fd/0` (`socket:[NNN]`), find it in
  `/proc/net/tcp` **or** `/proc/net/tcp6` (an IPv4 listener lands in `tcp`; a
  listener bound to `::` carries IPv4 clients as **mapped** addresses in
  `tcp6`), take the 32-hex mapped word's last 8 chars when needed, and decode
  the little-endian hex into dotted quad. Used only when `CLIENT_IP` is unset,
  and it **fails closed**: prints nothing ⇒ the admin gate stays shut.
- `pick_httpd()` now runs `--check` (a two-line mode added to `rns-httpd.c`
  that prints `ok` and exits 0) against **every shipped binary**, ABI order
  first, before falling back to `nc`.
- `record_engine()` writes the chosen engine to `$STATE/httpd.engine` and
  `$RNS_HOME/engine`; `/health` reports it.
- **Auto-upgrade:** if a healthy listener is already up but its engine is
  `busybox-nc`, and a binary now passes `--check`, `rns-pages.sh` kills the
  fallback (TERM, `sleep 1`, KILL) and relaunches on the real listener. The
  fallback is a lifeboat, not a destination.
- `page_log()` writes one short line per request to
  `/data/local/tmp/rns_pages.log` (rotated at 200 KB), so "did the customer's
  probe even reach this phone?" becomes a fact instead of a debate.

**Test that proves it.** New selftest section runs the fallback **exactly like
the phone does** — `RNS_LAB=0`, a wrapper that deliberately does **not** set
`CLIENT_IP`, `nc -lk -p PORT -e wrap` — then asserts: admin returns 200 with
`X-RNS-Front: 1`, the body contains `Staff login` and **not** `Staff only`,
`POST /api/login` returns `{"ok":true}`, and a probe still returns the portal.

### Case B — no captive-portal notification on customer phones

**Symptom.** Customer joins `RNS`, gets Wi-Fi, and the "Sign in to network"
notification never appears — or appears once and never again.

**Root cause (a race, plus a portability landmine).**
1. `fw_rebuild` **flushed** `RNS_FWD` and `RNS_PRE` on every pass (every 15 s
   and on every heal) and re-appended the captive `REDIRECT` **last**. In that
   window a guest's connectivity probe went straight out to the real internet,
   got a genuine "internet OK", and Android marked the network **VALIDATED**.
   Once validated, Android does not show the sign-in notification for that
   network again — a *permanent* symptom caused by a *millisecond* window, and
   invisible in any single rule dump taken after the fact.
2. If a ROM names the hotspot interface anything other than `ap0`
   (`softap0`, `swlan0`), **every** rule matched nothing and the gate was
   silently disabled.

**Fix.**
- `fw_rebuild` is now an **additive sync** — converge to the desired state
  without ever passing through an unprotected state:
  - the captive `REDIRECT` is only ever `-C`hecked and `-A`dded, **never
    flushed**;
  - base rules (DNS/DHCP `RETURN`, `443 REJECT --reject-with tcp-reset`,
    catch-all `DROP`) are checked in canonical order; a full `-F` rebuild
    happens **only** on first boot or when the chain is found **damaged**;
  - `_fw_sync_macs` diffs `iptables -S` output against the wanted-MAC list:
    stale per-MAC rules are `-D`eleted, missing ones `-I`nserted at position
    **1** (ahead of the base rules), in both `RNS_FWD` and nat `RNS_PRE`. No
    flush, so paying customers never lose their allow rule mid-pass.
- `lan_if()` **auto-detects** the hotspot interface (`ap0` → `softap0` →
  `swlan0`) when the configured one does not exist, persists it to `LAN_IF`,
  and logs the substitution. `rns-gate-min.sh` detects it too.
- `rns-ctl.sh verify` was turned into a one-paste diagnosis: serving
  **engine**, a **loopback admin check** that prints `ok: staff panel opens
  locally` or `BROKEN: admin refused the local phone`, the **detected
  interface** plus every hotspot-like interface on the device, the **actual
  rule dumps** (`nat RNS_PRE`, `RNS_FWD`, `RNS_IN`), the **page request log**
  tail, hostapd conf, `/health`, and log tails.

**Test that proves it.** A **fake `iptables`** shell script (a test double
keeping rules in files, implementing `-N -X -C -A -I -D -F -S`) lets the
firewall be asserted in the lab: redirect installed, active device allowed,
**rule order `allow < base < drop`**, HTTPS reset before drop, **idempotence**
(a second rebuild adds no duplicates), expired device's allow removed,
**redirect survives device churn**, and a **damaged chain** (only a bare
`DROP` left) **self-heals in order**. 60 checks total, ALL PASSED.

**Lesson.** *Destructive rebuilds create windows; additive sync removes them.*
When the broken state lasts milliseconds, you cannot debug it by observing —
you can only debug it by **reasoning about ordering** and then encoding that
ordering in a test double. And *never trust a name, a property, or a path*:
probe for capability, auto-detect, persist what you found, and log the
substitution.

**Guard.** The fake-iptables section is permanent in `selftest.sh`; the page
log and `verify` output mean the next report arrives with evidence attached.

---

## PR #6 — No preset packages, a real package builder, and a sales report
*(shipped as `releases/v6`, module 6.0 / 60)*

**Symptom (a feature request, in the operator's words).**
> "We want no preset added in it for packages, we make all by ourselves —
> Name, Speed UL, Speed DL, Time… no fixed 1 hr 3 hr 5 hr 12 hr 1 day 3 day,
> instead time and then dropdown select hr or days… and price too per hr vs
> per day, easy way. And a small system which calculates how many we sell in
> 1 day, date range filter, reporting."

**Evidence.** Before building a report *on top of* the voucher store, the
schema was read and then probed empirically — mint one code in the lab, dump
the row with field numbers:

```text
$ voucher_mint 1h 1 'Rs 500'   # then inspect the row
  $6=[new]  $9=[]  $10=[1790367400]  $11=[Rs 500]        # only 11 columns
$ vouchers_json
  ..."created":Rs 500,...                                  # NOT valid JSON
```

**Root cause (two latent bugs the feature request exposed).**
1. *Slot 10 was overloaded.* `voucher_mint` wrote **11** columns and put the
   mint time in the **expiry** slot and the note in the **created** slot, while
   redeemed rows used the documented 12-column layout. So an unused code showed
   a bogus expiry, and there was **no sale date anywhere** to report on.
2. *Numeric JSON slots used a bare `%s`.* Because v5 also copied a package's
   price label into the note, any priced package made **every** voucher row
   emit `"created":Rs 500` — malformed JSON that blanked the whole Codes tab.
   The suite missed it because it asserted with `grep '"ok":true'`, which
   cannot tell valid JSON from invalid.

**Fix.**
- **No presets.** `store_init` creates an *empty* `packages.tsv`; the seven
  stock packages are gone. An existing store is left untouched, so upgrading
  never deletes a shop's own packages — new `package_delete` +
  `action=delete` lets the operator remove them deliberately.
- **Package builder** in the operator's units: Name, Speed DL, Speed UL,
  **Time** = amount + Hours/Days dropdown, **Price** = amount + per-hour/per-day
  dropdown, and a **Total price** box that auto-fills from time × rate and stays
  **editable**. The stored price is authoritative and never recomputed behind
  the operator's back. Packages are now 9 columns (`…|price|state|rate|rate_unit`);
  7-column rows still load.
- **Sales report**: new Sales tab with From/To plus Today · Yesterday · Last 7
  days · Last 30 days · This month, four totals, by-day and by-package tables,
  and CSV export. Both readings of "sold" are shown side by side —
  **generated** (minted) and **redeemed** — so the difference is visible unsold
  stock. Backed by `sales_report` / `sales_json` / `sales_csv`, the login-gated
  `/api/admin/sales[.csv]`, and `rns-ctl.sh sales [from] [to]` / `packages`.
- **Money in paisa, as integers.** `money`, `money_sum`, `price_from_rate`.
  Two Rs 250.50 packages total Rs 501.00, never 500.99.
- **13-column voucher schema** with `created` as the authoritative sale date,
  plus a one-shot migration (marker `.schema13`, backup
  `vouchers.pre-schema13.bak`) that recovers the sale date of unused codes.
  Codes redeemed under the old layout genuinely have no mint time, so they are
  left **undated and counted as such** rather than guessed.
- **`num()` on every numeric JSON slot** — the whole class of injection dies,
  not just this instance.
- **Calendar conversion in awk** (`ymd_to_epoch`, `epoch_to_ymd`,
  `utc_offset_seconds`) because busybox/toolbox `date -d` is not dependable
  across ROMs. Verified against UTC, Asia/Karachi and America/New_York,
  including a leap day and the 1970 boundary.

**Test that proves it.** `selftest.sh` grew 60 → **102 checks, ALL PASSED**:
fresh install has zero packages; an upgrade keeps existing ones; duration math
(3 hours → 10800 s) and rate math (Rs 50/hr × 3 h → 150; Rs 300/day × 2 d →
600; Rs 300/day × 3 h → 37.50); override beats the computed rate; zero duration
rejected; delete works and *deleting a missing package fails honestly*;
migration of 11- and 12-column rows; sales totals, by-day, by-package,
date-range narrowing, decimal non-drift, and the undated/unpriced counts; CSV
headers and `Content-Disposition`; sales locked without login. Responses are
now validated with a **real JSON parser**, and a new `isolate-check.sh` rule
fails the build if the panel's JS references an element id that does not exist.

**The guards were mutation-tested.** Reintroducing the old 11-column mint made
the suite fail (`note lost`, and `"created":500` — the digits of "Rs 500
cash"); injecting `$('typoedId')` into the panel made `isolate-check.sh` fail.
A guard that has never been seen to fail is not a guard.

**Lesson.** *Read the schema before you build on it.* The request was for a
report; the report was impossible until the sale date existed, and asking "what
does this column actually contain?" turned up a bug that was already blanking
the Codes tab on any priced package. And *a feature request is a chance to
audit the layer underneath it.*

**Guard.** Parser-based JSON assertions replace grep; the id-consistency check
runs on every build; the migration keeps a backup and a marker so it can never
re-run and re-shift columns.

---

---

## PR #10 — "There is no ISO image to run in VirtualBox"
*(RNS-OS `1.0.1` — a separate product line from the Magisk module)*

**Symptom (verbatim).**
> "how to run rns os in virtual box oracle as i can see no iso image — so
> compile iso image and all setti[n]gs and guide to install too"

The repository advertised an appliance — "bootable Linux operating system for a
virtual machine", a build script, a VM creator, a whole `VirtualBox.md` — and
shipped something nobody could install: no ISO, and no working way to make one.

**Evidence.**
1. `git ls-files` contains no `.iso`; `.gitignore` excludes `RNS-OS/dist/` and
   `*.iso`. No release had ever been published (`gh release list` empty,
   `git tag` empty), so there was no download anywhere either.
2. The base image URL `build-iso.sh` hard-coded was
   `…/debian-cd/current/amd64/iso-cd/debian-12.11.0-amd64-netinst.iso`.
   Debian keeps only the *current* stable in `/debian-cd/current/` and moves
   every older point release to `/cdimage/archive/`. Debian 13 is current now
   (13.7.0, built 2026-09-12), so that path is a 404 today — confirmed by
   fetching both trees: the archive index lists 12.0.0 … 12.15.0.
3. So step 1 of the build failed on every machine — and in the worst way: a 404
   body saved as a `.iso` is still a file, and nothing looked inside it.
4. Even with an ISO in hand, a fresh VM install came up wrong. The shipped
   defaults were `RNS_MODE=wifi`, `GUEST_IF=wlan0`, `ADMIN_LAN=0`:
   - a VM has no radio unless a USB dongle is passed through, so the customer
     side was never addressed and `rns-dhcp` had no address range to serve;
   - VirtualBox NAT does not present a request as coming from the box, so
     `/admin` answered *"Staff only — open this page on the shop phone"* to the
     browser of the person who had just installed it.

**Root cause.** Three assumptions, each true on the phone and false on a VM:
that a pinned download URL stays valid (point releases move), that the customer
side is a radio (in a VM it is Adapter 2), and that the operator is sitting at
the appliance (with VirtualBox they never are).

**Fix.**
- `iso/build-iso.sh`: base-image candidates are the pinned Debian 12 archive
  images (12.15.0, then 12.11.0), each verified against the sha256 Debian
  publishes in the `SHA256SUMS` beside it. A candidate that 404s, downloads as
  HTML or fails its hash is skipped for the next one; an unknown `--url` falls
  back to fetching that `SHA256SUMS`. Input validation now runs *before* the
  xorriso check, so the failure names the file rather than the missing tool.
- `.github/workflows/build-iso.yml` (new): the ISO is built by CI — test suite,
  verified download, burn, then it proves the preseed and payload are *inside*
  the image, writes `SHA256SUMS`, uploads an artifact, and attaches the ISO to
  a Release when a `rns-os-*` tag is pushed. This is the only route for an
  operator with no Linux box, WSL or Docker.
- `payload/etc/rns/defaults.env`: `RNS_MODE=wired`, `GUEST_IF=enp0s8`,
  `ADMIN_LAN=1`.
- `rns-os-ctl`: `guest_if_detect()` takes the spare wired adapter when the
  configured name is not present — never the uplink (it owns the default
  route), virtual interfaces last — and firstboot applies the RNS-OS
  `ADMIN_LAN` over the value the engine's own config template seeds (on a
  genuine first boot only, so a later operator choice wins). New
  `rns os mode wired|wifi|off` switches the customer side and restarts the
  units in one step.
- `iso/vm/create-vm.sh` / `.ps1`: NAT port forwarding bound to `127.0.0.1`
  (panel `8080 → 8080`, SSH `2222 → 22`, host port auto-shifted when busy), the
  host-only adapter moved onto the appliance's own `192.168.50.x` subnet
  (VirtualBox's default `192.168.56.1` could not reach `192.168.50.1` at all),
  and the ISO is checked for the ISO9660 magic before a VM is built — pointing
  `--iso` at the wrong file now fails immediately instead of at *"FATAL: No
  bootable medium"*.

**Test that proves it.** `RNS-OS/tools/os-selftest.sh`, **127 → 163 checks**:
customer-interface detection driven through a synthetic `/sys` tree and a fake
`ip` (a VM-like tree and a nothing-spare tree, so it is deterministic on any
build host), `rns os mode` including its rejection of an unknown mode, the
shipped defaults as a contract, both base-image refusals (a 404 page saved as
`.iso`; a sha256 that does not match) with no network and no xorriso, and the VM
/CI packaging (forward bound to `127.0.0.1`, host-only subnet, pre-flight ISO
check, workflow runs the suite before it builds).

**Lesson.** "It is documented" is not "it is obtainable". When the deliverable
*is* an artifact, the path to that artifact has to work on the machine the user
actually has — and a VM appliance's defaults have to describe a VM, not the
phone the code came out of.

**Guard.** The suite asserts the shipped defaults, the base-image refusals and
the VM/CI packaging, so the next edit that would make a fresh VM unusable, or a
build impossible, fails the tests instead of reaching an operator.


## PR #12 — The recurring report, finally ended: both pages dark after a reboot
*(shipped as `releases/v8`, module 8.0 / 80)*

**Symptom (verbatim).**
> "after last pr and flashing the magisk module reboot and now same problem
> that i have told you a million times now admin panel and captive portal
> both not showing at user end mobile connected wifi but no captive portal
> tracked"

The same report returned after v4, v5, v6 and v7. Each release fixed a real
layer (probe contract, INPUT allow, self_peer_ip, additive firewall) — and
the phone still came back dark, because three *different* layers fail with
the identical user-visible symptom and the fixes kept targeting whichever
layer was nearest.

**Evidence.** Lab green (169 checks) while the phone is dark means the gap
is in what the lab cannot see: whether a process *actually serves* on the
device. Reading the launch path with that question in mind:
1. `rns-pages.sh` logged "pages listening" immediately after `launch` —
   **nothing ever checked that the port answered**. On the phone the
   compiled listeners can fail to exec (ABI/float/SELinux), and the
   busybox `nc` fallback dies instantly when the ROM's nc lacks `-k` or
   `-e` — or when the generated wrap's `#!/system/bin/sh` cannot exec
   (reproduced in the lab: `nc: can't execute …/nc-wrap.sh: No such file
   or directory`, which is the *shebang interpreter* missing, not the
   file). Every rung could fail while every log line said success.
2. `rns-gate-min.sh` installed the redirect for **one** interface name.
   A ROM calling the hotspot anything but `ap0` matched nothing: the
   probe escaped to the real internet, Android returned VALIDATED, and
   the sign-in sheet was permanently suppressed for that SSID — the
   exact "connected to wifi but no captive portal" report.
3. The admin panel was IP-gated **twice** (`/admin` in the page shell,
   `/api/login` + `require_admin` in the function handler). Any failure
   to recognise the shop phone — subnet change, unresolved peer on the nc
   fallback, opening the panel from a customer device — showed "Staff
   only" / "Admin opens on the shop phone only".

**Root cause, one sentence.** *Nobody ever asked "does it answer?" — the
listener was trusted because it was launched, the firewall was trusted
because a rule existed (for some name), and the admin gate was trusted
because the IP looked local to us.*

**Fix.**
- **Live-verified engine ladder** (`rns-pages.sh`): after every launch a
  real `GET /health` goes to `127.0.0.1:PORT`; only a rung that ANSWERS
  is kept. Ladder: each compiled binary → `nc -e` loop → `nc -c` loop →
  `nc` fifo inetd loop (needs only `-l -p`) → `busybox httpd` static
  overlay (pages + admin + every probe path; API degraded, never dark).
  A live-but-silent listener is killed and replaced; the supervisor
  re-ladders every 15 s; fallbacks upgrade to the compiled listener when
  it works; loop children are trap-killed and the port is swept in /proc.
  The generated wrap picks its shebang interpreter from what exists
  (`/system/bin/sh` on Android, `/bin/sh` in the lab).
- **Multi-interface gate** (`rns-gate-min.sh`): redirect + INPUT allow +
  DNS/DHCP passes + 443 reset + drop on EVERY hotspot-like name
  (configured, ap0/softap0/swlan0/wlan0/wlan1, /proc/net/dev), never the
  uplink (default-route interface — gating it would kill the shop's own
  internet). IPv6 guests get fast REJECT instead of silent DROP so
  dual-stack phones fall back to the IPv4 probe that gets the portal.
  The system's `/system/bin/iptables` is preferred over toolbox copies
  (two front-ends can hold two rule stores; only one sees traffic).
- **Password is the gate**: `/admin` serves the login page on every
  device; the dashboard stays behind the session token; failed logins are
  throttled 8/5 min per address; `/api/setup` (first password) stays
  phone-only; `ADMIN_GATE=1` restores the IP gate; `phone_ips()` knows
  every local address and caches them for the page shell.
- **Second boot door**: `boot-completed.sh` (Magisk BOOT_COMPLETED)
  beside late_start `service.sh`; the gate installs immediately at boot
  (a probe in the boot window must never escape).
- **Diagnostics**: `rns-ctl.sh doctor` repairs and proves in one paste;
  `verify` reports a LIVE probe verdict and the iptables binary used;
  `setpass` recovers a lost password from the phone shell.

**Test that proves it.** `selftest.sh` 169 → **205 checks, ALL PASSED**
(36 new): admin to any device / opt-in gate / shop pass-through, login
throttle per address, every forced engine rung answering health+admin+
probe, dead-listener replacement (a pid that holds the port but answers
nothing is detected and replaced), multi-interface redirect with uplink
exclusion and idempotence on a fake iptables, and the boot-completed path
run as itself. The watchdog gained `RNS_NO_WATCHDOG=1` after the harness
itself was bitten: a `RNS_LAB=0` page-shell test spawned a real
`rnsd.sh` that fought the ladder tests for the state directory — the
same class of "who is really running?" bug the release is about.

**Lesson.** *Launched is not serving; a rule exists is not a rule matches;
an IP looks local is not the operator is local.* When a symptom returns
"a million times", stop fixing the nearest layer and ask which layer's
failure is being OBSERVED — then make the system itself observe it, at
runtime, on the device, forever.

**Guard.** `isolate-check.sh` fails the build if the page starter loses
its live probe/verified ladder, or if the gate loses multi-interface
coverage or uplink protection. The engine ladder, dead-listener
replacement and multi-iface gate are permanent selftest sections.

**Known limit stated honestly.** Android remembers a network's verdict per
SSID. A phone that joined before must Forget the network and rejoin before
it will show the sign-in sheet again — a limit we state in the release
notes instead of pretending to fix.


# Part 2 — The skill set this repo uses

These are the skills the five PRs actually exercised. Each one is anchored to
the PR that proved it, so it is a checklist, not a slogan.

### 1. Evidence before hypothesis
Write down device facts (interface names, binary paths, timings, dead ends) in
`PLAN.md` **before** proposing a fix. PR #1's fact table — `ap0` not `wlan0`,
`ccmni0` uplink, 21 ms hostapd window, `kill -HUP` does not reload — prevented
whole categories of wrong fixes. Never hardcode what the device can tell you.

### 2. Reproduce in a lab, not on the customer's phone
`RNS_LAB=1` + seeded `lab-data/` + `/usr/bin/busybox` gives a runnable copy of
the gateway on a laptop. If a bug cannot be reproduced in the lab, the first
task is to *build the reproduction*, not to guess at a patch.

### 3. Build test doubles for the untestable
Real `iptables`, real hostapd and real Android probes are not available in CI.
PR #5 wrote a **fake iptables** that keeps rules in files; PR #4 wrote a
**broken-everything** mode and a **copy of the boot script**. A double that
models ordering and state is enough to prove correctness.

### 4. Break it on purpose (fault injection)
PR #4 corrupted `rns-http.sh`, `store.sh`, `net.sh` and both HTML files, then
asserted the pages still answered — and that exercise surfaced three
*unrelated production defects* (`sh busybox script`, unopenable log redirect,
unwritable pid dir). Ask "what else is broken while I am looking here?"

### 5. Walk the real entry path
Test `service.sh` (boot), `action.sh` (button) and `rnsd.sh` (supervisor) as
themselves, not just the functions they call. Every "never started at boot"
class defect lives on those paths.

### 6. Isolate the blast radius
Separate the *serving/observability* plane (`rns-front.sh`, `rns-pages.sh`)
from the *function* plane (`store.sh`, `net.sh`, `rns-http.sh`). Delegate
across the boundary in a **timed-out child**, keep an **embedded fallback** of
each page, and start the pages **first**. A broken function must never blank
the page that reports it.

### 7. Converge additively; never leave a gap
Check-then-add (`-C … || -A …`), insert/delete deltas in place, flush **only**
on first boot or proven damage. Applies to firewall rules, config files and
hostapd patches alike. Destructive rebuilds are how PR #5's captive
notification died.

### 8. Probe capability, don't trust metadata
`ro.product.cpu.abi` can lie; interface names differ per ROM; `ip6tables`,
`tc`, `setsid`, `curl` may be absent. Run `--check` on every shipped binary,
auto-detect `ap0/softap0/swlan0`, persist the answer, degrade gracefully and
**log the substitution**.

### 9. Heal synchronously on the request path
A 15 s sweep is invisible to a human staring at a screen. PR #3's
`bound_client_heal` repairs lease IP + firewall rules *before answering*, and
answers a bound device's probe with `204` so the OS verdict flips immediately.

### 10. Ship observability with every fix
If a fix cannot be confirmed from one paste, it is not finished:
`rns_pages.log` (did the probe reach us?), `httpd.engine` + `/health` (who is
serving?), `X-RNS-Front: 1` (which path answered?), `rns-ctl.sh verify`
(engine, loopback admin check, rule dumps, interfaces, page log, hostapd conf,
log tails).

### 11. Encode the lesson as a guard, not a comment
`tools/isolate-check.sh` **fails the build** if isolation regresses; the
fake-iptables and nc-fallback sections of `selftest.sh` fail if the race or the
"Staff only" bug returns. A fix without a guard is a future regression.

### 12. Fail closed on security, fail open on availability — deliberately
Admin gate: if the peer address cannot be resolved, refuse (`self_peer_ip`
prints nothing). Pages: never blank, always answer. Guest `443` is **rejected
with a TCP reset**, never decrypted; the portal asks for a voucher code only;
8 wrong codes lock that IP for 5 minutes. Both directions are chosen on
purpose and written down.

### 13. Respect the platform's contract
Captive probes must be answered **200 HTML on the probe URL** (unbound) or
**204** (bound); NAT'd packets traverse **INPUT**; Android **remembers** a
"verified" verdict per network, so the customer must forget the network —
a limit we state rather than pretend to fix.

### 14. Be explicit about what is NOT verified
Every PR body separates lab-proven from device-pending ("Live hostapd,
firewall and captive-portal behaviour still requires verification on the
rooted Infinix HOT 8"; "Phase 7 is the gap FINALANALYSIS already named").
Unproven claims are labelled, never implied.

### 15. Ship a numbered, self-identifying artefact + operator checklist
`releases/vN/{RNS_Gateway_vN.zip, NOTES.txt}` with install steps and a
test checklist in the operator's language, and `module.prop` version bumped so
the running build is visible in Magisk. The operator can always roll back and
always knows which build they are on.

### 16. Read the schema before you build on it
PR #6 was asked for a report and found a store whose "expiry" column sometimes
held a mint time and whose "created" column sometimes held free text. Dump a
real row **with field numbers** and a real response **into a parser** before
designing on top of either. Normalise first (one-shot migration, marker,
backup), then build.

### 17. Validate with a real parser, not a grep
`grep '"ok":true'` passed while the document was `"created":Rs 500` — invalid
JSON that blanked a whole tab. Parse it (`json_ok` in `selftest.sh`). The same
rule applies to ids: a typo'd `$('id')` returns null and throws silently, so
`isolate-check.sh` now diffs every JS id reference against the markup.

### 18. Mutation-test your guards
Reintroduce the bug on purpose and watch the suite fail. PR #6 did this twice
(old 11-column mint; a bogus id reference). A check that has never been seen to
fail is a comment, not a guard.

### 19. Count the gaps out loud
The sales report prints `unpriced` and `undated` instead of quietly treating
them as zero. A total that is knowingly short says so; a total that is silently
short gets a shopkeeper into an argument with their own till.

### 20. Keep secrets out, and say so
A home Wi-Fi password found in the evidence repo was **not** copied into the
module, and the operator was told to rotate it. Data lives outside the module
(`/sdcard/HotspotBilling`, fallback `/data/adb/rns`) so an update never wipes
codes; uninstall keeps data unless a `PURGE` marker exists.

---

# Part 3 — Playbook for the next problem

Follow these steps in order. Most steps are cheap; skipping them is expensive.

1. **Capture the report verbatim.** Quote the operator exactly (as PR #5 did).
   "The captive portal never gives a notification" and "the notification is
   late" are different bugs.
2. **Get one paste of evidence.**
   ```sh
   su -c 'sh /data/adb/modules/RNS_Hotspot/rns/bin/rns-ctl.sh verify'
   su -c 'cat /data/local/tmp/rns_pages.log'
   su -c 'cat /data/local/tmp/rns_hotspot.log'
   ```
   Read `engine`, the loopback admin verdict, the detected interface, the rule
   dumps, and whether the customer's probe appears in the page log.
3. **Localise the layer before touching code.**
   | Page log shows the probe? | Meaning |
   |---|---|
   | No | Below the page shell: redirect rule, interface name, DNS, listener down |
   | Yes, wrong answer | Page shell / probe contract (`200` vs `204`, HTML vs redirect) |
   | Yes, right answer, still broken | Above us: Android's cached network verdict, or the customer's client |
4. **Reproduce it in the lab.** Add a `selftest.sh` section that fails for the
   reported reason. No reproduction ⇒ build a test double (fake iptables,
   fake nc listener, broken files) until you have one.
5. **Name the root cause in one sentence**, including *why it was invisible
   before* (a flush window, a missing env var, a lying property, a shared
   script). If the sentence contains "probably", go back to step 2.
6. **Fix it the way the repo fixes things:** additive/idempotent, capability
   probed, isolated from unrelated code, healed on the request path, logged.
7. **Add the guard.** A check in `selftest.sh` (and `isolate-check.sh` if it is
   an architectural rule) that fails forever if this bug returns.
8. **Prove it:** `./tools/selftest.sh` → `ALL PASSED` with the new count,
   `./tools/build.sh`, `unzip -t`, and diff the zip payload against the source.
9. **Ship it:** `releases/vN/` zip + `NOTES.txt` (what was wrong, what changed,
   install steps, test checklist), bump `module.prop` version/versionCode,
   update `PLAN.md`'s dated fix list, `RNS-Gateway/README.md` and
   `module/OPERATOR.txt`.
10. **Write the PR body** with the template below, stating lab-proven vs
    device-pending explicitly.
11. **Say what we cannot fix from our side** (e.g. "forget the network on the
    customer phone — Android cached the old verified result").

### PR body template

```markdown
Fixes the reported problem(s):

**A. <operator's words>.**
<Root cause: mechanism, why it was invisible, which layer.>
<Fix: what the code does now, and why that cannot regress.>

**B. ...**

Also: <diagnostics added — what the next paste will show>.

Lab selftest: <N> checks, ALL PASSED, including new sections for <X> and <Y>.
Not verified here: <device-only behaviour>.

Release zip: releases/vN/RNS_Gateway_vN.zip — install notes and test
checklist in releases/vN/NOTES.txt.
```

---

# Part 4 — Symptom → cause → fix triage table

| Symptom on the phone | Most likely cause (PR) | First thing to check | Fix / workaround |
|---|---|---|---|
| Admin says "Staff only" on the shop phone | Listener on `busybox-nc`, no `CLIENT_IP` (#5) | `verify` → `engine`, and the loopback admin verdict | Fixed by `self_peer_ip()`; if engine is `busybox-nc`, v5 auto-upgrades when a binary works |
| Admin page blank | Page shell died / function code sourced into it (#4) | `X-RNS-Front: 1` header; `isolate-check.sh` | `rns-front.sh` + embedded fallback HTML; pages start first |
| "gateway functions are not answering yet" | `/api` child broken or slow (#4) — **pages are fine** | `rns-http.sh` syntax; log tail | Refresh; the delegated child recovers on its own |
| "Sign in to network" notification never appears | Probe escaped during a firewall flush window ⇒ Android VALIDATED (#5); wrong interface name (#5/#12); listener dark so nothing answers (#12) | `rns-ctl.sh doctor` → live probe verdict; page log empty ⇒ redirect/interface | v8 engine ladder + multi-interface gate; customer must **forget** the network once |
| Sign-in page never appears, page log empty | Redirect missing, `iptables`/`ip6tables` absent, or interface not `ap0` (#2/#4/#5) | `iptables -t nat -S RNS_PRE`; `verify` interface list | Ensure-only redirect; missing `ip6tables` no longer blocks IPv4 |
| Probe shows a certificate error | Probe was redirected to another port/host instead of 200 HTML (#2) | Response code on `/generate_204` | Serve every probe path as direct 200 HTML |
| Connected + voucher active but no internet after Wi-Fi toggle | Per-MAC rules flushed, nothing restored them per request (#3) | `iptables -S RNS_FWD \| grep <mac>` | `bound_client_heal` repairs before answering; probe gets `204` |
| Paying customer cut off for a moment every 15 s | Destructive rebuild window (#5) | Two `-S` dumps a second apart | `_fw_sync_macs` deltas, no flush |
| Tabs jump while scrolling | Swipe handler (#3) | — | Removed; tap-only tabs |
| Nothing starts at boot | `sh busybox script`, unopenable log redirect, unwritable pid dir (#4) | `/data/local/tmp/rns_hotspot.log` exists? | Fixed launchers, defensive log path, `$STATE` fallbacks |
| Both pages dark after a plain reboot | Listener launched but never verified; nc fallback dies on this ROM's nc (#12) | `rns-ctl.sh doctor` → "pages answer on port"? | v8 live-verified engine ladder: binaries → nc loops → busybox httpd |
| Admin says "Staff only" on any other phone / wrong subnet | IP gate on `/admin` and `/api/login` (#12) | ADMIN_GATE set in page.env? | v8: password is the gate (login page everywhere, 8/5 min throttle); `ADMIN_GATE=1` restores the IP gate |
| Magisk: "This zip is not a Magisk module!" | `module.prop` not at zip root (#1) | `unzip -l RNS_Gateway.zip` | `build.sh` zips from inside `module/` |
| Cannot tell which build is running | No version marker (#3) | Magisk module list | `module.prop` `version` / `versionCode` bumped per release |

---

## Quick reference — commands

```sh
# lab: prove everything, including the guards
cd RNS-Gateway && ./tools/selftest.sh          # expect: ALL PASSED (60 checks)
./tools/isolate-check.sh                       # architectural guard, run by build + selftest
./tools/build.sh                               # isolation → compile → zip (module.prop at root)
unzip -l RNS_Gateway.zip

# phone: one paste of evidence
su -c 'sh /data/adb/modules/RNS_Hotspot/rns/bin/rns-ctl.sh verify'
su -c 'cat /data/local/tmp/rns_pages.log'      # did the customer probe reach us?
su -c 'cat /data/local/tmp/rns_hotspot.log'
su -c 'sh /data/adb/modules/RNS_Hotspot/rns/bin/rns-ctl.sh pause'   # debug only: gate off
```

## Key files

| File | Role |
|---|---|
| `module/rns/bin/rns-front.sh` | Isolated page shell (`/admin`, `/`, probes, `/health`), `self_peer_ip()`, `page_log()` |
| `module/rns/bin/rns-pages.sh` | Listener starter: `pick_httpd --check` over every binary, `record_engine`, nc fallback + auto-upgrade |
| `module/rns/bin/net.sh` | `lan_if()` auto-detect, additive `fw_rebuild`, `_fw_sync_macs`, `gate_heal` |
| `module/rns/bin/rns-gate-min.sh` | Minimum redirect that never flushes, detects the interface too |
| `module/rns/bin/rns-http.sh` | Voucher/login/API handler, `bound_client_heal`, probe `204`/portal `200` |
| `module/rns/bin/rns-ctl.sh` | `status` / `mint` / `list` / `pause` / `resume` / **`verify`** |
| `module/action.sh`, `module/service.sh` | Real entry paths: pages first, `setsid` detach, defensive log, health poll, browser intents |
| `src/rns-httpd.c` | Listener; exports `CLIENT_IP`/`CLIENT_PORT`; `--check` capability probe |
| `tools/selftest.sh` | 102-check lab harness incl. fake iptables, nc fallback, deliberate breakage, boot path, package/rate math, schema migration, sales report, parser-based JSON validation |
| `tools/isolate-check.sh` | Build-time guard for page/function isolation **and** JS-id/markup consistency |
| `releases/vN/NOTES.txt` | Operator-facing what-was-wrong / install / test checklist |
| `PLAN.md` | Device fact table, phases, dated fix history |
