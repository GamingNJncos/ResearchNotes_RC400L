#!/bin/sh
# system.cgi — System overview: interface stats + signal history ring buffer
# GET: returns JSON with iface stats + RSRP history

SMD7=/dev/smd7
TMPOUT=/tmp/sys_cgi_resp.$$
HIST=/cache/raytrap/signal_history.json
HIST_MAX=20

printf 'Content-Type: application/json\r\n\r\n'

trap 'rm -f "$TMPOUT"; exec 3>&- 2>/dev/null' EXIT

# ── Interface stats from /proc/net/dev ───────────────────────────────────────
# Line format (after header): "  iface: rx_bytes rx_pkts rx_err rx_drop ... tx_bytes tx_pkts ..."
# Fields: 1=iface: 2=rx_bytes 3=rx_pkts 10=tx_bytes 11=tx_pkts
IFACES_JSON=$(awk '
NR <= 2 { next }
{
    gsub(/:/, "", $1)
    if ($1 == "lo") next
    state = "unknown"
    stfile = "/sys/class/net/" $1 "/operstate"
    if ((getline st < stfile) > 0) state = st
    close(stfile)
    gsub(/\r/, "", state)
    if (count > 0) printf ","
    printf "{\"name\":\"%s\",\"rx_bytes\":%s,\"rx_pkts\":%s,\"tx_bytes\":%s,\"tx_pkts\":%s,\"state\":\"%s\"}", \
        $1, $2, $3, $10, $11, state
    count++
}' /proc/net/dev 2>/dev/null)

# ── AT+CESQ → RSRP ──────────────────────────────────────────────────────────
RSRP_VAL="null"
if [ -r "$SMD7" ]; then
    > "$TMPOUT"
    exec 3<>"$SMD7" 2>/dev/null
    if [ $? -eq 0 ]; then
        printf 'AT+CESQ\r\n' >&3
        cat <&3 >"$TMPOUT" &
        rpid=$!
        i=0
        while [ $i -lt 5 ]; do
            sleep 1; i=$((i+1))
            grep -qF "$(printf 'OK\r')" "$TMPOUT" 2>/dev/null && break
            grep -qF "$(printf 'ERROR\r')" "$TMPOUT" 2>/dev/null && break
        done
        kill "$rpid" 2>/dev/null; wait "$rpid" 2>/dev/null
        exec 3>&-
        if grep -q '+CESQ:' "$TMPOUT" 2>/dev/null; then
            CESQ_LINE=$(grep '+CESQ:' "$TMPOUT" | head -1 | tr -d '\r')
            CESQ_VALS="${CESQ_LINE#+CESQ: }"
            RSRP_IDX=$(printf '%s' "$CESQ_VALS" | cut -d, -f6 | tr -d ' ')
            if [ -n "$RSRP_IDX" ] && [ "$RSRP_IDX" != "255" ] 2>/dev/null; then
                RSRP_VAL=$(( RSRP_IDX - 140 ))
            fi
        fi
    fi
fi

# ── Signal history ring buffer ───────────────────────────────────────────────
NOW=$(date +%s 2>/dev/null || printf '0')
mkdir -p "$(dirname "$HIST")" 2>/dev/null

# Append to history file (one line per entry: timestamp rsrp_or_null)
if [ "$RSRP_VAL" != "null" ]; then
    printf '%s %s\n' "$NOW" "$RSRP_VAL" >> "$HIST.txt" 2>/dev/null
    # Trim to last HIST_MAX lines
    if [ -f "$HIST.txt" ]; then
        tail -n "$HIST_MAX" "$HIST.txt" > "$HIST.txt.tmp" 2>/dev/null && mv "$HIST.txt.tmp" "$HIST.txt" 2>/dev/null
    fi
fi

# Build history JSON array from text file
HIST_JSON="[]"
if [ -f "$HIST.txt" ]; then
    HIST_JSON=$(awk 'BEGIN{printf "["}
        NR>1{printf ","}
        {printf "{\"t\":%s,\"rsrp\":%s}", $1, $2}
        END{printf "]"}' "$HIST.txt" 2>/dev/null)
    [ -z "$HIST_JSON" ] && HIST_JSON="[]"
fi

# ── Uptime ───────────────────────────────────────────────────────────────────
UPTIME_SEC=$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null)
[ -z "$UPTIME_SEC" ] && UPTIME_SEC="null"

# ── Output JSON ──────────────────────────────────────────────────────────────
printf '{"ok":true,"data":{"ifaces":[%s],"rsrp":%s,"signal_history":%s,"uptime_sec":%s}}\n' \
    "$IFACES_JSON" "$RSRP_VAL" "$HIST_JSON" "$UPTIME_SEC"
