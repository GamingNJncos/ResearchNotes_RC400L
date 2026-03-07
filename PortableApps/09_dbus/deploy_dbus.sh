#!/bin/sh
# deploy_dbus.sh — RC400L D-Bus installer
# Installs dbus-daemon and companion tools from PortableApps/09_dbus
#
# SETUP (from PC — run from repo root):
#   MSYS_NO_PATHCONV=1 adb push PortableApps/09_dbus /data/tmp/dbus
#   adb shell
#   rootshell
#   sh /data/tmp/dbus/deploy_dbus.sh
#
# WHAT THIS DOES:
#   1. Preflight: verify source files and root access
#   2. Creates /cache/bin/ and /cache/lib/ install dirs
#   3. Installs all dbus binaries to /cache/bin/
#   4. Installs libdbus-1.so.3 to /cache/lib/
#   5. Creates /data/dbus/ socket directory (writable, avoids /var/run/dbus/)
#   6. Writes minimal /cache/dbus-system.conf config pointing to /data/dbus/
#   7. Probes dbus-daemon --version and dbus-uuidgen (no caps needed)
#   8. Attempts conservative session bus start from rootshell (no inittab)
#   9. Cleans up staging area
#
# WHY /data/dbus/ INSTEAD OF /var/run/dbus/:
#   The Orbic rootfs is read-only overlay; /var/run/dbus/ does not exist
#   and cannot be created persistently. /data/ is the writable userdata
#   partition (174MB free, persists across reboots).
#
# DBUS-DAEMON CAPABILITIES ANALYSIS:
#   dbus-daemon binds UNIX domain sockets only (not network sockets).
#   UNIX sockets do NOT require CAP_NET_ADMIN or CAP_NET_RAW.
#   Qualcomm LSM restriction applies to AF_INET/AF_PACKET from adb tree,
#   not AF_UNIX. Therefore dbus-daemon --session/--system can be started
#   directly from rootshell WITHOUT an inittab escape.
#   Exception: if --system mode tries to chown/chmod socket to messagebus
#   user it may need CAP_CHOWN or CAP_DAC_OVERRIDE. Use --session or the
#   custom config (which omits user switching) to avoid this.
#
# BINARIES:
#   dbus-daemon          — message bus daemon (session or system bus)
#   dbus-send            — send a message to a running bus
#   dbus-monitor         — passively monitor all messages on a bus
#   dbus-launch          — launch dbus-daemon and set env vars for a session
#   dbus-run-session     — start a bus scoped to a single command's lifetime
#   dbus-cleanup-sockets — remove stale dbus sockets from /tmp
#   dbus-uuidgen         — generate or read the machine-id UUID
#
# USE CASES ON ORBIC:
#   - Some Qualcomm diagnostics services speak D-Bus
#   - dbus-monitor can sniff messages between any running D-Bus services
#   - dbus-send enables scripted introspection of services at runtime

SRC_DIR="/data/tmp/dbus"
BIN_DIR="/cache/bin"
LIB_DIR="/cache/lib"
DBUS_SOCKET_DIR="/data/dbus"
DBUS_CONF="/cache/dbus-system.conf"
DBUS_PID_FILE="/data/tmp/dbus-daemon.pid"
DBUS_LOG="/data/tmp/dbus-daemon.log"

ok()   { echo "  [+] $*"; }
info() { echo "  [*] $*"; }
err()  { echo "  [!] $*"; }
hdr()  { echo ""; echo "=== $* ==="; }

echo ""
echo "========================================"
echo " RC400L D-Bus installer"
echo "========================================"

# -------------------------------------------------------------------------
# [1] Preflight
# -------------------------------------------------------------------------
hdr "1. Preflight"

if [ "$(id -u)" != "0" ]; then
    err "Not running as root. Run: rootshell, then re-run this script."
    exit 1
fi
ok "Running as root (uid=$(id -u))"

for f in dbus-daemon dbus-send dbus-monitor dbus-launch \
          dbus-run-session dbus-cleanup-sockets dbus-uuidgen \
          libdbus-1.so.3; do
    if [ ! -f "$SRC_DIR/$f" ]; then
        err "Missing source file: $SRC_DIR/$f"
        err "Push the package first:"
        err "  MSYS_NO_PATHCONV=1 adb push PortableApps/09_dbus /data/tmp/dbus"
        exit 1
    fi
done
ok "All source files present in $SRC_DIR"

if ! mkdir -p "$BIN_DIR" 2>/dev/null; then
    err "/cache is not writable or not mounted"
    exit 1
fi
ok "/cache is writable"

# -------------------------------------------------------------------------
# [2] Create install directories
# -------------------------------------------------------------------------
hdr "2. Creating install directories"

mkdir -p "$BIN_DIR" || { err "mkdir $BIN_DIR failed"; exit 1; }
ok "Ready: $BIN_DIR"
mkdir -p "$LIB_DIR"  || { err "mkdir $LIB_DIR failed"; exit 1; }
ok "Ready: $LIB_DIR"

# -------------------------------------------------------------------------
# [3] Install binaries
# -------------------------------------------------------------------------
hdr "3. Installing D-Bus binaries to $BIN_DIR"

for bin in dbus-daemon dbus-send dbus-monitor dbus-launch \
           dbus-run-session dbus-cleanup-sockets dbus-uuidgen; do
    cp "$SRC_DIR/$bin" "$BIN_DIR/$bin"   || { err "cp $bin failed"; exit 1; }
    chmod +x "$BIN_DIR/$bin"             || { err "chmod $bin failed"; exit 1; }
    ok "Installed: $BIN_DIR/$bin"
done

# -------------------------------------------------------------------------
# [4] Install shared library
# -------------------------------------------------------------------------
hdr "4. Installing libdbus-1.so.3 to $LIB_DIR"

cp "$SRC_DIR/libdbus-1.so.3" "$LIB_DIR/libdbus-1.so.3" || { err "cp libdbus-1.so.3 failed"; exit 1; }
ok "Installed: $LIB_DIR/libdbus-1.so.3"

# -------------------------------------------------------------------------
# [5] Create socket directory
# -------------------------------------------------------------------------
hdr "5. Creating D-Bus socket directory at $DBUS_SOCKET_DIR"

# /data is the writable userdata partition. Using it avoids the
# read-only rootfs overlay and any /var/run/ tmpfs ambiguity.
mkdir -p "$DBUS_SOCKET_DIR" || { err "mkdir $DBUS_SOCKET_DIR failed"; exit 1; }
chmod 755 "$DBUS_SOCKET_DIR"
ok "Socket directory ready: $DBUS_SOCKET_DIR"

# Generate machine-id if it does not exist (dbus-daemon requires it)
MACHINE_ID_FILE="/data/dbus/machine-id"
if [ ! -f "$MACHINE_ID_FILE" ]; then
    LD_LIBRARY_PATH="$LIB_DIR" "$BIN_DIR/dbus-uuidgen" > "$MACHINE_ID_FILE" 2>/dev/null
    if [ -s "$MACHINE_ID_FILE" ]; then
        ok "Generated machine-id: $(cat $MACHINE_ID_FILE)"
    else
        # Fallback: use a static UUID if dbus-uuidgen fails this early
        echo "6b6c7a6f4f3e2d1c0b0a090807060504" > "$MACHINE_ID_FILE"
        info "dbus-uuidgen failed — wrote fallback machine-id"
    fi
else
    ok "Existing machine-id: $(cat $MACHINE_ID_FILE)"
fi

# -------------------------------------------------------------------------
# [6] Write minimal dbus config
# -------------------------------------------------------------------------
hdr "6. Writing minimal bus config to $DBUS_CONF"

# This config is for a local/custom bus — NOT the system bus.
# It avoids user= directives that would require CAP_SETUID/SETGID,
# and avoids /usr/share/dbus-1/ policy files that don't exist on Orbic.
# Socket address uses /data/dbus/ which is writable and persistent.

cat > /data/tmp/dbus_conf_tmp.conf << 'CONF_EOF'
<!DOCTYPE busconfig PUBLIC
  "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
  "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>

  <!-- Orbic RC400L custom D-Bus bus configuration              -->
  <!-- Socket lives in /data/dbus/ (writable, persistent)      -->
  <!-- No user= switching — runs as uid 0 (root)               -->

  <type>system</type>

  <listen>unix:path=/data/dbus/system_bus_socket</listen>

  <auth>EXTERNAL</auth>

  <pidfile>/data/tmp/dbus-daemon.pid</pidfile>

  <!-- Logging to syslog if available, else silent -->
  <syslog/>

  <!-- Allow all local root connections — tighten as needed -->
  <policy context="default">
    <allow user="root"/>
    <allow send_destination="*" eavesdrop="true"/>
    <allow receive_sender="*"/>
    <allow own="*"/>
  </policy>

</busconfig>
CONF_EOF

cp /data/tmp/dbus_conf_tmp.conf "$DBUS_CONF" || { err "cp dbus config failed"; exit 1; }
rm -f /data/tmp/dbus_conf_tmp.conf
ok "Config written: $DBUS_CONF"
info "Socket address: unix:path=/data/dbus/system_bus_socket"
info "PID file:       $DBUS_PID_FILE"

# -------------------------------------------------------------------------
# [7] Probe: dbus-daemon --version and dbus-uuidgen
# -------------------------------------------------------------------------
hdr "7. Probing binaries (no daemon start yet)"

info "dbus-daemon --version:"
LD_LIBRARY_PATH="$LIB_DIR" "$BIN_DIR/dbus-daemon" --version 2>&1 | head -3 | sed 's/^/    /'
echo ""

info "dbus-uuidgen (print existing or generate UUID):"
LD_LIBRARY_PATH="$LIB_DIR" "$BIN_DIR/dbus-uuidgen" 2>&1 | head -3 | sed 's/^/    /'
echo ""

# -------------------------------------------------------------------------
# [8] Conservative session bus start attempt
# -------------------------------------------------------------------------
hdr "8. Attempting dbus-daemon start (session bus, nofork, background)"

info "UNIX domain sockets do not require CAP_NET_ADMIN."
info "dbus-daemon --session can start from rootshell without inittab escape."
info "Using custom config with --config-file to point socket to /data/dbus/."
echo ""
info "Starting: LD_LIBRARY_PATH=$LIB_DIR $BIN_DIR/dbus-daemon \\"
info "          --config-file=$DBUS_CONF --fork --print-pid"
echo ""

# Launch with --fork so it daemonizes; capture PID from --print-pid output
DAEMON_PID=$(LD_LIBRARY_PATH="$LIB_DIR" "$BIN_DIR/dbus-daemon" \
    --config-file="$DBUS_CONF" \
    --fork \
    --print-pid \
    2>"$DBUS_LOG")
LAUNCH_RC=$?

if [ "$LAUNCH_RC" = "0" ] && [ -n "$DAEMON_PID" ]; then
    echo "$DAEMON_PID" > "$DBUS_PID_FILE"
    ok "dbus-daemon started — PID=$DAEMON_PID"
    sleep 1
    # Verify process still alive
    if [ -d "/proc/$DAEMON_PID" ]; then
        ok "Process confirmed alive at /proc/$DAEMON_PID"
        grep CapEff "/proc/$DAEMON_PID/status" 2>/dev/null | \
            awk '{printf "  [+] CapEff: %s\n", $2}'
    else
        info "Process exited immediately — check log: cat $DBUS_LOG"
    fi
elif [ "$LAUNCH_RC" != "0" ]; then
    info "dbus-daemon exited $LAUNCH_RC — may need inittab escape for CAP_DAC_OVERRIDE"
    info "Check log: cat $DBUS_LOG"
    echo ""
    info "FALLBACK — inittab escape for dbus-daemon:"
    echo "    TAG=dbus"
    echo "    ENTRY=\"dbus:5:once:LD_LIBRARY_PATH=${LIB_DIR} ${BIN_DIR}/dbus-daemon --config-file=${DBUS_CONF} --fork --print-pid >${DBUS_PID_FILE} 2>${DBUS_LOG}\""
    echo "    grep -v '^dbus' /etc/inittab > /data/tmp/inittab.dbus.new"
    echo "    cp /data/tmp/inittab.dbus.new /etc/inittab"
    echo "    echo \"\$ENTRY\" >> /etc/inittab"
    echo "    kill -HUP 1"
    echo "    sleep 2 && cat $DBUS_LOG"
fi

echo ""

# -------------------------------------------------------------------------
# [9] Cleanup staging area
# -------------------------------------------------------------------------
hdr "9. Cleaning up staging area"

for f in dbus-daemon dbus-send dbus-monitor dbus-launch \
          dbus-run-session dbus-cleanup-sockets dbus-uuidgen \
          libdbus-1.so.3; do
    rm -f "$SRC_DIR/$f"
done
ok "Removed staged files from $SRC_DIR (README/SOURCES preserved)"

# -------------------------------------------------------------------------
# Done
# -------------------------------------------------------------------------
echo ""
echo "========================================"
echo " INSTALL COMPLETE"
echo "========================================"
echo ""
echo " Binaries in:  $BIN_DIR/"
echo "   dbus-daemon            — message bus daemon"
echo "   dbus-send              — send a D-Bus message"
echo "   dbus-monitor           — sniff all bus messages"
echo "   dbus-launch            — launch daemon + set env"
echo "   dbus-run-session       — scoped single-session bus"
echo "   dbus-cleanup-sockets   — remove stale sockets"
echo "   dbus-uuidgen           — machine-id utility"
echo ""
echo " Library:  $LIB_DIR/libdbus-1.so.3"
echo " Config:   $DBUS_CONF"
echo " Socket:   /data/dbus/system_bus_socket"
echo " PID file: $DBUS_PID_FILE"
echo " Log:      $DBUS_LOG"
echo ""
echo " USAGE:"
echo ""
echo "   Check if daemon is running:"
echo "     cat $DBUS_PID_FILE"
echo "     ls -la /data/dbus/system_bus_socket"
echo ""
echo "   Send a message (once bus is running):"
echo "     LD_LIBRARY_PATH=$LIB_DIR DBUS_SYSTEM_BUS_ADDRESS=unix:path=/data/dbus/system_bus_socket \\"
echo "     $BIN_DIR/dbus-send --system --dest=org.freedesktop.DBus \\"
echo "       /org/freedesktop/DBus org.freedesktop.DBus.ListNames"
echo ""
echo "   Monitor all bus traffic:"
echo "     LD_LIBRARY_PATH=$LIB_DIR DBUS_SYSTEM_BUS_ADDRESS=unix:path=/data/dbus/system_bus_socket \\"
echo "     $BIN_DIR/dbus-monitor --system"
echo ""
echo "   Stop daemon:"
echo "     kill \$(cat $DBUS_PID_FILE)"
echo "     rm -f /data/dbus/system_bus_socket"
echo ""
echo "   Restart daemon:"
echo "     kill \$(cat $DBUS_PID_FILE) 2>/dev/null"
echo "     LD_LIBRARY_PATH=$LIB_DIR $BIN_DIR/dbus-daemon \\"
echo "       --config-file=$DBUS_CONF --fork --print-pid"
echo ""
echo " DBUS_SYSTEM_BUS_ADDRESS env var must point to our custom socket"
echo " because /run/dbus/system_bus_socket does not exist on this device."
echo ""
