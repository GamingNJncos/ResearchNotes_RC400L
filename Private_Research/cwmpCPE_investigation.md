# cwmpCPE (TR-069 CPE Client) — Investigation Notes

## Overview
- **Binary:** `cwmpCPE`
- **Source:** JMR540 `/sbin/cwmpCPE`
- **Size:** 435,020 bytes (425 KB)
- **Type:** ELF 32-bit LSB executable, ARM EABI5, dynamically linked

## What is TR-069 / CWMP?
TR-069 (CPE WAN Management Protocol) is a remote device management protocol used by ISPs to:
- Remotely configure device parameters (APN, WiFi SSID, firewall rules, etc.)
- Push firmware updates over-the-air
- Monitor device health, signal strength, connection status
- Provision new devices automatically on first boot
- Run diagnostics remotely (ping, traceroute, speed test)

The CPE (Customer Premises Equipment) client connects to an ACS (Auto Configuration Server) operated by the carrier.

## Dependencies
```
libbroker.so        — Foxconn message broker IPC (MISSING on Orbic, but available in 19_traf_monitor package)
libc.so.6           — present on Orbic
libcrypto.so.1.0.0  — present on Orbic
libfwupgrade.so     — Foxconn firmware upgrade lib (MISSING on Orbic, on JMR540 only)
libpthread.so.0     — present on Orbic
libssl.so.1.0.0     — present on Orbic
```

## Portability Status
**PARTIALLY PORTABLE** — needs 2 additional libs:
- `libbroker.so` (202 KB) — already staged in `19_traf_monitor`
- `libfwupgrade.so` — size/deps TBD, on JMR540 `/usr/lib/`

## Research Questions
- [ ] What ACS server does the Orbic RC400L normally connect to? (Check Orbic's `tr069` binary config)
- [ ] Can cwmpCPE be pointed at a local ACS (e.g., GenieACS, OpenACS)?
- [ ] What parameters does it expose? (Data model — TR-181, TR-098, vendor extensions?)
- [ ] Does the Orbic already have its own TR-069 client (`tr069` binary exists on Orbic)?
- [ ] Could running both TR-069 clients cause conflicts?
- [ ] What is the security model — mutual TLS? HTTP digest? Open?
- [ ] Is `libfwupgrade.so` functional on Orbic or does it depend on Foxconn partition layout?

## Potential Use Cases
1. **Local ACS server** — set up GenieACS on a laptop, point cwmpCPE at it for full remote management
2. **Parameter discovery** — TR-069 data models expose every configurable parameter on the device
3. **OTA firmware** — push custom firmware via the CWMP firmware upgrade RPC
4. **Carrier impersonation** — understand what the carrier's ACS can do to the device

## Security Concerns
- Running a CWMP client that phones home to an ISP ACS could expose the device to remote reconfiguration
- The Orbic already has its own `tr069` binary — running JMR540's `cwmpCPE` simultaneously is untested
- `libfwupgrade.so` could have destructive capabilities (writing to flash partitions)

## Related Files on JMR540
- `/etc/cwmp/` — config directory (check for ACS URL, credentials)
- `/sbin/cwmpCPE` — the binary
- `/etc/init.d/cwmpcfg` — init script
- `cfg` tool (staged in `16_cfg`) — may interact with cwmpCPE config

## Next Steps
- [ ] Extract `libfwupgrade.so` from JMR540 and check its deps
- [ ] Examine JMR540 `/etc/cwmp/` config files for ACS endpoints
- [ ] Compare with Orbic's `tr069` binary capabilities
- [ ] Set up a test ACS (GenieACS) if porting is attempted
