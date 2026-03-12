#!/bin/sh
# dns.cgi — DNS Monitor: capture port 53 traffic via tcpdump, serve as JSON
# actions: start, stop, poll, status, clear

TCPDUMP=/cache/bin/tcpdump
DNS_LOG=/tmp/raytrap_dns.txt
DNS_PID=/tmp/raytrap_dns.pid
MAX_LINES=500

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
    [ -f "$DNS_PID" ] || return 1
    local pid; pid=$(cat "$DNS_PID" 2>/dev/null)
    [ -z "$pid" ] && return 1
    kill -0 "$pid" 2>/dev/null
}

ACTION=$(param action)
IFACE=$(param iface)
[ -z "$IFACE" ] && IFACE="wlan0"

# Sanitize iface — only allow alnum+digits
IFACE=$(printf '%s' "$IFACE" | tr -cd 'a-zA-Z0-9')

case "$ACTION" in

start)
    if is_running; then
        ok '{"status":"already_running"}'
        exit 0
    fi
    [ ! -x "$TCPDUMP" ] && { err "tcpdump not found at $TCPDUMP"; exit 0; }
    # Rotate log
    > "$DNS_LOG" 2>/dev/null
    # BPF filter: UDP/TCP port 53, exclude the device itself (192.168.1.1) as source
    # -n: no name resolution, -l: line-buffered, -tt: unix timestamps, no -e (cleaner parse)
    nohup "$TCPDUMP" -i "$IFACE" -n -l -tt 'udp port 53 or tcp port 53' \
        >> "$DNS_LOG" 2>&1 &
    echo $! > "$DNS_PID"
    # Brief wait to detect immediate crash
    sleep 1
    if is_running; then
        ok '{"status":"started","iface":"'"$IFACE"'"}'
    else
        err "tcpdump failed to start on $IFACE — check interface"
    fi
    ;;

stop)
    if is_running; then
        pid=$(cat "$DNS_PID" 2>/dev/null)
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
    fi
    rm -f "$DNS_PID" 2>/dev/null
    ok '{"status":"stopped"}'
    ;;

clear)
    > "$DNS_LOG" 2>/dev/null
    ok '{"status":"cleared"}'
    ;;

status)
    running=false
    pid_val="null"
    if is_running; then
        running=true
        pid_val=$(cat "$DNS_PID" 2>/dev/null)
        [ -z "$pid_val" ] && pid_val="null"
    fi
    lines=0
    [ -f "$DNS_LOG" ] && lines=$(wc -l < "$DNS_LOG" 2>/dev/null | tr -d ' ')
    [ -z "$lines" ] && lines=0
    ok '{"running":'"$running"',"pid":'"$pid_val"',"lines":'"$lines"'}'
    ;;

poll|"")
    # Return last N lines parsed as JSON query records
    # tcpdump -tt -n output: timestamp IP src.srcport > dst.dstport: id+ TYPE? domain. (len)
    # Line format: "1741650000.123456 IP 192.168.1.101.52341 > 192.168.1.1.53: 12345+ A? google.com. (28)"
    # We only want queries (direction: client→device, i.e. dst port 53 where dst=192.168.1.1)
    # We also want to show upstream forwarded queries (device→upstream, from rmnet0 perspective)
    COUNT=$(param count)
    [ -z "$COUNT" ] && COUNT=100
    printf '%s' "$COUNT" | grep -qE '^[0-9]+$' || COUNT=100
    [ "$COUNT" -gt 500 ] && COUNT=500

    running=false
    is_running && running=true

    if [ ! -f "$DNS_LOG" ]; then
        ok '{"running":'"$running"',"queries":[]}'
        exit 0
    fi

    # Parse last COUNT lines into JSON
    JSON=$(tail -n "$COUNT" "$DNS_LOG" 2>/dev/null | awk '
    BEGIN { first=1 }
    /^[0-9]+\.[0-9]+ IP / {
        ts=$1
        src=$3
        dst=$5

        # Remove trailing colon from dst
        gsub(/:$/, "", dst)

        # Extract domain and type from query: "12345+ A? domain. (28)"
        # Fields: $6=id+, $7=TYPE?, $8=domain.
        qtype = ""
        domain = ""
        if (NF >= 8) {
            qtype = $7
            domain = $8
            gsub(/\?$/, "", qtype)
            gsub(/\.$/, "", domain)
        }

        # Source IP (strip port: last .N after last dot)
        # e.g. 192.168.1.101.52341 → 192.168.1.101
        n = split(src, parts, ".")
        srcip = ""
        for (i=1; i<=n-1; i++) srcip = srcip (i>1?".":"") parts[i]

        # Skip if no domain (not a query line)
        if (domain == "" || domain ~ /^[0-9]/) next

        if (!first) printf ","
        printf "{\"ts\":%s,\"src\":\"%s\",\"qtype\":\"%s\",\"domain\":\"%s\"}",
            ts, srcip, qtype, domain
        first=0
    }
    ')
    printf '{"ok":true,"data":{"running":%s,"queries":[%s]}}\n' "$running" "$JSON"
    ;;

*)
    err "unknown action: $ACTION"
    ;;

esac
