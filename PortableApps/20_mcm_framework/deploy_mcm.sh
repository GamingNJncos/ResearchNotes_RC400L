#!/bin/sh
# deploy_mcm.sh — RC400L MCM (Modem Control Manager) framework installer
# Installs mcm_ril_service and companion tools from PortableApps/20_mcm_framework
#
# SETUP (from PC — run from repo root):
#   MSYS_NO_PATHCONV=1 adb push PortableApps/20_mcm_framework /data/tmp/mcm
#   adb shell
#   rootshell
#   sh /data/tmp/mcm/deploy_mcm.sh
#
# WHAT THIS DOES:
#   1. Preflight: verify source files and root access
#   2. Creates /cache/bin/ and /cache/lib/ install dirs
#   3. Installs all MCM binaries to /cache/bin/
#   4. Installs all MCM shared libs to /cache/lib/
#   5. Creates /cache/bin/mcm_env.sh (LD_LIBRARY_PATH wrapper helper)
#   6. Probes MCM_ATCOP_CLI and uim_test_client (may work standalone)
#   7. Documents how to start mcm_ril_service via inittab escape
#   8. Cleans up staging area
#
# MCM FRAMEWORK OVERVIEW:
#   MCM = Modem Control Manager. A Qualcomm/Foxconn abstraction layer
#   that sits above QMI and provides a simplified API for modem control.
#   Architecture:
#     mcm_ril_service  — main daemon, bridges MCM API to underlying QMI/RIL
#     MCM_atcop_svc    — AT command proxy service (talks to mcm_ril_service)
#     MCM_ATCOP_CLI    — interactive AT command injector via MCM layer
#     MCM_MOBILEAP_ConnectionManager — mobile AP management via MCM
#     MCM_MOBILEAP_CLI — CLI for MCM MobileAP commands
#     mcm_data_srv     — MCM data services helper
#     mcmlocserver     — MCM location server (may need GPS hardware)
#     uim_test_client  — direct SIM/UIM interface test tool
#
# WHY INITTAB ESCAPE FOR mcm_ril_service:
#   mcm_ril_service must bind sockets and communicate with qmuxd.
#   Qualcomm LSM blocks socket() from the adb process tree.
#   Use the inittab injection pattern (see trafmon/tcpdump scripts).
#   TAG must be <= 4 chars for busybox inittab id field.
#
# CONFLICT WARNING:
#   mcm_ril_service may conflict with the Orbic's built-in QCMAP/RIL stack.
#   The existing /usr/bin/qcrild and QCMAP daemons already own the QMI
#   socket. Run mcm_ril_service cautiously — probe CLI tools first to see
#   if they can attach to the existing stack before starting a parallel RIL.
#
# SHARED LIBS (all deployed to /cache/lib/):
#   libmcm.so.0       — core MCM client API
#   libmcmipc.so.0    — MCM IPC transport layer
#   libmcm_log_util.so.0 — MCM logging utilities
#
# INTERESTING TARGETS FOR RESEARCH:
#   MCM_ATCOP_CLI  — AT command injection through MCM RIL (try: ATI, AT+CIMI)
#   uim_test_client — direct SIM access tests (ICCID, IMSI readback)

SRC_DIR="/data/tmp/mcm"
BIN_DIR="/cache/bin"
LIB_DIR="/cache/lib"
INITTAB="/etc/inittab"
INITTAB_BAK="/data/tmp/inittab.mcm.bak"

ok()   { echo "  [+] $*"; }
info() { echo "  [*] $*"; }
err()  { echo "  [!] $*"; }
hdr()  { echo ""; echo "=== $* ==="; }

echo ""
echo "========================================"
echo " RC400L MCM Framework installer"
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

MISSING=0
for f in mcm_ril_service mcm_data_srv MCM_ATCOP_CLI MCM_atcop_svc \
          MCM_MOBILEAP_CLI MCM_MOBILEAP_ConnectionManager \
          uim_test_client \
          libmcm.so.0 libmcmipc.so.0 libmcm_log_util.so.0; do
    if [ ! -f "$SRC_DIR/$f" ]; then
        err "Missing: $SRC_DIR/$f"
        MISSING=1
    fi
done

# mcmlocserver is optional — may not exist in all builds
if [ -f "$SRC_DIR/mcmlocserver" ]; then
    ok "mcmlocserver present (optional)"
else
    info "mcmlocserver not found — skipping (GPS-related, needs extra libs)"
fi

if [ "$MISSING" = "1" ]; then
    err "One or more required files are missing. Push the package first:"
    err "  MSYS_NO_PATHCONV=1 adb push PortableApps/20_mcm_framework /data/tmp/mcm"
    exit 1
fi
ok "All required source files present in $SRC_DIR"

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
hdr "3. Installing MCM binaries to $BIN_DIR"

for bin in mcm_ril_service mcm_data_srv MCM_ATCOP_CLI MCM_atcop_svc \
           MCM_MOBILEAP_CLI MCM_MOBILEAP_ConnectionManager uim_test_client; do
    cp "$SRC_DIR/$bin" "$BIN_DIR/$bin"   || { err "cp $bin failed"; exit 1; }
    chmod +x "$BIN_DIR/$bin"             || { err "chmod $bin failed"; exit 1; }
    ok "Installed: $BIN_DIR/$bin"
done

# Optional: mcmlocserver
if [ -f "$SRC_DIR/mcmlocserver" ]; then
    cp "$SRC_DIR/mcmlocserver" "$BIN_DIR/mcmlocserver"
    chmod +x "$BIN_DIR/mcmlocserver"
    ok "Installed: $BIN_DIR/mcmlocserver (optional)"
fi

# -------------------------------------------------------------------------
# [4] Install shared libraries
# -------------------------------------------------------------------------
hdr "4. Installing MCM shared libs to $LIB_DIR"

for lib in libmcm.so.0 libmcmipc.so.0 libmcm_log_util.so.0; do
    cp "$SRC_DIR/$lib" "$LIB_DIR/$lib" || { err "cp $lib failed"; exit 1; }
    ok "Installed: $LIB_DIR/$lib"
done

# -------------------------------------------------------------------------
# [5] Create convenience wrapper
# -------------------------------------------------------------------------
hdr "5. Creating mcm_env.sh helper at $BIN_DIR/mcm_env.sh"

# This is a dot-sourceable env snippet and also a runnable prefix.
# Usage: . /cache/bin/mcm_env.sh    (sets env in current shell)
#   OR:  /cache/bin/mcm_env.sh MCM_ATCOP_CLI  (runs binary with env set)

cat > /data/tmp/mcm_env_tmp.sh << 'ENV_EOF'
#!/bin/sh
# mcm_env.sh — set MCM environment and optionally run a command
# Usage:
#   . /cache/bin/mcm_env.sh            # source to set env in current shell
#   /cache/bin/mcm_env.sh MCM_ATCOP_CLI   # run a binary with env set
#   /cache/bin/mcm_env.sh uim_test_client

export LD_LIBRARY_PATH="/cache/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PATH="/cache/bin:$PATH"

if [ -n "$1" ]; then
    exec "$@"
fi
ENV_EOF

cp /data/tmp/mcm_env_tmp.sh "$BIN_DIR/mcm_env.sh" || { err "cp mcm_env.sh failed"; exit 1; }
chmod +x "$BIN_DIR/mcm_env.sh"
rm -f /data/tmp/mcm_env_tmp.sh
ok "Helper installed: $BIN_DIR/mcm_env.sh"

# -------------------------------------------------------------------------
# [6] Probe standalone tools
# -------------------------------------------------------------------------
hdr "6. Probing standalone CLI tools"

info "These tools may work without starting mcm_ril_service if they"
info "connect to the existing qmuxd socket on the Orbic firmware."
echo ""

# --- MCM_ATCOP_CLI ---
info "Trying: LD_LIBRARY_PATH=$LIB_DIR $BIN_DIR/MCM_ATCOP_CLI (10s timeout)"
info "Expected: usage/help, or connection error if mcm_ril_service not running"
echo ""
LD_LIBRARY_PATH="$LIB_DIR" timeout 10 "$BIN_DIR/MCM_ATCOP_CLI" 2>&1 | head -10 | sed 's/^/    /'
ATCOP_RC=$?
echo ""
if [ "$ATCOP_RC" = "0" ]; then
    ok "MCM_ATCOP_CLI exited 0"
elif [ "$ATCOP_RC" = "124" ]; then
    info "MCM_ATCOP_CLI timed out (10s) — likely waiting for IPC/socket"
    info "Start mcm_ril_service first (see step 7)"
else
    info "MCM_ATCOP_CLI exited $ATCOP_RC — connection refused or usage printed"
fi

echo ""

# --- uim_test_client ---
info "Trying: LD_LIBRARY_PATH=$LIB_DIR $BIN_DIR/uim_test_client (10s timeout)"
info "Expected: usage/help, menu, or QMI connection attempt"
echo ""
LD_LIBRARY_PATH="$LIB_DIR" timeout 10 "$BIN_DIR/uim_test_client" 2>&1 | head -10 | sed 's/^/    /'
UIM_RC=$?
echo ""
if [ "$UIM_RC" = "0" ]; then
    ok "uim_test_client exited 0"
elif [ "$UIM_RC" = "124" ]; then
    info "uim_test_client timed out (10s) — likely blocking on QMI socket"
else
    info "uim_test_client exited $UIM_RC"
fi

# -------------------------------------------------------------------------
# [7] Document inittab escape for mcm_ril_service
# -------------------------------------------------------------------------
hdr "7. Starting mcm_ril_service (MANUAL STEP — read conflict warning first)"

info "mcm_ril_service is the main MCM daemon. It bridges the MCM API"
info "to the underlying QMI/RIL stack."
echo ""
info "CONFLICT WARNING:"
info "  The Orbic already runs qcrild and QCMAP. mcm_ril_service may"
info "  conflict with qcrild by competing for the same QMI socket."
info "  Do NOT start mcm_ril_service in a production/active-call scenario."
info "  Test in isolation or after stopping qcrild if possible."
echo ""
info "When ready, start via inittab escape (for full caps / Qualcomm LSM bypass):"
echo ""
echo "    # From rootshell:"
echo "    INITTAB=/etc/inittab"
echo "    TAG=mcmd   # 4-char max (busybox constraint)"
echo "    ENTRY=\"\${TAG}:5:once:LD_LIBRARY_PATH=${LIB_DIR} ${BIN_DIR}/mcm_ril_service >/data/tmp/mcm_ril.log 2>&1\""
echo "    grep -v '^mcmd' \$INITTAB > /data/tmp/inittab.mcm.new"
echo "    cp /data/tmp/inittab.mcm.new \$INITTAB"
echo "    echo \"\$ENTRY\" >> \$INITTAB"
echo "    kill -HUP 1"
echo "    sleep 3"
echo "    cat /data/tmp/mcm_ril.log"
echo ""
info "After mcm_ril_service is running, retry MCM_ATCOP_CLI and uim_test_client."
info "AT commands via MCM_ATCOP_CLI: ATI (modem info), AT+CIMI (IMSI)"
echo ""

# Backup inittab now so it's ready if user proceeds manually
if [ ! -f "$INITTAB_BAK" ]; then
    cp "$INITTAB" "$INITTAB_BAK" && ok "Inittab backed up to $INITTAB_BAK (for manual recovery)"
fi

# -------------------------------------------------------------------------
# [8] Cleanup staging area
# -------------------------------------------------------------------------
hdr "8. Cleaning up staging area"

for f in mcm_ril_service mcm_data_srv MCM_ATCOP_CLI MCM_atcop_svc \
          MCM_MOBILEAP_CLI MCM_MOBILEAP_ConnectionManager \
          uim_test_client mcmlocserver \
          libmcm.so.0 libmcmipc.so.0 libmcm_log_util.so.0; do
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
echo "   mcm_ril_service              — main MCM daemon (needs inittab escape)"
echo "   MCM_atcop_svc                — AT command proxy service"
echo "   MCM_ATCOP_CLI                — AT command injector (try standalone)"
echo "   MCM_MOBILEAP_ConnectionManager — MobileAP manager"
echo "   MCM_MOBILEAP_CLI             — MobileAP CLI"
echo "   mcm_data_srv                 — MCM data services"
echo "   uim_test_client              — SIM/UIM test client (try standalone)"
echo ""
echo " Libraries in: $LIB_DIR/"
echo "   libmcm.so.0  libmcmipc.so.0  libmcm_log_util.so.0"
echo ""
echo " QUICK USAGE:"
echo "   LD_LIBRARY_PATH=$LIB_DIR $BIN_DIR/MCM_ATCOP_CLI"
echo "   LD_LIBRARY_PATH=$LIB_DIR $BIN_DIR/uim_test_client"
echo "   . $BIN_DIR/mcm_env.sh && MCM_ATCOP_CLI"
echo ""
echo " DAEMON: see step 7 output above for inittab injection commands."
echo " LOG:    cat /data/tmp/mcm_ril.log"
echo ""
echo " RESTORE INITTAB (if needed): cp $INITTAB_BAK $INITTAB && kill -HUP 1"
echo ""
