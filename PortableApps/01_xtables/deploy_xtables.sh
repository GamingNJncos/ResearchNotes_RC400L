#!/bin/sh
# deploy_xtables.sh — RC400L iptables daemon one-time installer
# Run from rootshell after pushing PortableApps/01_xtables/ contents to /data/tmp/xtables/
#
# SETUP (from PC):
#   MSYS_NO_PATHCONV=1 adb push PortableApps/01_xtables /data/tmp/xtables
#   MSYS_NO_PATHCONV=1 adb shell
#   rootshell
#   sh /data/tmp/xtables/deploy_xtables.sh
#
# WHAT THIS DOES:
#   1. Verifies xtables-multi exists on device (shipped with Orbic firmware)
#   2. Creates /cache/ipt/ working directory
#   3. Installs ipt_daemon.sh, ipt_ctl.sh, ipt_rules.sh to /cache/ipt/
#   4. Adds permanent respawn entry to /etc/inittab (survives reboots)
#   5. Signals init to start daemon immediately
#   6. Smoke-tests: verifies daemon has full caps, runs iptables -L via ipt_ctl.sh
#
# AFTER INSTALL — USAGE:
#   ipt_ctl.sh status                    # show all iptables tables
#   ipt_ctl.sh reload                    # reapply /cache/ipt/rules.sh
#   ipt_ctl.sh flush                     # flush ORBIC_* chains (safe)
#   ipt_ctl.sh log                       # show daemon log
#   ipt_ctl.sh iptables -t nat -L -n -v  # run any iptables command
#
# ENABLING RULES — edit /cache/ipt/rules.sh and uncomment sections:
#   Port 777 redirect to local port 8080 (rayhunter):
#     $IPT -t nat -A ORBIC_PREROUTING -i bridge0 -p tcp --dport 777 -j REDIRECT --to-ports 8080
#   TEE mirror all WiFi client traffic to host 192.168.1.50:
#     $IPT -t mangle -A ORBIC_MANGLE -i bridge0 -j TEE --gateway 192.168.1.50
#   Then: ipt_ctl.sh reload

SRC_DIR="/data/tmp/xtables"
DEST_DIR="/cache/ipt"
INITTAB="/etc/inittab"
INITTAB_BAK="/data/tmp/inittab.xtables.bak"
INITTAB_ENTRY="ipdm:5:respawn:/bin/sh /cache/ipt/ipt_daemon.sh"

ok()   { echo "  [+] $*"; }
info() { echo "  [*] $*"; }
err()  { echo "  [!] $*"; }
hdr()  { echo ""; echo "=== $* ==="; }

echo ""
echo "========================================"
echo " RC400L xtables daemon installer"
echo "========================================"

# -------------------------------------------------------------------------
# [1] Preflight checks
# -------------------------------------------------------------------------
hdr "1. Preflight"

# Must be root
if [ "$(id -u)" != "0" ]; then
    err "Not running as root. Run: rootshell, then re-run this script."
    exit 1
fi
ok "Running as root (uid=$(id -u))"

# Check xtables-multi exists
if [ ! -x /usr/sbin/xtables-multi ]; then
    err "/usr/sbin/xtables-multi not found or not executable."
    err "This device may not have iptables support built in."
    exit 1
fi
ok "xtables-multi found: $(ls -la /usr/sbin/xtables-multi | awk '{print $5, $9}')"

# Check iptables binary accessible (don't run it — rootshell lacks CAP_NET_ADMIN;
# the daemon will run iptables with full caps via inittab)
if command -v iptables >/dev/null 2>&1 || [ -x /usr/sbin/xtables-multi ]; then
    ok "iptables binary accessible (full test deferred to daemon smoke test)"
else
    err "iptables not found in PATH and /usr/sbin/xtables-multi missing."
    exit 1
fi

# Check source files exist
for f in ipt_daemon.sh ipt_ctl.sh ipt_rules.sh; do
    if [ ! -f "$SRC_DIR/$f" ]; then
        err "Missing source file: $SRC_DIR/$f"
        err "Push PortableApps/01_xtables/ to /data/tmp/xtables/ first:"
        err "  MSYS_NO_PATHCONV=1 adb push PortableApps/01_xtables /data/tmp/xtables"
        exit 1
    fi
done
ok "All source files present in $SRC_DIR"

# -------------------------------------------------------------------------
# [2] Create working directory
# -------------------------------------------------------------------------
hdr "2. Creating $DEST_DIR"
mkdir -p "$DEST_DIR" || { err "mkdir $DEST_DIR failed"; exit 1; }
ok "Directory ready: $DEST_DIR"

# -------------------------------------------------------------------------
# [3] Install files
# -------------------------------------------------------------------------
hdr "3. Installing files to $DEST_DIR"

for f in ipt_daemon.sh ipt_ctl.sh ipt_rules.sh; do
    cp "$SRC_DIR/$f" "$DEST_DIR/$f" || { err "cp $f failed"; exit 1; }
    chmod +x "$DEST_DIR/$f"         || { err "chmod $f failed"; exit 1; }
    ok "Installed: $DEST_DIR/$f"
done

# rules.sh is the live editable ruleset loaded by the daemon on startup/reload.
# ipt_rules.sh is the versioned source; rules.sh is the working copy.
if [ ! -f "$DEST_DIR/rules.sh" ]; then
    cp "$DEST_DIR/ipt_rules.sh" "$DEST_DIR/rules.sh"
    chmod +x "$DEST_DIR/rules.sh"
    ok "Created live ruleset: $DEST_DIR/rules.sh (copy of ipt_rules.sh)"
else
    ok "Live ruleset already exists: $DEST_DIR/rules.sh (not overwritten)"
fi

# Also install ipt_ctl.sh into a convenient PATH location if /cache is in PATH
# Users can call it as: sh /cache/ipt/ipt_ctl.sh <cmd>
# Or from rootshell just: /cache/ipt/ipt_ctl.sh <cmd>

# -------------------------------------------------------------------------
# [4] Backup and patch /etc/inittab
# -------------------------------------------------------------------------
hdr "4. Patching /etc/inittab"

# Backup (only first time)
if [ ! -f "$INITTAB_BAK" ]; then
    cp "$INITTAB" "$INITTAB_BAK" || { err "inittab backup failed"; exit 1; }
    ok "Backed up to $INITTAB_BAK"
else
    ok "Existing backup at $INITTAB_BAK (not overwriting)"
fi

# Check if entry already exists
if grep -q "^ipdm" "$INITTAB" 2>/dev/null; then
    info "ipdm entry already in inittab:"
    grep "^ipdm" "$INITTAB" | sed 's/^/    /'
    info "Removing old entry to ensure it is current..."
    grep -v "^ipdm" "$INITTAB" > /data/tmp/inittab.ipdm.new
    cp /data/tmp/inittab.ipdm.new "$INITTAB"
    rm -f /data/tmp/inittab.ipdm.new
fi

# Add respawn entry
echo "$INITTAB_ENTRY" >> "$INITTAB"
ok "Added to inittab: $INITTAB_ENTRY"

# Verify
if grep -q "^ipdm" "$INITTAB"; then
    ok "Entry confirmed in /etc/inittab"
else
    err "Entry NOT found in /etc/inittab after write — check filesystem"
    exit 1
fi

# -------------------------------------------------------------------------
# [5] Signal init to start daemon
# -------------------------------------------------------------------------
hdr "5. Starting daemon via kill -HUP 1"
kill -HUP 1
info "Signaled init. Waiting for daemon to start (up to 15s)..."

STARTED=0
for i in $(seq 1 15); do
    sleep 1
    [ -p "$DEST_DIR/cmd.fifo" ] && STARTED=1 && break
    printf "    %ds...\r" "$i"
done
echo ""

if [ "$STARTED" = "0" ]; then
    err "Daemon did not create FIFO within 15s"
    err "Check: cat $DEST_DIR/daemon.log"
    if [ -f "$DEST_DIR/daemon.log" ]; then
        echo "--- daemon.log ---"
        cat "$DEST_DIR/daemon.log"
        echo "--- end ---"
    fi
    exit 1
fi
ok "FIFO detected — daemon is running"

# Show PID and capabilities
DPID=$(cat "$DEST_DIR/daemon.pid" 2>/dev/null)
if [ -n "$DPID" ] && [ -d "/proc/$DPID" ]; then
    ok "Daemon PID=$DPID"
    CAPEFF=$(grep CapEff /proc/$DPID/status 2>/dev/null | awk '{print $2}')
    ok "CapEff=$CAPEFF"
    if [ "$CAPEFF" = "0000003fffffffff" ] || [ "$CAPEFF" = "00000000ffffffff" ]; then
        ok "Full capabilities confirmed"
    else
        info "Note: CapEff=$CAPEFF (may still be sufficient for iptables)"
    fi
else
    info "Could not read daemon PID from $DEST_DIR/daemon.pid"
fi

# -------------------------------------------------------------------------
# [6] Smoke test via ipt_ctl.sh
# -------------------------------------------------------------------------
hdr "6. Smoke test"
info "Running: ipt_ctl.sh iptables -L -n (filter table, abridged)..."
echo ""

# Send command via ipt_ctl.sh
sh "$DEST_DIR/ipt_ctl.sh" iptables -L -n 2>&1 | head -20 | sed 's/^/  /'
echo ""

# Check ORBIC chains exist
info "Checking ORBIC_PREROUTING in nat table..."
ORBIC_CHECK=$(sh "$DEST_DIR/ipt_ctl.sh" iptables -t nat -L -n 2>&1)
if echo "$ORBIC_CHECK" | grep -q "ORBIC_PREROUTING"; then
    ok "ORBIC_PREROUTING chain confirmed in nat table"
else
    info "ORBIC_PREROUTING not yet in nat table — run 'ipt_ctl.sh reload' to apply rules.sh"
fi

info "Checking ORBIC_MANGLE in mangle table..."
ORBIC_MANGLE=$(sh "$DEST_DIR/ipt_ctl.sh" iptables -t mangle -L -n 2>&1)
if echo "$ORBIC_MANGLE" | grep -q "ORBIC_MANGLE"; then
    ok "ORBIC_MANGLE chain confirmed in mangle table"
fi

# -------------------------------------------------------------------------
# [7] Success
# -------------------------------------------------------------------------
echo ""
echo "========================================"
echo " INSTALL COMPLETE"
echo "========================================"
echo ""
echo " Files installed to: $DEST_DIR/"
echo "   ipt_daemon.sh  — persistent daemon (runs as root via init)"
echo "   ipt_ctl.sh     — control client (run from rootshell)"
echo "   ipt_rules.sh   — editable ruleset (applied on boot)"
echo ""
echo " USAGE:"
echo "   sh /cache/ipt/ipt_ctl.sh status           # show all tables"
echo "   sh /cache/ipt/ipt_ctl.sh log              # daemon log"
echo "   sh /cache/ipt/ipt_ctl.sh flush            # clear ORBIC_* chains"
echo "   sh /cache/ipt/ipt_ctl.sh reload           # reapply rules.sh"
echo "   sh /cache/ipt/ipt_ctl.sh iptables -t nat -L -n -v"
echo ""
echo " TO ENABLE PORT 777 REDIRECT (WiFi clients → rayhunter on :8080):"
echo "   Edit /cache/ipt/rules.sh and uncomment section [1]"
echo "   Then: sh /cache/ipt/ipt_ctl.sh reload"
echo ""
echo " TO ENABLE TEE TRAFFIC MIRROR:"
echo "   Edit /cache/ipt/rules.sh and uncomment section [3]"
echo "   Set --gateway to your capture host IP (on 192.168.1.x)"
echo "   Then: sh /cache/ipt/ipt_ctl.sh reload"
echo ""
echo " DAEMON IS PERSISTENT — survives reboots via /etc/inittab"
echo " To remove: sh /cache/ipt/ipt_ctl.sh stop"
echo ""
