#!/bin/sh
# deploy.sh — RayTrap unified web interface installer
# RC400L / Orbic MDM9607
#
# SELF-CONTAINED: all binaries (tinyproxy, tcpdump, libpcap) are bundled.
# Web server: uses busybox httpd (built into device busybox — no binary needed).
#
# USAGE (from PC, repo root):
#   export MSYS_NO_PATHCONV=1
#   adb push PortableApps/26_raytrap /data/tmp/raytrap
#   adb shell
#   rootshell
#   sh /data/tmp/raytrap/deploy.sh

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

ok()   { echo "  [+] $*"; }
info() { echo "  [*] $*"; }
err()  { echo "  [!] $*"; }
hdr()  { echo ""; echo "=== $* ==="; }

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

# Verify busybox httpd is available on device
if ! busybox httpd --help >/dev/null 2>&1; then
    err "busybox httpd not available — cannot continue"
    exit 1
fi
ok "busybox httpd available"

# Verify required package files (tinyproxy, tcpdump, libpcap still bundled)
MISSING=0
for f in tinyproxy tcpdump libpcap.so.1 raytrap_daemon start.sh \
          tinyproxy.conf www/index.html \
          www/cgi-bin/status.cgi www/cgi-bin/firewall.cgi \
          www/cgi-bin/proxy.cgi www/cgi-bin/wifi.cgi \
          www/cgi-bin/routing.cgi www/cgi-bin/capture.cgi; do
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

# ── [4] Create raytrap directory layout ───────────────────────────────────────
hdr "4. Creating /cache/raytrap/"

mkdir -p "$DEST/www/cgi-bin" "$DEST/captures"
ok "Directories ready"

# ── [5] Install web files ─────────────────────────────────────────────────────
hdr "5. Installing web files"

cp "$SRC/start.sh"       "$DEST/start.sh"       && chmod 755 "$DEST/start.sh"       && ok "start.sh"
cp "$SRC/www/index.html" "$DEST/www/index.html"                                      && ok "index.html"

for CGI in status firewall proxy wifi routing capture; do
    cp "$SRC/www/cgi-bin/${CGI}.cgi" "$DEST/www/cgi-bin/${CGI}.cgi"
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

# ── [6] Install /etc/init.d/raytrap_daemon ────────────────────────────────────
hdr "6. Installing /etc/init.d/raytrap_daemon"

cp "$SRC/raytrap_daemon" "$RAYTRAP_INITD" || { err "Cannot write $RAYTRAP_INITD — read-only fs?"; exit 1; }
chmod 755 "$RAYTRAP_INITD"
ok "Installed: $RAYTRAP_INITD"

# ── [7] Patch /etc/init.d/misc-daemon ────────────────────────────────────────
hdr "7. Patching /etc/init.d/misc-daemon"

if [ ! -f "$MISC_DAEMON" ]; then
    info "misc-daemon not found — skipping (boot persistence via init.d unavailable)"
else
    cp "$MISC_DAEMON" /data/tmp/misc-daemon.raytrap.bak
    ok "Backed up → /data/tmp/misc-daemon.raytrap.bak"

    if grep -q "raytrap_daemon" "$MISC_DAEMON"; then
        ok "misc-daemon already patched — skipping"
    else
        # Determine start anchor: after rayhunter (if present) else before qti_ppp_le
        if grep -q "rayhunter_daemon start" "$MISC_DAEMON"; then
            START_ANCHOR="rayhunter_daemon start"; START_MODE="after"
        else
            START_ANCHOR="start_stop_qti_ppp_le start"; START_MODE="before"
        fi
        # Determine stop anchor
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

# ── [8] Launch busybox httpd via inittab once ─────────────────────────────────
hdr "8. Launching httpd (busybox, inittab once)"

TAG="rt$(( ($$ % 9) + 1 ))$(date +%S 2>/dev/null | cut -c3 || echo 0)"

# Remove any stale raytrap once entries
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
        # Find the PID
        for p in $(ls /proc/ 2>/dev/null | grep -E '^[0-9]+$'); do
            cmd=$(cat /proc/$p/cmdline 2>/dev/null | tr '\0' ' ')
            case "$cmd" in *busybox*httpd*-p*8888*) HPID=$p; break 2;; esac
        done
    fi
    printf "    %ds...\r" "$i"
done
echo ""

# Clean up once entry
grep -v "^${TAG}" "$INITTAB" > /data/tmp/inittab.rt.clean
cp /data/tmp/inittab.rt.clean "$INITTAB"
rm -f /data/tmp/inittab.rt.clean
kill -HUP 1

if [ -z "$HPID" ] || [ ! -d "/proc/$HPID" ]; then
    err "httpd did not start — check if busybox httpd is available"
else
    echo "$HPID" > "$PIDFILE"
    ok "httpd running PID=$HPID"
    grep CapEff /proc/$HPID/status 2>/dev/null | awk '{printf "  [+] CapEff: %s\n",$2}'
fi

# ── [9] Verify port 8888 ──────────────────────────────────────────────────────
hdr "9. Verifying port 8888"

sleep 1
HEX=$(printf "%04X" 8888)
if grep -qi "0A" /proc/net/tcp6 2>/dev/null && grep -qi "$HEX" /proc/net/tcp6 2>/dev/null; then
    ok "Port 8888 confirmed listening (tcp6)"
elif grep -qi "$HEX" /proc/net/tcp 2>/dev/null; then
    ok "Port 8888 confirmed listening (tcp)"
else
    info "Port 8888 not yet confirmed in /proc/net/tcp"
fi

# ── [10] Cleanup ──────────────────────────────────────────────────────────────
hdr "10. Cleanup"
# Note: /data/tmp/raytrap was pushed by adb (uid=2000) — cannot rm from rootshell
# Clean up from PC: adb shell rm -rf /data/tmp/raytrap
info "Staging at /data/tmp/raytrap — clean from PC with: adb shell rm -rf /data/tmp/raytrap"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "========================================"
echo " RAYTRAP INSTALL COMPLETE"
echo "========================================"
echo ""
echo " Web UI      : http://192.168.1.1:8888/"
echo " Binaries    : $CACHE_BIN/{tinyproxy,tcpdump}"
echo " Lib         : $CACHE_LIB/libpcap.so.1"
echo " Web root    : $DEST/www/"
echo " Init script : $RAYTRAP_INITD"
echo " Captures    : $DEST/captures/"
echo ""
echo " BOOT PERSISTENCE:"
echo "   misc-daemon → raytrap_daemon start (after modem ONLINE)"
echo ""
echo " MANUAL:"
echo "   /etc/init.d/raytrap_daemon start|stop|restart|status"
echo ""
echo " ACCESS VIA ADB:"
echo "   adb forward tcp:8889 tcp:8888"
echo "   then open http://127.0.0.1:8889/ in browser"
echo ""
