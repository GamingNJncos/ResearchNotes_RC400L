#!/bin/sh
# diag.cgi — RayTrap DIAG modem capture control
# Manages DIAG log mask config and bridges to rayhunter fork API
# Stream endpoint requires rayhunter fork with /api/log-mask and /api/stream

RAYHUNTER_PORT=8080
MASK_CONF=/data/rayhunter/mask.conf
STREAM_PORT_CONF=/data/rayhunter/stream_port.conf
DEFAULT_STREAM_PORT=37026

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
jstr(){ printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }
jbool(){ [ "$1" = "1" ] || [ "$1" = "true" ] && printf 'true' || printf 'false'; }

printf 'Content-Type: application/json\r\n\r\n'

ACTION=$(param action)

# ── helpers ───────────────────────────────────────────────────────────────────

# Get IP of a specific interface, empty string if not found/up
iface_ip() {
    ip addr show "$1" 2>/dev/null | grep 'inet ' | head -1 | \
        sed 's|.*inet \([0-9.]*\)/.*|\1|'
}

# Check if rayhunter fork API endpoint exists
rh_alive() {
    wget -q -O /dev/null --timeout=2 "http://127.0.0.1:${RAYHUNTER_PORT}/api/config" 2>/dev/null
    return $?
}

rh_has_stream() {
    # Probe the /api/stream endpoint; fork adds it, upstream returns 404
    local code
    code=$(wget -q -S --spider --timeout=2 "http://127.0.0.1:${RAYHUNTER_PORT}/api/stream" 2>&1 | \
           grep 'HTTP/' | tail -1 | awk '{print $2}')
    [ "$code" = "200" ] || [ "$code" = "101" ]
}

stream_port() {
    local p
    p=$(cat "$STREAM_PORT_CONF" 2>/dev/null | grep -E '^[0-9]+$' | head -1)
    printf '%s\n' "${p:-$DEFAULT_STREAM_PORT}"
}

# Default mask values (keys → default on/off)
# Note: printf used instead of heredoc — busybox sh heredoc misbehaves after \r\n written to stdout
mask_default() {
    printf 'lte_rrc=1\nlte_nas=1\nlte_l1=0\nlte_mac=0\nlte_rlc=0\nlte_pdcp=0\n'
    printf 'nr_rrc=1\nwcdma=1\ngsm=1\numts_nas=1\nip_data=1\nf3_debug=0\ngps=0\nqmi_events=0\n'
}

read_mask() {
    if [ ! -f "$MASK_CONF" ]; then
        mask_default
    else
        # Merge defaults with saved values (saved takes priority)
        local defaults saved
        defaults=$(mask_default)
        saved=$(cat "$MASK_CONF" 2>/dev/null)
        # Print defaults first, then saved — last value wins per key after dedup
        printf '%s\n%s\n' "$defaults" "$saved" | \
            awk -F= '!seen[$1]++{lines[NR]=$0; keys[NR]=$1} END{
                for(i=1;i<=NR;i++) if(lines[i]) print lines[i]
            }' 2>/dev/null || { printf '%s\n' "$defaults"; }
    fi
}

mask_to_json() {
    local mask json
    mask=$(read_mask)
    json=$(printf '%s\n' "$mask" | grep -E '^[a-z0-9_]+=.' | \
        awk -F= 'BEGIN{printf "{"} NR>1{printf ","} {v=($2=="1")?"true":"false"; printf "\"%s\":%s",$1,v} END{printf "}"}')
    printf '%s' "$json"
}

# ── status ─────────────────────────────────────────────────────────────────────
if [ "$ACTION" = "status" ]; then
    # Rayhunter process
    RH_PID=$(ps 2>/dev/null | grep rayhunter-daemon | grep -v grep | awk '{print $1}' | head -1)
    RH_RUNNING=false; [ -n "$RH_PID" ] && RH_RUNNING=true

    # Fork capability detection
    FORK_STREAM=false
    rh_has_stream && FORK_STREAM=true

    # Interface IPs — detected live, never hardcoded
    IP_WIFI=$(iface_ip bridge0)
    IP_RNDIS=$(iface_ip rndis0)
    IP_ADB="127.0.0.1"

    # Stream port
    SPORT=$(stream_port)

    printf '{"ok":true,"data":{"rayhunter":{"running":%s,"pid":%s,"port":%d,"fork_stream":%s},"interfaces":{"wifi":%s,"rndis":%s,"adb":%s},"stream_port":%d,"mask":' \
        "$RH_RUNNING" "${RH_PID:-null}" "$RAYHUNTER_PORT" "$FORK_STREAM" \
        "$(jstr "$IP_WIFI")" "$(jstr "$IP_RNDIS")" "$(jstr "$IP_ADB")" \
        "$SPORT"
    mask_to_json
    printf '}}\n'
    exit 0
fi

# ── get_mask ───────────────────────────────────────────────────────────────────
if [ "$ACTION" = "get_mask" ]; then
    printf '{"ok":true,"data":'
    mask_to_json
    printf '}\n'
    exit 0
fi

# ── set_mask ───────────────────────────────────────────────────────────────────
if [ "$ACTION" = "set_mask" ]; then
    KEYS="lte_rrc lte_nas lte_l1 lte_mac lte_rlc lte_pdcp nr_rrc wcdma gsm umts_nas ip_data f3_debug gps qmi_events"

    # Write mask config
    mkdir -p "$(dirname "$MASK_CONF")" 2>/dev/null
    {
        for key in $KEYS; do
            val=$(param "$key")
            case "$val" in
                1|true|on) printf '%s=1\n' "$key" ;;
                *)          printf '%s=0\n' "$key" ;;
            esac
        done
        # Special: enable_all overrides all
        if [ "$(param enable_all)" = "1" ] || [ "$(param enable_all)" = "true" ]; then
            for key in $KEYS; do printf '%s=1\n' "$key"; done
        fi
    } > "$MASK_CONF"

    # If rayhunter fork is deployed, push mask to its API
    APPLIED_TO_RH=false
    if rh_has_stream; then
        MASK_PAYLOAD=$(cat "$MASK_CONF" | \
            awk -F= '{printf "%s=%s&", $1, $2}' | sed 's/&$//')
        wget -q -O /dev/null --timeout=3 \
            --post-data="$MASK_PAYLOAD" \
            "http://127.0.0.1:${RAYHUNTER_PORT}/api/log-mask" 2>/dev/null \
            && APPLIED_TO_RH=true
    fi

    ok "{\"saved\":true,\"applied_to_rayhunter\":${APPLIED_TO_RH}}"
    exit 0
fi

# ── set_stream_port ────────────────────────────────────────────────────────────
if [ "$ACTION" = "set_stream_port" ]; then
    PORT=$(param port)
    printf '%s' "$PORT" | grep -qE '^[0-9]+$' || { err "invalid port"; exit 0; }
    [ "$PORT" -lt 1024 ] || [ "$PORT" -gt 65535 ] 2>/dev/null && { err "port out of range"; exit 0; }
    printf '%s\n' "$PORT" > "$STREAM_PORT_CONF"
    ok "{\"port\":$PORT}"
    exit 0
fi

# ── diag_owner_get ─────────────────────────────────────────────────────────────
# Returns who currently has /dev/diag open, and the config debug_mode state.
if [ "$ACTION" = "diag_owner_get" ]; then
    # Check rayhunter first — it's the primary candidate
    RH_PID=$(ps 2>/dev/null | grep rayhunter-daemon | grep -v grep | awk '{print $1}' | head -1)
    DIAG_OWNER="free"
    DIAG_PID="null"

    if [ -n "$RH_PID" ]; then
        # Does rayhunter hold /dev/diag?
        if ls -la "/proc/${RH_PID}/fd" 2>/dev/null | grep -q 'diag'; then
            DIAG_OWNER="rayhunter"
            DIAG_PID="$RH_PID"
        fi
    fi

    # If not rayhunter, scan other pids (slow but rarely needed)
    if [ "$DIAG_OWNER" = "free" ]; then
        for pid in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
            [ "$pid" = "$RH_PID" ] && continue
            if ls -la "/proc/${pid}/fd" 2>/dev/null | grep -q ' -> /dev/diag'; then
                DIAG_OWNER=$(cat "/proc/${pid}/comm" 2>/dev/null || printf 'pid:%s' "$pid")
                DIAG_PID="$pid"
                break
            fi
        done
    fi

    # Current debug_mode from rayhunter config
    DEBUG_MODE=false
    grep -q '^debug_mode = true' /data/rayhunter/config.toml 2>/dev/null && DEBUG_MODE=true

    printf '{"ok":true,"data":{"diag_owner":'
    jstr "$DIAG_OWNER"
    printf ',"diag_pid":%s,"debug_mode":%s}}\n' "$DIAG_PID" "$DEBUG_MODE"
    exit 0
fi

# ── diag_owner_set ─────────────────────────────────────────────────────────────
# owner=rayhunter → debug_mode=false (rayhunter grabs /dev/diag on start)
# owner=external  → debug_mode=true  (rayhunter skips /dev/diag; QCSuper/USB can open it)
if [ "$ACTION" = "diag_owner_set" ]; then
    OWNER=$(param owner)
    case "$OWNER" in
        rayhunter) NEW_MODE=false ;;
        external)  NEW_MODE=true  ;;
        *) err "owner must be 'rayhunter' or 'external'"; exit 0 ;;
    esac

    CONF=/data/rayhunter/config.toml
    if [ -f "$CONF" ] && grep -q '^debug_mode' "$CONF"; then
        sed -i "s/^debug_mode = .*/debug_mode = ${NEW_MODE}/" "$CONF" 2>/dev/null
    else
        printf 'debug_mode = %s\n' "$NEW_MODE" >> "$CONF"
    fi

    # Restart rayhunter via its init script so start-stop-daemon manages the pidfile correctly.
    # Direct kill leaves /tmp/rayhunter.pid stale — start-stop-daemon would refuse to restart.
    # Use stop+start rather than restart: restart has set -e and aborts if stop returns non-zero
    # (e.g. rayhunter not running). stop is allowed to fail here.
    /etc/init.d/rayhunter_daemon stop 2>/dev/null; /etc/init.d/rayhunter_daemon start 2>/dev/null

    printf '{"ok":true,"data":{"owner":'
    jstr "$OWNER"
    printf ',"debug_mode":%s,"restarting":true}}\n' "$NEW_MODE"
    exit 0
fi

err "unknown action: $ACTION"
