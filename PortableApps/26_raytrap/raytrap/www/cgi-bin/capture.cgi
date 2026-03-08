#!/bin/sh
# capture.cgi — RayTrap tcpdump control
# Captures saved to /cache/raytrap/captures/ as .pcap files

CAP_DIR=/cache/raytrap/captures
TCPDUMP=/cache/bin/tcpdump
PIDFILE="$CAP_DIR/tcpdump.pid"
METAFILE="$CAP_DIR/tcpdump.meta"

mkdir -p "$CAP_DIR" 2>/dev/null

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

# Emit headers based on action (download needs octet-stream)
if [ "$ACTION" = "download" ]; then
    FILE=$(param file)
    FILE=$(basename "$FILE")
    FPATH="$CAP_DIR/$FILE"
    case "$FILE" in *.pcap) ;; *)
        printf 'Content-Type: application/json\r\n\r\n{"ok":false,"error":"invalid filename"}\n'; exit 0;;
    esac
    if [ ! -f "$FPATH" ]; then
        printf 'Content-Type: application/json\r\n\r\n{"ok":false,"error":"file not found"}\n'; exit 0
    fi
    printf 'Content-Type: application/octet-stream\r\nContent-Disposition: attachment; filename="%s"\r\n\r\n' "$FILE"
    cat "$FPATH"
    exit 0
fi

printf 'Content-Type: application/json\r\n\r\n'

cap_pid() { cat "$PIDFILE" 2>/dev/null; }
cap_running() {
    local pid=$(cap_pid)
    [ -n "$pid" ] && [ -d "/proc/$pid" ] && return 0
    return 1
}

# File listing helper
list_files() {
    ls -t "$CAP_DIR"/*.pcap 2>/dev/null | while read -r f; do
        name=$(basename "$f")
        size=$(ls -lh "$f" 2>/dev/null | awk '{print $5}')
        printf '{"name":"%s","size":"%s"},' "$name" "$size"
    done | sed 's/,$//'
}

# ── status ────────────────────────────────────────────────────────────────────
if [ "$ACTION" = "status" ]; then
    RUNNING=false; PID=""; IFACE=""; FILE_=""; ELAPSED=""

    if cap_running; then
        RUNNING=true
        PID=$(cap_pid)
        if [ -f "$METAFILE" ]; then
            IFACE=$(grep '^iface=' "$METAFILE" | cut -d= -f2)
            FILE_=$(grep '^file=' "$METAFILE" | cut -d= -f2)
            START=$(grep '^start=' "$METAFILE" | cut -d= -f2)
            NOW=$(date +%s 2>/dev/null || echo 0)
            [ -n "$START" ] && [ -n "$NOW" ] && ELAPSED=$(( NOW - START ))
        fi
    fi

    FILES=$(list_files)

    printf '{"ok":true,"data":{"running":%s,"pid":%s,"iface":%s,"file":%s,"elapsed":%s,"files":[%s]}}\n' \
        "$RUNNING" "${PID:-null}" "$(jstr "$IFACE")" "$(jstr "$FILE_")" "${ELAPSED:-null}" "$FILES"
    exit 0
fi

# ── start ─────────────────────────────────────────────────────────────────────
if [ "$ACTION" = "start" ]; then
    if cap_running; then
        err "capture already running (PID=$(cap_pid)) — stop it first"
        exit 0
    fi

    IFACE=$(param iface); FILTER=$(param filter)
    DUR=$(param dur); NAME=$(param name)

    # Validate interface name (no special chars)
    echo "$IFACE" | grep -qE '^[a-zA-Z0-9_]+$' || { err "invalid interface"; exit 0; }

    # Build filename
    TS=$(date +%Y%m%d_%H%M%S 2>/dev/null || echo "cap")
    BASENAME="${NAME:-${IFACE}_${TS}}"
    BASENAME=$(echo "$BASENAME" | sed 's/[^a-zA-Z0-9_-]//g')
    CAPFILE="$CAP_DIR/${BASENAME}.pcap"

    # Build tcpdump command
    # -s 0 = full packet capture, -n = no DNS resolution
    CMD="$TCPDUMP -i $IFACE -w $CAPFILE -s 0 -n"

    # Append BPF filter — strip shell metacharacters to prevent injection
    if [ -n "$FILTER" ]; then
        FILTER_SAFE=$(echo "$FILTER" | sed "s/['\`\$\\\\|;&<>]//g")
        CMD="$CMD $FILTER_SAFE"
    fi

    # Launch in background, save PID
    START=$(date +%s 2>/dev/null || echo 0)
    $CMD >> "$CAP_DIR/tcpdump.log" 2>&1 &
    TDPID=$!
    echo "$TDPID" > "$PIDFILE"

    # If duration set, spawn background killer (no -G/-W needed)
    if [ -n "$DUR" ] && [ "$DUR" != "0" ]; then
        ( sleep "$DUR"; kill "$TDPID" 2>/dev/null ) &
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

# ── stop ──────────────────────────────────────────────────────────────────────
if [ "$ACTION" = "stop" ]; then
    if ! cap_running; then ok '"not_running"'; exit 0; fi
    PID=$(cap_pid)
    kill "$PID" 2>/dev/null
    sleep 1
    [ -d "/proc/$PID" ] && kill -9 "$PID" 2>/dev/null
    rm -f "$PIDFILE" "$METAFILE"
    ok '"stopped"'
    exit 0
fi

# ── clear ─────────────────────────────────────────────────────────────────────
if [ "$ACTION" = "clear" ]; then
    cap_running && { err "stop capture first"; exit 0; }
    rm -f "$CAP_DIR"/*.pcap "$CAP_DIR"/tcpdump.log 2>/dev/null
    ok '"cleared"'
    exit 0
fi

err "Unknown action: $ACTION"
