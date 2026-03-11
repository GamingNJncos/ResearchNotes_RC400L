#!/bin/sh
# usb.cgi — RayTrap USB Composition & Qualcomm DIAG debug control
# Reads/writes sysfs USB gadget nodes and /usrdata/mode.cfg
# Composition table sourced from /data/usb/boot_hsusb_composition (20-mode script)

USB=/sys/class/android_usb/android0
MODE_CFG=/usrdata/mode.cfg
MODE_TMP=/usrdata/mode_tmp.cfg

if [ "$REQUEST_METHOD" = "POST" ]; then
    QUERY_STRING=$(cat 2>/dev/null)
fi

urldecode() {
    printf '%s\n' "$1" | sed 's/+/ /g; s/%\([0-9A-Fa-f][0-9A-Fa-f]\)/\\x\1/g' | \
        while IFS= read -r L; do printf '%b\n' "$L"; done
}
param() {
    local raw
    raw=$(printf '%s' "$QUERY_STRING" | tr '&' '\n' | grep "^${1}=" | head -1 | cut -d= -f2-)
    urldecode "$raw"
}
ok()   { printf '{"ok":true,"data":%s}\n' "${1:-null}"; }
err()  { printf '{"ok":false,"error":"%s"}\n' "$(printf '%s' "$1" | sed 's/"/\\"/g')"; }
jstr() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }
jbool(){ [ "$1" = "1" ] || [ "$1" = "true" ] && printf 'true' || printf 'false'; }

printf 'Content-Type: application/json\r\n\r\n'

ACTION=$(param action)

# ── status ─────────────────────────────────────────────────────────────────────
if [ "$ACTION" = "status" ]; then
    FUNCS=$(cat "$USB/functions" 2>/dev/null)
    PID=$(cat "$USB/idProduct" 2>/dev/null)
    VID=$(cat "$USB/idVendor" 2>/dev/null)
    ENABLED=$(cat "$USB/enable" 2>/dev/null)
    MODE=$(cat "$MODE_CFG" 2>/dev/null | tr -d '[:space:]')
    TMP=$(cat "$MODE_TMP" 2>/dev/null | tr -d '[:space:]')
    APPLIED=$(cat /usrdata/mode 2>/dev/null | tr -d '[:space:]')

    DIAG_LIVE=false
    printf '%s' "$FUNCS" | grep -q 'diag' && DIAG_LIVE=true

    printf '{"ok":true,"data":{"functions":%s,"product_id":%s,"vendor_id":%s,"enabled":%s,"mode":%s,"tmp_mode":%s,"applied_mode":%s,"diag_live":%s}}\n' \
        "$(jstr "$FUNCS")" "$(jstr "$PID")" "$(jstr "$VID")" "$(jbool "$ENABLED")" \
        "$(jstr "$MODE")" "$(jstr "$TMP")" "$(jstr "$APPLIED")" "$DIAG_LIVE"
    exit 0
fi

# ── set_mode ───────────────────────────────────────────────────────────────────
# persist=1 → mode.cfg (survives reboots)
# persist=0 → mode_tmp.cfg (one-shot; consumed by boot_hsusb_composition on next boot)
if [ "$ACTION" = "set_mode" ]; then
    MODE=$(param mode)
    PERSIST=$(param persist)
    printf '%s' "$MODE" | grep -qE '^([1-9]|1[0-9]|20)$' || { err "invalid mode (1-20)"; exit 0; }

    if [ "$PERSIST" = "0" ]; then
        printf '%s\n' "$MODE" > "$MODE_TMP"
        ok "{\"mode\":$MODE,\"target\":\"next_boot\"}"
    else
        printf '%s\n' "$MODE" > "$MODE_CFG"
        ok "{\"mode\":$MODE,\"target\":\"persistent\"}"
    fi
    exit 0
fi

# ── live_apply ─────────────────────────────────────────────────────────────────
# Applies the current mode.cfg to sysfs immediately, background with 3-second
# delay so the HTTP response is delivered before USB disconnects.
# Covers modes used by DEBUG.sh (1/9) plus other research-useful compositions.
# WARNING: USB (RNDIS, ADB) disconnects briefly during apply.
if [ "$ACTION" = "live_apply" ]; then
    MODE=$(cat "$MODE_CFG" 2>/dev/null | tr -d '[:space:]')
    [ -z "$MODE" ] && MODE=9

    (sleep 3
     case "$MODE" in
     "1"|"16")
         echo 0 > "$USB/enable"
         echo f601 > "$USB/idProduct"
         echo 05C6 > "$USB/idVendor"
         echo diag > "$USB/f_diag/clients"
         echo smd,smd,smd > "$USB/f_serial/transports"
         echo QTI,BAM_DMUX > "$USB/f_rmnet/transports"
         echo diag,serial,adb,rmnet > "$USB/functions"
         echo 1 > "$USB/enable"
         /etc/init.d/adbd start >/dev/null 2>&1
         ;;
     "9"|"17")
         echo 0 > "$USB/enable"
         echo f622 > "$USB/idProduct"
         echo 05C6 > "$USB/idVendor"
         echo diag > "$USB/f_diag/clients"
         echo smd,smd,smd > "$USB/f_serial/transports"
         echo rndis,diag,serial,adb > "$USB/functions"
         echo 1 > "$USB/f_rndis/wceis"
         echo 1 > "$USB/enable"
         /etc/init.d/adbd start >/dev/null 2>&1
         ;;
     "18")
         echo 0 > "$USB/enable"
         echo f603 > "$USB/idProduct"
         echo 05C6 > "$USB/idVendor"
         echo diag > "$USB/f_diag/clients"
         echo smd,smd,smd > "$USB/f_serial/transports"
         echo QTI,BAM_DMUX > "$USB/f_rmnet/transports"
         echo diag,serial,adb,ecm_qc > "$USB/functions"
         echo 1 > "$USB/enable"
         /etc/init.d/adbd start >/dev/null 2>&1
         ;;
     "19")
         echo 0 > "$USB/enable"
         echo 9085 > "$USB/idProduct"
         echo 05C6 > "$USB/idVendor"
         echo 239 > "$USB/bDeviceClass"
         echo 2 > "$USB/bDeviceSubClass"
         echo 1 > "$USB/bDeviceProtocol"
         echo diag > "$USB/f_diag/clients"
         echo BAM_DMUX > "$USB/f_usb_mbim/mbim_transports"
         echo diag,adb,usb_mbim,gps > "$USB/functions"
         echo 1 > "$USB/remote_wakeup"
         echo 1 > "$USB/enable"
         /etc/init.d/adbd start >/dev/null 2>&1
         ;;
     "20")
         echo 0 > "$USB/enable"
         echo 9025 > "$USB/idProduct"
         echo 05C6 > "$USB/idVendor"
         echo diag > "$USB/f_diag/clients"
         echo smd,smd,smd > "$USB/f_serial/transports"
         echo QTI,BAM_DMUX > "$USB/f_rmnet/transports"
         echo diag,serial,rmnet,adb > "$USB/functions"
         echo 1 > "$USB/enable"
         /etc/init.d/adbd start >/dev/null 2>&1
         ;;
     *)
         # Fallback: mode 9 (device default)
         echo 0 > "$USB/enable"
         echo f622 > "$USB/idProduct"
         echo 05C6 > "$USB/idVendor"
         echo diag > "$USB/f_diag/clients"
         echo smd,smd,smd > "$USB/f_serial/transports"
         echo rndis,diag,serial,adb > "$USB/functions"
         echo 1 > "$USB/f_rndis/wceis"
         echo 1 > "$USB/enable"
         /etc/init.d/adbd start >/dev/null 2>&1
         ;;
     esac
     # Keep /usrdata/mode in sync with what was just applied
     echo "$MODE" > /usrdata/mode) </dev/null >/dev/null 2>&1 &

    ok "{\"mode\":$MODE,\"applying\":true,\"delay_sec\":3}"
    exit 0
fi

# ── custom_apply ───────────────────────────────────────────────────────────────
# Apply an arbitrary USB function composition live (does NOT persist across reboots).
# Parameters: functions (comma-separated), pid (4-hex idProduct, optional, default f622)
# Validated against a whitelist of registered function names.
if [ "$ACTION" = "custom_apply" ]; then
    FUNCS=$(param functions)
    PID=$(param pid)

    [ -z "$FUNCS" ] && { err "functions required"; exit 0; }

    # Validate: each token must be a known registered function name
    WHITELIST="diag serial adb rndis rndis_qc ecm ecm_qc rmnet usb_mbim gps ffs ncm mtp ptp mass_storage"
    OLD_IFS="$IFS"; IFS=","
    for fn in $FUNCS; do
        OK=false
        for w in $WHITELIST; do [ "$fn" = "$w" ] && { OK=true; break; }; done
        if ! $OK; then IFS="$OLD_IFS"; err "unknown function: $fn"; exit 0; fi
    done
    IFS="$OLD_IFS"

    [ -z "$PID" ] && PID="f622"
    printf '%s' "$PID" | grep -qiE '^[0-9a-f]{4}$' || { err "pid must be 4 hex digits"; exit 0; }

    FUNCS_J=$(printf '%s' "$FUNCS" | sed 's/"/\\"/g')
    (sleep 3
     echo 0 > "$USB/enable"
     printf '%s\n' "$PID" > "$USB/idProduct"
     echo 05C6 > "$USB/idVendor"
     echo diag > "$USB/f_diag/clients" 2>/dev/null
     echo smd,smd,smd > "$USB/f_serial/transports" 2>/dev/null
     echo 1 > "$USB/f_rndis/wceis" 2>/dev/null
     printf '%s\n' "$FUNCS" > "$USB/functions"
     echo 1 > "$USB/enable"
     /etc/init.d/adbd start >/dev/null 2>&1) </dev/null >/dev/null 2>&1 &

    ok "{\"functions\":\"$FUNCS_J\",\"pid\":\"$PID\",\"applying\":true,\"delay_sec\":3}"
    exit 0
fi

# ── diag_usb_set ───────────────────────────────────────────────────────────────
# Toggle the Qualcomm DIAG interface in the live USB gadget functions.
# enable=1 → add "diag" to current functions (host sees Qualcomm Diagnostics port)
# enable=0 → remove "diag" from current functions (DIAG hidden from USB host)
# Applies with 3-second delay via background fork; USB disconnects briefly.
# This is independent of the mode — it overlays on whatever mode is currently active.
if [ "$ACTION" = "diag_usb_set" ]; then
    ENABLE=$(param enable)
    CURRENT=$(cat "$USB/functions" 2>/dev/null)

    if [ "$ENABLE" = "1" ]; then
        # Add diag at front if not already present
        if printf '%s' "$CURRENT" | grep -q 'diag'; then
            NEW="$CURRENT"
        else
            NEW="diag,$CURRENT"
        fi
    else
        # Strip diag in all positions: start, middle, end, or solo
        NEW=$(printf '%s' "$CURRENT" | sed 's/^diag,//; s/,diag,/,/g; s/,diag$//; s/^diag$//')
    fi

    NF_J=$(printf '%s' "$NEW" | sed 's/"/\\"/g')
    EN=$ENABLE

    (sleep 3
     echo 0 > "$USB/enable"
     [ "$EN" = "1" ] && echo diag > "$USB/f_diag/clients"
     printf '%s\n' "$NEW" > "$USB/functions"
     echo 1 > "$USB/enable"
     /etc/init.d/adbd start >/dev/null 2>&1) </dev/null >/dev/null 2>&1 &

    ok "{\"enable\":$(jbool "$ENABLE"),\"new_functions\":\"$NF_J\",\"applying\":true,\"delay_sec\":3}"
    exit 0
fi

err "unknown action: $ACTION"
