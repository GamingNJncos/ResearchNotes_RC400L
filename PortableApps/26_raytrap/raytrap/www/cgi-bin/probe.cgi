#!/bin/sh
# probe.cgi — 802.11 Probe Request Monitor via mon0 monitor interface
# actions: start, stop, poll, status, clear

TCPDUMP=/cache/bin/tcpdump
PROBE_LOG=/tmp/raytrap_probes.txt
PROBE_PID=/tmp/raytrap_probe.pid
MON_IFACE=mon0
PHY=phy0

printf 'Content-Type: application/json\r\n\r\n'

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
ok()  { printf '{"ok":true,"data":%s}\n' "${1:-null}"; }
err() { printf '{"ok":false,"error":"%s"}\n' "$(printf '%s' "$1" | sed 's/"/\\"/g')"; }

is_running() {
    [ -f "$PROBE_PID" ] || return 1
    local pid; pid=$(cat "$PROBE_PID" 2>/dev/null)
    [ -z "$pid" ] && return 1
    kill -0 "$pid" 2>/dev/null
}

mon_exists() {
    ip link show "$MON_IFACE" >/dev/null 2>&1
}

ACTION=$(param action)

case "$ACTION" in

start)
    if is_running; then
        ok '{"status":"already_running"}'
        exit 0
    fi
    [ ! -x "$TCPDUMP" ] && { err "tcpdump not found"; exit 0; }

    # Try to create monitor interface
    MON_ERR=""
    if ! mon_exists; then
        iw phy "$PHY" interface add "$MON_IFACE" type monitor 2>/tmp/probe_mon_err.txt
        MON_ERR=$(cat /tmp/probe_mon_err.txt 2>/dev/null | tr '"' "'")
        rm -f /tmp/probe_mon_err.txt
    fi

    if ! mon_exists; then
        err "Cannot create monitor interface: ${MON_ERR:-iw failed. Monitor mode may not be supported by QCACLD driver. Run: iw phy phy0 info | grep -A20 modes}"
        exit 0
    fi

    # Bring up mon0
    ip link set "$MON_IFACE" up 2>/dev/null

    # Start capture — -tt for unix timestamps, -e for MAC, no name resolution
    > "$PROBE_LOG" 2>/dev/null
    nohup "$TCPDUMP" -i "$MON_IFACE" -n -l -tt -e \
        'type mgt subtype probe-req' >> "$PROBE_LOG" 2>&1 &
    echo $! > "$PROBE_PID"

    sleep 1
    if is_running; then
        ok '{"status":"started","iface":"'"$MON_IFACE"'"}'
    else
        # Clean up mon0 on failure
        ip link set "$MON_IFACE" down 2>/dev/null
        iw dev "$MON_IFACE" del 2>/dev/null
        err "tcpdump failed to start on $MON_IFACE"
    fi
    ;;

stop)
    if is_running; then
        pid=$(cat "$PROBE_PID" 2>/dev/null)
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
    fi
    rm -f "$PROBE_PID" 2>/dev/null
    # Tear down monitor interface
    if mon_exists; then
        ip link set "$MON_IFACE" down 2>/dev/null
        iw dev "$MON_IFACE" del 2>/dev/null
    fi
    ok '{"status":"stopped"}'
    ;;

clear)
    > "$PROBE_LOG" 2>/dev/null
    ok '{"status":"cleared"}'
    ;;

status)
    running=false
    is_running && running=true
    lines=0
    [ -f "$PROBE_LOG" ] && lines=$(wc -l < "$PROBE_LOG" 2>/dev/null | tr -d ' ')
    [ -z "$lines" ] && lines=0
    mon=false; mon_exists && mon=true
    ok '{"running":'"$running"',"mon_exists":'"$mon"',"lines":'"$lines"'}'
    ;;

poll|"")
    running=false
    is_running && running=true

    if [ ! -f "$PROBE_LOG" ]; then
        ok '{"running":'"$running"',"devices":[]}'
        exit 0
    fi

    # Parse probe log: group by MAC, accumulate SSIDs, count, last timestamp
    # tcpdump -tt -e probe-req format:
    # TIMESTAMP aa:bb:cc:dd:ee:ff (oui ...) > ff:ff:ff:ff:ff:ff ..., Probe Request (SSID: "name")
    # Field 2 = source MAC, SSID after "Probe Request (SSID: "
    JSON=$(awk '
    /Probe Request/ {
        ts=$1
        mac=$2
        gsub(/[^a-fA-F0-9:]/, "", mac)

        # Extract SSID
        ssid=""
        if (match($0, /SSID: "([^"]*)"/, arr)) {
            ssid=arr[1]
        } else if (match($0, /SSID: \(([^)]*)\)/, arr)) {
            ssid=arr[1]
        }
        if (ssid == "" || ssid ~ /^[[:space:]]*$/) ssid = "<broadcast>"

        count[mac]++
        last_ts[mac]=ts

        # Track unique SSIDs per MAC (store as |delimited)
        if (index(ssids[mac], "|" ssid "|") == 0) {
            ssids[mac] = ssids[mac] "|" ssid "|"
        }
    }
    END {
        first=1
        for (mac in count) {
            # Build SSID JSON array
            ssid_arr = ssids[mac]
            gsub(/^\|/, "", ssid_arr)
            gsub(/\|$/, "", ssid_arr)
            n = split(ssid_arr, sa, "|")
            ssid_json = "["
            for (i=1; i<=n; i++) {
                if (i>1) ssid_json = ssid_json ","
                # Escape quotes in SSID
                s = sa[i]
                gsub(/"/, "\\\"", s)
                ssid_json = ssid_json "\"" s "\""
            }
            ssid_json = ssid_json "]"

            if (!first) printf ","
            printf "{\"mac\":\"%s\",\"count\":%d,\"last_ts\":%s,\"ssids\":%s}",
                mac, count[mac], last_ts[mac], ssid_json
            first=0
        }
    }
    ' "$PROBE_LOG" 2>/dev/null)

    printf '{"ok":true,"data":{"running":%s,"devices":[%s]}}\n' "$running" "$JSON"
    ;;

*)
    err "unknown action: $ACTION"
    ;;

esac
