# RNS Gateway on OpenWrt — Complete Deployment Plan

**Version:** 7.0 (OpenWrt Port)  
**Date:** 2026-09-26  
**Target Hardware:** FiberHome AN1020-16T (ADSL2+ Router) + x86 Mini PC for core  
**Based on:** RNS Gateway v7 (Magisk module for Infinix HOT 8)  

---

## 1. Project Overview

### 1.1 Project Overview

The **RNS Gateway** is a hotspot billing and voucher management system originally built as a Magisk module for a rooted Infinix HOT 8 phone. This plan ports it to run natively on **OpenWrt** (or a compatible Linux router/firmware) — specifically targeting the **FiberHome AN1020-16T** ADSL router environment (or equivalent x86 hardware).

**Core functionality to port from Magisk module:**
- Voucher/captive portal system with MAC binding
- Package builder (custom speed, duration, pricing)
- Sales reporting (generated vs redeemed, CSV export)
- Online payments (JazzCash/EasyPaisa auto-verify)
- Staff dashboard with role-based access
- Rate limiting per package (TC/HTB)
- Shared storage for persistence across updates

### 3.3 Features to Port from v7

| Feature | v7 Implementation | OpenWrt Port Notes |
|---------|-----------|----------------|
| Captive Portal | ✅ | `nodogsplash` + custom nginx/Lua |
| Voucher System | ✅ | SQLite + Lua/luci-app |
| Package Builder | ✅ | LuCI app + SQLite |
| Sales Reporting | ✅ | SQLite + Lua + CSV export |
| Online Payments | ✅ | JazzCash/EasyPaisa webhook |
| Rate Limiting | ✅ | TC HTB + nftables |
| Client Kick/Ban | ✅ | iptables/nftables + deauth |
| Backup/Restore | ✅ | `/etc/rns/backups/` + sysupgrade-safe |

---

## 3. Hardware Requirements (OpenWrt)

| Resource | Minimum | Recommended |
|---------|--------|---------------|
| **CPU** | 2 cores @ 1GHz+ | 4 cores @ 2GHz+ |
| **RAM** | 512 MB | 1 GB+ |
| **Flash/Storage** | 16 MB flash + 1 GB USB | 1 GB+ (DB + logs) |
| **Network** | 1× WAN + 4× LAN | 2.5G preferred |
| **WiFi** | 802.11ac/ax | Qualcomm/MediaTek (open drivers) |

### 3.1 Recommended Hardware (OpenWrt-Supported)

| Device | CPU | RAM | Flash | WiFi | Price | Notes |
|---------|------|------|---------|
| **GL.iNet GL-MT6000 (Flint 2)** | MT7981B, 1GB, 128MB | 2.5G WAN/LAN, WiFi 6 | ~$130 | ✅ Best all-rounder |
| **GL-MT3000 (Beryl AX)** | MT7981B, 512MB, 128MB | Travel/AP | 50 clients |
| **NanoPi R5S/R6S** | RK3588S, 4-8GB, 2.5G×2/3 | **No WiFi** | 1Gbps+ routing |
| **Banana Pi R3/R4** | MT7986/MT7988, 2-4GB | Router board | 500+ users |
| **x86 Mini PC** | N100/N305, 8-16GB, 2.5G/10G | **Best performance** | 1000+ users |

---

## 5. OpenWrt Implementation Plan

### 12.1 Core Components to Port

| v7 Component | OpenWrt Implementation |
|---------|-----------|----------------|
| **Captive Portal** | `nodogsplash` + custom HTML/Lua | Replace Magisk `rns-front.sh` |
| **Voucher System** | ✅ | SQLite + Lua (`/usr/lib/lua/rns/`) |
| **Package Builder** | ✅ | LuCI app (`luci-app-rns`) |
| **Sales Reports** | ✅ | SQL queries + CSV export |
| **Online Payments** | ✅ | `rns-pay` Lua module + webhook |
| **Rate Limiting** | ✅ | `tc` + `nftables` + `nft-qos` |
| **Client Kick/Ban** | ✅ | `nft` + `hostapd_cli` / `hostapd_cli` |
| **Backup/Restore** | ✅ | `/etc/rns/backups/` + sysupgrade-safe |
| **RADIUS/AAA** | ⏳ | `freeradius` + `freeradius-mod-radattr` |

### 10.2 OpenWrt Package Structure

```
rns-gateway/
├── Makefile
├── Makefile
├── Makefile
├── Makefile
│   ├── control
│   │   ├── control (package metadata)
│   │   ├── conffiles
│   │   ├── postinst
│   │   └── prerm
│   ├── usr/
│   │   ├── bin/
│   │   │   ├── rnsctl          # CLI tool
│   │       │   └── rns-api     # Lua API daemon
│   │   └── lib/lua/rns/        # Lua modules
│   │       ├── voucher.lua
│   │       │   ├── store.lua
│   │       │   ├── net.sh      # Firewall + TC
│   │       │   ├── store.sh    # SQLite persistence
│   │       │   └── net.sh      # Network/firewall helpers
│   │   └── lib/lua/rns/       # Lua modules
│   │       ├── voucher.lua
│   │       │   ├── store.lua
│   │       │   ├── net.sh
│   │       │   └── common.sh
│   ├── www/
│   │   ├── portal.html         # Captive portal
│   │   ├── admin.html          # Staff dashboard
│   │   └── static/             # CSS/JS assets
│   └── www/luci-static/rns/   # LuCI static assets
├── root/
│   └── etc/
│       ├── rns/
│       │   ├── config.env      # Runtime config (JazzCash, etc.)
│       │   └── ssl/            # TLS certs for portal
│   └── www/luci-static/rns/   # Static assets (CSS/JS)
```

---

## 6. Network Configuration

### 12.1 Firewall Rules (nftables)

```nft
table inet rns {
    chain prerouting_lan {
        type filter hook prerouting priority 0; policy accept;
        iifname "br-lan" tcp dport 80 redirect to :2050
        tcp dport 443 ip saddr != $admin_ips counter reject
    }
    chain forward_lan {
        # Default: drop all
        # Per-voucher rules inserted dynamically:
        # iptables -I RNS_FWD -m mac --mac-source $MAC -j ACCEPT
    }
```

### 11.3 Nodogsplash Config

```conf
GatewayInterface br-lan
GatewayAddress 192.168.10.1
GatewayPort 2050
ExternalInterface wan

FirewallRuleSet authenticated-users {
    FirewallRule allow all
}

FirewallRuleSet preauthenticated-users {
    FirewallRule allow tcp port 53
    FirewallRule allow udp port 53
    FirewallRule allow tcp port 67
    FirewallRule allow udp port 67
    FirewallRule allow tcp port 80
    FirewallRule allow tcp port 443
}

EmptyRuleSetPolicy authenticated-users allow
EmptyRuleSetPolicy preauthenticated-users deny
RedirectURL http://192.168.10.1/portal
GatewayName RNS-Gateway
SessionTimeout 86400
ClientIdleTimeout 600
ClientForceTimeout 86400
MaxClients 500
MacMechanism block
```

### 12.3 Critical Files to Preserve

```
/etc/rns/
├── vouchers.db          # SQLite (survives sysupgrade)
├── vouchers.pre-schema13.bak
│   ├── database/
│   │   ├── vouchers.db
│   │   ├── payments.tsv
│   │   ├── packages.tsv
│   │   └── online-packages.tsv
│   ├── rns/
│   │   ├── config.env
│   │   ├── ssl/           # TLS certs for portal
│   │   └── ssl/          # TLS certs for portal
├── backups/
│   ├── vouchers-YYYYMMDD.db
│   └── payments-YYYYMMDD.tsv
└── logs/
    ├── rns.log
    └── nginx-access.log
```

---

## 14. Build Instructions

### 13.1 Build Custom Image

```bash
# 1. Setup build environment
git clone https://github.com/openwrt/openwrt.git -b openwrt-23.05
cd openwrt
./scripts/feeds update -a
./scripts/feeds install -a

# 2. Add RNS Gateway package
cp -r ../RNS-Gateway/openwrt-package/* package/rns-gateway/

# 7. Configure
make menuconfig
# Target: x86/64
# Target Profile: Generic
# LuCI → Applications → luci-app-rns-gateway (select)

# 7. Build
make -j$(nproc)

# Output: bin/targets/x86/64/openwrt-23.05.5-x86-64-generic-squashfs-combined.img.gz
```

---

## 16. Rollback Plan

| Scenario | Action |
|---------|------|
| **Config broken** | `sysupgrade -r /overlay/backup/config-backup.tar.gz` |
| **DB corrupted** | Restore from `/var/lib/rns/vouchers.db.bak` |
| **Firmware broken** | Failsafe mode → `firstboot -y && reboot` |
| **Payment webhook fails** | Check `/var/log/rns_payments.log` |
| **Client stuck** | `rnsctl kick <mac>` or `rnsctl pause` |

---

## 16. Rollback Procedure

```bash
# 1. Emergency: disable gateway
/etc/init.d/rns-gateway stop

# Restore from backup
sysupgrade -r /overlay/backups/latest.tar.gz
reboot

# Or full disk restore (if sysupgrade broken)
dd if=/mnt/backup/openwrt-backup.img of=/dev/mmcblk0
```

---

*Document version: 7.0 | Last updated: 2024 | For OpenWrt 23.05+*