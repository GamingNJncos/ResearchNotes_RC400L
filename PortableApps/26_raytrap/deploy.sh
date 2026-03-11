#!/bin/sh
# deploy.sh — RayTrap unified web interface installer
# RC400L / Orbic MDM9607
#
# SELF-CONTAINED: bundles tinyproxy, tcpdump, libpcap, and ipt daemon scripts.
# Web server: uses busybox httpd (built into device busybox — no binary needed).
#
# USAGE (from PC, repo root):
#   adb push PortableApps/26_raytrap /data/tmp/raytrap
#   adb shell
#   rootshell
#   sh /data/tmp/raytrap/deploy.sh
#
# WHAT THIS INSTALLS:
#   1. tinyproxy, tcpdump, libpcap.so.1  → /cache/bin/, /cache/lib/
#   2. ipt daemon (ipt_daemon.sh etc.)   → /cache/ipt/  (starts via inittab)
#   3. RayTrap web files + CGIs          → /cache/raytrap/www/
#   4. raytrap_daemon init script        → /etc/init.d/raytrap_daemon
#   5. misc-daemon boot hook             → raytrap starts after modem ONLINE
#   6. Rayhunter started if not running  → /etc/init.d/rayhunter_daemon start
#
# REPORTS COMPLETE ONLY WHEN ALL SERVICES ARE VERIFIED RUNNING.

SRC=/data/tmp/raytrap/raytrap
DEST=/cache/raytrap
CACHE_BIN=/cache/bin
CACHE_LIB=/cache/lib
TINYPROXY=$CACHE_BIN/tinyproxy
TCPDUMP=$CACHE_BIN/tcpdump
LIBPCAP=$CACHE_LIB/libpcap.so.1
MISC_DAEMON=/etc/init.d/misc-daemon
RAYTRAP_INITD=/etc/init.d/raytrap_daemon
INITTAB=/etc/inittab
PIDFILE=/tmp/raytrap_httpd.pid
IPT_DIR=/cache/ipt
IPT_FIFO=/cache/ipt/cmd.fifo

ok()   { echo "  [+] $*"; }
info() { echo "  [*] $*"; }
err()  { echo "  [!] $*"; }
hdr()  { echo ""; echo "=== $* ==="; }

FAIL=0
fail() { err "$*"; FAIL=1; }

echo ""
echo "========================================"
echo " RayTrap Web Interface Installer"
echo " RC400L / Orbic MDM9607"
echo "========================================"
echo " src   : $SRC"
echo " dest  : $DEST"
echo " port  : 8888"
echo " httpd : busybox httpd (built-in)"
echo ""

# ── [1] Preflight: verify package is complete ─────────────────────────────────
hdr "1. Preflight"

[ "$(id -u)" != "0" ] && { err "Not root — run: rootshell"; exit 1; }
ok "Running as root"

[ ! -d "$SRC" ] && {
    err "Source not found: $SRC"
    err "From PC: adb push PortableApps/26_raytrap /data/tmp/raytrap"
    exit 1
}
ok "Package present"

if ! busybox httpd --help >/dev/null 2>&1; then
    err "busybox httpd not available — cannot continue"
    exit 1
fi
ok "busybox httpd available"

MISSING=0
for f in tinyproxy tcpdump libpcap.so.1 raytrap_daemon start.sh \
          tinyproxy.conf www/index.html \
          www/cgi-bin/status.cgi www/cgi-bin/firewall.cgi \
          www/cgi-bin/proxy.cgi www/cgi-bin/wifi.cgi \
          www/cgi-bin/routing.cgi www/cgi-bin/capture.cgi \
          www/cgi-bin/diag.cgi www/cgi-bin/at.cgi \
          www/cgi-bin/usb.cgi \
          ipt/ipt_daemon.sh ipt/ipt_ctl.sh ipt/ipt_rules.sh; do
    if [ ! -f "$SRC/$f" ]; then
        err "Missing from package: $f"
        MISSING=1
    fi
done
[ $MISSING -eq 1 ] && { err "Package is incomplete — aborting."; exit 1; }
ok "All package files present"

# ── [2] Stop any running httpd on port 8888 ───────────────────────────────────
hdr "2. Stopping existing httpd"

if [ -f "$PIDFILE" ]; then
    OLD=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$OLD" ] && [ -d "/proc/$OLD" ]; then
        kill "$OLD" 2>/dev/null; sleep 1
        ok "Stopped httpd PID=$OLD"
    fi
    rm -f "$PIDFILE"
fi
for p in $(ls /proc/ 2>/dev/null | grep -E '^[0-9]+$'); do
    cmd=$(cat /proc/$p/cmdline 2>/dev/null | tr '\0' ' ')
    case "$cmd" in *httpd*-p*8888*) kill "$p" 2>/dev/null && ok "Killed stray httpd PID=$p";; esac
done

# ── [3] Install bundled binaries ──────────────────────────────────────────────
hdr "3. Installing binaries"

mkdir -p "$CACHE_BIN" "$CACHE_LIB"

cp "$SRC/tinyproxy"    "$TINYPROXY" && chmod 755 "$TINYPROXY" && ok "tinyproxy → $TINYPROXY"
cp "$SRC/tcpdump"      "$TCPDUMP"   && chmod 755 "$TCPDUMP"   && ok "tcpdump → $TCPDUMP"
cp "$SRC/libpcap.so.1" "$LIBPCAP"   && chmod 644 "$LIBPCAP"   && ok "libpcap.so.1 → $LIBPCAP"

# ── [4] Deploy ipt daemon ─────────────────────────────────────────────────────
hdr "4. Deploying iptables daemon"

mkdir -p "$IPT_DIR"

# Install scripts (CRLF-safe)
for f in ipt_daemon.sh ipt_ctl.sh ipt_rules.sh; do
    cp "$SRC/ipt/$f" "$IPT_DIR/$f"
    tr -d '\r' < "$IPT_DIR/$f" > /tmp/ipt_strip && cp /tmp/ipt_strip "$IPT_DIR/$f" && rm -f /tmp/ipt_strip
    chmod 755 "$IPT_DIR/$f"
    ok "Installed: $IPT_DIR/$f"
done

# Create live rules.sh only if not already present (preserve user edits)
if [ ! -f "$IPT_DIR/rules.sh" ]; then
    cp "$IPT_DIR/ipt_rules.sh" "$IPT_DIR/rules.sh"
    chmod 755 "$IPT_DIR/rules.sh"
    ok "Created live ruleset: $IPT_DIR/rules.sh"
else
    ok "Live ruleset exists: $IPT_DIR/rules.sh (preserved)"
fi

# Remove stale inittab entry and add fresh respawn
grep -v "^ipdm" "$INITTAB" > /data/tmp/inittab.ipdm.new
cp /data/tmp/inittab.ipdm.new "$INITTAB"
rm -f /data/tmp/inittab.ipdm.new
echo "ipdm:5:respawn:/bin/sh /cache/ipt/ipt_daemon.sh" >> "$INITTAB"
ok "inittab: ipdm respawn entry added"

# Kill any stale ipt_daemon instance
if [ -f "$IPT_DIR/daemon.pid" ]; then
    OLD_PID=$(cat "$IPT_DIR/daemon.pid" 2>/dev/null)
    [ -n "$OLD_PID" ] && [ -d "/proc/$OLD_PID" ] && kill "$OLD_PID" 2>/dev/null && ok "Stopped old ipt_daemon PID=$OLD_PID"
fi
rm -f "$IPT_FIFO"

kill -HUP 1
info "Waiting for ipt daemon FIFO (up to 15s)..."

IPT_OK=0
for i in $(seq 1 15); do
    sleep 1
    [ -p "$IPT_FIFO" ] && IPT_OK=1 && break
    printf "    %ds...\r" "$i"
done
echo ""

if [ "$IPT_OK" = "0" ]; then
    fail "ipt daemon did not start — FIFO not created within 15s"
    [ -f "$IPT_DIR/daemon.log" ] && { echo "--- daemon.log ---"; cat "$IPT_DIR/daemon.log"; echo "---"; }
else
    DPID=$(cat "$IPT_DIR/daemon.pid" 2>/dev/null)
    CAPEFF=$(grep CapEff /proc/$DPID/status 2>/dev/null | awk '{print $2}')
    ok "ipt daemon running PID=$DPID CapEff=$CAPEFF"
fi

# ── [5] Create raytrap directory layout ───────────────────────────────────────
hdr "5. Creating /cache/raytrap/"

mkdir -p "$DEST/www/cgi-bin" "$DEST/captures"
ok "Directories ready"

# ── [6] Install web files ─────────────────────────────────────────────────────
hdr "6. Installing web files"

cp "$SRC/start.sh" "$DEST/start.sh"
tr -d '\r' < "$DEST/start.sh" > /tmp/cgi_strip && cp /tmp/cgi_strip "$DEST/start.sh" && rm -f /tmp/cgi_strip
chmod 755 "$DEST/start.sh" && ok "start.sh"

cp "$SRC/www/index.html" "$DEST/www/index.html" && ok "index.html"

for CGI in status firewall proxy wifi routing capture diag at usb; do
    cp "$SRC/www/cgi-bin/${CGI}.cgi" "$DEST/www/cgi-bin/${CGI}.cgi"
    # Strip Windows CRLF — busybox sh fails to parse shebang if \r present
    tr -d '\r' < "$DEST/www/cgi-bin/${CGI}.cgi" > /tmp/cgi_strip && \
        cp /tmp/cgi_strip "$DEST/www/cgi-bin/${CGI}.cgi" && rm -f /tmp/cgi_strip
    chmod 755 "$DEST/www/cgi-bin/${CGI}.cgi"
    ok "cgi-bin/${CGI}.cgi"
done

# tinyproxy config — preserve existing user config if present
if [ ! -f "$DEST/tinyproxy.conf" ]; then
    cp "$SRC/tinyproxy.conf" "$DEST/tinyproxy.conf" && ok "tinyproxy.conf (new)"
else
    ok "tinyproxy.conf (kept existing)"
fi
[ ! -f /cache/tinyproxy.conf ] && cp "$DEST/tinyproxy.conf" /cache/tinyproxy.conf

# ── [7] Install /etc/init.d/raytrap_daemon ────────────────────────────────────
hdr "7. Installing /etc/init.d/raytrap_daemon"

cp "$SRC/raytrap_daemon" "$RAYTRAP_INITD" || { err "Cannot write $RAYTRAP_INITD — read-only fs?"; exit 1; }
tr -d '\r' < "$RAYTRAP_INITD" > /tmp/cgi_strip && cp /tmp/cgi_strip "$RAYTRAP_INITD" && rm -f /tmp/cgi_strip
chmod 755 "$RAYTRAP_INITD"
ok "Installed: $RAYTRAP_INITD"

# ── [8] Patch /etc/init.d/misc-daemon ────────────────────────────────────────
hdr "8. Patching /etc/init.d/misc-daemon"

if [ ! -f "$MISC_DAEMON" ]; then
    info "misc-daemon not found — skipping (boot persistence via init.d unavailable)"
else
    cp "$MISC_DAEMON" /data/tmp/misc-daemon.raytrap.bak
    ok "Backed up → /data/tmp/misc-daemon.raytrap.bak"

    if grep -q "raytrap_daemon" "$MISC_DAEMON"; then
        ok "misc-daemon already patched — skipping"
    else
        if grep -q "rayhunter_daemon start" "$MISC_DAEMON"; then
            START_ANCHOR="rayhunter_daemon start"; START_MODE="after"
        else
            START_ANCHOR="start_stop_qti_ppp_le start"; START_MODE="before"
        fi
        if grep -q "rayhunter_daemon stop" "$MISC_DAEMON"; then
            STOP_ANCHOR="rayhunter_daemon stop"; STOP_MODE="before"
        else
            STOP_ANCHOR="start_loc_launcher stop"; STOP_MODE="before"
        fi

        cat > /data/tmp/patch_misc.awk << 'AWKEOF'
{
    if (/^[[:space:]]*start\)/) { in_start=1; in_stop=0 }
    if (/^[[:space:]]*stop\)/)  { in_start=0; in_stop=1 }
    if (/^[[:space:]]*restart\)/) { in_start=0; in_stop=0 }
    done=0
    if (in_start && START_MODE=="after"  && index($0,START_ANCHOR)>0) {
        print; print "        if [ -f /etc/init.d/raytrap_daemon ]"
        print "        then"; print "           /etc/init.d/raytrap_daemon start"
        print "        fi"; done=1
    }
    if (in_start && START_MODE=="before" && index($0,START_ANCHOR)>0 && !done) {
        print "        if [ -f /etc/init.d/raytrap_daemon ]"
        print "        then"; print "           /etc/init.d/raytrap_daemon start"
        print "        fi"; print; done=1
    }
    if (in_stop && STOP_MODE=="before" && index($0,STOP_ANCHOR)>0 && !done) {
        print "        if [ -f /etc/init.d/raytrap_daemon ]"
        print "        then"; print "           /etc/init.d/raytrap_daemon stop"
        print "        fi"; print; done=1
    }
    if (!done) print
}
AWKEOF
        awk -v START_ANCHOR="$START_ANCHOR" -v START_MODE="$START_MODE" \
            -v STOP_ANCHOR="$STOP_ANCHOR"   -v STOP_MODE="$STOP_MODE" \
            -f /data/tmp/patch_misc.awk "$MISC_DAEMON" > /data/tmp/misc-daemon.patched

        if grep -q "raytrap_daemon" /data/tmp/misc-daemon.patched; then
            cp /data/tmp/misc-daemon.patched "$MISC_DAEMON" && chmod 755 "$MISC_DAEMON"
            ok "misc-daemon patched — raytrap starts at boot after modem ONLINE"
        else
            err "Patch failed — anchor not found in misc-daemon"
            info "Showing misc-daemon start section for diagnosis:"
            grep -A3 "start)" "$MISC_DAEMON" | head -20 | sed 's/^/    /'
        fi
        rm -f /data/tmp/patch_misc.awk /data/tmp/misc-daemon.patched
    fi
fi

# ── [9] Ensure rayhunter is running ───────────────────────────────────────────
hdr "9. Rayhunter"

# Helper: scan /proc for rayhunter-daemon process
rh_pid() {
    for p in $(ls /proc/ 2>/dev/null | grep -E '^[0-9]+$'); do
        cmd=$(cat /proc/$p/cmdline 2>/dev/null | tr '\0' ' ')
        case "$cmd" in *rayhunter-daemon*) echo "$p"; return 0;; esac
    done
    return 1
}

RH_PID=$(rh_pid)
if [ -n "$RH_PID" ]; then
    ok "rayhunter already running PID=$RH_PID"
else
    info "rayhunter not running — attempting start..."

    RH_BIN=""
    [ -f /data/rayhunter/rayhunter-daemon ] && RH_BIN=/data/rayhunter/rayhunter-daemon

    if [ -z "$RH_BIN" ]; then
        # rayhunter not installed — warn only, do not fail install
        info "WARNING: rayhunter binary not found at /data/rayhunter/rayhunter-daemon"
        info "         Install rayhunter (EFF stock or fork) and restart it manually."
        info "         RayTrap Capture tab will show DIAG UNAVAILABLE until rayhunter runs."
    else
        # rayhunter binary exists — start via init script or direct via ipt daemon
        # rootshell cannot exec start-stop-daemon (cap restriction); use ipt FIFO (full caps)
        RH_STARTED=0
        if [ -f /etc/init.d/rayhunter_daemon ]; then
            info "Starting via /etc/init.d/rayhunter_daemon (ipt daemon)..."
            echo "/etc/init.d/rayhunter_daemon start" > "$IPT_FIFO" 2>/dev/null || true
        else
            # No init script — launch binary directly via ipt daemon
            RH_CFG=/data/rayhunter/config.toml
            if [ -f "$RH_CFG" ]; then
                info "No init script found — launching rayhunter-daemon directly via ipt daemon..."
                echo "RUST_LOG=info $RH_BIN $RH_CFG > /data/rayhunter/rayhunter.log 2>&1 &" > "$IPT_FIFO" 2>/dev/null || true
            else
                info "WARNING: rayhunter config not found at $RH_CFG"
                info "         Cannot start rayhunter — start it manually after install."
            fi
        fi

        # Wait up to 8s for process to appear
        for i in $(seq 1 8); do
            sleep 1
            RH_PID=$(rh_pid) && { ok "rayhunter started PID=$RH_PID"; RH_STARTED=1; break; }
        done

        if [ "$RH_STARTED" = "0" ]; then
            # Non-fatal: RayTrap still works, just Capture/DIAG tab shows unavailable
            info "WARNING: rayhunter did not start within 8s"
            info "         Check /data/rayhunter/rayhunter.log for errors"
            info "         RayTrap Capture tab will show DIAG UNAVAILABLE"
        fi
    fi
fi

# ── [10] Launch busybox httpd via inittab once ────────────────────────────────
hdr "10. Launching httpd (busybox, inittab once)"

TAG="rt$(( ($$ % 9) + 1 ))$(date +%S 2>/dev/null | cut -c3 || echo 0)"

grep -v "^rt[0-9]" "$INITTAB" > /data/tmp/inittab.rt.new
cp /data/tmp/inittab.rt.new "$INITTAB"
rm -f /data/tmp/inittab.rt.new

HTTPD_CMD="busybox httpd -p 8888 -h $DEST/www"
echo "${TAG}:5:once:${HTTPD_CMD}" >> "$INITTAB"
ok "Injected inittab once entry (tag=$TAG)"

kill -HUP 1
info "Waiting for httpd (up to 20s)..."

HPID=""
for i in $(seq 1 20); do
    sleep 1
    HEX=$(printf "%04X" 8888)
    if grep -qi "0A" /proc/net/tcp6 2>/dev/null && grep -qi "$HEX" /proc/net/tcp6 2>/dev/null; then
        for p in $(ls /proc/ 2>/dev/null | grep -E '^[0-9]+$'); do
            cmd=$(cat /proc/$p/cmdline 2>/dev/null | tr '\0' ' ')
            case "$cmd" in *busybox*httpd*-p*8888*) HPID=$p; break 2;; esac
        done
    fi
    printf "    %ds...\r" "$i"
done
echo ""

grep -v "^${TAG}" "$INITTAB" > /data/tmp/inittab.rt.clean
cp /data/tmp/inittab.rt.clean "$INITTAB"
rm -f /data/tmp/inittab.rt.clean
kill -HUP 1

if [ -z "$HPID" ] || [ ! -d "/proc/$HPID" ]; then
    fail "httpd did not start — check if busybox httpd is available"
else
    echo "$HPID" > "$PIDFILE"
    ok "httpd running PID=$HPID"
    grep CapEff /proc/$HPID/status 2>/dev/null | awk '{printf "  [+] CapEff: %s\n",$2}'
fi

# ── [11] Verify port 8888 ─────────────────────────────────────────────────────
hdr "11. Verifying port 8888"

sleep 1
HEX=$(printf "%04X" 8888)
if grep -qi "0A" /proc/net/tcp6 2>/dev/null && grep -qi "$HEX" /proc/net/tcp6 2>/dev/null; then
    ok "Port 8888 confirmed listening (tcp6)"
elif grep -qi "$HEX" /proc/net/tcp 2>/dev/null; then
    ok "Port 8888 confirmed listening (tcp)"
else
    fail "Port 8888 NOT listening — httpd may have failed"
fi

# ── [12] Cleanup ──────────────────────────────────────────────────────────────
hdr "12. Cleanup"
info "Staging at /data/tmp/raytrap — clean from PC with: adb shell rm -rf /data/tmp/raytrap"

# ── [13] Final service verification ───────────────────────────────────────────
hdr "13. Final service verification"

SVC_FAIL=0

# httpd
HTTPD_OK=0
if [ -f "$PIDFILE" ]; then
    HP=$(cat "$PIDFILE" 2>/dev/null)
    [ -n "$HP" ] && [ -d "/proc/$HP" ] && HTTPD_OK=1
fi
if [ "$HTTPD_OK" = "1" ]; then
    ok "RayTrap httpd      RUNNING (PID=$HP, port 8888)"
else
    err "RayTrap httpd      FAILED"
    SVC_FAIL=1
fi

# ipt daemon
if [ -p "$IPT_FIFO" ]; then
    IPID=$(cat "$IPT_DIR/daemon.pid" 2>/dev/null)
    ok "iptables daemon    RUNNING (PID=$IPID, FIFO ready)"
else
    err "iptables daemon    FAILED (FIFO not present)"
    SVC_FAIL=1
fi

# rayhunter (warning only — separate install, not a RayTrap hard dependency)
RH_OK=0
for p in $(ls /proc/ 2>/dev/null | grep -E '^[0-9]+$'); do
    cmd=$(cat /proc/$p/cmdline 2>/dev/null | tr '\0' ' ')
    case "$cmd" in *rayhunter-daemon*) RH_OK=1; RH_PID=$p; break;; esac
done
if [ "$RH_OK" = "1" ]; then
    ok "rayhunter          RUNNING (PID=$RH_PID)"
else
    info "rayhunter          NOT RUNNING — Capture/DIAG tab shows UNAVAILABLE (start manually)"
fi

echo ""

if [ "$SVC_FAIL" = "1" ] || [ "$FAIL" = "1" ]; then
    echo "========================================"
    echo " INSTALL INCOMPLETE — SERVICE(S) FAILED"
    echo " Fix errors above and re-run deploy.sh"
    echo "========================================"
    exit 1
fi

echo "========================================"
echo " RAYTRAP INSTALL COMPLETE"
echo " All services verified running"
echo "========================================"
echo ""
echo " Web UI      : http://192.168.1.1:8888/"
echo " Binaries    : $CACHE_BIN/{tinyproxy,tcpdump}"
echo " Lib         : $CACHE_LIB/libpcap.so.1"
echo " Web root    : $DEST/www/"
echo " Init script : $RAYTRAP_INITD"
echo " Captures    : $DEST/captures/"
echo " ipt daemon  : $IPT_DIR/  (FIFO ready)"
echo ""
echo " BOOT PERSISTENCE:"
echo "   misc-daemon → raytrap_daemon start (after modem ONLINE)"
echo "   inittab     → ipt_daemon respawn (always on)"
echo ""
echo " MANUAL:"
echo "   /etc/init.d/raytrap_daemon start|stop|restart|status"
echo "   sh /cache/ipt/ipt_ctl.sh status"
echo ""
echo " ACCESS VIA ADB:"
echo "   adb forward tcp:8889 tcp:8888"
echo "   then open http://127.0.0.1:8889/ in browser"
echo ""
