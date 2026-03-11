#!/bin/sh
# wifi.cgi — RayTrap wpa_supplicant / wlan1 control

WPA_CLI=/cache/bin/wpa_cli
WPA_CONF=/cache/wpa/wpa_supplicant.conf
IFACE=wlan1
WLAN_XML=/usrdata/data/usr/wlan/wlan_conf_6174.xml

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

IP_MODE_FILE=/cache/wpa/ip_mode.cfg

find_wpa() {
    for p in $(ls /proc/ 2>/dev/null | grep -E '^[0-9]+$'); do
        local cmd=$(cat /proc/$p/cmdline 2>/dev/null | tr '\0' ' ')
        case "$cmd" in *wpa_supplicant*) echo "$p"; return;; esac
    done
}

find_dhcpcd() {
    for p in $(ls /proc/ 2>/dev/null | grep -E '^[0-9]+$'); do
        local cmd=$(cat /proc/$p/cmdline 2>/dev/null | tr '\0' ' ')
        case "$cmd" in *dhcpcd*wlan1*|*dhcpcd* )
            echo "$cmd" | grep -q wlan1 && { echo "$p"; return; }
            ;;
        esac
    done
}

wpa() { $WPA_CLI -i "$IFACE" "$@" 2>/dev/null; }

# Run command via ipt daemon (needed for CAP_NET_ADMIN ops like ip addr/route)
ipt() { sh /cache/ipt/ipt_ctl.sh "$@" >/dev/null 2>&1; }

# Read AP band from wlan_conf_6174.xml (single-line XML, first <band> tag is Advance_0)
ap_band_str() {
    local num
    num=$(sed 's/.*<Advance_0>//' "$WLAN_XML" 2>/dev/null | sed 's/<Advance_1>.*//' | grep -o '<band>[01]</band>' | grep -o '[01]')
    [ "$num" = "1" ] && echo "5" || echo "2.4"
}
ap_channel_str() {
    sed 's/.*<Advance_0>//' "$WLAN_XML" 2>/dev/null | sed 's/<Advance_1>.*//' | grep -o '<channel>[0-9]*</channel>' | grep -o '[0-9]*'
}

# ── status ────────────────────────────────────────────────────────────────────
if [ "$ACTION" = "status" ]; then
    WPA_PID=$(find_wpa)
    WPA_RUN=false; [ -n "$WPA_PID" ] && WPA_RUN=true

    RAW=$(wpa status 2>/dev/null)
    WPA_STATE=$(echo "$RAW" | grep '^wpa_state=' | cut -d= -f2)
    SSID=$(echo "$RAW" | grep '^ssid=' | cut -d= -f2)
    IP=$(echo "$RAW" | grep '^ip_address=' | cut -d= -f2)
    FREQ=$(echo "$RAW" | grep '^freq=' | cut -d= -f2)

    [ -z "$IP" ] && IP=$(ip addr show "$IFACE" 2>/dev/null | grep 'inet ' | awk '{print $2}' | head -1)

    AP_BAND=$(ap_band_str)
    AP_CHANNEL=$(ap_channel_str)

    # Derive wpa_supplicant connection band from freq
    STA_BAND=""
    if [ -n "$FREQ" ]; then
        [ "$FREQ" -ge 5000 ] 2>/dev/null && STA_BAND="5" || STA_BAND="2.4"
    fi

    # IP config state
    IP_MODE=$(cat "$IP_MODE_FILE" 2>/dev/null | awk '{print $1}')
    [ -z "$IP_MODE" ] && IP_MODE="none"
    DHCP_PID=$(find_dhcpcd)
    DHCP_RUN=false; [ -n "$DHCP_PID" ] && DHCP_RUN=true
    # Read static config stored in mode file (format: "static IP/CIDR GATEWAY")
    STATIC_IP=""; STATIC_GW=""
    if [ "$IP_MODE" = "static" ]; then
        STATIC_IP=$(cat "$IP_MODE_FILE" 2>/dev/null | awk '{print $2}')
        STATIC_GW=$(cat "$IP_MODE_FILE" 2>/dev/null | awk '{print $3}')
    fi

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

    printf '{"ok":true,"data":{"wpa_running":%s,"wpa_pid":%s,"wpa_state":%s,"ssid":%s,"ip_address":%s,"freq":%s,"sta_band":%s,"ap_band":%s,"ap_channel":%s,"ip_mode":%s,"dhcp_running":%s,"static_ip":%s,"static_gw":%s,"networks":[%s],"raw":"%s"}}\n' \
        "$WPA_RUN" "${WPA_PID:-null}" \
        "$(jstr "$WPA_STATE")" "$(jstr "$SSID")" "$(jstr "$IP")" \
        "${FREQ:-null}" "$(jstr "$STA_BAND")" "$(jstr "$AP_BAND")" "${AP_CHANNEL:-null}" \
        "$(jstr "$IP_MODE")" "$DHCP_RUN" "$(jstr "$STATIC_IP")" "$(jstr "$STATIC_GW")" \
        "$NETS" "$RAW_ESC"
    exit 0
fi

# ── add_network ───────────────────────────────────────────────────────────────
if [ "$ACTION" = "add_network" ]; then
    SSID=$(param ssid); PSK=$(param psk); BAND=$(param band)
    [ -z "$SSID" ] && { err "SSID required"; exit 0; }

    ID=$(wpa add_network | tr -d '[:space:]')
    echo "$ID" | grep -qE '^[0-9]+$' || { err "wpa_cli add_network failed — is wpa_supplicant running?"; exit 0; }

    wpa set_network "$ID" ssid "\"${SSID}\"" >/dev/null
    if [ -n "$PSK" ]; then
        wpa set_network "$ID" psk "\"${PSK}\"" >/dev/null
    else
        wpa set_network "$ID" key_mgmt NONE >/dev/null
    fi

    # Band restriction via freq_list
    case "$BAND" in
        2.4) wpa set_network "$ID" freq_list "2412 2417 2422 2427 2432 2437 2442 2447 2452 2457 2462" >/dev/null ;;
        5)   wpa set_network "$ID" freq_list "5180 5200 5220 5240 5260 5280 5300 5320 5500 5520 5540 5560 5580 5600 5620 5640 5660 5680 5700 5720 5745 5765 5785 5805 5825" >/dev/null ;;
    esac

    wpa enable_network "$ID" >/dev/null
    wpa select_network "$ID" >/dev/null
    wpa save_config >/dev/null

    ok "{\"id\":$ID,\"band\":$(jstr "${BAND:-auto}")}"
    exit 0
fi

# ── set_ap_band ───────────────────────────────────────────────────────────────
if [ "$ACTION" = "set_ap_band" ]; then
    BAND=$(param band)
    case "$BAND" in
        5)
            NEW_BAND_NUM=1; NEW_MODE=5
            NEW_HW_MODE=a; NEW_CHANNEL=36; NEW_CHANLIST="36 40 44 48 149 153 157 161"
            NEW_HT_CAPAB="[HT40-][SHORT-GI-20][SHORT-GI-40]"
            NEW_CHAN_LIST_XML="36-165"
            ;;
        2.4)
            NEW_BAND_NUM=0; NEW_MODE=4
            NEW_HW_MODE=g; NEW_CHANNEL=0; NEW_CHANLIST="1-11"
            NEW_HT_CAPAB="[HT40+][SHORT-GI-20][SHORT-GI-40]"
            NEW_CHAN_LIST_XML="1-11"
            ;;
        *)
            err "band must be 2.4 or 5"; exit 0
            ;;
    esac

    # Update wlan_conf_6174.xml for persistence (single-line XML, first occurrence = Advance_0)
    sed -i "s/<band>[01]<\/band>/<band>${NEW_BAND_NUM}<\/band>/" "$WLAN_XML" 2>/dev/null
    sed -i "s/<wifi80211mode>[0-9]*<\/wifi80211mode>/<wifi80211mode>${NEW_MODE}<\/wifi80211mode>/" "$WLAN_XML" 2>/dev/null
    sed -i "s/<channel_list>[^<]*<\/channel_list>/<channel_list>${NEW_CHAN_LIST_XML}<\/channel_list>/" "$WLAN_XML" 2>/dev/null

    # Update live /tmp/hostapd_wlan0.conf and SIGHUP hostapd via ipt daemon (full caps needed)
    # Does NOT kill hostapd — band change takes full effect on next AP restart.
    # SIGHUP triggers a reload; driver may or may not apply band change live.
    printf '#!/bin/sh\n' > /data/tmp/switch_ap_band.sh
    printf 'sed -i "s/^hw_mode=.*/hw_mode=%s/" /tmp/hostapd_wlan0.conf\n' "$NEW_HW_MODE" >> /data/tmp/switch_ap_band.sh
    printf 'sed -i "s/^channel=.*/channel=%s/" /tmp/hostapd_wlan0.conf\n' "$NEW_CHANNEL" >> /data/tmp/switch_ap_band.sh
    printf 'sed -i "s/^chanlist=.*/chanlist=%s/" /tmp/hostapd_wlan0.conf\n' "$NEW_CHANLIST" >> /data/tmp/switch_ap_band.sh
    printf 'sed -i "s/^ht_capab=.*/ht_capab=%s/" /tmp/hostapd_wlan0.conf\n' "$NEW_HT_CAPAB" >> /data/tmp/switch_ap_band.sh
    printf 'HAP_PID=$(cat /tmp/hostapd_wlan0.pid 2>/dev/null | tr -d "[:space:]")\n' >> /data/tmp/switch_ap_band.sh
    printf '[ -n "$HAP_PID" ] && [ -d "/proc/$HAP_PID" ] && kill -HUP "$HAP_PID" 2>/dev/null\n' >> /data/tmp/switch_ap_band.sh
    chmod +x /data/tmp/switch_ap_band.sh

    sh /cache/ipt/ipt_ctl.sh sh /data/tmp/switch_ap_band.sh >/dev/null 2>&1
    sleep 2

    ok "{\"band\":\"$BAND\",\"hw_mode\":\"$NEW_HW_MODE\",\"channel\":$NEW_CHANNEL,\"note\":\"Config updated. Band change takes full effect on next AP restart.\"}"
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

# ── start_wpa ─────────────────────────────────────────────────────────────────
if [ "$ACTION" = "start_wpa" ]; then
    WPA_PID=$(find_wpa)
    [ -n "$WPA_PID" ] && { ok '"already_running"'; exit 0; }

    # Create wlan1 if it doesn't exist (requires CAP_NET_ADMIN — route through ipt daemon)
    if ! ip link show "$IFACE" >/dev/null 2>&1; then
        sh /cache/ipt/ipt_ctl.sh iw phy phy0 interface add "$IFACE" type managed >/dev/null 2>&1
        sleep 1
        if ! ip link show "$IFACE" >/dev/null 2>&1; then
            err "Failed to create $IFACE interface"
            exit 0
        fi
    fi

    # Bring interface up
    sh /cache/ipt/ipt_ctl.sh ip link set "$IFACE" up >/dev/null 2>&1

    # Launch wpa_supplicant via ipt daemon (direct exec is blocked by LSM)
    sh /cache/ipt/ipt_ctl.sh /cache/bin/wpa_supplicant -B -i "$IFACE" -c "$WPA_CONF" -P /var/run/wpa_supplicant.pid >/dev/null 2>&1
    sleep 2
    WPA_PID=$(find_wpa)
    [ -n "$WPA_PID" ] && ok '"started"' || err "wpa_supplicant failed to start — check /cache/ipt/daemon.log"
    exit 0
fi

# ── stop_wpa ──────────────────────────────────────────────────────────────────
if [ "$ACTION" = "stop_wpa" ]; then
    WPA_PID=$(find_wpa)
    [ -z "$WPA_PID" ] && { ok '"already_stopped"'; exit 0; }
    kill "$WPA_PID" 2>/dev/null
    sleep 1
    WPA_PID=$(find_wpa)
    [ -z "$WPA_PID" ] && ok '"stopped"' || err "wpa_supplicant still running (PID $WPA_PID)"
    exit 0
fi

# ── set_ip_dhcp ───────────────────────────────────────────────────────────────
if [ "$ACTION" = "set_ip_dhcp" ]; then
    # Stop any running dhcpcd on wlan1
    DHCP_PID=$(find_dhcpcd)
    [ -n "$DHCP_PID" ] && ipt kill "$DHCP_PID"
    sleep 1

    # Flush existing IP and routes on wlan1
    ipt ip addr flush dev "$IFACE"
    ipt ip route flush dev "$IFACE"

    # Start dhcpcd (self-contained: sets IP, gateway, DNS)
    ipt dhcpcd -b "$IFACE"

    echo "dhcp" > "$IP_MODE_FILE"
    sleep 3

    DHCP_PID=$(find_dhcpcd)
    IP=$(ip addr show "$IFACE" 2>/dev/null | grep 'inet ' | awk '{print $2}' | head -1)
    ok "{\"dhcp_running\":$([ -n "$DHCP_PID" ] && echo true || echo false),\"ip_address\":$(jstr "$IP")}"
    exit 0
fi

# ── set_ip_static ─────────────────────────────────────────────────────────────
if [ "$ACTION" = "set_ip_static" ]; then
    CIDR=$(param ip)   # e.g. 192.168.1.100/24
    GW=$(param gw)     # e.g. 192.168.1.1

    [ -z "$CIDR" ] && { err "ip (CIDR) required"; exit 0; }
    [ -z "$GW" ]  && { err "gw (gateway) required"; exit 0; }

    # Validate basic format
    echo "$CIDR" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' || { err "ip must be in CIDR notation, e.g. 192.168.1.100/24"; exit 0; }
    echo "$GW"   | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'         || { err "gw must be an IP address"; exit 0; }

    # Stop dhcpcd if running
    DHCP_PID=$(find_dhcpcd)
    [ -n "$DHCP_PID" ] && ipt kill "$DHCP_PID"
    sleep 1

    # Flush and apply
    ipt ip addr flush dev "$IFACE"
    ipt ip route flush dev "$IFACE"
    ipt ip addr add "$CIDR" dev "$IFACE"
    ipt ip route add default via "$GW" dev "$IFACE" metric 200

    echo "static $CIDR $GW" > "$IP_MODE_FILE"

    IP=$(ip addr show "$IFACE" 2>/dev/null | grep 'inet ' | awk '{print $2}' | head -1)
    GW_CHECK=$(ip route show dev "$IFACE" 2>/dev/null | grep default | awk '{print $3}')
    [ -n "$IP" ] && ok "{\"ip_address\":$(jstr "$IP"),\"gateway\":$(jstr "$GW_CHECK")}" || err "IP assignment failed"
    exit 0
fi

# ── release_ip ────────────────────────────────────────────────────────────────
if [ "$ACTION" = "release_ip" ]; then
    DHCP_PID=$(find_dhcpcd)
    [ -n "$DHCP_PID" ] && ipt kill "$DHCP_PID"
    ipt ip addr flush dev "$IFACE"
    ipt ip route flush dev "$IFACE"
    echo "none" > "$IP_MODE_FILE"
    ok '"released"'
    exit 0
fi

err "Unknown action: $ACTION"
