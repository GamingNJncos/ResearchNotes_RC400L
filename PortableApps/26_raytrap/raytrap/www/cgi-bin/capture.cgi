#!/bin/sh
# capture.cgi — RayTrap tcpdump control
# Supports two modes:
#   File mode: saves .pcap to /cache/raytrap/captures/ (disk risk with large caps)
#   Stream mode: pipes tcpdump -w - to a nc listener, zero disk writes

CAP_DIR=/cache/raytrap/captures
TCPDUMP=/cache/bin/tcpdump
PIDFILE="$CAP_DIR/tcpdump.pid"
METAFILE="$CAP_DIR/tcpdump.meta"

# Stream state
STREAM_PIDFILE="$CAP_DIR/stream.pid"   # holds "tcpdump_pid:nc_pid"
STREAM_FIFO="$CAP_DIR/stream.fifo"
STREAM_PORT_CONF=/data/rayhunter/stream_port.conf
DEFAULT_STREAM_PORT=37027               # distinct from DIAG stream port (37026)

mkdir -p "$CAP_DIR" 2>/dev/null

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

# ── download — must handle before Content-Type header ────────────────────────
if [ "$REQUEST_METHOD" = "GET" ]; then
    QUERY_STRING="$QUERY_STRING"
fi
ACTION=$(param action)

if [ "$ACTION" = "download" ]; then
    FILE=$(param file)
    FILE=$(basename "$FILE")
    FPATH="$CAP_DIR/$FILE"
    case "$FILE" in *.pcap) ;; *)
        printf 'Content-Type: application/json\r\n\r\n{"ok":false,"error":"invalid filename"}\n'; exit 0;;
    esac
    [ -f "$FPATH" ] || { printf 'Content-Type: application/json\r\n\r\n{"ok":false,"error":"file not found"}\n'; exit 0; }
    printf 'Content-Type: application/octet-stream\r\nContent-Disposition: attachment; filename="%s"\r\n\r\n' "$FILE"
    cat "$FPATH"
    exit 0
fi

printf 'Content-Type: application/json\r\n\r\n'

# ── helpers ───────────────────────────────────────────────────────────────────

stream_port() {
    local p
    p=$(cat "$STREAM_PORT_CONF" 2>/dev/null | grep -E '^[0-9]+$' | head -1)
    printf '%s\n' "${p:-$DEFAULT_STREAM_PORT}"
}

iface_ip() {
    ip addr show "$1" 2>/dev/null | grep 'inet ' | head -1 | \
        sed 's|.*inet \([0-9.]*\)/.*|\1|'
}

# Enumerate interfaces that are UP and suitable for capture
list_ifaces() {
    ip link show 2>/dev/null | grep 'state UP' | \
        grep -E 'bridge0|rmnet0|wlan0|wlan1|rndis0|lo' | \
        sed 's/^[0-9]*: \([^:@]*\).*/\1/'
}

cap_pid()     { cat "$PIDFILE" 2>/dev/null; }
cap_running() {
    local pid; pid=$(cap_pid)
    [ -n "$pid" ] && [ -d "/proc/$pid" ]
}

stream_pids()    { cat "$STREAM_PIDFILE" 2>/dev/null; }
stream_td_pid()  { stream_pids | cut -d: -f1; }
stream_nc_pid()  { stream_pids | cut -d: -f2; }
stream_running() {
    local td nc
    td=$(stream_td_pid); nc=$(stream_nc_pid)
    [ -n "$td" ] && [ -d "/proc/$td" ] && return 0
    return 1
}

kill_stream() {
    local td nc
    td=$(stream_td_pid); nc=$(stream_nc_pid)
    [ -n "$td" ] && kill "$td" 2>/dev/null
    [ -n "$nc" ] && kill "$nc" 2>/dev/null
    sleep 1
    [ -n "$td" ] && [ -d "/proc/$td" ] && kill -9 "$td" 2>/dev/null
    [ -n "$nc" ] && [ -d "/proc/$nc" ] && kill -9 "$nc" 2>/dev/null
    rm -f "$STREAM_PIDFILE" "$STREAM_FIFO"
}

list_files() {
    ls -t "$CAP_DIR"/*.pcap 2>/dev/null | while read -r f; do
        name=$(basename "$f")
        size=$(ls -lh "$f" 2>/dev/null | awk '{print $5}')
        printf '{"name":"%s","size":"%s"},' "$name" "$size"
    done | sed 's/,$//'
}

validate_iface() {
    printf '%s' "$1" | grep -qE '^[a-zA-Z0-9_]+$'
}

build_filter_safe() {
    # Strip shell metacharacters from BPF filter — injection prevention
    printf '%s' "$1" | sed "s/['\`\$\\\\|;&<>]//g"
}

# ── status ────────────────────────────────────────────────────────────────────
if [ "$ACTION" = "status" ]; then
    # File capture status
    F_RUNNING=false; F_PID="null"; F_IFACE=""; F_FILE=""; F_ELAPSED="null"
    if cap_running; then
        F_RUNNING=true
        F_PID=$(cap_pid)
        if [ -f "$METAFILE" ]; then
            F_IFACE=$(grep '^iface=' "$METAFILE" | cut -d= -f2)
            F_FILE=$(grep '^file=' "$METAFILE" | cut -d= -f2)
            START=$(grep '^start=' "$METAFILE" | cut -d= -f2)
            NOW=$(date +%s 2>/dev/null || echo 0)
            [ -n "$START" ] && [ -n "$NOW" ] && F_ELAPSED=$(( NOW - START ))
        fi
    fi

    # Stream capture status
    S_RUNNING=false
    stream_running && S_RUNNING=true
    SPORT=$(stream_port)

    # Interface IPs for stream URLs
    IP_WIFI=$(iface_ip bridge0)
    IP_RNDIS=$(iface_ip rndis0)

    # Available interfaces
    IFACES=$(list_ifaces | awk '{printf "\"%s\",",$0}' | sed 's/,$//')

    FILES=$(list_files)

    printf '{"ok":true,"data":{"file":{"running":%s,"pid":%s,"iface":%s,"file":%s,"elapsed":%s},"stream":{"running":%s,"port":%d,"wifi_ip":%s,"rndis_ip":%s},"ifaces":[%s],"files":[%s]}}\n' \
        "$F_RUNNING" "$F_PID" "$(jstr "$F_IFACE")" "$(jstr "$F_FILE")" "$F_ELAPSED" \
        "$S_RUNNING" "$SPORT" "$(jstr "$IP_WIFI")" "$(jstr "$IP_RNDIS")" \
        "$IFACES" "$FILES"
    exit 0
fi

# ── start (file mode) ─────────────────────────────────────────────────────────
if [ "$ACTION" = "start" ]; then
    cap_running && { err "capture already running (PID=$(cap_pid)) — stop first"; exit 0; }

    IFACE=$(param iface); FILTER=$(param filter)
    DUR=$(param dur);     NAME=$(param name)

    validate_iface "$IFACE" || { err "invalid interface name"; exit 0; }
    [ -z "$IFACE" ] && { err "interface required"; exit 0; }

    TS=$(date +%Y%m%d_%H%M%S 2>/dev/null || echo "cap")
    BASENAME="${NAME:-${IFACE}_${TS}}"
    BASENAME=$(printf '%s' "$BASENAME" | sed 's/[^a-zA-Z0-9_-]//g')
    CAPFILE="$CAP_DIR/${BASENAME}.pcap"

    CMD="$TCPDUMP -i $IFACE -w $CAPFILE -s 0 -n"
    if [ -n "$FILTER" ]; then
        CMD="$CMD $(build_filter_safe "$FILTER")"
    fi

    START=$(date +%s 2>/dev/null || echo 0)
    $CMD >> "$CAP_DIR/tcpdump.log" 2>&1 &
    TDPID=$!
    printf '%s\n' "$TDPID" > "$PIDFILE"

    if [ -n "$DUR" ] && [ "$DUR" != "0" ]; then
        ( sleep "$DUR"; kill "$TDPID" 2>/dev/null; rm -f "$PIDFILE" "$METAFILE" ) &
    fi

    cat > "$METAFILE" << META
iface=$IFACE
file=$(basename "$CAPFILE")
filter=$FILTER
start=$START
dur=$DUR
META

    ok "{\"pid\":$TDPID,\"file\":$(jstr "$(basename "$CAPFILE")")}"
    exit 0
fi

# ── stop (file mode) ──────────────────────────────────────────────────────────
if [ "$ACTION" = "stop" ]; then
    cap_running || { ok '"not_running"'; exit 0; }
    PID=$(cap_pid)
    kill "$PID" 2>/dev/null
    sleep 1
    [ -d "/proc/$PID" ] && kill -9 "$PID" 2>/dev/null
    rm -f "$PIDFILE" "$METAFILE"
    ok '"stopped"'
    exit 0
fi

# ── stream_start ──────────────────────────────────────────────────────────────
if [ "$ACTION" = "stream_start" ]; then
    stream_running && { err "stream already running — stop first"; exit 0; }

    IFACE=$(param iface); FILTER=$(param filter)
    validate_iface "$IFACE" || { err "invalid interface name"; exit 0; }
    [ -z "$IFACE" ] && { err "interface required"; exit 0; }

    SPORT=$(stream_port)

    # Clean up any stale fifo
    rm -f "$STREAM_FIFO"
    mkfifo "$STREAM_FIFO" || { err "failed to create stream fifo"; exit 0; }

    # Start nc listener FIRST — opens read end of fifo so tcpdump doesn't block
    # nc -l -p PORT: listen for one client, send fifo content
    nc -l -p "$SPORT" < "$STREAM_FIFO" > /dev/null 2>&1 &
    NCPID=$!

    # Start tcpdump writing pcap to fifo — -w - writes to stdout, redirect to fifo
    CMD="$TCPDUMP -i $IFACE -w - -s 0 -n"
    if [ -n "$FILTER" ]; then
        CMD="$CMD $(build_filter_safe "$FILTER")"
    fi
    $CMD > "$STREAM_FIFO" 2>/dev/null &
    TDPID=$!

    printf '%s:%s\n' "$TDPID" "$NCPID" > "$STREAM_PIDFILE"

    # Brief check that both launched
    sleep 1
    if ! kill -0 "$TDPID" 2>/dev/null; then
        kill_stream
        err "tcpdump failed to start — check interface"
        exit 0
    fi

    IP_WIFI=$(iface_ip bridge0)
    IP_RNDIS=$(iface_ip rndis0)

    ok "{\"td_pid\":$TDPID,\"nc_pid\":$NCPID,\"port\":$SPORT,\"wifi_ip\":$(jstr "$IP_WIFI"),\"rndis_ip\":$(jstr "$IP_RNDIS")}"
    exit 0
fi

# ── stream_stop ───────────────────────────────────────────────────────────────
if [ "$ACTION" = "stream_stop" ]; then
    stream_running || { ok '"not_running"'; exit 0; }
    kill_stream
    ok '"stopped"'
    exit 0
fi

# ── set_stream_port ───────────────────────────────────────────────────────────
if [ "$ACTION" = "set_stream_port" ]; then
    PORT=$(param port)
    printf '%s' "$PORT" | grep -qE '^[0-9]+$' || { err "invalid port"; exit 0; }
    printf '%s\n' "$PORT" > "$STREAM_PORT_CONF"
    ok "{\"port\":$PORT}"
    exit 0
fi

# ── clear ─────────────────────────────────────────────────────────────────────
if [ "$ACTION" = "clear" ]; then
    cap_running && { err "stop file capture first"; exit 0; }
    rm -f "$CAP_DIR"/*.pcap "$CAP_DIR"/tcpdump.log 2>/dev/null
    ok '"cleared"'
    exit 0
fi

err "unknown action: $ACTION"
