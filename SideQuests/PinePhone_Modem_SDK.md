# Side Quest: PinePhone Modem SDK — Cross-Pollination with RC400L

> **Repo:** https://github.com/the-modem-distro/pinephone_modem_sdk
> **Why this matters:** The PinePhone's Quectel EG25-G modem module runs the **same Qualcomm MDM9607 SoC** (ARM Cortex-A7 + Hexagon DSP) as the RC400L. The Modem Distro project replaces the entire Quectel proprietary userspace with open-source tooling, exposing cellular capabilities the stock firmware deliberately hides. Everything they built for EG25-G application-processor Linux is directly portable to the RC400L.

---

## Architecture Alignment

| Layer | EG25-G (PinePhone) | RC400L (Orbic) |
|---|---|---|
| SoC | Qualcomm MDM9607 | Qualcomm MDM9607 |
| App processor | ARM Cortex-A7 | ARM Cortex-A7 |
| Baseband DSP | Qualcomm Hexagon (AMSS) | Qualcomm Hexagon (AMSS) |
| Kernel | CAF 3.18.140 | CAF 3.18.140 (stock Orbic) |
| Libc | glibc 2.22 | glibc 2.22 |
| Init | SysV | SysV |
| QMI stack | qmuxd + libqmi | qmuxd + libqmi |
| AT forwarding | atfwd (via /tmp/at-interface.srv.sock) | atfwd_daemon (44 cmds, same socket) |
| Remaining blobs | TZ Kernel + ADSP .mbn | TZ Kernel + ADSP .mbn |

Same SoC. Same kernel version. Same ABI. Same blob structure. **Any open-source binary built for EG25-G application Linux runs on RC400L without recompilation if linked against glibc 2.22.**

---

## What the Modem SDK Actually Provides

The project's userspace is **79.9% Python, 10.6% C**. It replaces the Quectel proprietary stack with a thin Python daemon layer that speaks directly to the modem via QMI and AT. Remaining proprietary blobs are limited to:
- TZ (TrustZone) kernel `.mbn`
- ADSP firmware `.mbn` (Hexagon DSP — the baseband itself)

Everything else — boot, kernel, rootfs, modem management daemon — is open source and GPL-3.0.

---

## Direct Benefits for RC400L

### 1. Signal Tracking (Neighbor Cell Measurement)

The SDK implements **signal tracking** as a first-class feature. This goes beyond what atfwd_daemon's `+PCISCAN` does — it continuously monitors:
- Serving cell: RSRP, RSRQ, SINR, RSSI, PCI, EARFCN, band
- Neighbor cells: full list with signal levels
- Technology transitions (LTE → WCDMA → GSM fallback events)

**How:** Via QMI NAS `GET_SIGNAL_INFO`, `GET_SERVING_SYSTEM`, and `NETWORK_INFO` indications — the same QMI services accessible from our deployed QMI stack. The Python daemon subscribes to indications rather than polling. This is directly portable: run the signal tracking module on the RC400L application processor and pipe output to RayTrap's status endpoint.

**RC400L advantage over Rayhunter DIAG path:** No CAP_NET_RAW required. Pure QMI via qmuxd. Works from within our existing CapBnd=0x00c0 rootshell environment or via the ipt_daemon FIFO.

### 2. Cell Broadcast Relay

The SDK relays **ETWS/CMAS cell broadcast messages** from the modem to userspace. These are emergency alert broadcasts transmitted by towers — distinct from SMS — and include:
- Earthquake/Tsunami Warning System (ETWS) messages
- Commercial Mobile Alert System (CMAS) / WEA alerts
- Public Warning System (PWS) identity of transmitting cell

For stingray/rogue base station research: legitimate towers send these on schedule; rogue cells typically don't, or send malformed versions. This gives a passive detection signal orthogonal to what SIB analysis provides.

**QMI path:** `QMI_WMS` service, `BROADCAST_CONFIG` and `BROADCAST_INDICATION` messages. Already in `libqmiservices.so.1` on the RC400L.

### 3. GPS Activation

The SDK enables **onboard GPS via `AT+QGPS=1`**, streaming NMEA sentences from the MDM9607's integrated GPS receiver. The RC400L hardware has GPS capability (MDM9607 includes integrated GPS/GNSS hardware) — whether Orbic connected the antenna is unknown, but the firmware command path exists.

**Immediate test:** Write `AT+QGPS=1\r` to `/tmp/at-interface.srv.sock` and check for NMEA output on `/dev/ttyHS0` or `/dev/smd*` serial nodes. If the antenna is connected, this enables standalone GPS on the device — useful for correlating cell tower positions with physical location.

### 4. Internal Audio / Call Recording

The SDK exposes **voice call audio** via the MDM9607's built-in audio codec, routed through the USB audio interface. This is notable because:
- The RC400L is nominally a data-only device, but our atfwd RE confirmed `QMI_VOICE` is active and sending indications
- The Hexagon DSP is processing voice IQ — the hardware supports it
- The SDK's approach (CAF kernel audio + userspace PCM capture) is the same platform

**For RC400L:** The `AT+QPCMV` command (PCM voice interface enable) combined with `/dev/snd/` audio nodes could expose call audio if a cellular call is somehow established. Primary research value: confirm whether the RC400L modem will accept and process voice calls at all, and whether IMSI catchers targeting voice are triggering QMI_VOICE indications we could log.

### 5. Reduced Clock Frequencies / Power Tuning

The SDK drops minimum CPU frequency to **100 MHz** (vs Quectel stock 800 MHz, RC400L stock 998 MHz). This is achieved by modifying the cpufreq scaling governor and available frequency table in the kernel device tree.

**For RC400L context:** The device runs at 998.4 MHz constantly with no dynamic scaling. If the device is battery-powered during field research, this is significant: the MDM9607 at idle doing LTE monitoring burns far more power than necessary. The SDK's cpufreq patches apply directly to our CAF 3.18.140 kernel.

**Immediate low-effort win:** Write `998400` → `ondemand` governor via sysfs: `echo ondemand > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor` — no kernel change needed, just userspace config. Modem SDK confirmed this works on identical hardware.

### 6. AT+QENG Engineering Mode — TESTED, N/A

**Tested 2026-03-08 via `/dev/smd7` (live session).**

`AT+QENG="servingcell"` → **ERROR**. Expected: the RC400L's modem module is **Sino-Smartidea** (confirmed via `ATI`: `Manufacturer: Sino-Smartidea`, `Model: Sino-Smartidea`, `Revision: XXXXXX_V1.0.3`), not Quectel EG25-G. `AT+QENG` is Quectel-proprietary and does not exist in the Sino-Smartidea firmware. Any Quectel-specific AT docs do not apply here.

This changes the AT command cross-pollination story: the QMI/userspace layer still maps 1:1, but the AT command set is Sino-Smartidea's, not EG25-G's. Their proprietary commands (if any engineering mode exists) are undocumented publicly.

### 7. Custom Bootloader (LK2nd) — EDL / Fastboot Access

The SDK uses **LK2nd** (a fork of Little Kernel) with custom fastboot extensions:
- `fastboot oem stay` — stay in fastboot without timeout
- `fastboot oem reboot-recovery` — force recovery boot
- `fastboot getvar` extensions for modem partition layout

The RC400L uses the same LK bootloader family (Qualcomm MDM9x07 standard). The LK2nd patches for custom fastboot commands are directly applicable — flash LK2nd to the `sbl` partition and gain proper EDL/fastboot control of the RC400L without the Quectel/Orbic restrictions. This would enable flashing modified userspace images cleanly rather than relying on ADB + inittab tricks.

**Risk:** Bricking if partition layout differs. Requires EDL backup first (already documented in main notes).

---

## Modem SDK Architecture — Porting Path

```
EG25-G (PinePhone SDK)          RC400L (target)
─────────────────────────       ────────────────────────────
modem-init daemon (Python)  →   drop in /cache/bin/, launch via inittab
signal-tracker (Python)     →   pipe JSON to RayTrap /status endpoint
cell-broadcast (Python)     →   new RayTrap /alerts endpoint
qmi-helpers (Python/C)      →   same libqmi.so.1.0.0 ABI
GPS NMEA relay (Python)     →   new RayTrap /gps endpoint
cpufreq tuning              →   sysfs write, immediate, no kernel change
```

The SDK's Python stack requires only Python 3 and `pyqmi` or direct AT socket writes — no exotic dependencies. Python 3 is not on the RC400L rootfs but can be staged to `/cache/bin/` as a static ARM build (~6 MB). Alternatively the C components compile standalone against glibc 2.22.

---

## What Does NOT Cross Over

| Feature | Reason |
|---|---|
| Kernel patches | RC400L kernel is in flash — recompile + flash needed, high risk |
| Custom bootloader (LK2nd) | Requires EDL access + confirmed partition map first |
| USB audio routing | EG25-G connects to PinePhone AP via USB; RC400L has no external AP |
| ADSP / baseband .mbn swap | RF calibration data is device-specific — direct swap will break radio |

The ADSP firmware is the one area where a direct swap is dangerous. Even though both are MDM9607, the RF frontend components (PA, filters, antenna matching) differ between EG25-G and RC400L hardware. Flashing EG25-G ADSP blobs to the RC400L would likely result in degraded RF performance or no signal at all. **Do not swap modem .mbn files.**

---

## Live Test Results (2026-03-08)

All tests performed via `/dev/smd7` (exclusive-open, single fd, `read -t 4` timeout):

| Command | Result | Notes |
|---|---|---|
| `AT` | `OK` | Channel confirmed live |
| `ATI` | `Sino-Smartidea` / `XXXXXX_V1.0.3` | **Module vendor confirmed — not Quectel** |
| `AT+GMM` | `Sino-Smartidea` | |
| `AT+CSQ` | `ERROR` | Blocked while in active data call |
| `AT+CREG?` | `ERROR` | Same |
| `AT+CEREG?` | `ERROR` | Same |
| `AT+COPS?` | `ERROR` | Same |
| `AT+QENG="servingcell"` | `ERROR` | Quectel-specific, not applicable |
| `AT+GETSIB` | `ERROR` | atfwd-registered; likely requires modem idle/no data call |
| `AT+PCISCAN` | `ERROR` | Same |
| `AT+SYSCMD=id` | `OK` → `uid=0(root) gid=0(root)` | **Root exec confirmed via SMD7** |
| `AT+SYSCMD=echo test > /tmp/f` | `OK` → file written | Shell redirect works |

**Key SMD7 findings:**
- `/dev/smd7` is exclusive-open (`EBUSY` on second open while first fd is active) — all commands must share one fd
- `read -t` on the fd works correctly with busybox; VTIME stty approach does NOT work (SMD is not a TTY)
- `AT+SYSCMD` executes as root but output goes to redirected files, not the AT response stream
- `AT+GETSIB` / `AT+PCISCAN` should be retested with modem in idle state (data disconnected)

---

## Priority Actions

1. ~~Test AT+QENG~~ — **DONE, N/A** — module is Sino-Smartidea, not Quectel
2. **Retry AT+GETSIB / AT+PCISCAN** in modem idle state (disable data connection first)
3. **Test AT+QGPS=1 via SMD7** — check if GPS antenna is connected on RC400L hardware
4. **Port signal-tracker module** — clone SDK, pull the QMI NAS signal tracking Python module, adapt JSON output → RayTrap `/status`
5. **Port cell broadcast relay** — QMI_WMS broadcast indications → new RayTrap `/alerts` endpoint; strong rogue cell indicator
6. **cpufreq governor** — immediate, zero risk, write `ondemand` to sysfs scaling_governor
7. **Stage Python 3 static ARM build** — prerequisite for running SDK Python modules on device

---

## Key Takeaway

The Modem SDK proves that the MDM9607 application processor userspace is fully replaceable with open-source tooling. The RC400L doesn't need a full reflash to benefit — the SDK's individual modules (signal tracking, cell broadcast, GPS) are Python/C daemons that can run alongside the existing Orbic stack from `/cache/bin/`, launched via our established inittab escape technique. The cellular capabilities are already in the modem hardware and AMSS firmware. The SDK just exposes them cleanly.
