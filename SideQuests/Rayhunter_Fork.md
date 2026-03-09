# Side Quest: Rayhunter Fork — Boot Mask & DIAG Log Categories

The RC400L ships with [rayhunter](https://github.com/EFForg/rayhunter) from the EFF as its IMSI-catcher detection daemon. This fork extends it with two capabilities needed for practical research use:

1. **Persistent boot mask** — the selected DIAG log categories are applied to the modem at every startup, regardless of operating mode
2. **Streaming API** — `GET /api/stream` returns a live chunked octet-stream of raw DIAG frames, enabling real-time capture with external tools (QCSuper, Wireshark)

Source: `Firmware_Backups/rayhunter-OLD/` (gitignored — firmware dump)
Build + deploy scripts: `PortableApps/26_raytrap/rh_build.sh`, `rh_deploy.sh`

---

## DIAG Log Mask Categories

The rayhunter UI exposes 14 toggleable log categories plus an "Enable All" override. Each category maps to one or more Qualcomm DIAG log code IDs sent to the modem via `DIAG_LOG_CONFIG_F`.

### MDM9607 RAT Support

The RC400L uses the **Qualcomm MDM9607** (LTE Cat-4). Supported radio access technologies:

| RAT | Supported | Notes |
|-----|-----------|-------|
| LTE (4G) | ✓ | Primary RAT — all LTE categories apply |
| WCDMA / HSPA (3G) | ✓ | Fallback RAT — limited coverage areas |
| GSM / GPRS / EDGE (2G) | ✓ | Emergency fallback |
| NR / 5G | ✗ | **MDM9607 is LTE Cat-4 only — no 5G hardware** |

### Category Reference Table

| Category | DIAG Code(s) | Protocol Layer | What It Captures on MDM9607 |
|----------|-------------|----------------|------------------------------|
| `lte_rrc` | `0xB0C0` | LTE RRC | System Information Blocks (SIBs 1–13), RRCConnectionSetup/Release, MeasurementReport, HandoverCommand, SecurityModeCommand. **Primary source for cell identity (EARFCN, PCI, TAC, PLMN) and neighbor lists.** |
| `lte_nas` | `0xB0E2 0xB0E3 0xB0EC 0xB0ED` | LTE NAS (EMM/ESM) | Attach Request/Accept/Reject, Authentication Request/Response, Security Mode Command, TAU (Tracking Area Update), PDN Connectivity Request, Detach. Reveals GUTI, IMSI exposure events, authentication vectors. |
| `lte_l1` | `0xB17F 0xB11F 0xB180 0xB100 0xB101` | LTE Physical Layer | Serving cell RSRP/RSRQ/SINR measurements, neighbor cell scan results, channel estimates, timing advance, PBCH decode. Used for signal quality monitoring and rogue cell detection. |
| `lte_mac` | `0xB063 0xB064 0xB065 0xB08A 0xB08B 0xB08C` | LTE MAC | HARQ feedback, UL/DL transport block scheduling, buffer status reports, random access procedure. Throughput and scheduling visibility. |
| `lte_rlc` | `0xB086 0xB087 0xB088 0xB089` | LTE RLC | AM/UM mode PDU delivery, retransmission events, sequence number gaps, status PDUs. Link reliability indicators. |
| `lte_pdcp` | `0xB097 0xB098 0xB09A 0xB09B 0xB09C` | LTE PDCP | Header compression (ROHC), ciphering status, integrity protection events, SRB/DRB data plane activity. |
| `wcdma` | `0x412F` | WCDMA RRC | 3G RRC OTA messages: RRCConnectionSetup, MeasurementReport, cell reselection, inter-RAT handover commands. Active only when modem camps on WCDMA. |
| `gsm` | `0x512F 0x5226` | GSM L3 / GPRS | GSM BCCH, RR (channel assignment, handover), MM (location update, authentication), GMM (GPRS attach/RAU). Active only when modem falls back to 2G. |
| `umts_nas` | `0x713A` | UMTS NAS (GMM/SM) | 3G NAS: GPRS Mobility Management attach/detach/RAU, Session Management (PDP context activation). Mirrors `lte_nas` for 3G data sessions. |
| `ip_data` | `0x11EB` | Data Services | IP-layer events at the modem data services layer: data call setup/teardown, PDN bearer activation, packet-level activity indicators. Does not capture packet payloads. |
| `nr_rrc` | `0xB821` | NR RRC | **No-op on MDM9607.** This code targets 5G NR RRC messages. The MDM9607 has no 5G capability; enabling this category generates no log output on this device. |
| `f3_debug` | *(none)* | Diagnostic F3 | **UI only — no log codes assigned.** F3 diagnostic messages are only captured when `enable_all` is set. Selecting this category alone has no effect. |
| `gps` | *(none)* | GPS/GNSS | **UI only — no log codes assigned.** GPS NMEA or fix data is only captured under `enable_all`. Selecting this alone has no effect. |
| `qmi_events` | *(none)* | QMI | **UI only — no log codes assigned.** QMI service events are only captured under `enable_all`. Selecting this alone has no effect. |

> **`enable_all`** calls `DIAG_LOG_CONFIG_F` with all log types enabled across every subsystem. This produces very high log volume and may impact modem performance. Use targeted categories for normal research.

### Practical Combinations

| Goal | Enable |
|------|--------|
| Rogue cell / IMSI-catcher detection | `lte_rrc` + `lte_nas` |
| Signal survey + neighbor cell mapping | `lte_rrc` + `lte_l1` |
| Full LTE protocol stack trace | `lte_rrc` + `lte_nas` + `lte_l1` + `lte_mac` + `lte_rlc` + `lte_pdcp` |
| Multi-RAT fallback research | add `wcdma` + `gsm` + `umts_nas` |
| Deep modem diagnostic dump | `enable_all` |

---

## The Boot Mask Problem

### Stock Rayhunter Behavior

Stock rayhunter has two operating modes controlled by `debug_mode` in `config.toml`:

- `debug_mode = false` (default): rayhunter opens `/dev/diag`, applies a built-in 11-code log mask, and streams captured frames to QMDL files for analysis
- `debug_mode = true`: rayhunter skips `/dev/diag` entirely, leaving it free for external tools (QCSuper, qmuxd)

The problem: the log mask configured in the UI was saved to `config.toml` but **only applied in `debug_mode = false`**. Switching to external capture mode (`debug_mode = true`) meant the modem reverted to whatever DIAG state it had from the previous session or boot default — no selected categories were applied.

```rust
// Stock main.rs — mask only applied when NOT in debug mode
if !config.debug_mode {
    let mut dev = DiagDevice::new(&config.device).await?;
    // ... apply mask ...
    run_diag_read_thread(..., dev, ...);
}
// In debug_mode=true: /dev/diag never opened, mask never applied
```

### Fork Fix: Always Apply, Conditionally Release

The fork restructures startup to always open `/dev/diag` and apply the saved mask first, then decide whether to keep the handle (normal capture mode) or release it (debug/external mode):

```rust
// Fork main.rs — mask applied regardless of debug_mode
let retry_dur = if config.debug_mode {
    Duration::from_secs(5)   // short window — /dev/diag may not be free long
} else {
    Duration::from_secs(30)
};
let dev_result = DiagDevice::new_with_retries(retry_dur, &config.device).await;

let dev_opt: Option<DiagDevice> = match dev_result {
    Ok(mut dev) => {
        // Apply saved mask (or built-in default if nothing selected)
        if any_set {
            if config.log_mask.enable_all {
                dev.enable_all_log_codes().await?;
            } else if let Some(codes) = config.log_mask.to_log_codes() {
                dev.apply_log_codes(&codes).await?;
            }
        } else {
            dev.config_logs().await?;   // built-in 11-code default
        }

        if config.debug_mode {
            info!("debug_mode=true: boot mask applied, releasing /dev/diag for external use");
            None   // dev dropped here — /dev/diag fd closed, modem retains the mask
        } else {
            Some(dev)   // keep handle open for capture thread
        }
    }
    Err(e) if config.debug_mode => {
        // Non-fatal: /dev/diag was already held (e.g. qmuxd beat us to it)
        info!("debug_mode: could not open /dev/diag for boot mask ({e}), continuing");
        None
    }
    Err(e) => return Err(RayhunterError::DiagInitError(e)),
};

// Capture thread only started if dev_opt is Some (normal mode)
if let Some(dev) = dev_opt {
    run_diag_read_thread(..., dev, ...);
}
```

**Key insight**: the Qualcomm modem retains the applied log mask in its running state after the `/dev/diag` file descriptor is closed. Closing the fd does not reset the mask. This means rayhunter can seed the mask at boot and immediately release the device — QCSuper (or any other tool) connects to a modem already configured with the desired log categories active.

### Original Rayhunter Compatibility

This change is fully backward compatible:

- `debug_mode = false`: behavior identical to stock — mask applied, device retained, capture thread runs
- `debug_mode = true` with `/dev/diag` available: mask applied (new behavior), device released, external tools see a pre-configured modem
- `debug_mode = true` with `/dev/diag` busy (qmuxd already connected): non-fatal, mask application skipped, continues normally — same as stock behavior
- No mask selected (all categories false): falls back to `config_logs()` built-in 11-code list — same as stock default
