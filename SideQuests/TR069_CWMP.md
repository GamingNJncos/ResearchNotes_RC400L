# Side Quest: TR-069 / CWMP — RC400L vs JMR540

**Protocol:** TR-069 (CWMP — CPE WAN Management Protocol)
**Status:** Firmware-static analysis; no live ACS session captured
**Devices:** Orbic RC400L (MDM9607) | JioFi JMR540 (MDM9607)

---

## Background

TR-069 (CWMP) is a DSL Forum / Broadband Forum standard that gives a carrier's Auto Configuration Server (ACS) bidirectional remote management of a CPE device. The CPE initiates outbound SOAP-over-HTTPS sessions to the ACS (Inform calls), and the ACS can send RPCs back (SetParameterValues, Download, Upload, Reboot, FactoryReset, AddObject, etc.). The ACS has close to unconditional control over any device that successfully contacts it.

Both devices ship a full CWMP client implementation. The configurations differ significantly in carrier engagement, authentication posture, and what capabilities are left exposed by default.

---

## File Inventory

### Orbic RC400L

| Path | Description |
|------|-------------|
| `/usr/bin/tr069` | CWMP client daemon — 316 KB, ELF 32-bit ARM, stripped |
| `/etc/xml/tr069/tr069.xml` | Runtime configuration (XML) |
| `/etc/xml/tr069/cert.pem` | TLS client certificate — meigsmart ODM cert |
| `/etc/xml/tr069/key.pem` | RSA private key paired with above cert |
| `/etc/xml/goahead/encrypt.conf` | Web UI encryption flags per subsystem |
| `/etc/xml/omadm/cpe_git.bb` | Yocto build recipe (ODM build artifacts) |

The binary is the CPE side only — no ACS-side logic. The daemon is started by `start_cpe_daemon` (runlevel 28).

### JioFi JMR540

| Path | Description |
|------|-------------|
| `/sbin/cwmpCPE` | CWMP client daemon — 425 KB, ELF 32-bit ARM, stripped |
| `/etc/cfg/main/cwmp_V01.cfg` | Runtime parameter store (key=value) |
| `/etc/ath/cwmpcfg` | Default value initialization script (sourced on first boot) |
| `/etc/cwmpcfg` | Boot wrapper — copies defaults to `/foxusr/cwmp/main/` |
| `/etc/init.d/cwmpcfg` | Init.d script, symlinked as `S38cwmpcfg` |
| `/usr/www/en-jio/mAcsManage.html` | Web UI: ACS settings page |
| `/usr/www/cgi-bin/en-jio/mAcsManage.html` | CGI-side copy of above |

Live config is written to `/foxusr/cwmp/main/` at runtime (writable flash partition). The `/info/trE/cacerts/` cert directory referenced in config is in the `foxusr` partition, not present in the system dump — provisioned at runtime.

---

## Configuration Comparison

### Core Parameters

| Parameter | RC400L | JMR540 |
|-----------|--------|--------|
| EnableCWMP | `0` (disabled) | `1` (enabled) |
| ACS URL | *(empty)* | `https://macs.oss.jio.com:8443/ftacs-digest/ACS` |
| ACS Username | *(empty)* | *(empty in cwmp_V01.cfg; set via cwmpcfg script)* |
| ACS Password | *(empty)* | *(empty in cwmp_V01.cfg; set via cwmpcfg script)* |
| ConnectionRequest Username | `admin` | `ftacs` |
| ConnectionRequest Password | `admin` | `ftacs` |
| ConnectionRequest Auth | `0` (disabled) | *(not explicit; auth method set per ACS server)* |
| ConnectionRequest Port | `7547` | *(inherits CWMP default: 7547)* |
| PeriodicInformEnable | `0` | `1` |
| PeriodicInformInterval | 3600 s | 86400 s (24 h) |
| STUN | Disabled | Not configured |
| UpgradesManaged | *(not set)* | `1` |
| UpgradeControl | *(not set)* | `1` |

### JMR540 Dual ACS Server Configuration

The JMR540 configures two ACS server entries in `cwmp_V01.cfg`:

```
InitServer_0_IsPrimary=1
InitServer_0_AuthMethod=1          ← Digest auth
InitServer_0_Username=606DC759C4A6 ← WiFi MAC address of this unit
InitServer_0_Password=0014A4-FAP_FC4008-606DC759C4A6
                       ↑            ↑         ↑
                  Foxconn OUI   internal   WiFi MAC
                               model code

InitServer_1_IsPrimary=0
InitServer_1_AuthMethod=2          ← Basic auth
InitServer_1_Username=             ← empty
InitServer_1_Password=             ← empty
```

The primary ACS server password is fully deterministic: `{OUI}-{model}_{MAC}`. OUI `0014A4` is Foxconn's registered prefix. The MAC is visible over the air during any WiFi probe. This means the ACS authentication credential for any individual JMR540 unit is reconstructable by an observer who can see the device's MAC address.

---

## TLS / Certificate Posture

### RC400L — Shared ODM Keypair

`/etc/xml/tr069/cert.pem` and `key.pem` are a matched self-signed certificate/key pair. The certificate:

```
Subject: C=CN, ST=China, L=Xi'an, O=meigsmart, OU=meigsmart,
         CN=caiyongbing, emailAddress=caiyongbing@meigsmart.com
Issuer:  Self-signed (same DN)
Valid:   2018-07-27 → 2028-07-24
Key:     RSA 1024-bit
```

This is an ODM developer personal certificate from meigsmart — the Chinese ODM that manufactured the RC400L for Orbic. Key findings:

- **Private key is in the firmware in cleartext.** Any party with access to the firmware image has the private key.
- **Shared across all units.** Every RC400L running this firmware has the same keypair. There is no per-device provisioning.
- **1024-bit RSA.** Below current minimum recommendations (2048-bit).
- **Personally identified.** The cert DN is a developer's name and personal work email address, not a product or carrier identity.

This cert appears intended for TLS client authentication with an ACS server. With the private key extracted, an attacker could impersonate any RC400L to any ACS that trusts this certificate.

The `encrypt.conf` file shows `<tr069>1</tr069>`, meaning the GoAhead web server encrypts TR-069 credentials in the management UI. The underlying `tr069.xml` config stores them in plaintext XML regardless.

### JMR540 — Runtime-Provisioned Cert

The JMR540 references `HttpsCertFile=/info/trE/cacerts/****.pem` but this partition is not present in the system dump — it is part of the `foxusr` UBIFS volume provisioned at runtime or during activation. No cert material is visible in static analysis. The HTTPS connection to `macs.oss.jio.com:8443` uses standard CA chain validation against this cert store.

---

## Build Artifact Disclosure

The file `/etc/xml/omadm/cpe_git.bb` is a Yocto BitBake recipe left in the production firmware. It reveals:

- **ODM identity:** meigsmart (Xi'an, China). Build project: `PRJ_SLT779`.
- **Multi-carrier scope:** The recipe includes install paths for a `VZW/config/` directory (Verizon) under OMA-DM for the same project variant. The same ODM build was producing firmware for both Orbic/Verizon and potentially other carriers simultaneously.
- **Developer artifacts:** Comment `caiyongbing@2018-05-16 for telnetd` — the build recipe explicitly adds `telnetd` to the system startup. This is a separate but compound concern: TR-069 is not the only remote management interface.
- **Source layout:** `${WORKSPACE}/cpe/` — confirms the full CPE software stack (web server, TR-069 client, WLAN management, OMA-DM, SMS, voice) ships from a single meigsmart internal codebase.

---

## JMR540 — Additional CWMP Capabilities

From `cwmpcfg`:

```sh
cfg -a CWMPDEBUGENABLE=${CWMPDEBUGENABLE:=3}   # debug level 3 enabled by default
cfg -a IMSI_NOTIFY=1                            # IMSI reported on every Inform
```

**Download/Upload queues:** 5 simultaneous download queues + 5 upload queues are configured, each with URL, credentials, delay, timer, and file path fields. This supports scheduled and queued firmware/config file operations initiated by the ACS.

**IMSI notification:** `IMSI_NOTIFY=1` means every CWMP Inform message includes the device's IMSI. Combined with the unit's MAC-derived ACS auth credential, Jio's ACS can correlate physical device identity (MAC/OUI) with active SIM card identity (IMSI) for the full fleet.

**TR-262 data model:** `deviceInfo.cfg` declares `TR-262-1-0-0` with Tunnel support. TR-262 is the *Femto Cell Gateway* data model — it defines management of femtocell (small cell) network equipment. Its presence in a consumer MiFi is unexpected and may expose management surface beyond what a standard MiFi data model (TR-181, TR-196) would provide.

**Commented-out default WiFi password:** Found in `cwmpcfg`:
```sh
# cfg -a CWMPAP1SECKEYPASSPHRASE="1234567a"
```
This is the prior-generation default WiFi passphrase, commented out but visible in cleartext in the production configuration script.

---

## TR-069 Protocol Abuse Surface

The following RPCs are standard to CWMP and apply to any device with an active ACS connection:

| RPC | Capability | Abuse |
|-----|-----------|-------|
| `SetParameterValues` | Write any writable parameter | Change ACS URL to attacker-controlled server |
| `GetParameterValues` | Read any parameter | Exfiltrate credentials, APN config, SSID/PSK |
| `Download` | Push file to device | Firmware replacement, config overwrite |
| `Upload` | Pull file from device | Exfiltrate running config from `/foxusr/cwmp/main/` |
| `FactoryReset` | Wipe device to defaults | Denial of service |
| `Reboot` | Force reboot | Denial of service / force re-registration |
| `AddObject` | Create new object instance | Add WANConnectionDevice, firewall rule instance |
| `DeleteObject` | Remove object instance | Delete routing entry, firewall rule |
| `ChangeDUState` | Install/remove software modules | (if supported) arbitrary software install |

An attacker who controls the ACS — by any means — has equivalent control to physical access plus root shell on the device.

### Threat Paths

**ACS URL poisoning (JMR540):**
The ACS URL `macs.oss.jio.com` is hardcoded as a default but stored in writable flash. If an attacker can reach the device's running CWMP config (e.g., via another vulnerability), they can redirect the ACS URL. Alternatively, DNS poisoning of `macs.oss.jio.com` during an Inform would cause the device to contact an attacker ACS. No certificate pinning is visible in the configuration.

**MAC-derived credential reconstruction (JMR540):**
The primary ACS Digest auth credential is `0014A4-FAP_FC4008-{MAC}`. The MAC is broadcast in WiFi probe/beacon frames. An attacker who observes a JMR540's MAC over WiFi can reconstruct its ACS password and authenticate to Jio's ACS as that device — enabling parameter enumeration and potentially Inform replay attacks.

**ConnectionRequest with no authentication (RC400L):**
`ConnectionRequestAuth=0` means the TR-069 daemon on the RC400L accepts incoming ConnectionRequest HTTP messages from any source on port 7547 without validating credentials. The credentials `admin/admin` would not be checked even if auth were enabled. Any host that can reach port 7547 on the device can trigger the CPE to initiate an ACS session. Combined with control of an ACS server, this is a full-session initiation primitive that requires no existing CPE-side authentication.

**ODM keypair impersonation (RC400L):**
The RSA private key in `key.pem` is common across all RC400L units and is extractable from firmware. Any ACS that performs mutual TLS using this certificate as the client trust anchor will accept a connection from an attacker who holds this key, without being able to distinguish it from a legitimate device.

**Firmware update without visible integrity verification:**
Neither device's config includes parameters referencing signature verification for firmware pushed via the Download RPC. The `UpgradesManaged=1` and `UpgradeControl=1` flags on the JMR540 confirm the ACS has upgrade authority with no additional validation visible in the CPE config.

---

## Summary

| Finding | RC400L | JMR540 |
|---------|--------|--------|
| CWMP enabled by default | No | **Yes** |
| Hardcoded ACS URL | No | **Yes** (`macs.oss.jio.com`) |
| Default connection request auth | **Disabled** (`Auth=0`) | Enabled (`ftacs/ftacs`) |
| ACS credentials | None (empty) | **MAC-derived, reconstructable** |
| TLS material in firmware | **ODM shared keypair (cleartext)** | Runtime-provisioned (not in dump) |
| Per-device cert identity | No (shared ODM cert) | Yes (MAC as username) |
| IMSI reported to ACS | Unknown | **Yes** (`IMSI_NOTIFY=1`) |
| Remote firmware upgrade | Not configured | **Enabled** |
| Data model anomaly | None noted | **TR-262 Femtocell** |
| Build artifact disclosure | **ODM identity, multi-carrier scope** | None |
| Default credential exposure | `admin/admin` (ConnReq, auth off) | `ftacs/ftacs` (ConnReq) + `1234567a` (WiFi, commented) |
