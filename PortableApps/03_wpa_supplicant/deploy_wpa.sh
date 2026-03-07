#!/bin/sh
# deploy_wpa.sh — RC400L wpa_supplicant installer and config generator
# Requires: rootshell access via adb (or serial)
#
# SETUP (from PC):
#   MSYS_NO_PATHCONV=1 adb push PortableApps/03_wpa_supplicant /data/tmp/wpa
#   adb shell
#   rootshell
#   sh /data/tmp/wpa/deploy_wpa.sh
#
# WHAT THIS DOES:
#   1. Installs wpa_supplicant, wpa_cli, wpa_passphrase to /cache/bin/
#   2. Creates /cache/wpa_supplicant_sta.conf  (MODE A — full STA)
#   3. Creates /cache/wpa_supplicant_p2p.conf  (MODE B — P2P alongside AP)
#   4. Creates /cache/bin/wpa_start_sta.sh     (MODE A launcher)
#   5. Creates /cache/bin/wpa_start_p2p.sh     (MODE B launcher)
#   6. Creates /cache/bin/wpa_launch.sh        (inittab injection helper)
#   Does NOT start wpa_supplicant automatically — prints instructions instead.
#
# WHY INITTAB ESCAPE:
#   rootshell runs uid=0 but CapBnd=0x00c0 (SETUID+SETGID only).
#   CAP_NET_ADMIN (required by wpa_supplicant to manage wireless interfaces)
#   is NOT in the bounding set. init (PID 1) has full caps.
#   By injecting a `once` entry into /etc/inittab and sending kill -HUP 1,
#   init spawns the wpa_supplicant wrapper with full capabilities.
#
# HARDWARE CONSTRAINT — iw list valid combinations:
#   { managed, AP } <= 1   <-- AP and STA share this slot
#   { P2P-client, P2P-GO } <= 1
#   { Unknown mode (10) } <= 1
#   total <= 3, #channels <= 2
#
#   MODE A: wlan0 AP -> wlan0 STA. AP is disabled while STA is active.
#   MODE B: wlan0 stays AP. New p2p0 interface added as P2P-client.
#           P2P-client != full STA — scanning works, association is non-standard.
#
# SAFETY WARNINGS:
#   MODE A stops the QCMAP WiFi AP — ALL WiFi clients disconnect.
#   Only run MODE A from ADB or serial (not over WiFi).
#   MODE B is the safer first test — AP stays up, only adds p2p0.
#   To restore AP after MODE A: reboot, or: start qcmap_cm &

SRC_DIR="/data/tmp/wpa"
BIN_DIR="/cache/bin"
INITTAB_BAK="/data/tmp/inittab.wpa.bak"

ok()   { echo "  [+] $*"; }
info() { echo "  [*] $*"; }
err()  { echo "  [!] $*"; }
hdr()  { echo ""; echo "=== $* ==="; }

echo ""
echo "========================================"
echo " RC400L wpa_supplicant installer"
echo "========================================"
echo ""

# -------------------------------------------------------------------------
# [1] Preflight checks
# -------------------------------------------------------------------------
hdr "1. Preflight"

if [ "$(id -u)" != "0" ]; then
    err "Not running as root. Run: rootshell, then re-run this script."
    exit 1
fi
ok "Running as root (uid=$(id -u))"

for bin in wpa_supplicant wpa_cli wpa_passphrase; do
    if [ ! -f "$SRC_DIR/$bin" ]; then
        err "Missing binary: $SRC_DIR/$bin"
        err "Push the package first:"
        err "  MSYS_NO_PATHCONV=1 adb push PortableApps/03_wpa_supplicant /data/tmp/wpa"
        exit 1
    fi
done
ok "All three binaries present in $SRC_DIR"

mkdir -p "$BIN_DIR" || { err "mkdir $BIN_DIR failed"; exit 1; }
ok "Destination directory ready: $BIN_DIR"

# -------------------------------------------------------------------------
# [2] Install binaries
# -------------------------------------------------------------------------
hdr "2. Installing binaries to $BIN_DIR"

for bin in wpa_supplicant wpa_cli wpa_passphrase; do
    cp "$SRC_DIR/$bin" "$BIN_DIR/$bin" || { err "cp $bin failed"; exit 1; }
    chmod +x "$BIN_DIR/$bin"           || { err "chmod $bin failed"; exit 1; }
    ok "Installed: $BIN_DIR/$bin  ($(ls -la $BIN_DIR/$bin | awk '{print $5}') bytes)"
done

echo ""
info "Version check (runs without CAP_NET_ADMIN):"
"$BIN_DIR/wpa_supplicant" --version 2>&1 | head -3 | sed 's/^/    /'

# -------------------------------------------------------------------------
# [3] Create config: MODE A — full STA (wlan0, AP disabled)
# -------------------------------------------------------------------------
hdr "3. Creating /cache/wpa_supplicant_sta.conf (MODE A)"

cat > /cache/wpa_supplicant_sta.conf << 'EOF'
# wpa_supplicant_sta.conf — MODE A: full STA on wlan0
# WARNING: wlan0 AP (QCMAP/hostapd) must be stopped before using this.
# Use wpa_launch.sh sta — or run wpa_start_sta.sh via inittab escape.
ctrl_interface=/var/run/wpa_supplicant
ctrl_interface_group=0
update_config=1

# Add networks manually here, or use wpa_cli after wpa_supplicant starts:
#   wpa_cli -i wlan0 add_network
#   wpa_cli -i wlan0 set_network 0 ssid '"YourSSID"'
#   wpa_cli -i wlan0 set_network 0 psk '"YourPassword"'
#   wpa_cli -i wlan0 set_network 0 key_mgmt WPA-PSK
#   wpa_cli -i wlan0 enable_network 0
#   wpa_cli -i wlan0 save_config

# network={
#     ssid="YourSSID"
#     psk="YourPassword"
#     key_mgmt=WPA-PSK
# }
EOF

ok "Created /cache/wpa_supplicant_sta.conf"

# -------------------------------------------------------------------------
# [4] Create config: MODE B — P2P alongside AP (p2p0)
# -------------------------------------------------------------------------
hdr "4. Creating /cache/wpa_supplicant_p2p.conf (MODE B)"

cat > /cache/wpa_supplicant_p2p.conf << 'EOF'
# wpa_supplicant_p2p.conf — MODE B: P2P-client on p2p0 alongside wlan0 AP
# wlan0 stays in AP mode (QCMAP/hostapd untouched).
# p2p0 is added as a virtual P2P-client interface.
# LIMITATION: P2P-client != full managed STA. Scanning works.
#   Association to standard WPA2 APs may not work correctly in this mode.
#   This is primarily useful for scanning and P2P (Wi-Fi Direct) operations.
ctrl_interface=/var/run/wpa_supplicant
ctrl_interface_group=0
update_config=1
p2p_disabled=0

# Scan test (safe, no association):
#   wpa_cli -i p2p0 scan
#   wpa_cli -i p2p0 scan_results
EOF

ok "Created /cache/wpa_supplicant_p2p.conf"

# -------------------------------------------------------------------------
# [5] Create wrapper: wpa_start_sta.sh (MODE A)
# -------------------------------------------------------------------------
hdr "5. Creating /cache/bin/wpa_start_sta.sh (MODE A launcher)"

cat > /cache/bin/wpa_start_sta.sh << 'EOF'
#!/bin/sh
# wpa_start_sta.sh — MODE A: full STA on wlan0
# WARNING: Stops QCMAP's hostapd. All WiFi clients will disconnect.
# Must be launched via init (inittab escape) for CAP_NET_ADMIN.
# Use wpa_launch.sh sta to inject and trigger.

LOG="/data/tmp/wpa_sta.log"
exec >> "$LOG" 2>&1
echo "[wpa_start_sta] Starting at $(date)"

# Kill hostapd if running
HOSTAPD_PID=$(cat /var/run/hostapd.pid 2>/dev/null)
if [ -z "$HOSTAPD_PID" ]; then
    HOSTAPD_PID=$(pgrep hostapd 2>/dev/null)
fi
if [ -n "$HOSTAPD_PID" ]; then
    echo "[wpa_start_sta] Killing hostapd PID=$HOSTAPD_PID"
    kill "$HOSTAPD_PID"
    sleep 1
fi

# Bring wlan0 down, switch to managed, bring up
echo "[wpa_start_sta] Setting wlan0 to managed mode"
ip link set wlan0 down
iw dev wlan0 set type managed
ip link set wlan0 up

mkdir -p /var/run/wpa_supplicant

echo "[wpa_start_sta] Launching wpa_supplicant on wlan0"
/cache/bin/wpa_supplicant -B -i wlan0 \
    -c /cache/wpa_supplicant_sta.conf \
    -P /var/run/wpa_supplicant.pid \
    -f "$LOG"

echo "[wpa_start_sta] wpa_supplicant launched (PID=$(cat /var/run/wpa_supplicant.pid 2>/dev/null))"
EOF

chmod +x /cache/bin/wpa_start_sta.sh
ok "Created /cache/bin/wpa_start_sta.sh"

# -------------------------------------------------------------------------
# [6] Create wrapper: wpa_start_p2p.sh (MODE B)
# -------------------------------------------------------------------------
hdr "6. Creating /cache/bin/wpa_start_p2p.sh (MODE B launcher)"

cat > /cache/bin/wpa_start_p2p.sh << 'EOF'
#!/bin/sh
# wpa_start_p2p.sh — MODE B: P2P-client on p2p0 alongside wlan0 AP
# wlan0 AP stays up. QCMAP and hostapd are NOT touched.
# Must be launched via init (inittab escape) for CAP_NET_ADMIN.
# Use wpa_launch.sh p2p to inject and trigger.

LOG="/data/tmp/wpa_p2p.log"
exec >> "$LOG" 2>&1
echo "[wpa_start_p2p] Starting at $(date)"

# Create p2p0 virtual interface if it does not exist
if ! ip link show p2p0 >/dev/null 2>&1; then
    echo "[wpa_start_p2p] Creating p2p0 as p2p-client on phy0"
    iw phy phy0 interface add p2p0 type p2p-client
    if [ $? -ne 0 ]; then
        echo "[wpa_start_p2p] iw interface add failed — phy may not support it"
        exit 1
    fi
fi

ip link set p2p0 up
mkdir -p /var/run/wpa_supplicant

echo "[wpa_start_p2p] Launching wpa_supplicant on p2p0"
/cache/bin/wpa_supplicant -B -i p2p0 \
    -c /cache/wpa_supplicant_p2p.conf \
    -P /var/run/wpa_p2p.pid \
    -f "$LOG"

echo "[wpa_start_p2p] wpa_supplicant launched (PID=$(cat /var/run/wpa_p2p.pid 2>/dev/null))"
EOF

chmod +x /cache/bin/wpa_start_p2p.sh
ok "Created /cache/bin/wpa_start_p2p.sh"

# -------------------------------------------------------------------------
# [7] Create inittab injection helper: wpa_launch.sh
# -------------------------------------------------------------------------
hdr "7. Creating /cache/bin/wpa_launch.sh (inittab injection helper)"

cat > /cache/bin/wpa_launch.sh << 'EOF'
#!/bin/sh
# wpa_launch.sh — injects a one-shot inittab entry and signals init
# Usage: sh /cache/bin/wpa_launch.sh [sta|p2p]
#   sta  — MODE A: stop AP, run wpa_supplicant on wlan0 (default)
#   p2p  — MODE B: keep AP, add p2p0, run wpa_supplicant on p2p0
#
# Requires: rootshell (uid=0). The spawned script gets full caps from init.

MODE="${1:-sta}"
INITTAB="/etc/inittab"
INITTAB_BAK="/data/tmp/inittab.wpa.bak"

# Unique 4-char tag (busybox inittab limit)
TAG="wp$(( ($$ % 9) + 1 ))"

# Backup inittab (first time only)
if [ ! -f "$INITTAB_BAK" ]; then
    cp "$INITTAB" "$INITTAB_BAK"
    echo "  [*] Backed up /etc/inittab to $INITTAB_BAK"
fi

# Remove any previous wp* entries
grep -v "^wp" "$INITTAB" > /data/tmp/inittab.wpa.new
cp /data/tmp/inittab.wpa.new "$INITTAB"
rm -f /data/tmp/inittab.wpa.new

# Inject the appropriate once entry
if [ "$MODE" = "p2p" ]; then
    SCRIPT="/cache/bin/wpa_start_p2p.sh"
    LOGFILE="/data/tmp/wpa_p2p.log"
else
    SCRIPT="/cache/bin/wpa_start_sta.sh"
    LOGFILE="/data/tmp/wpa_sta.log"
    MODE="sta"
fi

rm -f "$LOGFILE"
echo "${TAG}:5:once:/bin/sh ${SCRIPT}" >> "$INITTAB"
echo "  [+] Injected: ${TAG}:5:once:/bin/sh ${SCRIPT}"

kill -HUP 1
echo "  [+] Signaled init (kill -HUP 1)"
echo ""
echo "  [*] wpa_supplicant starting in $MODE mode..."
echo "  [*] Log: $LOGFILE"
echo ""

sleep 2
echo "  [*] Log so far:"
cat "$LOGFILE" 2>/dev/null | sed 's/^/      /' || echo "      (no log yet)"
echo ""

if [ "$MODE" = "p2p" ]; then
    echo "  Next steps:"
    echo "    Check status:  wpa_cli -i p2p0 status"
    echo "    Scan:          wpa_cli -i p2p0 scan"
    echo "    Results:       wpa_cli -i p2p0 scan_results"
    echo "    Full log:      cat /data/tmp/wpa_p2p.log"
else
    echo "  Next steps:"
    echo "    Check status:  wpa_cli -i wlan0 status"
    echo "    Add network:   wpa_cli -i wlan0 add_network"
    echo "    Full log:      cat /data/tmp/wpa_sta.log"
    echo ""
    echo "  Restore AP:    reboot  (or: start qcmap_cm &)"
fi
EOF

chmod +x /cache/bin/wpa_launch.sh
ok "Created /cache/bin/wpa_launch.sh"

# -------------------------------------------------------------------------
# [8] Backup inittab now (before any launch)
# -------------------------------------------------------------------------
hdr "8. Backing up /etc/inittab"

if [ ! -f "$INITTAB_BAK" ]; then
    cp /etc/inittab "$INITTAB_BAK" || { err "inittab backup failed"; exit 1; }
    ok "Backed up to $INITTAB_BAK"
else
    ok "Existing backup at $INITTAB_BAK (not overwriting)"
fi

# -------------------------------------------------------------------------
# [9] Summary and instructions
# -------------------------------------------------------------------------
echo ""
echo "========================================"
echo " INSTALL COMPLETE"
echo "========================================"
echo ""
echo " Installed binaries:"
echo "   $BIN_DIR/wpa_supplicant"
echo "   $BIN_DIR/wpa_cli"
echo "   $BIN_DIR/wpa_passphrase"
echo ""
echo " Configs created:"
echo "   /cache/wpa_supplicant_sta.conf  — MODE A (full STA)"
echo "   /cache/wpa_supplicant_p2p.conf  — MODE B (P2P alongside AP)"
echo ""
echo " Launchers created:"
echo "   /cache/bin/wpa_start_sta.sh     — MODE A worker (run via init)"
echo "   /cache/bin/wpa_start_p2p.sh     — MODE B worker (run via init)"
echo "   /cache/bin/wpa_launch.sh        — inittab injection helper"
echo ""
echo "========================================"
echo " HOW TO RUN — READ BEFORE PROCEEDING"
echo "========================================"
echo ""
echo " *** SAFETY NOTICE ***"
echo "   wpa_supplicant requires CAP_NET_ADMIN."
echo "   rootshell CapBnd=0x00c0 — CAP_NET_ADMIN is NOT available."
echo "   You MUST use wpa_launch.sh (inittab escape) to start it."
echo "   Do NOT attempt to run wpa_supplicant directly from rootshell."
echo ""
echo " -------------------------------------------------------"
echo " MODE B — P2P-client alongside AP (SAFER, TRY FIRST)"
echo " -------------------------------------------------------"
echo "   Keeps wlan0 AP active. Adds p2p0 virtual interface."
echo "   P2P-client != full STA. Scanning works; association"
echo "   to regular WPA2 APs may not work in this mode."
echo ""
echo "   Run from rootshell:"
echo "     sh /cache/bin/wpa_launch.sh p2p"
echo ""
echo "   After launch:"
echo "     wpa_cli -i p2p0 status"
echo "     wpa_cli -i p2p0 scan"
echo "     wpa_cli -i p2p0 scan_results"
echo "     cat /data/tmp/wpa_p2p.log"
echo ""
echo " -------------------------------------------------------"
echo " MODE A — Full STA on wlan0 (STOPS WIFI AP)"
echo " -------------------------------------------------------"
echo "   !! WARNING: ALL WIFI CLIENTS WILL DISCONNECT !!"
echo "   !! Only run this from ADB or serial — NOT over WiFi !!"
echo ""
echo "   Stops hostapd, switches wlan0 to managed mode,"
echo "   starts wpa_supplicant on wlan0."
echo ""
echo "   Run from rootshell (ADB/serial only):"
echo "     sh /cache/bin/wpa_launch.sh sta"
echo ""
echo "   After launch:"
echo "     wpa_cli -i wlan0 status"
echo "     wpa_cli -i wlan0 scan"
echo "     wpa_cli -i wlan0 scan_results"
echo "     cat /data/tmp/wpa_sta.log"
echo ""
echo "   Add a network:"
echo "     wpa_cli -i wlan0 add_network"
echo "     wpa_cli -i wlan0 set_network 0 ssid '\"YourSSID\"'"
echo "     wpa_cli -i wlan0 set_network 0 psk '\"YourPassword\"'"
echo "     wpa_cli -i wlan0 set_network 0 key_mgmt WPA-PSK"
echo "     wpa_cli -i wlan0 enable_network 0"
echo "     wpa_cli -i wlan0 status"
echo ""
echo "   Restore AP:"
echo "     reboot"
echo "     -- or manually: start qcmap_cm &"
echo ""
echo " -------------------------------------------------------"
echo " RESTORING /etc/inittab (if needed)"
echo " -------------------------------------------------------"
echo "   cp $INITTAB_BAK /etc/inittab"
echo "   kill -HUP 1"
echo ""
