#!/bin/sh
# deploy_thttpd.sh — RC400L thttpd lightweight HTTP server deployer
# Requires: rootshell access via adb
#
# SETUP (from PC — run from repo root):
#   MSYS_NO_PATHCONV=1 adb push PortableApps/04_thttpd /data/tmp/thttpd
#   adb shell
#   rootshell
#   sh /data/tmp/thttpd/deploy_thttpd.sh
#
# WHAT THIS DOES:
#   1. Copies thttpd binary to /cache/bin/thttpd (root-owned, executable)
#   2. Creates /cache/www/ serve directory
#   3. Writes a default /cache/www/index.html
#   4. Injects a `once` inittab entry so init spawns thttpd with full caps
#      (rootshell CapBnd=0x00c0 lacks CAP_NET_BIND_SERVICE; init has full caps)
#   5. Signals init (kill -HUP 1) to spawn thttpd
#   6. Verifies process started and port 8888 is listening
#   7. Restores /etc/inittab (once entry already consumed by init)
#   8. Cleans up /data/tmp staging directory
#
# AFTER INSTALL:
#   Access from any WiFi client:  http://192.168.1.1:8888/
#   Stop server:                  kill $(cat /cache/thttpd.pid)
#   Restart:                      Re-run this script
#   Serve files:                  Place files in /cache/www/
#   Log:                          cat /cache/thttpd.log
#
# OPTIONAL — port 80 redirect via iptables (requires deploy_xtables.sh first):
#   sh /cache/ipt/ipt_ctl.sh iptables -t nat -A ORBIC_PREROUTING \
#       -i bridge0 -p tcp --dport 80 -j REDIRECT --to-ports 8888
#   To remove:
#   sh /cache/ipt/ipt_ctl.sh iptables -t nat -D ORBIC_PREROUTING \
#       -i bridge0 -p tcp --dport 80 -j REDIRECT --to-ports 8888
#
# WHY INITTAB ESCAPE:
#   rootshell runs uid=0 but CapBnd=0x00c0 (CAP_SETUID + CAP_SETGID only).
#   CAP_NET_BIND_SERVICE is absent. Even port 8888 (>1024) requires the
#   socket() call to succeed, but the Qualcomm LSM blocks AF_INET socket()
#   for the entire adb process tree (adbd -> adb shell -> rootshell).
#   init (PID 1) runs with CapBnd=0x3fffffffff. Injecting a `once` entry
#   and sending kill -HUP 1 causes init to spawn thttpd directly outside
#   the adbd cgroup/LSM context, allowing socket binding to succeed.
#   The `once` action runs the entry one time and does not respawn — perfect
#   for a daemon that manages its own background process.

SRC_DIR="/data/tmp/thttpd"
THTTPD_SRC="$SRC_DIR/thttpd"
THTTPD_BIN="/cache/bin/thttpd"
SERVE_DIR="/cache/www"
LOG_FILE="/cache/thttpd.log"
PID_FILE="/cache/thttpd.pid"
PORT="8888"
INITTAB="/etc/inittab"
INITTAB_BAK="/data/tmp/inittab.thttpd.bak"

# Unique 4-char tag for inittab id field (busybox limit)
TAG="th$(( ($$ % 9) + 1 ))$(date +%S 2>/dev/null | cut -c3 || echo 0)"

ok()   { echo "  [+] $*"; }
info() { echo "  [*] $*"; }
err()  { echo "  [!] $*"; }
hdr()  { echo ""; echo "=== $* ==="; }

echo ""
echo "========================================"
echo " RC400L thttpd HTTP server deployer"
echo "========================================"
echo " port     : $PORT"
echo " serve    : $SERVE_DIR"
echo " log      : $LOG_FILE"
echo " pid      : $PID_FILE"
echo " tag      : $TAG"
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

if [ ! -f "$THTTPD_SRC" ]; then
    err "Binary not found: $THTTPD_SRC"
    err "Push from PC first:"
    err "  MSYS_NO_PATHCONV=1 adb push PortableApps/04_thttpd /data/tmp/thttpd"
    exit 1
fi
ok "Source binary present: $THTTPD_SRC"

# Check if thttpd is already running
if [ -f "$PID_FILE" ]; then
    OLDPID=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$OLDPID" ] && [ -d "/proc/$OLDPID" ]; then
        info "thttpd already running (PID=$OLDPID). Stopping it first..."
        kill "$OLDPID" 2>/dev/null
        sleep 1
        ok "Stopped existing instance"
    fi
    rm -f "$PID_FILE"
fi

# -------------------------------------------------------------------------
# [2] Install binary
# -------------------------------------------------------------------------
hdr "2. Installing thttpd binary"

mkdir -p /cache/bin || { err "mkdir /cache/bin failed"; exit 1; }
cp "$THTTPD_SRC" "$THTTPD_BIN" || { err "cp thttpd failed — check source exists"; exit 1; }
chmod 755 "$THTTPD_BIN"        || { err "chmod thttpd failed"; exit 1; }
ok "Installed: $(ls -la $THTTPD_BIN)"

# -------------------------------------------------------------------------
# [3] Create serve directory and index.html
# -------------------------------------------------------------------------
hdr "3. Creating web root"

mkdir -p "$SERVE_DIR" || { err "mkdir $SERVE_DIR failed"; exit 1; }
ok "Directory ready: $SERVE_DIR"

cat > "$SERVE_DIR/index.html" << 'HTML'
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Orbic RC400L</title>
  <style>
    body { font-family: monospace; background: #1a1a1a; color: #e0e0e0;
           max-width: 600px; margin: 40px auto; padding: 0 16px; }
    h1   { color: #4fc3f7; border-bottom: 1px solid #333; padding-bottom: 8px; }
    h2   { color: #81c784; margin-top: 24px; }
    a    { color: #4fc3f7; }
    code { background: #2a2a2a; padding: 2px 6px; border-radius: 3px; }
    ul   { line-height: 1.8; }
    .dim { color: #888; font-size: 0.9em; }
  </style>
</head>
<body>
  <h1>Orbic RC400L</h1>
  <p class="dim">thttpd running on port 8888 &bull; Qualcomm MDM9607 &bull; ARM Cortex-A7</p>

  <h2>Research Tools</h2>
  <ul>
    <li><a href="http://192.168.1.1:8080/">Rayhunter UI</a>
        <span class="dim">— IMSI catcher detection on :8080</span></li>
    <li><a href="http://192.168.1.1:8888/">thttpd</a>
        <span class="dim">— this page, file server on :8888</span></li>
  </ul>

  <h2>Device Info</h2>
  <ul>
    <li>WiFi IP: <code>192.168.1.1</code></li>
    <li>Interfaces: <code>bridge0</code> (LAN), <code>wlan0</code> (AP), <code>rmnet0</code> (LTE)</li>
    <li>Persistent storage: <code>/cache</code> (30 MB), <code>/data</code> (174 MB)</li>
  </ul>

  <h2>Quick Commands (rootshell)</h2>
  <ul>
    <li>Stop thttpd: <code>kill $(cat /cache/thttpd.pid)</code></li>
    <li>View log: <code>cat /cache/thttpd.log</code></li>
    <li>iptables status: <code>sh /cache/ipt/ipt_ctl.sh status</code></li>
  </ul>

  <p class="dim">Served from /cache/www/ &mdash; drop files here to share them.</p>
</body>
</html>
HTML

ok "Created: $SERVE_DIR/index.html"

# -------------------------------------------------------------------------
# [4] Backup /etc/inittab
# -------------------------------------------------------------------------
hdr "4. Backing up /etc/inittab"

if [ ! -f "$INITTAB_BAK" ]; then
    cp "$INITTAB" "$INITTAB_BAK" || { err "inittab backup failed"; exit 1; }
    ok "Backed up to $INITTAB_BAK"
else
    ok "Existing backup at $INITTAB_BAK (not overwriting)"
fi

# -------------------------------------------------------------------------
# [5] Inject inittab once entry
# -------------------------------------------------------------------------
hdr "5. Injecting inittab once entry"

# Remove any stale thttpd entries (tag starts with "th")
grep -v "^th[0-9]" "$INITTAB" > /data/tmp/inittab.thttpd.new 2>/dev/null
cp /data/tmp/inittab.thttpd.new "$INITTAB"
rm -f /data/tmp/inittab.thttpd.new

# Build the thttpd command:
# -p PORT    : listen port
# -d DIR     : document root
# -l FILE    : log file
# -i FILE    : pid file
# -h         : generate index listings for directories
# No -D flag : thttpd daemonizes by default (detaches from init, which is fine)
THTTPD_CMD="$THTTPD_BIN -p $PORT -d $SERVE_DIR -l $LOG_FILE -i $PID_FILE -h"

echo "${TAG}:5:once:${THTTPD_CMD}" >> "$INITTAB"
ok "Entry appended: ${TAG}:5:once:${THTTPD_CMD}"

if ! grep -q "^${TAG}" "$INITTAB"; then
    err "Entry not confirmed in /etc/inittab — possible read-only filesystem"
    exit 1
fi
ok "Entry confirmed in /etc/inittab"

# -------------------------------------------------------------------------
# [6] Signal init to spawn thttpd
# -------------------------------------------------------------------------
hdr "6. Signaling init (kill -HUP 1)"

kill -HUP 1
info "Waiting for thttpd to start (up to 15s)..."

TPID=""
for i in $(seq 1 15); do
    sleep 1
    # thttpd writes its own pid file after daemonizing
    if [ -f "$PID_FILE" ]; then
        TPID=$(cat "$PID_FILE" 2>/dev/null)
        [ -n "$TPID" ] && [ -d "/proc/$TPID" ] && break
    fi
    # Also scan /proc directly in case pid file write is delayed
    for p in $(ls /proc/ | grep -E "^[0-9]+$"); do
        cmdline=$(cat /proc/$p/cmdline 2>/dev/null | tr '\0' ' ')
        case "$cmdline" in
            */cache/bin/thttpd*) TPID=$p; break 2 ;;
        esac
    done
    printf "    %ds...\r" "$i"
done
echo ""

if [ -z "$TPID" ] || [ ! -d "/proc/$TPID" ]; then
    err "thttpd did not start within 15s"
    err "Check log: cat $LOG_FILE"
    info "Restoring /etc/inittab..."
    cp "$INITTAB_BAK" "$INITTAB"
    kill -HUP 1
    exit 1
fi

ok "thttpd running, PID=$TPID"
grep CapEff /proc/$TPID/status 2>/dev/null | awk '{printf "  [+] CapEff: %s\n", $2}'

# -------------------------------------------------------------------------
# [7] Verify port is listening
# -------------------------------------------------------------------------
hdr "7. Verifying port $PORT"

sleep 1
if netstat -tlnp 2>/dev/null | grep -q ":${PORT}"; then
    ok "Port $PORT is listening"
    netstat -tlnp 2>/dev/null | grep ":${PORT}" | sed 's/^/      /'
else
    info "netstat unavailable or port not shown — checking via /proc/net/tcp..."
    # Port 8888 = 0x22B8
    HEX_PORT=$(printf "%04X" "$PORT")
    if grep -qi "$HEX_PORT" /proc/net/tcp 2>/dev/null; then
        ok "Port $PORT confirmed in /proc/net/tcp"
    else
        info "Could not confirm port via /proc/net/tcp — thttpd may still be binding"
    fi
fi

# Show log tail
if [ -f "$LOG_FILE" ]; then
    echo ""
    info "Log tail:"
    tail -5 "$LOG_FILE" 2>/dev/null | sed 's/^/      /'
fi

# -------------------------------------------------------------------------
# [8] Restore /etc/inittab (once entry already consumed)
# -------------------------------------------------------------------------
hdr "8. Restoring /etc/inittab"

# once entries are consumed by busybox init after one execution,
# but we clean up explicitly to keep inittab tidy.
grep -v "^${TAG}" "$INITTAB" > /data/tmp/inittab.thttpd.clean 2>/dev/null
cp /data/tmp/inittab.thttpd.clean "$INITTAB"
rm -f /data/tmp/inittab.thttpd.clean
kill -HUP 1
ok "inittab restored and init signaled"

# -------------------------------------------------------------------------
# [9] Cleanup staging directory
# -------------------------------------------------------------------------
hdr "9. Cleanup"

rm -rf "$SRC_DIR"
ok "Removed staging directory: $SRC_DIR"

# -------------------------------------------------------------------------
# Done
# -------------------------------------------------------------------------
echo ""
echo "========================================"
echo " INSTALL COMPLETE"
echo "========================================"
echo ""
echo " Binary  : $THTTPD_BIN"
echo " Web root: $SERVE_DIR"
echo " Log     : $LOG_FILE"
echo " PID     : $PID_FILE (PID=$TPID)"
echo ""
echo " ACCESS:"
echo "   http://192.168.1.1:$PORT/"
echo ""
echo " MANAGE:"
echo "   Stop:    kill \$(cat $PID_FILE)"
echo "   Log:     cat $LOG_FILE"
echo "   Files:   place files in $SERVE_DIR"
echo ""
echo " PORT 80 REDIRECT (optional, requires xtables daemon):"
echo "   sh /cache/ipt/ipt_ctl.sh iptables -t nat -A ORBIC_PREROUTING \\"
echo "       -i bridge0 -p tcp --dport 80 -j REDIRECT --to-ports $PORT"
echo ""
echo " TO RESTART after reboot or kill:"
echo "   Re-push from PC and re-run this script, OR"
echo "   add a 'respawn' inittab entry for persistent service."
echo ""
