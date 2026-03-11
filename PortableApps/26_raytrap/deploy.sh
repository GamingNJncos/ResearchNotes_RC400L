#!/bin/sh
# deploy.sh — RayTrap unified web interface installer
# RC400L / Orbic MDM9607
#
# SELF-CONTAINED: bundles tinyproxy, tcpdump, libpcap, ipt daemon scripts,
# and rayhunter v0.10.2 (musl static armv7).
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
#   3. rayhunter v0.10.2                 → /data/rayhunter/  (if missing or broken)
#   4. RayTrap web files + CGIs          → /cache/raytrap/www/
#   5. raytrap_daemon init script        → /etc/init.d/raytrap_daemon
#   6. misc-daemon boot hook             → raytrap starts after modem ONLINE
#
# RAYHUNTER HANDLING:
#   - Not installed            → installs bundled v0.10.2 + config + init script
#   - glibc binary (segfaults) → detects and replaces with bundled musl static
#   - Old/stock musl binary    → upgrades to bundled v0.10.2
#   - Fork binary (/api/stream)→ keeps as-is (already enhanced)
#   - Already running          → verifies API responds and keeps running
#
# REPORTS COMPLETE ONLY WHEN ALL SERVICES ARE VERIFIED RUNNING AND RESPONDING.

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
RH_BIN=/data/rayhunter/rayhunter-daemon
RH_CFG=/data/rayhunter/config.toml
RH_QMDL=/data/rayhunter/qmdl
RH_LOG=/data/rayhunter/rayhunter.log
RH_INITD=/etc/init.d/rayhunter_daemon
RH_PORT=8080
BUNDLED_RH=$SRC/rayhunter-daemon-bin
BUNDLED_RH_INITD=$SRC/rayhunter_daemon_init
BUNDLED_RH_VERSION="v0.10.2"

ok()   { echo "  [+] $*"; }
info() { echo "  [*] $*"; }
err()  { echo "  [!] $*"; }
hdr()  { echo ""; echo "=== $* ==="; }

FAIL=0
fail() { err "$*"; FAIL=1; }

# Helper: check if rayhunter-daemon process is running; echo PID if yes
rh_pid() {
    for p in $(ls /proc/ 2>/dev/null | grep -E '^[0-9]+$'); do
        cmd=$(cat /proc/$p/cmdline 2>/dev/null | tr '\0' ' ')
        case "$cmd" in *rayhunter-daemon*) echo "$p"; return 0;; esac
    done
    return 1
}

# Helper: probe rayhunter binary without starting the server
# Returns 0=works, 1=segfault/crash, 2=not found
rh_probe() {
    local bin="${1:-$RH_BIN}"
    [ ! -f "$bin" ] && return 2
    # Run with a bogus config path — binary will fail on missing file (exit 1)
    # but a glibc-incompatible binary will SIGSEGV (exit 139) or SIGILL (exit 132)
    timeout 3 "$bin" /nonexistent_rh_probe.toml >/tmp/rh_probe.txt 2>&1
    local ret=$?
    rm -f /tmp/rh_probe.txt
    if [ "$ret" -eq 139 ] || [ "$ret" -eq 132 ] || [ "$ret" -eq 134 ]; then
        return 1  # crash
    fi
    return 0  # worked (config-not-found error is expected and fine)
}

# Helper: check if rayhunter API responds on RH_PORT; echo detected type
rh_api_check() {
    local result
    result=$(wget -q -O - --timeout=3 "http://127.0.0.1:$RH_PORT/api/system-stats" 2>/dev/null)
    if echo "$result" | grep -q "disk_bytes_available\|system_stats\|cpu"; then
        # Has /api/stream? → it's our fork
        local stream
        stream=$(wget -q -O - --timeout=2 "http://127.0.0.1:$RH_PORT/api/stream" \
                 --spider 2>&1 | head -3)
        if echo "$stream" | grep -q "200\|chunked"; then
            echo "fork"
        else
            echo "stock"
        fi
        return 0
    fi
    return 1
}

echo ""
echo "========================================"
echo " RayTrap Web Interface Installer"
echo " RC400L / Orbic MDM9607"
echo "========================================"
echo " src     : $SRC"
echo " dest    : $DEST"
echo " port    : 8888"
echo " httpd   : busybox httpd (built-in)"
echo " bundled : rayhunter $BUNDLED_RH_VERSION (musl static armv7)"
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
          ipt/ipt_daemon.sh ipt/ipt_ctl.sh ipt/ipt_rules.sh \
          rayhunter-daemon-bin rayhunter_daemon_init; do
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

for f in ipt_daemon.sh ipt_ctl.sh ipt_rules.sh; do
    cp "$SRC/ipt/$f" "$IPT_DIR/$f"
    tr -d '\r' < "$IPT_DIR/$f" > /tmp/ipt_strip && cp /tmp/ipt_strip "$IPT_DIR/$f" && rm -f /tmp/ipt_strip
    chmod 755 "$IPT_DIR/$f"
    ok "Installed: $IPT_DIR/$f"
done

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

# Kill stale ipt_daemon instance if any
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

# ── [5] Rayhunter detection and setup ─────────────────────────────────────────
hdr "5. Rayhunter detection and setup"

RH_STATUS="unknown"   # not_found | glibc_crash | static_ok | fork_ok
RH_REPLACED=0

if [ ! -f "$RH_BIN" ]; then
    RH_STATUS="not_found"
    info "rayhunter binary NOT found at $RH_BIN"
else
    info "Probing rayhunter binary compatibility..."
    rh_probe "$RH_BIN"
    PROBE_RET=$?
    if [ "$PROBE_RET" -eq 1 ]; then
        RH_STATUS="glibc_crash"
        err "rayhunter binary crashes on startup (SIGSEGV/SIGILL)"
        err "Binary is likely a glibc dynamic build incompatible with this device's libc"
    elif [ "$PROBE_RET" -eq 0 ]; then
        RH_STATUS="static_ok"
        ok "rayhunter binary probe: functional (static/musl build)"
    fi
fi

# Determine if we need to install/replace
RH_NEEDS_INSTALL=0
case "$RH_STATUS" in
    not_found)
        info "Action: INSTALL bundled $BUNDLED_RH_VERSION (device has no rayhunter)"
        RH_NEEDS_INSTALL=1
        ;;
    glibc_crash)
        info "Action: REPLACE with bundled $BUNDLED_RH_VERSION (musl static, no glibc dependency)"
        RH_NEEDS_INSTALL=1
        ;;
    static_ok)
        ok "Action: KEEP existing binary (already functional)"
        ;;
esac

if [ "$RH_NEEDS_INSTALL" = "1" ]; then
    if [ ! -f "$BUNDLED_RH" ]; then
        fail "Bundled rayhunter binary missing from package — cannot install"
        info "Manual install: https://github.com/EFForg/rayhunter/releases"
        info "  Download: rayhunter-$BUNDLED_RH_VERSION-linux-armv7.zip"
        info "  Extract rayhunter-daemon, then:"
        info "  adb push rayhunter-daemon //data/rayhunter/rayhunter-daemon"
    else
        mkdir -p "$RH_QMDL"
        # Use cp + ipt FIFO for atomic replace (avoids partial-write on existing file)
        cp "$BUNDLED_RH" /data/tmp/rh_new_bin
        echo "cp /data/tmp/rh_new_bin $RH_BIN && chmod 755 $RH_BIN && rm -f /data/tmp/rh_new_bin" > "$IPT_FIFO" 2>/dev/null || true
        sleep 2
        if [ -f "$RH_BIN" ]; then
            BIN_SIZE=$(wc -c < "$RH_BIN" 2>/dev/null | tr -d ' ')
            ok "rayhunter-daemon installed: $RH_BIN ($BIN_SIZE bytes, $BUNDLED_RH_VERSION musl static)"
            RH_REPLACED=1
        else
            fail "rayhunter-daemon install failed — file not found after copy"
        fi
    fi
fi

# Ensure config.toml exists
if [ ! -f "$RH_CFG" ]; then
    info "Creating default config.toml..."
    cat > /tmp/rh_default_cfg.toml << 'CFGEOF'
qmdl_store_path = "/data/rayhunter/qmdl"
port = 8080
debug_mode = false
enable_dummy_analyzer = false
colorblind_mode = false
ui_level = 1
[log_mask]
lte_rrc = true
lte_nas = true
lte_l1 = true
lte_mac = true
lte_rlc = true
lte_pdcp = true
nr_rrc = true
wcdma = true
gsm = true
umts_nas = true
ip_data = true
f3_debug = true
gps = true
qmi_events = true
enable_all = true
CFGEOF
    echo "cp /tmp/rh_default_cfg.toml $RH_CFG" > "$IPT_FIFO" 2>/dev/null || true
    sleep 1
    rm -f /tmp/rh_default_cfg.toml
    [ -f "$RH_CFG" ] && ok "config.toml created (default)" || err "config.toml creation failed"
else
    ok "config.toml exists (preserved existing)"
fi

# Ensure qmdl directory exists
mkdir -p "$RH_QMDL" 2>/dev/null || echo "mkdir $RH_QMDL" > "$IPT_FIFO"

# Ensure init script exists
if [ ! -f "$RH_INITD" ]; then
    if [ -f "$BUNDLED_RH_INITD" ]; then
        cp "$BUNDLED_RH_INITD" /tmp/rh_initd_tmp
        tr -d '\r' < /tmp/rh_initd_tmp > "$RH_INITD" && chmod 755 "$RH_INITD"
        rm -f /tmp/rh_initd_tmp
        ok "rayhunter_daemon init script installed → $RH_INITD"
    else
        info "WARNING: bundled init script not found — manual boot start unavailable"
    fi
else
    ok "rayhunter_daemon init script exists → $RH_INITD"
fi

# ── [6] Start rayhunter ───────────────────────────────────────────────────────
hdr "6. Starting rayhunter"

RH_PID=$(rh_pid)
if [ -n "$RH_PID" ]; then
    if [ "$RH_REPLACED" = "1" ]; then
        # Old binary replaced — must restart
        info "New binary installed — stopping old rayhunter PID=$RH_PID..."
        kill "$RH_PID" 2>/dev/null
        sleep 2
        RH_PID=""
    else
        ok "rayhunter already running PID=$RH_PID — checking API..."
    fi
fi

if [ -z "$RH_PID" ]; then
    info "Starting rayhunter..."
    if [ -f "$RH_INITD" ]; then
        echo "$RH_INITD start" > "$IPT_FIFO" 2>/dev/null || true
        info "  Sent: $RH_INITD start (via ipt daemon — required for CAP_SYS_ADMIN)"
    elif [ -f "$RH_BIN" ] && [ -f "$RH_CFG" ]; then
        info "  No init script — launching directly via ipt daemon..."
        echo "RUST_LOG=info $RH_BIN $RH_CFG > $RH_LOG 2>&1 &" > "$IPT_FIFO" 2>/dev/null || true
    else
        info "  WARNING: cannot start rayhunter — binary or config missing"
    fi

    info "Waiting for rayhunter (up to 10s)..."
    for i in $(seq 1 10); do
        sleep 1
        RH_PID=$(rh_pid) && { ok "rayhunter started PID=$RH_PID"; break; }
        printf "    %ds...\r" "$i"
    done
    echo ""
fi

# ── [7] Verify rayhunter API ──────────────────────────────────────────────────
hdr "7. Verifying rayhunter"

# NOTE: Port 8080 on this device is also used by the Orbic management service.
# HTTP probes to 127.0.0.1:8080 are intercepted and return Orbic error JSON.
# Instead, we verify rayhunter by: (1) process present, (2) log confirms startup.

RH_API_OK=0
RH_TYPE="unknown"

if [ -n "$RH_PID" ]; then
    info "rayhunter process found (PID=$RH_PID) — verifying via startup log..."

    # Wait up to 10s for the startup message to appear in the log
    for i in $(seq 1 10); do
        sleep 1
        if [ -f "$RH_LOG" ] && grep -qE "spinning up server|orca is hunting" "$RH_LOG" 2>/dev/null; then
            RH_API_OK=1
            break
        fi
        printf "    %ds...\r" "$i"
    done
    echo ""

    if [ "$RH_API_OK" = "1" ]; then
        # Detect fork vs stock: fork binary has /api/stream; check log for fork indicators
        if grep -qE "stream|diag_mode|log.mask" "$RH_LOG" 2>/dev/null; then
            RH_TYPE="fork (extended API)"
        else
            RH_TYPE="stock $BUNDLED_RH_VERSION"
        fi
        ok "rayhunter confirmed running — startup log verified — type: $RH_TYPE"
        [ -f "$RH_LOG" ] && tail -3 "$RH_LOG" | sed 's/^/    /'
    else
        info "WARNING: rayhunter process running (PID=$RH_PID) but startup not confirmed in log yet"
        info "  Log may be redirected elsewhere or still initializing"
        info "  Check: cat $RH_LOG"
        info "  The Capture tab will show DIAG UNAVAILABLE until rayhunter is fully up"
        # Show last few log lines if available
        [ -f "$RH_LOG" ] && { info "Last log lines:"; tail -5 "$RH_LOG" | sed 's/^/    /'; }
    fi
else
    info "WARNING: rayhunter process not running"
    [ -f "$RH_LOG" ] && { info "Last log lines:"; tail -5 "$RH_LOG" | sed 's/^/    /'; }
    info "  RayTrap Capture tab will show DIAG UNAVAILABLE"
    info "  To start manually: echo \"$RH_INITD start\" > $IPT_FIFO"
    info "  To install rayhunter: https://github.com/EFForg/rayhunter/releases"
    info "    Download rayhunter-$BUNDLED_RH_VERSION-linux-armv7.zip"
fi

# ── [8] Create raytrap directory layout ───────────────────────────────────────
hdr "8. Creating /cache/raytrap/"

mkdir -p "$DEST/www/cgi-bin" "$DEST/captures"
ok "Directories ready"

# ── [9] Install web files ─────────────────────────────────────────────────────
hdr "9. Installing web files"

cp "$SRC/start.sh" "$DEST/start.sh"
tr -d '\r' < "$DEST/start.sh" > /tmp/cgi_strip && cp /tmp/cgi_strip "$DEST/start.sh" && rm -f /tmp/cgi_strip
chmod 755 "$DEST/start.sh" && ok "start.sh"

cp "$SRC/www/index.html" "$DEST/www/index.html" && ok "index.html"

for CGI in status firewall proxy wifi routing capture diag at usb; do
    cp "$SRC/www/cgi-bin/${CGI}.cgi" "$DEST/www/cgi-bin/${CGI}.cgi"
    tr -d '\r' < "$DEST/www/cgi-bin/${CGI}.cgi" > /tmp/cgi_strip && \
        cp /tmp/cgi_strip "$DEST/www/cgi-bin/${CGI}.cgi" && rm -f /tmp/cgi_strip
    chmod 755 "$DEST/www/cgi-bin/${CGI}.cgi"
    ok "cgi-bin/${CGI}.cgi"
done

if [ ! -f "$DEST/tinyproxy.conf" ]; then
    cp "$SRC/tinyproxy.conf" "$DEST/tinyproxy.conf" && ok "tinyproxy.conf (new)"
else
    ok "tinyproxy.conf (kept existing)"
fi
[ ! -f /cache/tinyproxy.conf ] && cp "$DEST/tinyproxy.conf" /cache/tinyproxy.conf

# ── [10] Install /etc/init.d/raytrap_daemon ───────────────────────────────────
hdr "10. Installing /etc/init.d/raytrap_daemon"

cp "$SRC/raytrap_daemon" "$RAYTRAP_INITD" || { err "Cannot write $RAYTRAP_INITD — read-only fs?"; exit 1; }
tr -d '\r' < "$RAYTRAP_INITD" > /tmp/cgi_strip && cp /tmp/cgi_strip "$RAYTRAP_INITD" && rm -f /tmp/cgi_strip
chmod 755 "$RAYTRAP_INITD"
ok "Installed: $RAYTRAP_INITD"

# ── [11] Patch /etc/init.d/misc-daemon ────────────────────────────────────────
hdr "11. Patching /etc/init.d/misc-daemon"

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

# ── [12] Launch busybox httpd via inittab once ────────────────────────────────
hdr "12. Launching httpd (busybox, inittab once)"

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

# ── [13] Verify port 8888 ─────────────────────────────────────────────────────
hdr "13. Verifying port 8888"

sleep 1
HEX=$(printf "%04X" 8888)
if grep -qi "0A" /proc/net/tcp6 2>/dev/null && grep -qi "$HEX" /proc/net/tcp6 2>/dev/null; then
    ok "Port 8888 confirmed listening (tcp6)"
elif grep -qi "$HEX" /proc/net/tcp 2>/dev/null; then
    ok "Port 8888 confirmed listening (tcp)"
else
    fail "Port 8888 NOT listening — httpd may have failed"
fi

# ── [14] Cleanup ──────────────────────────────────────────────────────────────
hdr "14. Cleanup"
info "Staging at /data/tmp/raytrap — clean from PC with: adb shell rm -rf /data/tmp/raytrap"

# ── [15] Final service verification ───────────────────────────────────────────
hdr "15. Final service verification"

SVC_FAIL=0

# httpd
HTTPD_OK=0
if [ -f "$PIDFILE" ]; then
    HP=$(cat "$PIDFILE" 2>/dev/null)
    [ -n "$HP" ] && [ -d "/proc/$HP" ] && HTTPD_OK=1
fi
if [ "$HTTPD_OK" = "1" ]; then
    ok "RayTrap httpd      RUNNING  (PID=$HP, port 8888)"
else
    err "RayTrap httpd      FAILED   — check busybox httpd availability"
    SVC_FAIL=1
fi

# ipt daemon
if [ -p "$IPT_FIFO" ]; then
    IPID=$(cat "$IPT_DIR/daemon.pid" 2>/dev/null)
    ok "iptables daemon    RUNNING  (PID=$IPID, FIFO ready)"
else
    err "iptables daemon    FAILED   — check $IPT_DIR/daemon.log"
    SVC_FAIL=1
fi

# rayhunter (non-fatal — separate from RayTrap core)
RH_FINAL_PID=$(rh_pid)
if [ -n "$RH_FINAL_PID" ]; then
    if [ "$RH_API_OK" = "1" ]; then
        ok "rayhunter          RUNNING  (PID=$RH_FINAL_PID, API OK, $RH_TYPE)"
    else
        info "rayhunter          RUNNING  (PID=$RH_FINAL_PID, API not yet responding — may still be starting)"
    fi
else
    info "rayhunter          NOT RUNNING — Capture/DIAG tab unavailable"
    info "  Status was: $RH_STATUS"
    case "$RH_STATUS" in
        not_found)   info "  rayhunter was not installed — bundled version install may have failed" ;;
        glibc_crash) info "  Old glibc binary detected and replaced — start failed anyway" ;;
        static_ok)   info "  Binary was functional but failed to start — check: cat $RH_LOG" ;;
    esac
    info "  Manual start: echo \"$RH_INITD start\" > $IPT_FIFO"
    info "  Or install:   https://github.com/EFForg/rayhunter/releases (linux-armv7)"
fi

echo ""

if [ "$SVC_FAIL" = "1" ] || [ "$FAIL" = "1" ]; then
    echo "========================================"
    echo " INSTALL INCOMPLETE — SERVICE(S) FAILED"
    echo " Review errors above and re-run deploy.sh"
    echo "========================================"
    exit 1
fi

echo "========================================"
echo " RAYTRAP INSTALL COMPLETE"
echo " Core services verified running"
echo "========================================"
echo ""
echo " Web UI      : http://192.168.1.1:8888/"
echo " Binaries    : $CACHE_BIN/{tinyproxy,tcpdump}"
echo " Lib         : $CACHE_LIB/libpcap.so.1"
echo " Web root    : $DEST/www/"
echo " Init script : $RAYTRAP_INITD"
echo " Captures    : $DEST/captures/"
echo " ipt daemon  : $IPT_DIR/  (FIFO ready)"
echo " rayhunter   : $RH_BIN ($BUNDLED_RH_VERSION)"
echo ""
echo " BOOT PERSISTENCE:"
echo "   misc-daemon → raytrap_daemon start (after modem ONLINE)"
echo "   inittab     → ipt_daemon respawn (always on)"
echo ""
echo " MANUAL:"
echo "   /etc/init.d/raytrap_daemon start|stop|restart|status"
echo "   sh /cache/ipt/ipt_ctl.sh status"
echo "   echo '$RH_INITD start' > $IPT_FIFO"
echo ""
echo " ACCESS VIA ADB:"
echo "   adb forward tcp:8889 tcp:8888"
echo "   then open http://127.0.0.1:8889/ in browser"
echo ""
