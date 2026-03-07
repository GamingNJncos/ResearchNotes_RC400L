#!/bin/sh
# deploy_tools.sh — RC400L combined zero-dependency tools installer
# Covers packages: 10_reg, 11_battery_devinfo, 12_athdiag, 13_conntrackd,
#   14_nfnl_osf, 15_ubi_tools, 17_network_misc, 22_hardware_utils,
#   23_smb_tools, 24_netlink_qos, 25_shadow_extras
#
# SETUP (from PC — push this script first, then whichever packages you want):
#   MSYS_NO_PATHCONV=1 adb push PortableApps/deploy_tools.sh /data/tmp/deploy_tools.sh
#
#   MSYS_NO_PATHCONV=1 adb push PortableApps/10_reg             /data/tmp/reg
#   MSYS_NO_PATHCONV=1 adb push PortableApps/11_battery_devinfo /data/tmp/battery
#   MSYS_NO_PATHCONV=1 adb push PortableApps/12_athdiag         /data/tmp/athdiag
#   MSYS_NO_PATHCONV=1 adb push PortableApps/13_conntrackd      /data/tmp/conntrackd
#   MSYS_NO_PATHCONV=1 adb push PortableApps/14_nfnl_osf        /data/tmp/nfnl_osf
#   MSYS_NO_PATHCONV=1 adb push PortableApps/15_ubi_tools       /data/tmp/ubi_tools
#   MSYS_NO_PATHCONV=1 adb push PortableApps/17_network_misc    /data/tmp/network_misc
#   MSYS_NO_PATHCONV=1 adb push PortableApps/22_hardware_utils  /data/tmp/hw_utils
#   MSYS_NO_PATHCONV=1 adb push PortableApps/24_netlink_qos     /data/tmp/netlink_qos
#   MSYS_NO_PATHCONV=1 adb push PortableApps/23_smb_tools       /data/tmp/smb_tools
#   MSYS_NO_PATHCONV=1 adb push PortableApps/25_shadow_extras   /data/tmp/shadow_extras
#
# Run (from rootshell):
#   adb shell
#   rootshell
#   sh /data/tmp/deploy_tools.sh [--skip-foxconn]
#
# FLAGS:
#   --skip-foxconn    Skip 22_hardware_utils (Foxconn-specific, may not work on Orbic)
#
# CAP NOTE:
#   rootshell: uid=0, CapBnd=0x00c0 (SETUID+SETGID only).
#   CAP_FOWNER is missing — cannot chmod files owned by adb (uid=2000).
#   Workaround used here: cp src dest (creates root-owned copy), then chmod.
#
# CAP_NET_ADMIN NOTE (conntrackd, nfnl_osf, pimd):
#   These binaries need CAP_NET_ADMIN which rootshell does not have.
#   To run them, use the inittab escape approach (see deploy_xtables.sh / ipt_daemon.sh).
#   This script installs the binaries only — it does NOT attempt to run them.

DEST_DIR="/cache/bin"
STAGING="/data/tmp"

SKIP_FOXCONN=0
for arg in "$@"; do
    case "$arg" in
        --skip-foxconn) SKIP_FOXCONN=1 ;;
    esac
done

ok()   { echo "  [+] $*"; }
info() { echo "  [*] $*"; }
err()  { echo "  [!] $*"; }
hdr()  { echo ""; echo "=== $* ==="; }

# Counters
INSTALLED=0
SKIPPED=0
FAILED=0

# Tracking lists (space-separated names)
INSTALLED_PKGS=""
SKIPPED_PKGS=""
FAILED_PKGS=""

# install_bin SRC_FILE DEST_DIR
# Creates a root-owned copy of SRC_FILE in DEST_DIR and makes it executable.
install_bin() {
    local src="$1"
    local dest="$2/$(basename "$1")"
    cp "$src" "$dest" 2>/dev/null || { err "cp failed: $src -> $dest"; return 1; }
    chmod +x "$dest"              || { err "chmod failed: $dest"; return 1; }
    ok "$(basename "$1")  ->  $dest"
    return 0
}

echo ""
echo "========================================"
echo " RC400L zero-dependency tools installer"
echo "========================================"
if [ "$SKIP_FOXCONN" = "1" ]; then
    info "Mode: --skip-foxconn (22_hardware_utils will be skipped)"
fi

# -------------------------------------------------------------------------
# [1] Preflight
# -------------------------------------------------------------------------
hdr "1. Preflight"

if [ "$(id -u)" != "0" ]; then
    err "Not running as root. Run: rootshell, then re-run this script."
    exit 1
fi
ok "Running as root (uid=0)"

mkdir -p "$DEST_DIR" || { err "Cannot create $DEST_DIR"; exit 1; }
ok "Destination ready: $DEST_DIR"

# -------------------------------------------------------------------------
# [2] 10_reg — hardware register read/write
# -------------------------------------------------------------------------
hdr "2. 10_reg (hardware register tool)"

PKG_SRC="$STAGING/reg"
if [ -f "$PKG_SRC/reg" ]; then
    if install_bin "$PKG_SRC/reg" "$DEST_DIR"; then
        INSTALLED=$((INSTALLED + 1))
        INSTALLED_PKGS="$INSTALLED_PKGS reg"
    else
        FAILED=$((FAILED + 1)); FAILED_PKGS="$FAILED_PKGS reg"
    fi
else
    info "Source not found: $PKG_SRC/reg  (push 10_reg to $PKG_SRC to install)"
    SKIPPED=$((SKIPPED + 1)); SKIPPED_PKGS="$SKIPPED_PKGS 10_reg"
fi

# -------------------------------------------------------------------------
# [3] 11_battery_devinfo — battery status, device info, IP address
# -------------------------------------------------------------------------
hdr "3. 11_battery_devinfo (battery / devinfo / ip_addr)"

PKG_SRC="$STAGING/battery"
PKG_OK=0
PKG_FOUND=0
for bin in battery devinfo ip_addr; do
    if [ -f "$PKG_SRC/$bin" ]; then
        PKG_FOUND=$((PKG_FOUND + 1))
        install_bin "$PKG_SRC/$bin" "$DEST_DIR" && PKG_OK=$((PKG_OK + 1))
    fi
done
if [ "$PKG_FOUND" = "0" ]; then
    info "Source not found: $PKG_SRC/  (push 11_battery_devinfo to $PKG_SRC to install)"
    SKIPPED=$((SKIPPED + 1)); SKIPPED_PKGS="$SKIPPED_PKGS 11_battery_devinfo"
elif [ "$PKG_OK" = "$PKG_FOUND" ]; then
    INSTALLED=$((INSTALLED + 1)); INSTALLED_PKGS="$INSTALLED_PKGS 11_battery_devinfo"
else
    err "$((PKG_FOUND - PKG_OK)) of $PKG_FOUND binaries failed to install"
    FAILED=$((FAILED + 1)); FAILED_PKGS="$FAILED_PKGS 11_battery_devinfo"
fi

# -------------------------------------------------------------------------
# [4] 12_athdiag — Atheros WiFi diagnostics
# -------------------------------------------------------------------------
hdr "4. 12_athdiag (Atheros WiFi diagnostics — reads /sys/class/net/wlan0/)"

PKG_SRC="$STAGING/athdiag"
if [ -f "$PKG_SRC/athdiag" ]; then
    if install_bin "$PKG_SRC/athdiag" "$DEST_DIR"; then
        INSTALLED=$((INSTALLED + 1)); INSTALLED_PKGS="$INSTALLED_PKGS 12_athdiag"
    else
        FAILED=$((FAILED + 1)); FAILED_PKGS="$FAILED_PKGS 12_athdiag"
    fi
else
    info "Source not found: $PKG_SRC/athdiag  (push 12_athdiag to $PKG_SRC to install)"
    SKIPPED=$((SKIPPED + 1)); SKIPPED_PKGS="$SKIPPED_PKGS 12_athdiag"
fi

# -------------------------------------------------------------------------
# [5] 13_conntrackd — connection tracking daemon
# -------------------------------------------------------------------------
hdr "5. 13_conntrackd (connection tracking daemon)"
info "NOTE: conntrackd needs CAP_NET_ADMIN. Install-only — use inittab escape to run."
info "      See deploy_xtables.sh / ipt_daemon.sh for the inittab escape pattern."

PKG_SRC="$STAGING/conntrackd"
if [ -f "$PKG_SRC/conntrackd" ]; then
    if install_bin "$PKG_SRC/conntrackd" "$DEST_DIR"; then
        INSTALLED=$((INSTALLED + 1)); INSTALLED_PKGS="$INSTALLED_PKGS 13_conntrackd"
    else
        FAILED=$((FAILED + 1)); FAILED_PKGS="$FAILED_PKGS 13_conntrackd"
    fi
else
    info "Source not found: $PKG_SRC/conntrackd  (push 13_conntrackd to $PKG_SRC to install)"
    SKIPPED=$((SKIPPED + 1)); SKIPPED_PKGS="$SKIPPED_PKGS 13_conntrackd"
fi

# -------------------------------------------------------------------------
# [6] 14_nfnl_osf — netfilter OS fingerprinting loader
# -------------------------------------------------------------------------
hdr "6. 14_nfnl_osf (netfilter OS fingerprinting — loads nfnl_osf.conf into netfilter)"
info "NOTE: nfnl_osf needs CAP_NET_ADMIN. Install-only — use inittab escape or ipt_ctl passthrough to run."

PKG_SRC="$STAGING/nfnl_osf"
if [ -f "$PKG_SRC/nfnl_osf" ]; then
    if install_bin "$PKG_SRC/nfnl_osf" "$DEST_DIR"; then
        INSTALLED=$((INSTALLED + 1)); INSTALLED_PKGS="$INSTALLED_PKGS 14_nfnl_osf"
    else
        FAILED=$((FAILED + 1)); FAILED_PKGS="$FAILED_PKGS 14_nfnl_osf"
    fi
else
    info "Source not found: $PKG_SRC/nfnl_osf  (push 14_nfnl_osf to $PKG_SRC to install)"
    SKIPPED=$((SKIPPED + 1)); SKIPPED_PKGS="$SKIPPED_PKGS 14_nfnl_osf"
fi

# -------------------------------------------------------------------------
# [7] 15_ubi_tools — UBI flash tools
# -------------------------------------------------------------------------
hdr "7. 15_ubi_tools (UBI flash filesystem tools)"

PKG_SRC="$STAGING/ubi_tools"
UBI_BINS="mkfs.ubifs ubimkvol ubinfo ubinize ubirename ubirmvol ubiupdatevol"
PKG_OK=0
PKG_FOUND=0
for bin in $UBI_BINS; do
    if [ -f "$PKG_SRC/$bin" ]; then
        PKG_FOUND=$((PKG_FOUND + 1))
        install_bin "$PKG_SRC/$bin" "$DEST_DIR" && PKG_OK=$((PKG_OK + 1))
    fi
done
if [ "$PKG_FOUND" = "0" ]; then
    info "Source not found: $PKG_SRC/  (push 15_ubi_tools to $PKG_SRC to install)"
    SKIPPED=$((SKIPPED + 1)); SKIPPED_PKGS="$SKIPPED_PKGS 15_ubi_tools"
elif [ "$PKG_OK" = "$PKG_FOUND" ]; then
    INSTALLED=$((INSTALLED + 1)); INSTALLED_PKGS="$INSTALLED_PKGS 15_ubi_tools"
else
    err "$((PKG_FOUND - PKG_OK)) of $PKG_FOUND binaries failed to install"
    FAILED=$((FAILED + 1)); FAILED_PKGS="$FAILED_PKGS 15_ubi_tools"
fi

# -------------------------------------------------------------------------
# [8] 17_network_misc — pimd + genl-ctrl-list
# -------------------------------------------------------------------------
hdr "8. 17_network_misc (pimd multicast daemon + genl-ctrl-list)"
info "NOTE: pimd needs CAP_NET_ADMIN/CAP_NET_RAW. Install-only — use inittab escape to run."
info "      genl-ctrl-list is safe to run from rootshell."

PKG_SRC="$STAGING/network_misc"
PKG_OK=0
PKG_FOUND=0
for bin in pimd genl-ctrl-list; do
    if [ -f "$PKG_SRC/$bin" ]; then
        PKG_FOUND=$((PKG_FOUND + 1))
        install_bin "$PKG_SRC/$bin" "$DEST_DIR" && PKG_OK=$((PKG_OK + 1))
    fi
done
if [ "$PKG_FOUND" = "0" ]; then
    info "Source not found: $PKG_SRC/  (push 17_network_misc to $PKG_SRC to install)"
    SKIPPED=$((SKIPPED + 1)); SKIPPED_PKGS="$SKIPPED_PKGS 17_network_misc"
elif [ "$PKG_OK" = "$PKG_FOUND" ]; then
    INSTALLED=$((INSTALLED + 1)); INSTALLED_PKGS="$INSTALLED_PKGS 17_network_misc"
else
    err "$((PKG_FOUND - PKG_OK)) of $PKG_FOUND binaries failed to install"
    FAILED=$((FAILED + 1)); FAILED_PKGS="$FAILED_PKGS 17_network_misc"
fi

# -------------------------------------------------------------------------
# [9] 22_hardware_utils — Foxconn hardware tools
# -------------------------------------------------------------------------
hdr "9. 22_hardware_utils (Foxconn hardware utilities)"

if [ "$SKIP_FOXCONN" = "1" ]; then
    info "Skipped via --skip-foxconn flag."
    SKIPPED=$((SKIPPED + 1)); SKIPPED_PKGS="$SKIPPED_PKGS 22_hardware_utils(--skip-foxconn)"
else
    info "NOTE: These tools are Foxconn-specific (JMR540 OEM). Some may not work on Orbic RC400L."
    info "      Use --skip-foxconn to skip this package."
    PKG_SRC="$STAGING/hw_utils"
    HW_BINS="fx-usb-switch fx-vbatt fxpollinkey wifi_cal_bin wifi_nv_mac pmm fx_shutdown firmware_upgrade"
    PKG_OK=0
    PKG_FOUND=0
    for bin in $HW_BINS; do
        if [ -f "$PKG_SRC/$bin" ]; then
            PKG_FOUND=$((PKG_FOUND + 1))
            install_bin "$PKG_SRC/$bin" "$DEST_DIR" && PKG_OK=$((PKG_OK + 1))
        fi
    done
    if [ "$PKG_FOUND" = "0" ]; then
        info "Source not found: $PKG_SRC/  (push 22_hardware_utils to $PKG_SRC to install)"
        SKIPPED=$((SKIPPED + 1)); SKIPPED_PKGS="$SKIPPED_PKGS 22_hardware_utils"
    elif [ "$PKG_OK" = "$PKG_FOUND" ]; then
        INSTALLED=$((INSTALLED + 1)); INSTALLED_PKGS="$INSTALLED_PKGS 22_hardware_utils"
    else
        err "$((PKG_FOUND - PKG_OK)) of $PKG_FOUND binaries failed to install"
        FAILED=$((FAILED + 1)); FAILED_PKGS="$FAILED_PKGS 22_hardware_utils"
    fi
fi

# -------------------------------------------------------------------------
# [10] 23_smb_tools — SMB config helpers
# -------------------------------------------------------------------------
hdr "10. 23_smb_tools (SMB config file helpers)"
info "NOTE: modify_smbuser and modify_workgroup edit config files only."
info "      No smbd/nmbd is included — these do not start a file server."

PKG_SRC="$STAGING/smb_tools"
PKG_OK=0
PKG_FOUND=0
for bin in modify_smbuser modify_workgroup; do
    if [ -f "$PKG_SRC/$bin" ]; then
        PKG_FOUND=$((PKG_FOUND + 1))
        install_bin "$PKG_SRC/$bin" "$DEST_DIR" && PKG_OK=$((PKG_OK + 1))
    fi
done
if [ "$PKG_FOUND" = "0" ]; then
    info "Source not found: $PKG_SRC/  (push 23_smb_tools to $PKG_SRC to install)"
    SKIPPED=$((SKIPPED + 1)); SKIPPED_PKGS="$SKIPPED_PKGS 23_smb_tools"
elif [ "$PKG_OK" = "$PKG_FOUND" ]; then
    INSTALLED=$((INSTALLED + 1)); INSTALLED_PKGS="$INSTALLED_PKGS 23_smb_tools"
else
    err "$((PKG_FOUND - PKG_OK)) of $PKG_FOUND binaries failed to install"
    FAILED=$((FAILED + 1)); FAILED_PKGS="$FAILED_PKGS 23_smb_tools"
fi

# -------------------------------------------------------------------------
# [11] 24_netlink_qos — netlink QoS tools
# -------------------------------------------------------------------------
hdr "11. 24_netlink_qos (netlink QoS class tools)"

PKG_SRC="$STAGING/netlink_qos"
PKG_OK=0
PKG_FOUND=0
for bin in nl-class-delete nl-cls-list; do
    if [ -f "$PKG_SRC/$bin" ]; then
        PKG_FOUND=$((PKG_FOUND + 1))
        install_bin "$PKG_SRC/$bin" "$DEST_DIR" && PKG_OK=$((PKG_OK + 1))
    fi
done
if [ "$PKG_FOUND" = "0" ]; then
    info "Source not found: $PKG_SRC/  (push 24_netlink_qos to $PKG_SRC to install)"
    SKIPPED=$((SKIPPED + 1)); SKIPPED_PKGS="$SKIPPED_PKGS 24_netlink_qos"
elif [ "$PKG_OK" = "$PKG_FOUND" ]; then
    INSTALLED=$((INSTALLED + 1)); INSTALLED_PKGS="$INSTALLED_PKGS 24_netlink_qos"
else
    err "$((PKG_FOUND - PKG_OK)) of $PKG_FOUND binaries failed to install"
    FAILED=$((FAILED + 1)); FAILED_PKGS="$FAILED_PKGS 24_netlink_qos"
fi

# -------------------------------------------------------------------------
# [12] 25_shadow_extras — extended shadow-utils
# -------------------------------------------------------------------------
hdr "12. 25_shadow_extras (extended shadow-utils)"
info "NOTE: These tools operate on /etc/shadow."
info "      Deploy 02_shadow_suite first to create /etc/shadow if it does not exist."

PKG_SRC="$STAGING/shadow_extras"
SHADOW_BINS="grpck grpconv grpunconv pwck pwconv pwunconv prepasswd groupmems gpasswd newusers chfn.shadow chsh.shadow chgpasswd newgrp.shadow lastlog logoutd expiry faillog"

if [ ! -f /etc/shadow ]; then
    err "/etc/shadow does not exist — shadow_extras require it."
    err "Deploy 02_shadow_suite first to initialize /etc/shadow, then re-run."
    info "Binaries will still be installed; they will fail at runtime without /etc/shadow."
fi

PKG_OK=0
PKG_FOUND=0
for bin in $SHADOW_BINS; do
    if [ -f "$PKG_SRC/$bin" ]; then
        PKG_FOUND=$((PKG_FOUND + 1))
        install_bin "$PKG_SRC/$bin" "$DEST_DIR" && PKG_OK=$((PKG_OK + 1))
    fi
done
if [ "$PKG_FOUND" = "0" ]; then
    info "Source not found: $PKG_SRC/  (push 25_shadow_extras to $PKG_SRC to install)"
    SKIPPED=$((SKIPPED + 1)); SKIPPED_PKGS="$SKIPPED_PKGS 25_shadow_extras"
elif [ "$PKG_OK" = "$PKG_FOUND" ]; then
    INSTALLED=$((INSTALLED + 1)); INSTALLED_PKGS="$INSTALLED_PKGS 25_shadow_extras"
else
    err "$((PKG_FOUND - PKG_OK)) of $PKG_FOUND binaries failed to install"
    FAILED=$((FAILED + 1)); FAILED_PKGS="$FAILED_PKGS 25_shadow_extras"
fi

# -------------------------------------------------------------------------
# [13] Sanity tests — safe binaries only
# -------------------------------------------------------------------------
hdr "13. Sanity tests (safe binaries)"

# reg --help
if [ -x "$DEST_DIR/reg" ]; then
    info "reg --help:"
    "$DEST_DIR/reg" --help 2>&1 | head -3 | sed 's/^/    /'
else
    info "reg not installed — skipping test"
fi
echo ""

# devinfo
if [ -x "$DEST_DIR/devinfo" ]; then
    info "devinfo:"
    "$DEST_DIR/devinfo" 2>&1 | head -5 | sed 's/^/    /'
else
    info "devinfo not installed — skipping test"
fi
echo ""

# ip_addr
if [ -x "$DEST_DIR/ip_addr" ]; then
    info "ip_addr:"
    "$DEST_DIR/ip_addr" 2>&1 | sed 's/^/    /'
else
    info "ip_addr not installed — skipping test"
fi
echo ""

# genl-ctrl-list (generic netlink enumeration — no caps needed)
if [ -x "$DEST_DIR/genl-ctrl-list" ]; then
    info "genl-ctrl-list (generic netlink families):"
    "$DEST_DIR/genl-ctrl-list" 2>&1 | head -10 | sed 's/^/    /'
else
    info "genl-ctrl-list not installed — skipping test"
fi
echo ""

# -------------------------------------------------------------------------
# [14] Cleanup staging area
# -------------------------------------------------------------------------
hdr "14. Cleanup staging area"

for dir in reg battery athdiag conntrackd nfnl_osf ubi_tools network_misc hw_utils smb_tools netlink_qos shadow_extras; do
    if [ -d "$STAGING/$dir" ]; then
        rm -rf "$STAGING/$dir" && ok "Removed $STAGING/$dir" || err "Failed to remove $STAGING/$dir"
    fi
done

# -------------------------------------------------------------------------
# [15] Summary
# -------------------------------------------------------------------------
echo ""
echo "========================================"
echo " INSTALL SUMMARY"
echo "========================================"
echo ""
echo "  Packages installed : $INSTALLED"
echo "  Packages skipped   : $SKIPPED"
echo "  Packages failed    : $FAILED"
echo ""

if [ -n "$INSTALLED_PKGS" ]; then
    echo "  Installed:"
    for p in $INSTALLED_PKGS; do
        echo "    [+] $p"
    done
    echo ""
fi

if [ -n "$SKIPPED_PKGS" ]; then
    echo "  Skipped (source not pushed or flag set):"
    for p in $SKIPPED_PKGS; do
        echo "    [*] $p"
    done
    echo ""
fi

if [ -n "$FAILED_PKGS" ]; then
    echo "  Failed:"
    for p in $FAILED_PKGS; do
        echo "    [!] $p"
    done
    echo ""
fi

echo "  Binaries in $DEST_DIR:"
ls "$DEST_DIR" 2>/dev/null | sed 's/^/    /'
echo ""

echo " USAGE:"
echo "   export PATH=$DEST_DIR:\$PATH"
echo ""
echo "   # Diagnostics (safe to run from rootshell):"
echo "   $DEST_DIR/reg --help"
echo "   $DEST_DIR/devinfo"
echo "   $DEST_DIR/battery"
echo "   $DEST_DIR/ip_addr"
echo "   $DEST_DIR/athdiag --help"
echo "   $DEST_DIR/ubinfo -a"
echo "   $DEST_DIR/genl-ctrl-list"
echo "   $DEST_DIR/nl-cls-list"
echo ""
echo "   # Needs CAP_NET_ADMIN (use inittab escape / ipt_daemon.sh passthrough):"
echo "   $DEST_DIR/conntrackd -h"
echo "   $DEST_DIR/nfnl_osf -f /path/to/nfnl_osf.conf"
echo "   $DEST_DIR/pimd --help"
echo ""
echo "   # Foxconn-specific (may not work on Orbic RC400L):"
echo "   $DEST_DIR/fx-vbatt"
echo "   $DEST_DIR/wifi_nv_mac"
echo ""
echo "   # SMB config helpers (edit config files only, no smbd included):"
echo "   $DEST_DIR/modify_workgroup WORKGROUP"
echo "   $DEST_DIR/modify_smbuser USER PASSWORD"
echo ""
echo "   # Shadow-utils (require /etc/shadow):"
echo "   $DEST_DIR/pwck"
echo "   $DEST_DIR/grpck"
echo "   $DEST_DIR/gpasswd USER"
echo ""

if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
