#!/bin/sh
# deploy_trafmonitor.sh — RC400L traffic monitor installer
# Installs traf-monitor daemon and traf-monitor-cli from PortableApps/19_traf_monitor
#
# SETUP (from PC — run from repo root):
#   MSYS_NO_PATHCONV=1 adb push PortableApps/19_traf_monitor /data/tmp/traf_monitor
#   adb shell
#   rootshell
#   sh /data/tmp/traf_monitor/deploy_trafmonitor.sh
#
# WHAT THIS DOES:
#   1. Preflight: verify source files and root access
#   2. Creates /cache/bin/ and /cache/lib/ install dirs
#   3. Installs traf-monitor, traf-monitor-cli to /cache/bin/
#   4. Installs libbroker.so to /cache/lib/
#   5. Creates /cache/bin/trafmon_start.sh (inittab injection wrapper)
#   6. Probes traf-monitor-cli --help (works from rootshell if no sockets needed)
#   7. Cleans up staging area
#
# WHY INITTAB ESCAPE FOR THE DAEMON:
#   rootshell CapBnd=0x00c0 (SETUID+SETGID only). traf-monitor is a
#   Foxconn traffic-accounting daemon that requires network sockets.
#   Qualcomm LSM blocks socket() calls from the adb process tree.
#   The trafmon_start.sh wrapper injects a `once` entry into /etc/inittab
#   and sends kill -HUP 1 so init (full caps, outside adb tree) spawns
#   the daemon directly.
#
# ABOUT libbroker.so:
#   Foxconn inter-process message broker library. traf-monitor links
#   against it dynamically. Must be in LD_LIBRARY_PATH at startup.
#   traf-monitor-cli also links against it for IPC to the daemon.
#
# AFTER INSTALL:
#   Probe CLI:    LD_LIBRARY_PATH=/cache/lib /cache/bin/traf-monitor-cli --help
#   Start daemon: sh /cache/bin/trafmon_start.sh
#   Stop daemon:  kill $(cat /data/tmp/trafmon.pid 2>/dev/null)

SRC_DIR="/data/tmp/traf_monitor"
BIN_DIR="/cache/bin"
LIB_DIR="/cache/lib"
INITTAB="/etc/inittab"
INITTAB_BAK="/data/tmp/inittab.trafmon.bak"
WRAPPER="/cache/bin/trafmon_start.sh"

ok()   { echo "  [+] $*"; }
info() { echo "  [*] $*"; }
err()  { echo "  [!] $*"; }
hdr()  { echo ""; echo "=== $* ==="; }

echo ""
echo "========================================"
echo " RC400L traf-monitor installer"
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

for f in traf-monitor traf-monitor-cli libbroker.so; do
    if [ ! -f "$SRC_DIR/$f" ]; then
        err "Missing source file: $SRC_DIR/$f"
        err "Push the package first:"
        err "  MSYS_NO_PATHCONV=1 adb push PortableApps/19_traf_monitor /data/tmp/traf_monitor"
        exit 1
    fi
done
ok "All source files present in $SRC_DIR"

# Check /cache is mounted and writable
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
hdr "3. Installing binaries to $BIN_DIR"

for bin in traf-monitor traf-monitor-cli; do
    cp "$SRC_DIR/$bin" "$BIN_DIR/$bin"   || { err "cp $bin failed"; exit 1; }
    chmod +x "$BIN_DIR/$bin"             || { err "chmod $bin failed"; exit 1; }
    ok "Installed: $BIN_DIR/$bin"
done

# -------------------------------------------------------------------------
# [4] Install shared library
# -------------------------------------------------------------------------
hdr "4. Installing libbroker.so to $LIB_DIR"

cp "$SRC_DIR/libbroker.so" "$LIB_DIR/libbroker.so" || { err "cp libbroker.so failed"; exit 1; }
# chmod is informational only — library does not need +x
ok "Installed: $LIB_DIR/libbroker.so"
info "LD_LIBRARY_PATH=$LIB_DIR must be set before running either binary"

# -------------------------------------------------------------------------
# [5] Create inittab injection wrapper
# -------------------------------------------------------------------------
hdr "5. Creating trafmon_start.sh wrapper at $WRAPPER"

# Write the wrapper — it handles inittab injection itself so it can be
# called from rootshell at any time without re-running this full script.
# The wrapper uses a `once` inittab action (runs once, no respawn).
# Tag must be <= 4 chars for busybox inittab id field.

cat > /data/tmp/trafmon_wrapper_tmp.sh << 'WRAPPER_EOF'
#!/bin/sh
# trafmon_start.sh — inject traf-monitor into inittab and fire it via init
# Usage: sh /cache/bin/trafmon_start.sh
# Must be run from rootshell (uid=0)

DAEMON="/cache/bin/traf-monitor"
LIB_DIR="/cache/lib"
INITTAB="/etc/inittab"
INITTAB_BAK="/data/tmp/inittab.trafmon.bak"
LOGFILE="/data/tmp/trafmon.log"
PIDFILE="/data/tmp/trafmon.pid"

# Unique 4-char tag: tm + last digit of PID + last digit of seconds
TAG="tm$(( $$ % 10 ))$(date +%S 2>/dev/null | cut -c2 || echo 0)"

echo ""
echo "=== trafmon_start.sh ==="
echo "  TAG=$TAG"
echo "  DAEMON=$DAEMON"
echo "  LD_LIBRARY_PATH=$LIB_DIR"
echo ""

if [ "$(id -u)" != "0" ]; then
    echo "  [!] Must run as root (rootshell)"
    exit 1
fi

if [ ! -x "$DAEMON" ]; then
    echo "  [!] $DAEMON not found — run deploy_trafmonitor.sh first"
    exit 1
fi

# Backup inittab once
if [ ! -f "$INITTAB_BAK" ]; then
    cp "$INITTAB" "$INITTAB_BAK" || { echo "  [!] inittab backup failed"; exit 1; }
    echo "  [*] Backed up inittab to $INITTAB_BAK"
fi

# Remove any previous trafmon inittab entries
grep -v "^tm" "$INITTAB" > /data/tmp/inittab.tm.new
cp /data/tmp/inittab.tm.new "$INITTAB"
rm -f /data/tmp/inittab.tm.new

# Inject: once action so init spawns it with full caps, no respawn loop
ENTRY="${TAG}:5:once:LD_LIBRARY_PATH=${LIB_DIR} ${DAEMON} >${LOGFILE} 2>&1"
echo "$ENTRY" >> "$INITTAB"
echo "  [+] Injected: $ENTRY"

echo "  [*] Signaling init (kill -HUP 1)..."
kill -HUP 1

echo "  [*] Waiting for daemon to appear (up to 15s)..."
FOUND_PID=""
for i in $(seq 1 15); do
    sleep 1
    for p in $(ls /proc/ | grep -E "^[0-9]+$"); do
        cmdline=$(cat /proc/$p/cmdline 2>/dev/null | tr '\0' ' ')
        case "$cmdline" in
            *traf-monitor*) FOUND_PID=$p; break 2 ;;
        esac
    done
done

if [ -z "$FOUND_PID" ]; then
    echo "  [!] traf-monitor did not start within 15s"
    echo "  [*] Restoring inittab..."
    cp "$INITTAB_BAK" "$INITTAB"
    kill -HUP 1
    echo "  [*] Check log: cat $LOGFILE"
    exit 1
fi

echo "$FOUND_PID" > "$PIDFILE"
echo "  [+] traf-monitor running — PID=$FOUND_PID"
grep CapEff /proc/$FOUND_PID/status 2>/dev/null | awk '{printf "  [+] CapEff: %s\n", $2}'
echo ""
echo "  Log:    cat $LOGFILE"
echo "  Stop:   kill $FOUND_PID"
echo "  CLI:    LD_LIBRARY_PATH=$LIB_DIR /cache/bin/traf-monitor-cli"
WRAPPER_EOF

cp /data/tmp/trafmon_wrapper_tmp.sh "$WRAPPER" || { err "cp wrapper failed"; exit 1; }
chmod +x "$WRAPPER"                              || { err "chmod wrapper failed"; exit 1; }
rm -f /data/tmp/trafmon_wrapper_tmp.sh
ok "Wrapper installed: $WRAPPER"

# -------------------------------------------------------------------------
# [6] Probe traf-monitor-cli
# -------------------------------------------------------------------------
hdr "6. Probing traf-monitor-cli"
info "Attempting: LD_LIBRARY_PATH=$LIB_DIR $BIN_DIR/traf-monitor-cli --help"
info "(May fail if it requires daemon IPC — that is expected at this stage)"
echo ""

LD_LIBRARY_PATH="$LIB_DIR" "$BIN_DIR/traf-monitor-cli" --help 2>&1 | head -15 | sed 's/^/    /'
CLI_RC=$?
echo ""

if [ "$CLI_RC" = "0" ]; then
    ok "traf-monitor-cli exited 0 — usage printed above"
else
    info "traf-monitor-cli exited $CLI_RC — likely needs daemon IPC (normal)"
    info "Start the daemon first: sh $WRAPPER"
    info "Then retry: LD_LIBRARY_PATH=$LIB_DIR $BIN_DIR/traf-monitor-cli"
fi

# -------------------------------------------------------------------------
# [7] Cleanup staging area
# -------------------------------------------------------------------------
hdr "7. Cleaning up staging area"

rm -f "$SRC_DIR/traf-monitor" \
      "$SRC_DIR/traf-monitor-cli" \
      "$SRC_DIR/libbroker.so"
# Leave README/SOURCES and the deploy script itself intact
ok "Removed staged binaries from $SRC_DIR (README/SOURCES preserved)"

# -------------------------------------------------------------------------
# Done
# -------------------------------------------------------------------------
echo ""
echo "========================================"
echo " INSTALL COMPLETE"
echo "========================================"
echo ""
echo " Binaries:  $BIN_DIR/traf-monitor"
echo "            $BIN_DIR/traf-monitor-cli"
echo " Library:   $LIB_DIR/libbroker.so"
echo " Wrapper:   $WRAPPER"
echo ""
echo " USAGE:"
echo "   Start daemon (inittab escape):"
echo "     sh $WRAPPER"
echo ""
echo "   Probe CLI (after daemon is running):"
echo "     LD_LIBRARY_PATH=$LIB_DIR $BIN_DIR/traf-monitor-cli"
echo ""
echo "   Check daemon log:"
echo "     cat /data/tmp/trafmon.log"
echo ""
echo " NOTE: traf-monitor uses libbroker.so (Foxconn message broker)."
echo "       It may conflict with other Foxconn daemons that also load"
echo "       libbroker. Monitor /data/tmp/trafmon.log for IPC errors."
echo ""
