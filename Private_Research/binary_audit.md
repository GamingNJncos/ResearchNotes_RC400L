# Binary & Symlink Audit: JMR540 vs RC400L (Orbic)

## Objective
Identify binaries and symlinks present on JMR540 partitions that do NOT exist on the RC400L.
Goal: find portable tools that could expand capabilities on a jailed-root RC400L.

## Status
- [x] Scan JMR540 rootfs / system / recovery
- [x] Scan JMR540 modem & libs
- [x] Scan Orbic rootfs / recoveryfs / cachefs / usrfs
- [x] Scan Orbic modem & libs
- [x] Diff and analysis

## Architecture Notes
- Both devices: Qualcomm MDM9607, ARM Cortex-A7 (armv7, 32-bit)
- Both use glibc 2.22 (NOT musl) — ABI compatible
- Both use OpenSSL 1.0.0 — ABI compatible
- Both use SysV init (no systemd)
- Both have the Qualcomm QMI/QCMAP stack
- JMR540 busybox: 978,888 bytes (~152 applets + fatattr, sha3sum)
- Orbic busybox: 1,259,572 bytes (~183 applets, larger but missing fatattr/sha3sum)

---

## HIGH-VALUE: Unique to JMR540 (Not on RC400L)

### TIER 1 — Immediate Tactical Value (Escape / Privilege Escalation)

| Binary | Path | Size | Why It Matters |
|--------|------|------|----------------|
| `su.shadow` | /bin/ | 36,512 | **Full su implementation** with shadow password support. Orbic has NO su binary. |
| `login.shadow` | /bin/ | 68,396 | **Full login** with shadow/PAM. Could enable persistent shell access. |
| `nologin` | /sbin/ | 5,916 | Account lockout tool — useful for hardening after gaining access. |
| `chroot` | /sbin/ (busybox) | symlink | Busybox applet on JMR540. Can break out of jailed environments. |
| `fatattr` | /bin/ (busybox) | symlink | **FAT filesystem attribute manipulation** — unique JMR540 busybox applet. Not compiled into Orbic busybox. |
| `passwd.shadow` | /usr/bin/ | 42,388 | Change passwords. Orbic has no standalone passwd binary. |
| `vipw.shadow` | /sbin/ | 43,176 | Edit passwd/shadow files safely. |

### TIER 2 — User/Group Management (Persistence & Privilege)

| Binary | Path | Size | Purpose |
|--------|------|------|---------|
| `useradd` | /usr/sbin/ | 83,836 | Create new user accounts |
| `userdel` | /usr/sbin/ | 53,052 | Delete user accounts |
| `usermod` | /usr/sbin/ | 81,004 | Modify user accounts |
| `groupadd` | /usr/sbin/ | 40,072 | Create groups |
| `groupdel` | /usr/sbin/ | 35,848 | Delete groups |
| `groupmod` | /usr/sbin/ | 47,424 | Modify groups |
| `groupmems` | /usr/sbin/ | 40,008 | Manage group membership |
| `newusers` | /usr/sbin/ | 54,632 | Batch user creation |
| `chage` | /usr/bin/ | 39,532 | Change password aging |
| `chfn.shadow` | /usr/bin/ | 32,916 | Change finger info |
| `chsh.shadow` | /usr/bin/ | 44,104 | Change login shell |
| `chpasswd.shadow` | /usr/sbin/ | 35,260 | Batch password changes |
| `chgpasswd` | /usr/sbin/ | 40,168 | Batch group password changes |
| `expiry` | /usr/bin/ | 22,020 | Check password expiration |
| `faillog` | /usr/bin/ | 17,080 | Login failure log |
| `gpasswd` | /usr/bin/ | 45,096 | Administer groups |
| `grpck` | /usr/sbin/ | 39,908 | Verify group file integrity |
| `grpconv/grpunconv` | /usr/sbin/ | ~35K | Convert group shadow files |
| `lastlog` | /usr/bin/ | 12,188 | Show last login info |
| `logoutd` | /usr/sbin/ | 8,052 | Enforce login time restrictions |
| `newgidmap` | /usr/bin/ | 27,712 | Set GID mappings (user namespaces) |
| `newuidmap` | /usr/bin/ | 27,712 | Set UID mappings (user namespaces) |
| `pwck/pwconv/pwunconv` | /usr/sbin/ | ~30K | Password file management |
| `prepasswd` | /sbin/ | 9,172 | Pre-set passwords |

**Dependency:** These all link against the shadow library suite. May need `libshadow` or be statically linked — verify with `readelf -d`.

### TIER 3 — Network & Connectivity Tools

| Binary | Path | Size | Purpose |
|--------|------|------|---------|
| `pppd` | /usr/sbin/ | 261,996 | **PPP daemon** — dial-up/VPN/serial connections. Not on Orbic. |
| `chat` | /usr/sbin/ | 22,916 | Modem chat scripts (used with pppd) |
| `poff` / `pon` | /usr/bin/ | scripts | PPP connect/disconnect helpers |
| `tinyproxy` | /usr/sbin/ | 61,716 | **Lightweight HTTP proxy** — could tunnel traffic or pivot |
| `thttpd` | /sbin/ | 120,908 | **Lightweight HTTP server** — web shell host, file exfil |
| `ddclient` | /usr/sbin/ | 137,322 | **Dynamic DNS client** (Perl script) — callback/persistence |
| `conntrackd` | /usr/sbin/ | 265,216 | Connection tracking daemon — firewall state sync |
| `pimd` | /usr/sbin/ | 112,164 | PIM multicast routing daemon |
| `wpa_supplicant` | /usr/sbin/ | 834,332 | **WPA supplicant** — WiFi client mode. NOT on Orbic. |
| `wpa_cli` | /usr/sbin/ | 65,896 | WPA supplicant CLI control |
| `wpa_passphrase` | /usr/sbin/ | 29,288 | Generate WPA PSK |
| `fx_wpa_app` | /usr/sbin/ | 104,484 | Foxconn WPA management app |
| `fx_wpa_ui` | /usr/sbin/ | 47,812 | Foxconn WPA UI |
| `wlan_services` | /usr/sbin/ | 13,256 | WLAN service manager |
| `nfnl_osf` | /usr/sbin/ | 10,620 | OS fingerprinting via netfilter |
| `xtables-multi` | /usr/sbin/ | 73,392 | **iptables/ip6tables** unified binary. Orbic has no iptables binary! |

### TIER 4 — D-Bus Framework (IPC Attack Surface)

| Binary | Path | Size | Purpose |
|--------|------|------|---------|
| `dbus-daemon` | /usr/bin/ | 332,292 | **D-Bus message bus daemon** — entire IPC framework not on Orbic |
| `dbus-send` | /usr/bin/ | 17,988 | Send D-Bus messages (control services) |
| `dbus-monitor` | /usr/bin/ | 14,108 | Sniff D-Bus traffic |
| `dbus-launch` | /usr/bin/ | 14,980 | Launch D-Bus session |
| `dbus-run-session` | /usr/bin/ | 10,628 | Run command in D-Bus session |
| `dbus-cleanup-sockets` | /usr/bin/ | 9,588 | Clean stale sockets |
| `dbus-uuidgen` | /usr/bin/ | 8,108 | Generate machine UUID |

**Dependency:** Requires `libdbus-1.so.3` (present on JMR540, NOT on Orbic). Would need to bring the library.

### TIER 5 — MCM Framework (Additional Modem Control Layer)

| Binary | Path | Size | Purpose |
|--------|------|------|---------|
| `MCM_MOBILEAP_ConnectionManager` | /usr/bin/ | 73,612 | MCM mobile AP connection manager |
| `MCM_MOBILEAP_CLI` | /usr/bin/ | 66,308 | MCM mobile AP CLI |
| `MCM_ATCOP_CLI` | /usr/bin/ | 14,456 | MCM AT command CLI |
| `MCM_atcop_svc` | /usr/bin/ | 18,152 | MCM AT command service |
| `mcm_data_srv` | /usr/bin/ | 52,996 | MCM data service |
| `mcm_ril_service` | /usr/bin/ | 340,412 | **MCM RIL service** — radio interface layer control |
| `mcmlocserver` | /usr/bin/ | 55,664 | MCM location server |
| `FX_QCMAP_IPC` | /usr/bin/ | 35,264 | Foxconn QCMAP IPC bridge |

**Dependency:** Requires `libmcm.so.0`, `libmcmipc.so.0`, `libmcm_log_util.so.0` — all present on JMR540, NOT on Orbic.

### TIER 6 — GPS / Location

| Binary | Path | Size | Purpose |
|--------|------|------|---------|
| `garden_app` | /usr/bin/ | 31,956 | GPS test/garden application |
| `location_hal_test` | /usr/bin/ | 110,552 | Location HAL test tool |

**Dependency:** Requires 18+ location libraries (`libloc_*`, `libgps_*`, `libgeofence`, `libizat_core`, etc.) — all on JMR540, NONE on Orbic.

### TIER 7 — Audio / ALSA

| Binary | Path | Size | Purpose |
|--------|------|------|---------|
| `aplay` | /usr/bin/ | 19,444 | ALSA audio playback |
| `arec` | /usr/bin/ | 17,676 | ALSA audio recording |
| `amix` | /usr/bin/ | 7,620 | ALSA mixer control |
| `alsaucm_test` | /usr/bin/ | 12,188 | ALSA UCM test |

**Dependency:** Requires `libalsa_intf.so.1`, `libaudioalsa.so.1`, `libaudcal.so.1`, `libacdbloader.so.1` — on JMR540 only.

### TIER 8 — Diagnostics & Debug

| Binary | Path | Size | Purpose |
|--------|------|------|---------|
| `cnss_diag` | /usr/bin/ | 186,912 | **WiFi/CNSS diagnostics** — packet logging, firmware debug |
| `athdiag` | /usr/bin/ | 21,936 | Atheros WiFi diagnostics |
| `fampdiag` | /usr/bin/ | 31,232 | Factory diagnostics |
| `ipacmdiag` | /usr/bin/ | 9,112 | IPA connection manager diagnostics |
| `ipacm_perf` | /usr/bin/ | 28,368 | IPA performance tool |
| `pktlogconf` | /usr/bin/ | 11,400 | Packet log configuration |
| `traf-monitor` | /usr/bin/ | 24,976 | Traffic monitoring daemon |
| `traf-monitor-cli` | /usr/bin/ | 8,924 | Traffic monitor CLI |
| `uim_test_client` | /usr/bin/ | 40,752 | UIM (SIM) test client |

### TIER 9 — Foxconn Device Management

| Binary | Path | Size | Purpose |
|--------|------|------|---------|
| `cfg` | /bin/ | 452,664 | Configuration management tool |
| `devinfo` | /bin/ | 9,836 | Device info query |
| `3gcm` | /usr/bin/ | 142,716 | 3G connection manager |
| `3gcmif` | /usr/bin/ | 17,756 | 3G CM interface |
| `apMgr` | /sbin/ | 59,672 | AP manager |
| `apn` | /sbin/ | 12,336 | APN configuration |
| `cwmpCPE` | /sbin/ | 435,020 | **TR-069 CPE client** — remote device management |
| `freset` | /sbin/ | 7,632 | Factory reset |
| `internet` | /sbin/ | 14,188 | Internet connection control |
| `lan` | /sbin/ | 16,568 | LAN configuration |
| `wan` | /sbin/ | 14,604 | WAN configuration |
| `wan_wifi` | /sbin/ | 20,436 | WAN WiFi bridge |
| `lan_wifi` | /usr/sbin/ | 6,132 | LAN WiFi config |
| `port_forward` | /sbin/ | 13,500 | Port forwarding rules |
| `router` | /sbin/ | 7,912 | Router mode config |
| `simlock` | /sbin/ | 23,084 | **SIM lock/unlock** |
| `wifi_cal_bin` | /sbin/ | 10,720 | WiFi calibration |
| `wifi_nv_mac` | /sbin/ | 8,492 | WiFi NV MAC address |
| `fx-usb-switch` | /usr/sbin/ | 7,500 | USB mode switching |
| `fx-vbatt` | /usr/sbin/ | 13,524 | Battery voltage monitor |
| `fx_shutdown` | /usr/sbin/ | 6,660 | Foxconn shutdown handler |
| `fx_send_data` | /usr/bin/ | 10,260 | Send data via Foxconn IPC |
| `fxdevmgr_cli` | /usr/sbin/ | 15,868 | Foxconn device manager CLI |
| `fxpollinkey` | /usr/sbin/ | 10,368 | Poll input keys |
| `fxui-led` | /usr/sbin/ | 30,144 | LED control |
| `firmware_upgrade` | /usr/sbin/ | 6,540 | Firmware upgrade tool |
| `upgrade` | /usr/sbin/ | 45,748 | System upgrade |
| `modify_smbuser` | /usr/sbin/ | 5,900 | SMB user modification |
| `modify_workgroup` | /usr/sbin/ | 6,388 | SMB workgroup config |
| `rjil-vvm` | /usr/sbin/ | 12,996 | Jio visual voicemail |
| `monitor_qcmap.sh` | /bin/ | 523 | QCMAP monitor script |

### TIER 10 — Misc Tools / System

| Binary | Path | Size | Purpose |
|--------|------|------|---------|
| `IoEConsoleClient` | /usr/bin/ | 55,124 | IoE (Internet of Everything) console |
| `battery` | /usr/sbin/ | 6,152 | Battery status tool |
| `pmm` | /usr/sbin/ | 21,468 | Power management module |
| `pmm_test` | /usr/sbin/ | 7,196 | PMM test |
| `reg` | /usr/bin/ | 6,424 | Register access tool |
| `genl-ctrl-list` | /usr/sbin/ | 7,828 | Generic netlink control list |
| `run-postinsts` | /usr/sbin/ | 1,746 | Run post-install scripts |
| `update-rc.d` | /usr/sbin/ | 5,062 | Manage SysV init symlinks |
| `qmi_ping_*` (7 tools) | /usr/bin/ | ~16K ea | QMI ping test suite |

---

## Unique Busybox Applets: JMR540 vs Orbic

JMR540 busybox has these applets NOT in Orbic busybox:
| Applet | Purpose |
|--------|---------|
| `fatattr` | **FAT filesystem extended attributes** — manipulate attrs on vfat partitions |
| `sha3sum` | SHA-3 hash computation |

Orbic busybox has these applets NOT in JMR540 busybox:
| Applet | Purpose |
|--------|---------|
| `login` | Built into busybox on Orbic (JMR540 uses shadow's login instead) |
| `su` | Built into busybox on Orbic (JMR540 uses shadow's su instead) |

---

## Unique Shared Libraries: JMR540 Only

### Critical for Portability
| Library | Purpose | Needed By |
|---------|---------|-----------|
| `libdbus-1.so.3` | D-Bus IPC | dbus-daemon, dbus-send, etc. |
| `libmcm.so.0` | MCM framework | MCM_* binaries |
| `libmcmipc.so.0` | MCM IPC | MCM_* binaries |
| `libmcm_log_util.so.0` | MCM logging | MCM_* binaries |
| `libmcm_srv_audio.so.0` | MCM audio service | MCM audio |
| `libpcap.so.1` | **Packet capture** | cnss_diag, potential tcpdump |
| `libwpa_client.so` | WPA supplicant client | wpa_cli, fx_wpa_app |
| `libavahi-client.so.3` | mDNS/service discovery | Avahi stack |
| `libavahi-common.so.3` | Avahi common | Avahi stack |
| `libavahi-core.so.7` | Avahi core | Avahi stack |
| `libavahi-glib.so.1` | Avahi GLib integration | Avahi stack |
| `libloc_*.so` (8+ libs) | GPS/Location | garden_app, location_hal_test |
| `libgps_*.so` (2 libs) | GPS utilities | GPS stack |
| `libalsa_intf.so.1` | ALSA audio interface | aplay, arec, amix |
| `libaudioalsa.so.1` | Audio ALSA | Audio stack |
| `libacdb*.so` (4 libs) | Audio calibration DB | Audio stack |
| `libbroker.so` | Foxconn message broker | Foxconn apps |
| `libfwupgrade.so` | Firmware upgrade lib | firmware_upgrade |
| `libfxcutil.so` | Foxconn utility lib | fx_* apps |

### Also on JMR540 but NOT Orbic
| Library | Purpose |
|---------|---------|
| `libreadline.so` | NOT on JMR540 (Orbic only) |
| `libsqlite3.so` | NOT on JMR540 usr/lib (Orbic only) |
| `libcurl.so` | NOT on JMR540 (Orbic only) |

---

## Unique Init Scripts: JMR540 Only

| Script | Purpose |
|--------|---------|
| `start_Foxconn_Application_le` | Main Foxconn application launcher |
| `start_MCM_MOBILEAP_ConnectionManager_le` | MCM mobile AP |
| `start_mcm_data_srv_le` | MCM data service |
| `start_mcm_ril_srv_le` | MCM RIL service |
| `start_MCM_atcop_svc_le` | MCM AT command service |
| `start_embms_le` | eMBMS service |
| `start_ipacmdiag_le` | IPA diagnostics |
| `start_shortcut_fe_le` | **Shortcut Forwarding Engine** — hardware-accelerated packet forwarding |
| `start_wlan_services` | WLAN services |
| `fx_ap` | Foxconn AP mode |
| `fx_ap_restart` | AP restart |
| `fx_ar6k` | AR6K WiFi driver |
| `fx_download_mode` | Download/flash mode |
| `fx_performance` | Performance tuning |
| `fx_signal` | Signal handling |
| `fx_sta` | Station (client) mode |
| `cfg` / `cwmpcfg` | Configuration / TR-069 |
| `thttpd.sh` | Lightweight HTTP server |
| `mcmlocserverd` | MCM location server |
| `diagrebootapp` | Diag-triggered reboot |
| `fampdiag` | Factory diagnostics |
| `ppp` | PPP daemon control |

---

## Unique to Orbic (Not on JMR540) — For Reference

| Binary | Purpose |
|--------|---------|
| `LKCore` | Orbic's main app (LK=LittleKernel based UI) |
| `goahead` | GoAhead web server (vs JMR540's thttpd) |
| `mbimd` | MBIM daemon (vs JMR540's QMI-only approach) |
| `mdm-daemon` | Orbic modem daemon |
| `mgtts` | Orbic TTS engine |
| `iperf` / `iperf3` | Network performance testing |
| `sqlite3` | SQLite CLI |
| `hci_qcomm_init` | Bluetooth HCI init |
| `i2cdetect/dump/get/set` | I2C bus tools |
| `oma_dm` / `dmclient` | OMA-DM device management |
| `tr069` | TR-069 client (Orbic version) |
| `ethtool` | Ethernet tool |
| `flash_erase/lock/unlock` | MTD flash tools |
| `nanddump/nandtest/nandwrite` | NAND flash tools |
| `sigma_dut` | WiFi certification test tool |
| `sntp` | Simple NTP client |
| `sms` | SMS tool |
| `qt_daemon/qt_process` | Qt UI framework |
| `wireless_net` / `wland` / `wscd` | Orbic WiFi management |
| `perl5.22.0` | Perl 5.22 (vs JMR540's 5.20) |

---

## Portability Assessment

### Easy to Port (Self-contained or matching lib deps)
These binaries should work if copied to the RC400L since both devices share glibc 2.22 + OpenSSL 1.0.0:

1. **`su.shadow`** + **`login.shadow`** — likely link only against libc, libcrypt, libpam (check with readelf)
2. **`thttpd`** — lightweight, typically minimal deps
3. **`nologin`** — trivial binary
4. **`passwd.shadow`** + user management tools — shadow suite, likely self-contained
5. **`xtables-multi`** (iptables) — deps on libip4tc/libip6tc/libxtables which Orbic already has
6. **`pppd`** + `chat` — usually links libc + libcrypt only
7. **`tinyproxy`** — minimal deps
8. **`conntrackd`** — deps on libnetfilter_conntrack (present on both)
9. **`cfg`** / **`devinfo`** — may have Foxconn-specific deps
10. **Busybox from JMR540** — drop-in replacement to get `fatattr`, `sha3sum`

### Requires Bringing Libraries
1. **D-Bus stack** — need `libdbus-1.so.3` (+ deps)
2. **MCM framework** — need `libmcm*.so` (3-4 libs)
3. **GPS/Location** — need 18+ location libs
4. **Audio/ALSA** — need 7+ audio libs
5. **WPA supplicant** — need `libwpa_client.so`
6. **Avahi/mDNS** — need 4 avahi libs
7. **libpcap** — single lib, enables packet capture

### Recommended Priority Actions

1. **Copy `xtables-multi`** → get iptables/ip6tables on the RC400L (firewall control, NAT, port forwarding). Orbic already has the required iptc/xtables libs.
2. **Copy shadow suite** (`su.shadow`, `login.shadow`, `passwd.shadow`, `useradd`, `usermod`) → persistent user/auth control.
3. **Copy `thttpd`** → lightweight web server for file transfer or web shell.
4. **Copy `tinyproxy`** → HTTP proxy for traffic pivoting.
5. **Copy `pppd` + `chat`** → serial/modem PPP connections.
6. **Copy `libpcap.so.1`** → enables packet capture tools (compile tcpdump against it).
7. **Copy JMR540 busybox** → gain `fatattr` and `sha3sum` applets (test compatibility first).
8. **Copy `wpa_supplicant` + `wpa_cli` + `libwpa_client.so`** → WiFi client mode (connect to external networks).
9. **Copy `simlock`** → SIM lock/unlock tool (carrier unlock potential).
10. **Copy `cnss_diag`** → WiFi firmware diagnostics and packet logging.

---

## Next Steps
- [ ] Run `readelf -d` on high-priority JMR540 binaries to verify exact library dependencies
- [ ] Cross-reference Orbic's existing libs to confirm which JMR540 binaries are truly portable
- [ ] Test binary compatibility by copying a simple tool (e.g., `nologin`) to a running RC400L
- [ ] Investigate whether Orbic's larger busybox can be rebuilt with fatattr/sha3sum enabled
- [ ] Check if `xtables-multi` version matches Orbic's libiptc/libxtables versions
