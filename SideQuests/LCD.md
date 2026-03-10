# Side Quest: LCD Framebuffer — RC400L Display Hardware & Control

**Display:** 128×128 pixels, RGB565, little-endian
**Device node:** `/dev/fb0` (`crw-rw---- root:video`, mode 0660)
**Driver:** FBTFT (Framebuffer Tiny) — kernel module `fbtft_device.ko` at `/usr/lib/modules/3.18.48/kernel/drivers/video/fbdev/fbtft/`

---

## Hardware Specs

| Parameter     | Value               |
|---------------|---------------------|
| Resolution    | 128 × 128 px        |
| Color format  | RGB565 (16-bit)     |
| Byte order    | Little-endian       |
| Buffer size   | 32,768 bytes        |
| Device file   | `/dev/fb0`          |
| Pixel layout  | Row-major, top-left |

**RGB565 packing (LE):**
```
Bit:  15 14 13 12 11 | 10  9  8  7  6  5 |  4  3  2  1  0
      R4 R3 R2 R1 R0 | G5 G4 G3 G2 G1 G0 | B4 B3 B2 B1 B0
Stored as 2 bytes:  low byte first (little-endian)
```

---

## Stock Firmware Display Control

The stock firmware uses **Qt Embedded 4.8.7** (`/usr/bin/qt_daemon`) for all LCD output. It is started by `/etc/init.d/start_qt.sh` after boot.

- `qt_daemon` renders UI state (signal, battery, WiFi connected/disconnected, etc.) and owns `/dev/fb0` exclusively
- `qt_process` handles UI state transitions
- `qt_test` — test harness binary
- Source references visible in logs: `qt_lcdcontrol.cpp`, state machine with state 6 as primary display state
- Backlight is software-controlled via the Qt layer

When rayhunter is running, it takes over `/dev/fb0` directly (qt_daemon has already exited or is bypassed).

---

## Rayhunter Display Control

Rayhunter writes directly to `/dev/fb0`. Source: `daemon/src/display/orbic.rs`.

The `ui_level` setting in `config.toml` controls display behavior:

| `ui_level` | Behavior |
|---|---|
| `0` | Invisible — framebuffer not touched |
| `1` | 2px status bar only (green=recording, red=high-warning, white=paused) |
| `2` | `orca.gif` animation + 2px status bar |
| `3` | `eff.png` static image + 2px status bar |
| `128` | Trans pride flag (full-screen stripes) |

Images are baked into the binary at compile time via `include_dir!("$CARGO_MANIFEST_DIR/images/")`:
- `daemon/images/orca.gif` — animated orca (EFF mascot)
- `daemon/images/eff.png` — EFF logo

Rayhunter refreshes the display every **1000 ms**. Any direct `/dev/fb0` write will be overwritten after ~1 second unless rayhunter is paused or stopped.

### Pixel write path (Rust):
```rust
// orbic.rs — Framebuffer::write_buffer
for (r, g, b) in buffer {
    let mut rgb565: u16 = (r as u16 & 0b11111000) << 8;
    rgb565 |= (g as u16 & 0b11111100) << 3;
    rgb565 |= (b as u16) >> 3;
    raw_buffer.extend(rgb565.to_le_bytes());
}
tokio::fs::write("/dev/fb0", &raw_buffer).await.unwrap();
```

---

## Direct Framebuffer Access

Since `/dev/fb0` is `root:video` 0660, any process running as uid=0 can write to it directly:

```sh
# From rootshell (uid=0, CapBnd=0x00c0 — no special caps needed for char dev write):
dd if=/path/to/raw_rgb565.bin of=/dev/fb0 bs=32768

# Or via ipt_daemon FIFO (full caps):
echo "dd if=/path/to/raw.bin of=/dev/fb0 bs=32768" > /cache/ipt/cmd.fifo
```

**NOTE:** rootshell has CapBnd=0x00c0 (SETUID+SETGID only), but writing to a char device is a standard DAC operation — no capabilities required. rootshell as uid=0 can write to `/dev/fb0` directly.

---

## Image Conversion (Host Side)

The device has no image processing tools. Conversion from PNG/JPEG/GIF to raw RGB565 must happen on the host.

**Python + Pillow:**
```python
from PIL import Image
import struct, sys

img = Image.open(sys.argv[1]).convert('RGB').resize((128, 128), Image.LANCZOS)
out = bytearray()
for r, g, b in img.getdata():
    rgb565 = ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3)
    out += struct.pack('<H', rgb565)
sys.stdout.buffer.write(bytes(out))
```

Output: 32,768 bytes of raw RGB565 LE, row-major, ready to `dd` to `/dev/fb0`.

---

## Test Scripts

### `lcd_test.sh` — single static image

Converts any image to 128×128 RGB565 and writes it to the display once (or with a freeze loop):

```sh
export MSYS_NO_PATHCONV=1
./lcd_test.sh path/to/image.png
./lcd_test.sh path/to/image.png --freeze     # loop-write for 10s
./lcd_test.sh path/to/image.png --freeze 30  # loop-write for 30s
```

### `lcd_toaster.py` — multi-frame animation (flying toaster)

Generates 3 wing-pose frames with PIL and loops them on the device via a flag-file shell loop. The toaster stays centered; wings cycle up → level → down → level:

```sh
export MSYS_NO_PATHCONV=1
python lcd_toaster.py                        # run until Ctrl+C
python lcd_toaster.py --duration 60          # auto-stop after 60 s
python lcd_toaster.py --fps 8               # frame rate (default: 6 Hz)
python lcd_toaster.py --save-frames          # also save PNG previews to cwd
python lcd_toaster.py --no-push             # generate frames only, no ADB
python lcd_toaster.py --stop-rh             # pause rayhunter during animation
```

**Animation mechanics:** pushes 3 raw RGB565 frames to `/data/tmp/lcd_f{0,1,2}.raw`, then pushes and runs a busybox sh loop on the device (`dd` → `usleep` per frame). A flag file at `/data/tmp/lcd_run` controls loop lifetime — removed on exit for clean shutdown.

**Frame sequence:** `[0, 1, 2, 1]` → up → level → down → level → repeat

**Rayhunter conflict:** if `ui_level != 0` rayhunter will overwrite `/dev/fb0` every ~1 s, causing a brief flash of its status screen between animation frames. Use `--stop-rh` to suppress this, or set `ui_level = 0` in `config.toml` before running.

---

## Replacing Rayhunter's Built-in Images

To permanently change the images rayhunter displays:

1. Replace `Firmware_Backups/rayhunter-OLD/daemon/images/orca.gif` and/or `eff.png`
   - Any size works — the code auto-resizes via `image::imageops::FilterType::CatmullRom`
   - 128×128 is optimal (no resize needed)
2. Rebuild: `./rh_build.sh` (WSL Ubuntu)
3. Deploy: `./rh_deploy.sh`

Or add a new `ui_level` value in `generic_framebuffer.rs`:
```rust
// Add a new file to daemon/images/, then add a new branch:
4 => fb.draw_img(IMAGE_DIR.get_file("custom.png").unwrap().contents()).await,
```

---

## fbset / fbsplash (Recovery Filesystem)

The recoveryfs ships `fbset` and `fbsplash` at `/sbin/`:
- `fbset` — query/set framebuffer display mode
- `fbsplash` — display an image on the framebuffer (recovery mode use)

These are NOT present in the system rootfs. The `fbsplash` binary in recoveryfs is used to show "Updating..." during OTA. Format expected by `fbsplash` is typically raw or PPM — not confirmed for this device.

---
