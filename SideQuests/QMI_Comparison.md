# Side Quest: QMI Capability Comparison — RC400L vs JMR540

> Both devices run MDM9607 (ARM Cortex-A7 LTE Cat-4). Same SoC, same glibc (2.22), same QMI library version. What differs is how much of the modem's capability the firmware vendor chose to expose — and how.

---

## Architectural Summary

**RC400L (Orbic/Foxconn):** Pure QMI/QCMAP stack. All services are direct QMI clients of qmuxd. No abstraction layer.

**JMR540 (Foxconn/JioFi):** Same QMI/QCMAP stack **plus** a full MCM (Mobile Connection Manager) abstraction layer. MCM wraps QMI behind a higher-level API and adds a parallel service tree.

The significance: the JMR540 vendors added a middleware layer Qualcomm distributes with MDM9607 BSPs but which many OEMs strip. The RC400L's `atfwd_daemon` is 8x larger than the JMR540 version because the Orbic build baked all the AT command handlers directly into the daemon rather than delegating them through MCM.

---

## QMI Core Binaries

| Binary | RC400L | JMR540 | Notes |
|---|---|---|---|
| `qmuxd` | 108 KB | 88 KB | Both multiplex QMI over SMD/BAM to modem |
| `netmgrd` | **517 KB** | 220 KB | Orbic 2.3× larger — more feature-rich |
| `atfwd_daemon` | **164 KB** | 20 KB | Orbic 8× larger — extended AT handler set |
| `qmi_shutdown_modem` | present | present | identical |
| `qmi_ip_multiclient` | present | present | identical |
| `thermal-engine` | **3.7 MB** | present | Orbic significantly larger |
| `qmi_simple_ril_test` | present | present | diagnostic test binary |

---

## QMI Libraries

Both devices carry the same 11-library stack. Version packaging differs:

| Library | RC400L | JMR540 |
|---|---|---|
| `libqmi.so` | `.so.1.0.0` | `.so.1` |
| `libqmiidl.so` | `.so.1.0.0` | `.so.1` |
| `libqmiservices.so` | `.so.1.0.0` | `.so.1` |
| `libqmi_cci.so` | `.so.1.0.0` | `.so.1` |
| `libqmi_client_helper.so` | `.so.1.0.0` | `.so.1` |
| `libqmi_client_qmux.so` | `.so.1.0.0` | `.so.1` |
| `libqmi_common_so.so` | `.so.1.0.0` | `.so.1` |
| `libqmi_csi.so` | `.so.1.0.0` | `.so.1` |
| `libqmi_encdec.so` | `.so.1.0.0` | `.so.1` |
| `libqmi_ip.so` | `.so.1.0.0` | `.so.1` |
| `libqmi_sap.so` | `.so.1.0.0` | `.so.1` |

Same underlying code, different packaging convention. The `.so.1.0.0` naming on Orbic is the full soname with major.minor.patch; JMR540 uses major-only. Binaries compiled against either will work on the RC400L (already confirmed with deployed JMR540 binaries).

---

## MCM Framework — JMR540 Only

The JMR540 ships a complete MCM stack that the RC400L firmware does not include.

| Binary | Size | Role |
|---|---|---|
| `mcm_ril_service` | 333 KB | Full RIL abstraction over QMI |
| `mcm_data_srv` | — | Data service abstraction |
| `MCM_atcop_svc` | — | Second AT command path (parallel to atfwd_daemon) |
| `mcmlocserver` | — | MCM service coordinator / local IPC server |
| `MCM_MOBILEAP_ConnectionManager` | — | Mobile AP via MCM (parallel to QCMAP_ConnectionManager) |
| `MCM_ATCOP_CLI` | 15 KB | Interactive CLI into MCM AT service |
| `MCM_MOBILEAP_CLI` | — | CLI for MCM Mobile AP |
| `FX_QCMAP_IPC` | — | Foxconn-specific QCMAP IPC bridge |

| Library | Size | Role |
|---|---|---|
| `libmcm.so.0` | 45 KB | MCM core |
| `libmcmipc.so.0` | 26 KB | MCM IPC transport |
| `libmcm_log_util.so.0` | 9.7 KB | MCM logging |
| `libmcm_srv_audio.so.0` | 25 KB | Audio service via MCM |
| `libloc_mcm_qmi_test_shim.so.1` | — | Location/GPS MCM shim |
| `libloc_mcm_test_shim.so.1` | — | Location test shim |
| `libloc_mcm_type_conv.so.1` | — | Location type conversion |

All MCM binaries and libraries have been extracted and deployed to the RC400L at `/cache/bin/` and `/cache/lib/` as part of the PortableApps deployment. They are present on the device but **untested against the live Orbic QMI stack**.

---

## QCMAP Stack

Both devices run the standard QCMAP stack:

| Component | RC400L | JMR540 |
|---|---|---|
| `QCMAP_ConnectionManager` | 683 KB | present |
| `QCMAP_CLI` | present | present |
| `QCMAP_StaInterface` | present | present |
| `QCMAP_Web_CLIENT` | present | — |
| `libqcmapipc.so` | `.so.1.0.0` | `.so.1` |
| `libqcmaputils.so` | `.so.1.0.0` | `.so.1` |
| `libqcmap_client.so` | `.so.1.0.0` | `.so.1` |
| `libqcmap_cm.so` | `.so.1.0.0` | `.so.1` |
| `qcmap_auth` | present | — |
| `qcmap_web_cgi` | present | — |
| `monitor_qcmap.sh` | — | present |
| `MCM_MOBILEAP_ConnectionManager` | — | present |

The RC400L adds web interface binaries for the Orbic admin panel; the JMR540 adds an MCM-based parallel MOBILEAP manager and a monitoring script.

---

## AT Command Surface Comparison

The JMR540's `atfwd_daemon` (20 KB) handles only `+CFUN` and defers everything else to `MCM_atcop_svc`.

The RC400L's `atfwd_daemon` (164 KB) handles 44 AT commands directly, covering GPS, audio, cellular, hardware I/O, and security. See [atfwd_daemon Reverse Engineering](./atfwd_reversal.md) for the full breakdown.

---

## QMI IP Configuration

| Parameter | RC400L | JMR540 | Notes |
|---|---|---|---|
| TCP server port | 7777 | 7777 | same |
| UDP single-client port | 7788 | 7788 | same |
| FPOP UDP port | **7755** | **7788** | differs |
| Max LAN clients | **3** | **8** | JMR540 2.7× higher |
| Max TMGI count | **3** | **8** | JMR540 2.7× higher |

JMR540 configured for higher concurrency — consistent with targeting a broader user base. The FPOP port difference is minor and unlikely to affect anything practical.

---

## Platform / SoC Variants

| Device | soc_id values in `power_config` | Governor hispeed |
|---|---|---|
| RC400L | 290, 296, 297, 298, 299, **322** | 998400 Hz |
| JMR540 | 290, 296, 297, 298, 299 | 800000 Hz |

soc_id 322 is Orbic-specific — a MDM9607 silicon variant or SKU not present in the JMR540 firmware. The hispeed frequency difference (998400 vs 800000 Hz) means the Orbic runs the CPU faster at load — potentially relevant for throughput benchmarking.

---

## Modem Interface — Transports

Both devices use the same MDM9607 QMI transport configuration:

- **Primary control:** `LINUX_QMI_TRANSPORT_BAM` on `/dev/smdcntl0` (QMI_CONN_ID_RMNET_0)
- **Secondary control:** `LINUX_QMI_TRANSPORT_BAM` on `/dev/smdcntl8` (QMI_CONN_ID_RMNET_8)
- **SMD channel names:** DATA5_CNTL, DATA40_CNTL

JMR540's `MCM_atcop_svc` explicitly tunes SMD8: `echo 10 > /sys/class/tty/smd8/open_timeout` — the Orbic version skips this.

---

## QMI Services Used (by daemon)

Reconstructed from strings and import tables:

| QMI Service | RC400L daemon | JMR540 daemon |
|---|---|---|
| `QMI_AT` (AT command forwarding) | atfwd_daemon | atfwd_daemon + MCM_atcop_svc |
| `QMI_NAS` (network access service) | atfwd_daemon (GETSIB, PCISCAN, WDISABLEEN, RLKMODE, SER) | via MCM |
| `QMI_DMS` (device management) | atfwd_daemon (IMEI, CHIPID, CFUN) | via MCM |
| `QMI_QCMAP_MSGR` (mobile AP) | QCMAP_ConnectionManager | both QCMAP_CM and MCM_MOBILEAP_CM |
| `QMI_WDS` (wireless data) | netmgrd | netmgrd + mcm_data_srv |
| `QMI_LOC` (location/GPS) | atfwd_daemon (GPS handler) | via MCM location shims |
| `QMI_VOICE` | atfwd_daemon (voice call state handler present) | via mcm_ril_service |
| `QMI_PDC` (peripheral device config) | via QCMAP | via QCMAP |

---

## Diagnostic Test Binaries

| Tool | RC400L | JMR540 |
|---|---|---|
| `qmi_simple_ril_test` | present | present |
| `qmi_ping_svc` | — | present |
| `qmi_ping_test` | — | present |
| `qmi_ping_clnt_test_0000` | — | present |
| `qmi_ping_clnt_test_0001` | — | present |
| `qmi_ping_clnt_test_1000` | — | present |
| `qmi_ping_clnt_test_1001` | — | present |
| `qmi_ping_clnt_test_2000` | — | present |
| `mcm_data_test` | — | present (in /usr/tests/) |

JMR540 ships a complete QMI ping test suite for verifying end-to-end QMI transport. The RC400L has none of these — diagnostics were stripped for the product build.

---

## Key Findings

1. **The MCM framework is present on RC400L** (deployed from JMR540) but never tested against the live Orbic modem stack. Since both use MDM9607 and the same QMI library versions, MCM services communicating through qmuxd should work — but internal QMI service IDs and message formats could differ between modem firmware versions.

2. **The RC400L atfwd_daemon is a superset** of what the JMR540 exposes through AT commands — 44 commands vs 1 (CFUN). The JMR540 deferred the rest to MCM, which has its own command surface accessible through `MCM_ATCOP_CLI`.

3. **Voice call state handling exists in RC400L's atfwd_daemon** — the daemon registers for and receives `QMI_VOICE` call state indications despite this being a data-only device. The modem stack is running full voice QMI.

4. **GPS subsystem is more feature-rich on RC400L** — includes GPS simulation (forge mode), NMEA serial bridge, position fix reporting. JMR540 defers to MCM location shims.

5. **CPU runs faster on RC400L** — hispeed frequency 998400 Hz vs 800000 Hz on JMR540. Different product target; Orbic may prioritize throughput over battery life.

---

## Next Steps

- Start `mcm_ril_service` on RC400L via inittab, test whether it can register with qmuxd
- Compare `MCM_ATCOP_CLI` command surface against native `atfwd_daemon` AT commands
- Use `QMI_AT` service via qmuxd to directly test AT command forwarding (bypass atfwd_daemon)
- Cross-reference QMI_NAS message IDs for GETSIB/PCISCAN against Qualcomm MSM Interface headers
