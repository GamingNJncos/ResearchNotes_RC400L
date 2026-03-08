#!/bin/sh
# wifi.cgi — RayTrap wpa_supplicant / wlan1 control

WPA_CLI=/cache/bin/wpa_cli
WPA_CONF=/cache/wpa/wpa_supplicant.conf
IFACE=wlan1

printf 'Content-Type: application/json\r\n\r\n'

if [ "$REQUEST_METHOD" = "POST" ]; then
    QUERY_STRING=$(cat 2>/dev/null)
fi

urldecode() {
    printf '%s\n' "$1" | sed 's/+/ /g; s/%\([0-9A-Fa-f][0-9A-Fa-f]\)/\\x\1/g' | while IFS= read -r L; do printf '%b\n' "$L"; done
}
param() {
    local raw
    raw=$(printf '%s' "$QUERY_STRING" | tr '&' '\n' | grep "^${1}=" | head -1 | cut -d= -f2-)
    urldecode "$raw"
}

ok()  { printf '{"ok":true,"data":%s}\n' "${1:-null}"; }
err() { printf '{"ok":false,"error":"%s"}\n' "$(echo "$1" | sed 's/"/\\"/g')"; }
jstr(){ printf '"%s"' "$(echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }

ACTION=$(param action)

find_wpa() {
    for p in $(ls /proc/ 2>/dev/null | grep -E '^[0-9]+$'); do
        local cmd=$(cat /proc/$p/cmdline 2>/dev/null | tr '\0' ' ')
        case "$cmd" in *wpa_supplicant*) echo "$p"; return;; esac
    done
}

wpa() { $WPA_CLI -i "$IFACE" "$@" 2>/dev/null; }

# ── status ────────────────────────────────────────────────────────────────────
if [ "$ACTION" = "status" ]; then
    WPA_PID=$(find_wpa)
    WPA_RUN=false; [ -n "$WPA_PID" ] && WPA_RUN=true

    RAW=$(wpa status 2>/dev/null)
    WPA_STATE=$(echo "$RAW" | grep '^wpa_state=' | cut -d= -f2)
    SSID=$(echo "$RAW" | grep '^ssid=' | cut -d= -f2)
    IP=$(echo "$RAW" | grep '^ip_address=' | cut -d= -f2)

    # Fallback: get IP from ip addr
    [ -z "$IP" ] && IP=$(ip addr show "$IFACE" 2>/dev/null | grep 'inet ' | awk '{print $2}' | head -1)

    # Networks list — use temp file to avoid pipe-subshell variable loss
    NETS_RAW=$(wpa list_networks 2>/dev/null)
    NETTMP=/tmp/wifi_nets_$$.json
    printf '' > "$NETTMP"

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        id=$(echo "$line" | awk '{print $1}')
        echo "$id" | grep -qE '^[0-9]+$' || continue
        ssid=$(echo "$line" | awk '{print $2}')
        flags=$(echo "$line" | awk '{print $4}')
        current=false
        echo "$flags" | grep -q 'CURRENT' && current=true
        printf '{"id":%s,"ssid":%s,"current":%s}\n' "$id" "$(jstr "$ssid")" "$current" >> "$NETTMP"
    done << EOF
$(echo "$NETS_RAW" | tail -n +2)
EOF

    NETS=$(awk 'NR>1{printf ","} {printf "%s",$0}' "$NETTMP" 2>/dev/null)
    rm -f "$NETTMP"
    RAW_ESC=$(echo "$RAW" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' '|' | sed 's/|/\\n/g')

    printf '{"ok":true,"data":{"wpa_running":%s,"wpa_pid":%s,"wpa_state":%s,"ssid":%s,"ip_address":%s,"networks":[%s],"raw":"%s"}}\n' \
        "$WPA_RUN" "${WPA_PID:-null}" \
        "$(jstr "$WPA_STATE")" "$(jstr "$SSID")" "$(jstr "$IP")" \
        "$NETS" "$RAW_ESC"
    exit 0
fi

# ── add_network ───────────────────────────────────────────────────────────────
if [ "$ACTION" = "add_network" ]; then
    SSID=$(param ssid); PSK=$(param psk)
    [ -z "$SSID" ] && { err "SSID required"; exit 0; }

    ID=$(wpa add_network | tr -d '[:space:]')
    echo "$ID" | grep -qE '^[0-9]+$' || { err "wpa_cli add_network failed — is wpa_supplicant running?"; exit 0; }

    wpa set_network "$ID" ssid "\"${SSID}\"" >/dev/null
    if [ -n "$PSK" ]; then
        wpa set_network "$ID" psk "\"${PSK}\"" >/dev/null
    else
        wpa set_network "$ID" key_mgmt NONE >/dev/null
    fi

    wpa enable_network "$ID" >/dev/null
    wpa select_network "$ID" >/dev/null
    wpa save_config >/dev/null

    ok "{\"id\":$ID}"
    exit 0
fi

# ── connect ───────────────────────────────────────────────────────────────────
if [ "$ACTION" = "connect" ]; then
    ID=$(param id)
    echo "$ID" | grep -qE '^[0-9]+$' || { err "invalid id"; exit 0; }
    wpa select_network "$ID" >/dev/null
    ok '"connecting"'
    exit 0
fi

# ── disconnect ────────────────────────────────────────────────────────────────
if [ "$ACTION" = "disconnect" ]; then
    wpa disconnect >/dev/null
    ok '"disconnected"'
    exit 0
fi

# ── remove ────────────────────────────────────────────────────────────────────
if [ "$ACTION" = "remove" ]; then
    ID=$(param id)
    echo "$ID" | grep -qE '^[0-9]+$' || { err "invalid id"; exit 0; }
    wpa remove_network "$ID" >/dev/null
    wpa save_config >/dev/null
    ok '"removed"'
    exit 0
fi

err "Unknown action: $ACTION"
