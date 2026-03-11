# Side Quest: AT Command Deep Dive — RC400L (Sino-Smartidea / MDM9607)

**Interface:** `/dev/smd7` (exclusive-open, `crw-rw---- root:root`)
**Access:** `exec 3<>/dev/smd7` via inittab-escaped rootshell, or `/tmp/at-interface.srv.sock` (unauthenticated UNIX socket)
**Command registry:** 322 entries (`AT$QCCLAC`), 174+ captured (`AT+CLAC`, timed out at 90s)
**Source material:** Live device probe (`Private_Research/at_fuzz/`), `atfwd_daemon` RE (`SideQuests/atfwd_re.md`)

---

## Device Identity

| Field | Value |
|---|---|
| Modem manufacturer string | `Sino-Smartidea` |
| Firmware revision (`ATI`) | `XXXXXX_V1.0.3` (X's are literal in firmware string) |
| Internal module version | `NO.1.0.2` (embedded in handler registration log strings) |
| IMEI | `***************` |
| IMSI | `***************` (MCC=310, MNC=240 = T-Mobile US) |
| Chip ID / ADB serial | `*****` |
| Hardware | MDM9607 Part=297, PCB rev 1.0 (`AT$QCHWREV` bare exec) |
| SIM type | USIM (`AT^CARDMODE` = 2) |
| RTC timezone offset | UTC+8 (China Standard Time, `$CCLK: +32`) |
| Build path (from binary) | `/home/make/version/l7_retail_mr_zhanxun/trunk/apps_proc/cpe/qt/interface/dev/src/` |
| Module lineage | **Meige Technology** M602A/M611A reference design |

---

## AT Command Namespace Overview

The RC400L modem exposes four distinct command namespaces. Each reflects a different layer of the Qualcomm MDM9607 firmware stack.

### `AT+` — 3GPP / ITU Standard Commands

**Defined by:** 3GPP TS 27.007 (general), 3GPP TS 27.005 (SMS), ITU-T V.25ter (data bearer)
**What it represents:** The standardized layer. Every cellular modem from every vendor is supposed to implement these identically. In practice, Qualcomm extends some with non-standard parameter ranges or response formats.

These commands are what the GSM/UMTS/LTE specifications define as the host interface to the modem. They cover:
- Network registration and status (`+CREG`, `+CEREG`, `+COPS`)
- SIM access (`+CPIN`, `+CIMI`, `+CRSM`)
- SMS management (`+CMGF`, `+CMGS`, `+CMGL`)
- PDP context / bearer setup (`+CGDCONT`, `+CGACT`, `+CGATT`)
- Supplementary services (`+CCFC`, `+CCWA`, `+CLCK`)
- Signal quality (`+CSQ`)
- Call control (`+CLCC`, `+CHUP`, `+CVHU`)

**Total in QCCLAC:** ~180 entries (including duplicates from multi-registrar assembly)

**Key Qualcomm deviations on this device:**
- `+CSSN` mode=2 — standard only defines 0–1; Qualcomm extension
- `+CFUN` range 4–7 — standard defines 0–4; ranges 5–7 are Qualcomm-specific low-power modes
- `+CVMOD=3` — standard defines 0–2; value 3 is Qualcomm IMS-preferred extension
- `+CEMODE` range (0–3) — standard, but value mapping is Qualcomm-specific
- `+CGSN` / `+CIMI` — `?` form returns ERROR; bare exec works. Non-standard parser behavior
- `+CPOL` — completely blocked (CME ERROR: op not allowed) both forms — carrier PLMN list restriction

---

### `AT$` — Qualcomm Proprietary Extended Commands

**Defined by:** Qualcomm internal AT command specification (not public)
**What it represents:** Qualcomm's own extension namespace. The `$` prefix is Qualcomm-specific. These commands expose modem internals that 3GPP standards don't cover: RF configuration, LTE signal metrics, band management, CDMA legacy stack, PDP profile management beyond the 3GPP range, and hardware diagnostics.

Structural note: `AT$QCCLAC` assembles this list by merging multiple internal registrar tables. The result is that commands appear duplicated when two registrars both register the same base command — the CDMA registrar and the 3GPP registrar independently register bearer-layer commands, causing ~50 entries to appear twice in the full list.

**Subcategories:**

| Prefix pattern | Category | Examples |
|---|---|---|
| `$QC*` | Qualcomm generics | `$QCSQ`, `$QCBANDPREF`, `$QCHWREV`, `$QCCLAC` |
| `$QCPWRDN` | Power control | Modem power-down (DANGEROUS — appears twice) |
| `$QCPDP*` | PDP profile management | `$QCPDPP`, `$QCPDPCFGE`, `$QCPDPIMSCFGE` |
| `$QCPRF*` | Extended PDP profiles (100–179) | `$QCPRFCRT`, `$QCPRFMOD` |
| `$QCAPNE` | APN extended | Full APN config beyond `+CGDCONT` |
| `$QCSIM*` | SIM extended | `$QCSIMSTAT`, `$QCPINSTAT`, `$QCSIMAPP` |
| `$QCRSRP` / `$QCRSRQ` | LTE signal metrics | RSRP/RSRQ via QMI NAS |
| `$QCMIP*` | Mobile IP (CDMA legacy) | Full MIP profile management — likely ERROR on LTE |
| `$QCHDR*` | HDR/EVDO (CDMA legacy) | `$QCHDRC`, `$QCHDRR` — return values despite LTE-only |
| `$CSQ` / `$CREG` | Aliases | `$` aliases for standard `+CSQ`, `+CREG` |
| `$CCLK` | Clock | QC clock with UTC+8 offset exposed |
| `$ECALL` | Emergency call | eCall extension |
| `*CNTI` | Technology | `*CNTI=0` → query current RAT |

**Total in QCCLAC:** ~100 entries (after deduplication)

**Notable:**
- `$QCHWREV` only works as bare exec — `=?` and `?` return ERROR
- `$QCVOLT` same — bare exec returns `0` (voltage stub or uncalibrated)
- `$QCBANDPREF` includes WLAN 2.4+5GHz bands (MDM9607 Wi-Fi coexistence legacy, non-functional on this unit)
- `$QCATMOD=7,1` — AT command mode 7, submode 1 (the active mode at time of probe)

---

### `AT^` — Huawei-Derived / ODM Caret Commands

**Defined by:** Huawei's AT extension layer (originally), adopted broadly by ODMs building on Qualcomm chipsets
**What it represents:** The `^` namespace originated in Huawei modem firmware and became a de-facto standard among Chinese ODM modem manufacturers. It is not a 3GPP standard and not a Qualcomm specification — it is an OEM/ODM convention layer that Sino-Smartidea (and others) implemented alongside the Qualcomm `$` commands. The presence of `^` commands on a non-Huawei device is a clear ODM supply chain indicator.

| Command | Description | Live result |
|---|---|---|
| `^SYSINFO` | System info (Huawei-style) | `4,0,0,0,1` = no service, SIM valid — bare exec only |
| `^SYSCONFIG` | Mode preference + acquisition order | `17,2,1,2` = LTE+WCDMA+GSM, GWL order — writable |
| `^CARDMODE` | SIM card type | `2` = USIM |
| `^BANDLOCK` | Band locking | `1,0` = enabled, all bands |
| `^PCILOCK` | Physical Cell ID lock | `65535,65535` = disabled/unlocked |
| `^EARFCNLOCK` | EARFCN channel lock | `65535,65535` = disabled/unlocked |
| `^SCELLINFO` | Serving cell info | MCC, MNC, Cell ID, LAC, BAND, EARFCN, RSCP |
| `^PREFMODE` | Preferred mode | No response on this device |
| `^SPN` | Service provider name | No response |
| `^MODE` | Mode (extended) | `0` |
| `^DSCI` | Data/speech call info URCs | `0` = disabled |
| `^HDRCSQ` | HDR (EVDO) signal quality | `0` = no EVDO |
| `^GSN` / `^CGSN` / `^MEID` | CDMA ESN/IMEI/MEID | No response (LTE-only unit, no CDMA identifiers) |
| `^HWVER` | Hardware version | No response |
| `^VOLT` | Voltage | No response |
| `^CPIN` | PIN (Huawei alias for `+CPIN`) | Returns CME ERROR: SIM failure (vs `+CPIN` returning READY — different code path) |
| `^RESET` | Modem reset | **SKIP — destructive** |

**Total in QCCLAC:** ~18 entries

**ODM supply chain note:** `^SYSCONFIG`, `^BANDLOCK`, `^PCILOCK`, `^EARFCNLOCK`, and `^SCELLINFO` are the most practically useful commands in this namespace for research. The `^SYSCONFIG` write path is confirmed — you can change the RAT preference and acquisition order live.

---

### Vendor Custom Commands (atfwd_daemon — Not in Standard Lists)

**Defined by:** Meige Technology / Sino-Smartidea firmware, registered via `QMI_AT` service
**What it represents:** The 44 commands `atfwd_daemon` registers directly with the modem's QMI AT service. These appear in `AT+CLAC` / `AT$QCCLAC` because the QMI AT service aggregates all registered handlers into the master list, but they are not standard in any sense — they are implemented entirely in the userspace daemon, not in the modem firmware. Sending them reaches `atfwd_daemon` on the application processor, not the modem DSP.

| Command | Risk | Handler | Notes |
|---|---|---|---|
| `+SYSCMD` | **CRITICAL** | `popen()` | Arbitrary root shell command; output returned in response |
| `+GETSIB` | HIGH (research) | QMI NAS | Raw SIB packet data (`SIB_PKT: %s`) |
| `+PCISCAN` | HIGH (research) | QMI NAS | Neighbor PCI list via band scan |
| `+RLKMODE` | MEDIUM | QMI NAS | Radio link key mode |
| `+WDISABLEEN` | MEDIUM | QMI NAS | WiFi hardware disable (persists) |
| `+WIFIPSK` | HIGH | XML+crypto | Read/set WiFi PSK; generates PSK from IMEI via AES |
| `+WIFISSID` | LOW | XML+IPC | Read/set SSID via `wlan_conf_6174.xml` |
| `+WLANCONFDEL` | HIGH | filesystem | Deletes WLAN config |
| `+MGGPIOCTRL` | HIGH | sysfs | Unconstrained GPIO write/read |
| `+MEIGEDL` | CRITICAL | RSA-gated | Firmware download (Meige lineage command) |
| `+GPSSTART` / `+GPSEND` | LOW | shell | Start/stop `gps_ctl_srv` daemon |
| `+GPSFIX` | LOW | QMI LOC | Get current GPS fix |
| `+FGGPSINIT` / `+FGGPSMODE` / `+FGGPSRUN` | MEDIUM | shell+QMI | GPS position injection / spoofing |
| `+FGUARTNMEA` | LOW | config | Enable UART NMEA output |
| `+ECMPARAM` / `+ECMSTATE` | MEDIUM | QCMAP_Client | USB ECM tethering management |
| `+AUDIOPATH` / `+PCMAUDIO` / `+PCMCONFIG` | MEDIUM | amix | PCM audio path routing (VoLTE paths included) |
| `+CLVL` / `+CMIC` / `+CMUT` | LOW | amix | Speaker volume, mic gain, mic mute |
| `+MGTTS` / `+MGTTSETUP` / `+MGTTSTATE` | LOW | `mgtts` binary | Text-to-speech synthesis |
| `+CODEC` | LOW | sysfs | nau8810 codec enable/disable |
| `+CHIPID` | INFO | sysfs/cmdline | Returns ADB serial `*****` |
| `+IPR` | INFO | config | Overridden — returns ADB serial instead of baud rate |
| `+SER` | INFO | QMI NAS | Returns ADB serial with no OK terminator (parser bug) |
| `+POWEROFF` | DANGER | system | Device power off |
| `+CFUN` | MEDIUM | QMI DMS | Modem function level (delegated, not inline) |
| `+MSECEN` | UNKNOWN | unknown | "Security enable" — function unclear |
| `+MGSLEEP` | LOW | config | Query sleep mode |
| `+SLEEPEN` | MEDIUM | sysfs | USB/system sleep control (persists) |
| `+CHGBATID` / `+CHGBATINFO` / `+CHGBATSTATUS` | LOW | sysfs | Battery/charge status queries |

---

## Command Prefix Taxonomy Summary

| Prefix | Origin | Scope | Who defines it | Implemented where |
|---|---|---|---|---|
| `AT+` | ITU-T / 3GPP | Industry standard | 3GPP TS 27.007/27.005, ITU V.25ter | Modem DSP firmware |
| `AT$` | Qualcomm | Proprietary | Qualcomm internal spec | Modem DSP firmware |
| `AT^` | Huawei/ODM | OEM convention | Huawei, adopted by Chinese ODMs | Modem DSP or ODM middleware |
| `AT*` | Various | Mixed | Ericsson, Qualcomm, others | Modem DSP firmware |
| `AT&` | ITU-T V.25ter | Standard | ITU | Modem DSP firmware |
| Vendor customs (`+SYSCMD`, `+GETSIB` etc.) | Meige/Sino-Smartidea | Device-specific | OEM firmware | `atfwd_daemon` (userspace, application CPU) |

**Critical architectural distinction:** `AT+`, `AT$`, `AT^` commands are executed by the modem DSP itself. The vendor custom commands registered by `atfwd_daemon` are executed on the application CPU (ARM Cortex-A7 Linux side) — they never touch the DSP. The QMI AT service routes them transparently, making them indistinguishable from the caller's perspective.

---

## Qualcomm vs Non-Qualcomm Overlapping Commands

Several commands appear in both the standard namespace and as Qualcomm `$QC` variants. In every case the QC variant has a different code path and sometimes different behavior.

| Standard | QC Variant | Behavioral difference |
|---|---|---|
| `+CPIN` | `+QCPIN` | `+CPIN?` → `READY`; `+QCPIN?` → CME ERROR: SIM failure. Different internal SIM probe path. |
| `+CLCK` | `+QCLCK` | `+CLCK` supports 15 facility codes; `+QCLCK=?` only lists SC and FD. |
| `+CPWD` | `+QCPWD` | `+QCPWD=?` → `("SC",8),("P2",8)` only; standard supports more facilities. |
| `+CIMI` | `+QCIMI` | `+CIMI` bare exec works; `+QCIMI?` → CME ERROR: op not allowed. |
| `+CMGR` | `$QCMGR` | Dollar-prefixed SMS aliases — likely legacy routing from CDMA stack. |
| `+CMGS` | `$QCMGS` | Same. |
| `+CMGL` | `$QCMGL` | Same. |
| `+CMGD` | `$QCMGD` | Same. |
| `+CNMI` | `$QCCNMI` | Standard + QC alias both present, both functional, all URCs disabled by default. |
| `+CPMS` | `$QCPMS` | QC SMS storage alias. |
| `+CMGF` | `$QCMGF` | QC SMS format alias. |
| `+CMGW` | `$QCMGW` | QC SMS write alias. |
| `+CMSS` | `$QCMSS` | QC SMS send-from-storage alias. |
| `+CSMP` | `$QCSMP` | QC SMS text mode params alias. |
| `+COPS` | `$QCCOPS` | `+COPS?` → `0` (auto); `$QCCOPS?` → `0`. Parallel PLMN management paths. |
| `+CREG` | `$CREG` | Dollar alias — `$CREG?` → `0,0` (disabled, not registered). |
| `+CGEQREQ` | `+QCGEQREQ` | Identical parameter ranges. |
| `+CGEQMIN` | `+QCGEQMIN` | Identical. |
| `+CGEQOS` | `+QCGEQOS` | **Key difference: PDP ID range 100–179 vs standard 1–24.** QC extended profile space in NVM. |
| `+CGQREQ` | `+QCGQREQ` | Identical. |
| `+CGQMIN` | `+QCGQMIN` | Identical. |
| `+CGTFT` | `+QCGTFT` | Identical. |
| `+CSQ` | `$CSQ` / `$QCSQ` | `+CSQ` → CME ERROR: op not allowed (blocked). `$QCSQ` returns 5-parameter extended result (RSSI, SINR, RSRP-delta, RSRP, RSRQ). `$CSQ=?` → extended range with RSSI_dbm. |
| `+CGSN` | `^CGSN` | Standard returns IMEI via bare exec; `^CGSN` (Huawei alias) returns ERROR — no CDMA IMEI assigned. |
| `+CFUN` | (delegated) | `+CFUN` in `AT+CLAC` is handled partly by `atfwd_daemon` (delegates to QMI DMS) and partly by modem directly — appears twice in `AT+CLAC` as a result (lines 55 and 108). |
| `+CLAC` | `$QCCLAC` | `+CLAC` = active-mode filtered list (times out at 90s+); `$QCCLAC` = complete firmware registry (322 entries, terminates with OK). |
| `+CCLK` | `$CCLK` | Parallel clock commands. Both show `"80/01/06,02:21:11+32"` — RTC reset + UTC+8 offset. |
| `+CNUM` | `+MDN` | `+CNUM` is standard subscriber number; `+MDN` is CDMA Mobile Directory Number. Both return ERROR — no MDN provisioned. |
| `^CPIN` | `+CPIN` | Huawei vs standard. `+CPIN?` = READY; `^CPIN?` = CME ERROR: SIM failure. |
| `^SCELLINFO` | `$` (no direct equiv) | Serving cell info in `^` namespace. No `$QC` equivalent — only the Huawei-convention command is present. |

**Pattern:** The `$QC` SMS variants (`$QCMGR`, `$QCMGS` etc.) exist because the CDMA stack has its own SMS registrar. On an LTE-only device they are functionally redundant with the standard `+CM*` commands but routed through different internal code paths. The QoS variants (`+QCGEQOS` etc.) have a meaningful difference: the `+QC` prefix versions manage the extended QC profile range (PIDs 100–179 in NVM) rather than the standard 1–24 range.

---

## Radio Intelligence Commands

Commands useful for cellular research and IMSI catcher detection, requiring no `CAP_NET_RAW`:

| Command | Namespace | What you get | Status |
|---|---|---|---|
| `AT+GETSIB` | Vendor (atfwd) | Raw SIB1–SIB7 hex packets from serving cell — neighbor lists, TAC, RACH params, handover targets | **Untested live** — research priority |
| `AT+PCISCAN` | Vendor (atfwd) | Physical Cell ID list of all detectable cells — active scan via QMI NAS | **Untested live** — research priority |
| `AT^SCELLINFO` | Huawei/ODM | MCC, MNC, Cell ID, LAC, BAND, EARFCN, RSCP of current serving cell | Confirmed working (zeros when unregistered) |
| `AT$QCRSRP` | Qualcomm | LTE RSRP in dBm | Requires registration |
| `AT$QCRSRQ` | Qualcomm | LTE RSRQ in dB | Requires registration |
| `AT$QCSQ` | Qualcomm | RSSI, SINR, RSRP-delta, RSRP, RSRQ — all in one response | Requires registration |
| `AT^BANDLOCK` | Huawei/ODM | Lock modem to specific LTE band | Confirmed read: `1,0` (enabled, all bands) |
| `AT^PCILOCK` | Huawei/ODM | Lock to a specific Physical Cell ID | Confirmed read: `65535,65535` = unlocked |
| `AT^EARFCNLOCK` | Huawei/ODM | Lock to a specific EARFCN channel | Confirmed read: `65535,65535` = unlocked |
| `AT^SYSCONFIG` | Huawei/ODM | Read/write RAT preference and acquisition order | Confirmed: `17,2,1,2` = LTE+WCDMA+GSM |
| `AT+CSCB=1,"4370-4389",""` | 3GPP | Enable ETWS/CMAS emergency broadcast reception | Channels pre-configured, disabled by default |
| `AT*CNTI=0` | Qualcomm/misc | Current RAT type | `*CNTI: 0,NONE` when unregistered |
| `AT+CREG=2` | 3GPP | Enable enhanced registration URCs with LAC+Cell ID in unsolicited reports | Standard, widely supported |

**Suggested live test sequence:**
```
AT^SYSCONFIG=13,2,1,2       # force LTE-only acquisition
AT$QCBANDPREF=<target>      # restrict to one band
AT+PCISCAN                  # enumerate visible PCIs
AT^PCILOCK=<EARFCN>,<PCI>   # lock to a specific cell
AT+GETSIB                   # pull raw SIBs from that cell
AT$QCRSRP?                  # confirm signal quality
AT^SCELLINFO                # serving cell parameters
```

**What AT cannot do that DIAG can:**
- Raw Uu-interface frame capture (PDCP/RLC/MAC layer) — requires DIAG log codes `0x412F` etc.
- NAS protocol message logs (Attach, TAU, Auth Request) — DIAG `0xB0C0`/`0xB0EC`
- IQ samples / baseband — hardware-level only

The AT surface provides the **cell intelligence layer** (who's present, what they're broadcasting, their RF parameters). DIAG adds the **protocol layer** (what the modem sends/receives across the air).

---

## Carrier and Network State (at time of probe)

| Parameter | Value |
|---|---|
| Registration state | NOT REGISTERED (`+CREG: 2,0`, `*CNTI: 0,NONE`) |
| USIM | Present, initialized, PIN READY |
| Active APN (PID 1) | `fast.t-mobile.com` — IPV4V6, CHAP auth, IMS/VoLTE enabled |
| Pre-loaded APNs | PIDs 2–6: Verizon (VZWADMIN, vzwinternet, VZWAPP, VZWEMERGENCY) — standard QC multi-carrier provisioning |
| T-Mobile SMSC | `*****` (type 145, international format) |
| SMS storage | 23 ME slots, 0 used |
| Carrier lock | **FULLY UNLOCKED** — all personalization types (`PN`, `PU`, `PP`) return 0. `+CPOL` is blocked (PLMN list restriction), not a simlock. No simlock binary in Orbic rootfs. |
| Voice mode | `+CVMOD=3` (IMS-preferred); `+CAOC=1` (call metering active) |
| CDMA protocol rev | `$QCPREV=9` (IS-2000 Release F) — modem supports full CDMA2000 despite LTE-only deployment |
| PS attach | Not attached (`+CGATT: 0`) |
| RAT config | `^SYSCONFIG: 17,2,1,2` = LTE+WCDMA+GSM, GWL acquisition order |
| EPS bearer mode | `+CEMODE: 1` (CS/PS mode 1, IMS PS voice not preferred) |

---

## Firmware Anomalies and Parser Bugs

| Anomaly | Commands | Detail |
|---|---|---|
| ADB serial returned instead of expected value | `+CHIPID?`, `+IPR?` | Both return `*****`. `AT+CHIPID=?` returns "PASS" not a numeric range. Orbic/Foxconn override of standard V.25ter commands. |
| No OK terminator | `AT+SER=?` | Emits `+SER:*****` with no trailing `OK`. Parser bug in handler. |
| Response prefix mismatch | `AT+QCMUX?` | Returns `+CMUX: C,2` instead of `+QCMUX:`. Firmware bug — wrong response prefix registered. |
| Contradictory SIM status | `+QCPIN?` vs `+CPIN?` | QCPIN: CME ERROR: SIM failure. CPIN: READY. Same SIM, different internal probe code paths. |
| CLAC timeout | `AT+CLAC` | List streams for 90s+ and never terminates with OK. ~174 entries captured before timeout. Use `AT$QCCLAC` instead. |
| CDMA values on LTE device | `$QCPREV`, `$QCHDRC`, `$QCHDRT` | Return valid CDMA state values despite no CDMA air interface. Full CDMA firmware stack is persistent in modem NVM. |
| UTC+8 RTC offset | `$CCLK`, `+CCLK` | Both show `+32` = UTC+8 quarters = China Standard Time. Set at manufacturing origin. RTC date is 1980-01-06 (power-cycled without GPS/NTP). |
| Duplicate commands in QCCLAC | `$QCCAV`, `$QCCHV`, full 3GPP bearer block | QCCLAC assembles from multiple registrars. CDMA registrar and 3GPP registrar both register bearer commands — ~50-entry duplication is a known Qualcomm multi-mode AT dispatcher artifact. |
| `+SER?` returns "9" | `+SER` | `?` form returns the digit `9` — possibly a version number or mode identifier. Undocumented. |

---

## Security Findings Summary

| Finding | Severity | Detail |
|---|---|---|
| Unauthenticated AT socket | CRITICAL | `/tmp/at-interface.srv.sock` — no ACL, no credential check. Any local process sends `AT+SYSCMD` → instant root. |
| `AT+SYSCMD` root exec | CRITICAL | `popen(user_string)` directly in handler — arbitrary shell command execution, output returned. No argument sanitization. |
| RSA private key in binary | CRITICAL | `atfwd_daemon` embeds the PEM private key used to gate USB mode switching and `+MEIGEDL` firmware flash. Shared across all Meige-derived firmware devices. One dump = ability to forge signed commands for entire product line. |
| WiFi PSK from IMEI | HIGH | AES-CBC key derivation uses device IMEI (printed on label). PSK recoverable offline from any unit. Algorithm is static in `atfwd_daemon`. |
| `+MGGPIOCTRL` unconstrained GPIO | HIGH | Arbitrary sysfs GPIO write — can reach hardware peripherals, power management, RF switches. No authentication. |
| `+GETSIB` SIB data exposure | HIGH (research) | Raw SIB packets from serving cell without `CAP_NET_RAW`. Neighbor cell lists = same data IMSI catchers manipulate. |
| Meige shared vulnerability surface | HIGH | All vulnerabilities in `atfwd_daemon` affect every OEM customer using Meige M602A/M611A reference firmware — not just Orbic RC400L. |
| GPS position injection | MEDIUM | `+FGGPSMODE` with 9-parameter position config injects arbitrary GPS fixes into all device consumers. |
| Voice QMI active | MEDIUM | `QMI_VOICE` running and producing indications on a data-only device. PCM audio routing commands present for VoLTE paths. Modem voice capability not disabled at DSP level. |
| `+WDISABLEEN` / `+SLEEPEN` | MEDIUM | Persistent WiFi kill and USB sleep disable — denial-of-service primitives reachable via unauthenticated socket. |

---

## Open Research Threads

- **`AT+GETSIB` live test** — does it return SIB data when registered on a cell? What SIBs are exposed and in what format?
- **`AT+PCISCAN` live test** — does the PCI list match known towers? Does it expose cells invisible to passive listening?
- **`+MGGPIOCTRL` GPIO mapping** — which GPIO numbers correspond to which hardware on the RC400L PCB? FCC internal photos show LED headers.
- **AES PSK derivation** — extract the key schedule from `atfwd_daemon`, apply to a known IMEI, verify against `/usrdata/data/persistent/wlan/psk`.
- **RSA key extraction** — isolate the 4 base64 blobs in `atfwd_daemon`, determine which is the private key, verify it signs the `switch_usb` parameter block.
- **`+MSECEN` function** — "Security enable" handler logs `AT_FWD_CMD_MSECEN_SET:%s` and `Unsupported MSECEN = %s`. Unclear what values it accepts or what it controls.
- **`+MEIGEDL` gate** — does it go through the same RSA check as USB switching? If so, the same extracted key enables unsigned firmware flash on any Meige-derived device.
- **Voice call initiation** — can `QMI_VOICE` commands sent directly (not through AT) initiate a call and route audio through the nau8810 codec? PCB has no exposed mic but codec pads may be populated.
