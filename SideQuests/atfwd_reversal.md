# Side Quest: atfwd_daemon Reversal — RC400L (Orbic)

**Binary:** `/usr/bin/atfwd_daemon`
**Size:** 167,064 bytes (164 KB)
**Format:** ELF 32-bit LSB shared object, ARM EABI5, dynamically linked, stripped
**BuildID:** `e6c46cef98a14ab98a48bfe160b12a3786cc7e70`
**Compiler:** GCC (ARM EABI5, `.ARM.attributes` confirms `aeabi`)

**Comparison:** JMR540 `atfwd_daemon` is 20,200 bytes (20 KB) — 8× smaller. The JMR540 version handles only `+CFUN` and delegates everything else to `MCM_atcop_svc`. The Orbic build inlines 44 AT command handlers directly.

---

## Dynamic Imports

```
libc.so.6
libpthread.so.0
libstdc++.so.6
libgcc_s.so.1
libxml2.so.2          ← XML parsing (wlan_conf_6174.xml, syslog_conf.xml)
librt.so.1
libcrypto.so.1.0.0    ← RSA signature verification (USB mode switching)
libm.so.6
libqcmap_client.so.1  ← QCMAP_Client C++ class
libqmi_cci.so.1       ← QMI client interface
libqmi.so.1
libdsutils.so.1       ← Qualcomm data service utils
libqmiservices.so.1   ← QMI service definitions
```

Notable: `libcrypto` and `libxml2` are not typical for an AT command daemon. Both are used in specific handler subsystems (USB mode RSA check, WiFi XML config parsing respectively).

---

## QMI Services Accessed

Reconstructed from function names and QMI message IDs:

| QMI Service | Functions Used | Purpose |
|---|---|---|
| `QMI_AT` | `qmi_atcop_srvc_init_client`, `qmi_atcop_reg_at_command_fwd_req`, `qmi_atcop_fwd_at_cmd_resp`, `qmi_atcop_fwd_at_urc_helper` | AT command forwarding registration and response |
| `QMI_NAS` | `odm_nas_qmi_get_cell_ind_cb`, `odm_lte_getsib_cell_info`, `odm_lte_pci_band_scan` | LTE cell info, SIB retrieval, PCI scan |
| `QMI_DMS` | `qmi_dms_get_imei_num` | IMEI query |
| `QMI_QCMAP_MSGR` | `QCMAP_Client::EnableMobileAP`, `QCMAP_Client::DisableMobileAP`, `QCMAP_Client::ConnectBackHaul`, `QCMAP_Client::DisconnectBackHaul`, `QCMAP_Client::GetWWANPolicy`, `QCMAP_Client::SetWWANPolicy`, `QCMAP_Client::GetWWANStatus`, `QCMAP_Client::GetNetworkConfiguration` | ECM/USB tethering, WWAN management |
| `QMI_VOICE` | (indication callback registered) | Voice call state monitoring |
| `QMI_LOC` | GPS position fix session management | AT+GPS* handlers |

QMI messages exchanged (from log format strings):
- `QMI_AT_REG_AT_CMD_FWD_REQ_V01` — register AT commands with modem
- `QMI_AT_FWD_RESP_AT_CMD_REQ_V01` — send AT command request
- `QMI_AT_FWD_RESP_AT_CMD_RESP_V01` — send AT command response

---

## QCMAP_Client C++ Interface

The binary uses `libqcmap_client.so.1` through a C++ QCMAP_Client object. Mangled symbols recovered:

```
_ZN12QCMAP_ClientC1EPFvP17qmi_client_structjPvjS2_E
  → QCMAP_Client::QCMAP_Client(callback)     [constructor]

_ZN12QCMAP_Client14EnableMobileAPEP18qmi_error_type_v01
  → QCMAP_Client::EnableMobileAP(qmi_error*)

_ZN12QCMAP_Client15DisableMobileAPEP18qmi_error_type_v01
  → QCMAP_Client::DisableMobileAP(qmi_error*)

_ZN12QCMAP_Client15ConnectBackHaulE29qcmap_msgr_wwan_call_type_v01P18qmi_error_type_v01
  → QCMAP_Client::ConnectBackHaul(call_type, qmi_error*)

_ZN12QCMAP_Client18DisconnectBackHaulE29qcmap_msgr_wwan_call_type_v01P18qmi_error_type_v01
  → QCMAP_Client::DisconnectBackHaul(call_type, qmi_error*)

_ZN12QCMAP_Client13GetWWANPolicyEP30qcmap_msgr_net_policy_info_v01P18qmi_error_type_v01
  → QCMAP_Client::GetWWANPolicy(policy*, qmi_error*)

_ZN12QCMAP_Client13SetWWANPolicyE30qcmap_msgr_net_policy_info_v01P18qmi_error_type_v01
  → QCMAP_Client::SetWWANPolicy(policy, qmi_error*)

_ZN12QCMAP_Client13GetWWANStatusEP31qcmap_msgr_wwan_status_enum_v01S1_P18qmi_error_type_v01
  → QCMAP_Client::GetWWANStatus(v4_status*, v6_status*, qmi_error*)

_ZN12QCMAP_Client23GetNetworkConfigurationE29qcmap_msgr_ip_family_enum_v01P17qcmap_nw_params_tP18qmi_error_type_v01
  → QCMAP_Client::GetNetworkConfiguration(ip_family, nw_params*, qmi_error*)
```

These are called from the `+ECMPARAM`/`+ECMSTATE` handler to manage USB tethering, and potentially from other handlers that affect WAN connectivity.

---

## Registered AT Commands — Complete List (44)

Reconstructed from string literals found at registration time and from handler function log prefixes.

### Network / Modem

| Command | Direction | Handler | Notes |
|---|---|---|---|
| `+SYSCMD` | SET | `popen()` / `system()` | Shell command exec. Output piped back as response. This is the AT+SYSCMD vector — `Goint into SYSCMD`, `Read syscmd->%s`, `SYSCMD response.` |
| `+RLKMODE` | SET, QUERY | QMI NAS | Radio link key mode. `NO.resp -- QMI response RLKMODE set OK = %d` |
| `+SER` | SET, QUERY | QMI NAS | Serial/service mode. `NO.resp -- QMI response SER inq OK = %d` |
| `+WDISABLEEN` | SET, QUERY | QMI NAS | WiFi hardware disable. `NO.resp -- QMI response WDISABLE inq OK = %d`, `unwdisable` / `wdisable disable/enable` |
| `+CFUN` | SET | QMI DMS | Phone function control (modem on/off/reset) |
| `+CHIPID` | QUERY | sysfs/cmdline | Device chip ID. Reads `/usrdata/sec/chipid` or parses `/proc/cmdline`. `@@mk:chipid_str=%s` |
| `+IPR` | SET, QUERY | config | Baud rate |
| `+POWEROFF` | SET | system | Device power off |
| `+MEIGEDL` | — | unknown | Firmware download. Name "MEIGE" → Meige Technology module lineage |

### USB / Tethering (ECM)

| Command | Direction | Handler | Notes |
|---|---|---|---|
| `+ECMPARAM` | SET, QUERY | QCMAP_Client | USB ECM parameters: `autoconnect_en`, `ip_type`, `mobileap_en`. Calls `EnableMobileAP`/`DisableMobileAP`. `I:ecm_command_process action=%d`, `I:ecm_command_process mobileap_en=%d` |
| `+ECMSTATE` | QUERY | QCMAP_Client | USB ECM current state. `ecmstate_command_process_get`, public IP for IPv6 logged |
| `+ECMDUP` | SET | unknown | USB ECM duplicate mode |

### WiFi

| Command | Direction | Handler | Notes |
|---|---|---|---|
| `+WIFISSID` | SET, QUERY | XML + IPC | SSID get/set. Validates length, parses `/usrdata/data/usr/wlan/wlan_conf_6174.xml`, IPC with `wireless_net` daemon. `AT_WIFI:set ssid1/ssid2 failed!` |
| `+WIFIPSK` | SET, QUERY | XML + IPC + crypto | PSK get/set. Gets IMEI via QMI DMS, validates MAC from `wireless_net` via IPC socket `/tmp/MY_SOCKET`, can **generate PSK from IMEI**. Writes to `/usrdata/data/persistent/wlan/psk`. `AT_WIFI:wifi generate psk request coming...` |
| `+WLANCONFDEL` | SET | filesystem | Deletes WLAN configuration. `Goint into WLANCONFDEL` |

### GPS

| Command | Direction | Handler | Notes |
|---|---|---|---|
| `+GPSSTART` | SET | gps_ctl_srv | Starts GPS session. Launches `start-stop-daemon -S -b -a gps_ctl_srv` |
| `+GPSEND` | SET | gps_ctl_srv | Ends GPS session. `start-stop-daemon -K -n gps_ctl_srv` |
| `+GPSFIX` | QUERY | QMI LOC | Position fix. Response format: `+GPSFIX:%llu,%f,%c,%f,%c,%0.1f,%0.1f,%0.1f,%0.1f` (timestamp, lat, N/S, lon, E/W, altitude, h_accuracy, v_accuracy, speed). `GPS pd session not fix yet!`, `GPS pd session is closed!` |
| `+GPSCONFIG` | SET | QMI LOC | GPS session configuration |
| `+FGGPSINIT` | SET | forge GPS | GPS simulation init. Launches `start-stop-daemon -S -b -a serial_bridge -- -l /dev/nmea -r /dev/ttyHSL1` for NMEA bridge |
| `+FGGPSMODE` | SET | forge GPS | Simulation position mode. Full parameter set: `position_mode`, `position_recurrence`, `min_interval`, `preferred_accuracy`, `preferred_time`, `preferred_fixnum`, `preferred_fixtime`, `preferred_session_type`, `preferred_opera_mode` |
| `+FGGPSPORT` | SET | forge GPS | GPS port configuration |
| `+FGGPSRUN` | SET | forge GPS | Start GPS simulation. `echo 0 > /usrdata/gps_flag`, `cat /usrdata/gps_flag` |
| `+FGGPSSTOP` | SET | forge GPS | Stop GPS simulation |
| `+FGUARTNMEA` | SET, QUERY | config | UART NMEA output enable. Persists to `/usrdata/fguartnmea.cfg`. `The fguartnmea will be set to %d` |
| `+FGDEBUG` | — | forge GPS | Debug mode for forge GPS |

### LTE Cell Information

| Command | Direction | Handler | Notes |
|---|---|---|---|
| `+GETSIB` | QUERY | QMI NAS | Get System Information Block. Returns raw SIB packet data: `SIB_PKT: %s`, `SIB_PKT_LEN: %d`. Uses `odm_lte_getsib_cell_info`, registers cell indication callback `odm_nas_qmi_get_cell_ind_cb`. Error: `+GETSIB: ERROR`, `%s(): Invalid cellinfo ind msg error %d`, `%s(): No handler for SIB CELL IND id %d` |
| `+PCISCAN` | QUERY | QMI NAS | Physical Cell ID scan. Returns PCI list: `+PCISCAN: 0` on empty, `+PCISCAN: ERROR`, `odm_lte_pci_band_scan PCI NUM:%d`. Uses `odm_lte_pci_band_scan send qmi band scan` |

### Audio

| Command | Direction | Handler | Notes |
|---|---|---|---|
| `+AUDIOPATH` | SET, QUERY | amix | Audio path routing |
| `+PCMAUDIO` | SET | amix | PCM audio setup (CS voice or VoLTE). Sets `SEC_AUX_PCM_RX` mixer routes, TX/RX paths. `pcm_audio response.`, `pcm_VoLTE_audio response.` |
| `+PCMCONFIG` | SET | amix | PCM configuration. `pcm_config response.`, `pcm_VoLTE_config response.` |
| `+PCMPAD` | SET | amix | PCM pad settings. `pcm_pad response.`, `pcm_VoLTE_pad response.` |
| `+CODEC` | SET, QUERY | sysfs | Codec selection. Controls `/sys/module/snd_soc_nau8810/parameters/enable`. `echo Y/N > /sys/module/snd_soc_nau8810/parameters/enable` |
| `+CLVL` | SET, QUERY | amix | Speaker volume. 7 levels (0–6) mapped to mixer values: `amix "Headphone Playback Volume" 0/18/36/54/72/90/108/127`. Config stored to `/usrdata/pcm_spk_vol` |
| `+CMIC` | SET, QUERY | amix | Mic gain. 7 levels mapped to: `amix "Capture PGA Volume" 3/13/23/33/43/53/63`. Config stored to `/usrdata/pcm_mic_vol` |
| `+CMUT` | SET, QUERY | amix | Microphone mute. `amix "Mic PGA MICP Switch" 0/1 && amix "Mic PGA MICN Switch" 0/1`. Config to `/usrdata/pcm_mute` |
| `+MGTTS` | SET, QUERY | mgtts binary | Text-to-speech. Launches: `mgtts -m %d -u %d -s %d -t %s -o %s`, plays result with `aplay -C 1 -F PCM -R 16000 /usrdata/mgOutPcm`. Config: `/usrdata/mgtts/mgtts.cfg`, `/usrdata/mgtts/mgtts_volume.cfg` |
| `+MGTTSETUP` | SET, QUERY | mgtts config | TTS setup (speed, volume). `mgttsSetVspeedCfg`, `mgttsSetVolumeCfg`, `mgttsSetArgMode %d, mgttsSetArgVal %d` |
| `+MGTTSTATE` | QUERY | mgtts | TTS state query |

### Hardware / Power

| Command | Direction | Handler | Notes |
|---|---|---|---|
| `+MGGPIOCTRL` | SET, QUERY | sysfs GPIO | Arbitrary GPIO control. Full sysfs GPIO API: `GpioSysfs_ExportGpio`, `GpioSysfs_WriteDirection`, `GpioSysfs_WriteValue`, `GpioSysfs_ReadValue`. Path: `%s/gpio%d/%s` under `/sys/class/gpio`. `AT_FWD_CMD_MGGPIOCTRL_SET status:%s` |
| `+MGSLEEP` | QUERY | config | Query sleep mode. `query mgsleep coming...` |
| `+SLEEPEN` | SET, QUERY | sysfs | Sleep enable/disable. Persists to `/usrdata/sleepen.cfg`. Controls: `echo enable/disable > /sys/devices/78d9000.usb/usleepen` and `echo enable/disable > /sys/devices/soc:wakeup_report/wsleepen` |
| `+CHGBATID` | QUERY | sysfs | Battery ID. Uses `battery_id_get_value` |
| `+CHGBATINFO` | QUERY | sysfs | Battery info. Uses `battery_get_value`, reads `/sys/kernel/chg_info/voltage_battery` |
| `+CHGBATSTATUS` | QUERY | sysfs | Charge status. Uses `charge_type_get_cfg`/`charge_type_set_cfg` |
| `+MSECEN` | SET | unknown | Security enable. `AT_FWD_CMD_MSECEN_SET:%s`, `Unsupported MSECEN = %s` |

---

## Embedded Cryptographic Material

The binary contains **at least 4 large base64-encoded blobs** ranging from ~1.2 KB to ~1.6 KB each (decoded ~900–1200 bytes). These appear immediately before the RSA verification logic:

```
RSA Verify passed, switchUSB
/sbin/usb/compositions/switch_usb %s %d
```

The `switch_usb` path is only executed after `RSA Verify passed` — USB composition switching requires a valid RSA signature check against the embedded key material. This is a Meige-origin security feature: the device refuses to switch USB modes unless the command is signed.

The presence of `libcrypto.so.1.0.0` is entirely explained by this RSA verification. It is not used for anything else in the binary.

---

## Internal Version String

```
NO.1.0.2 -- +GETSIB command has been detected
NO.1.0.2 -- +PCISCAN command has been detected
NO.1.0.2 -- +RLKMODE has been detected
NO.1.0.2 -- +SLEEPEN command has been detected
NO.1.0.2 -- +WDISABLEEN command has been detected
```

The `NO.1.0.2` prefix appears consistently on commands that go through QMI NAS and the sleep/radio management handlers. This is likely an internal firmware/module version identifier baked into the handler registration table — not a global build version.

---

## MEIGE Module Origin

`+MEIGEDL` (firmware download) and the `MEIGE` string in the WiFi PSK handler both point to **Meige Technology** — a Chinese module manufacturer that produces MDM9607-based LTE modules (M602A, M611A, etc.) under the "Meige" brand.

The Orbic RC400L uses a Foxconn-assembled mainboard, but this evidence suggests the modem subsystem firmware is derived from or substantially based on a Meige MDM9607 module reference design. The RSA-protected USB mode switching is a known Meige feature used to prevent unauthorized USB mode changes on their modules.

Cross-referencing: Meige M602A/M611 AT command manuals document `AT+MEIGEDL`, `AT+MGGPIOCTRL`, `AT+MGSLEEP`, `AT+MGTTSETUP`, and the full GPS forge suite — all present in this binary.

---

## Voice Call State Handler (Unexpected)

The daemon registers for and processes `QMI_VOICE` call state indications:

```
Voice Connection Initialized. User Handle: %d
Voice call, mode %d, dir %d, type %d call id %d, state %d
```

The RC400L is a data-only hotspot with no voice calling functionality exposed to users. However, the MDM9607 modem is a full LTE Cat-4 SoC with voice capability. The `atfwd_daemon` monitors voice call state — either as a holdover from the Meige reference firmware or as a hook for a feature Orbic never enabled.

This means QMI_VOICE service is active on the modem and producing indications. Whether VoLTE or circuit-switched voice is actually functional at the radio level is unknown, but the PCM audio mixer commands (`+PCMAUDIO`, `+PCMCONFIG`) being present supports the possibility.

---

## Socket Interfaces

| Socket | Type | User |
|---|---|---|
| `/tmp/at-interface.srv.sock` | UNIX stream | Server socket — receives AT commands from other processes |
| `/tmp/at-interface-gps.srv.sock` | UNIX stream | GPS subsystem AT interface |
| `/tmp/qct-qcmap.clt.sock` | UNIX dgram | QCMAP client socket (connects to QCMAP_ConnectionManager) |
| `/tmp/MY_SOCKET` | UNIX stream | IPC with `wireless_net` daemon for IMEI/MAC retrieval |

---

## Filesystem Layout

| Path | Purpose |
|---|---|
| `/usrdata/sec/chipid` | Device chip ID persistent storage |
| `/usrdata/sleepen.cfg` | Sleep enable state (0/1) |
| `/usrdata/fguartnmea.cfg` | UART NMEA enable state |
| `/usrdata/gps_file` | GPS session state file |
| `/usrdata/gps_flag` | GPS run flag (0/1 via echo) |
| `/usrdata/mgtts/mgtts.cfg` | TTS configuration |
| `/usrdata/mgtts/mgtts_volume.cfg` | TTS volume configuration |
| `/usrdata/mgOutPcm` | TTS PCM output buffer |
| `/usrdata/pcm_mic_vol` | Mic gain level |
| `/usrdata/pcm_spk_vol` | Speaker volume level |
| `/usrdata/pcm_mute` | Mic mute state |
| `/usrdata/baud_rate.cfg` | Baud rate (IPR) |
| `/usrdata/data/persistent/wlan/psk` | Persistent WiFi PSK |
| `/usrdata/data/usr/wlan/wlan_conf_6174.xml` | WLAN configuration (XML, parsed by libxml2) |
| `/usrdata/data/usr/mac_data` | MAC address data |
| `/usrdata/forgedebug.cfg` | GPS forge debug config |
| `/usrdata/w_disable.cfg` | WiFi hardware disable state |
| `/etc/qcmobileapenable` | QCMAP mobile AP enable flag |
| `/etc/xml/wlan/wlan_conf_6174.xml` | Default WLAN config (before user override) |
| `/etc/xml/syslog/syslog_conf.xml` | Syslog configuration (libxml2) |

---

## Commands With Direct Shell Execution

These handlers call `popen()` or `system()` — they execute shell commands as root:

| Command | Shell Execution |
|---|---|
| `+SYSCMD` | `popen(cmd)` — arbitrary shell command, output returned in response |
| `+GPSSTART` | `start-stop-daemon -S -b -a gps_ctl_srv` |
| `+GPSEND` | `start-stop-daemon -K -n gps_ctl_srv` |
| `+FGGPSINIT` | `start-stop-daemon -S -b -a serial_bridge -- -l /dev/nmea -r /dev/ttyHSL1` |
| `+FGGPSRUN` | `echo 0 > /usrdata/gps_flag`, `cat /usrdata/gps_flag` |
| `+SLEEPEN` | `echo enable/disable > /sys/devices/78d9000.usb/usleepen` |
| `+CODEC` | `echo Y/N > /sys/module/snd_soc_nau8810/parameters/enable` |
| `+CLVL` | `amix "..."` (7 invocations per volume level) |
| `+CMIC` | `amix "..."` (gain levels) |
| `+CMUT` | `amix "Mic PGA MICP Switch" 0/1 && amix "Mic PGA MICN Switch" 0/1` |
| `+PCMAUDIO` | `amix "..."` (multiple mixer paths, VoLTE and CS voice routing) |
| `+MGTTS` | `mgtts -m %d -u %d -s %d -t %s -o %s`, `aplay -C 1 -F PCM ...` |
| `+ECMSTATE` / `+ECMPARAM` | (via QCMAP, not direct shell) |

`+SYSCMD` is the notable one. The handler literally calls `popen()` with the user-supplied string. This is the root command execution path the Rayhunter installer exploits.

---

## JMR540 Comparison

| Feature | RC400L atfwd | JMR540 atfwd |
|---|---|---|
| Size | 164 KB | 20 KB |
| AT commands registered | **44** | **1** (+CFUN only) |
| GPS handlers | full (6 real + 5 forge + NMEA) | none — deferred to MCM |
| Audio handlers | full (9 commands + amix control) | none |
| NAS/LTE handlers | GETSIB, PCISCAN, RLKMODE, SER, WDISABLEEN | none |
| Hardware I/O | GPIO, sleep, charging, battery, chipid | none |
| WiFi config | SSID, PSK, WLAN delete | none |
| USB/ECM | ECM state/params/dup | none |
| QCMAP integration | QCMAP_Client C++ calls | none |
| RSA verification | present (USB switch) | absent |
| Shell exec | popen + system | system only (+CFUN reset?) |
| Voice call monitoring | present | absent |
| MEIGE origin indicators | `+MEIGEDL`, RSA, GPS forge | absent |

---

## Research Threads

**Active:**
- Can `+GETSIB` be queried live via `adb shell serial "AT+GETSIB"` to retrieve raw SIB1/SIB2 from the serving cell? SIB data would expose cell configuration, handover parameters, and neighbor cell lists.
- Can `+PCISCAN` be triggered to list neighbor PCIs? This could provide the same data Rayhunter gets from DIAG but through AT, without needing CAP_NET_RAW.
- Is `+MGGPIOCTRL` actually wired to GPIOs connected to anything interesting on the RC400L PCB? (FCC photos showed LED headers — GPIO might control them.)
- Can `+FGGPSMODE` inject a fake GPS position? Full parameter set suggests it can — useful for location spoofing research.
- What does `+MSECEN` control? "Security enable" — could relate to the RSA USB-switch gate or a separate firmware security mode.
- Does `+MEIGEDL` still function? If the USB mode RSA check can be bypassed or the key is the same across all Meige-derived devices, this could be an OTA firmware update vector.

**Completed:**
- AT+SYSCMD confirmed working — this is the path Rayhunter uses for initial root access
- Complete AT command surface enumerated from binary strings
