#!/bin/sh
# handshake.cgi — WPA2 EAPOL handshake capture
# BPF: ether proto 0x888e (EAPOL only, ~300 bytes per frame)
# Storage: /cache/raytrap/handshakes/   Hard cap: 50 files, auto-purge oldest
#
# actions:
#   list     — list saved handshake files (default GET)
#   capture  — start tcpdump in background
#   stop     — kill active capture
#   delete   — delete a file (POST: file=<name>)
#   download — serve a file for download (GET: file=<name>)

HS_DIR=/cache/raytrap/handshakes
TCPDUMP=/cache/bin/tcpdump
PIDFILE="$HS_DIR/hs_capture.pid"
MAX_FILES=50

mkdir -p "$HS_DIR" 2>/dev/null

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

ACTION=$(param action)

# ── download — handle before Content-Type header ─────────────────────────────
if [ "$ACTION" = "download" ]; then
    FILE=$(param file)
    FILE=$(basename "$FILE")
    case "$FILE" in *.pcap) ;; *)
        printf 'Content-Type: application/json\r\n\r\n{"ok":false,"error":"invalid filename"}\n'; exit 0;;
    esac
    FPATH="$HS_DIR/$FILE"
    [ -f "$FPATH" ] || { printf 'Content-Type: application/json\r\n\r\n{"ok":false,"error":"not found"}\n'; exit 0; }
    printf 'Content-Type: application/octet-stream\r\nContent-Disposition: attachment; filename="%s"\r\n\r\n' "$FILE"
    cat "$FPATH"
    exit 0
fi

printf 'Content-Type: application/json\r\n\r\n'

# ── list ──────────────────────────────────────────────────────────────────────
if [ -z "$ACTION" ] || [ "$ACTION" = "list" ]; then
    # Check if capture is running
    running=false
    pid=""
    if [ -f "$PIDFILE" ]; then
        pid=$(cat "$PIDFILE" 2>/dev/null)
        [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && running=true
    fi

    # Build file list JSON — newest first
    entries=""
    count=0
    for f in $(ls -t "$HS_DIR"/*.pcap 2>/dev/null); do
        fname=$(basename "$f")
        size=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
        mtime=$(date -r "$f" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || stat -c '%y' "$f" 2>/dev/null | cut -d. -f1)
        entry="{\"file\":$(jstr "$fname"),\"size\":${size:-0},\"mtime\":$(jstr "${mtime:----}")}"
        if [ -z "$entries" ]; then
            entries="$entry"
        else
            entries="${entries},${entry}"
        fi
        count=$((count + 1))
    done

    ok "{\"running\":${running},\"pid\":$(jstr "${pid:-}"),\"count\":${count},\"files\":[${entries}]}"
    exit 0
fi

# ── capture ───────────────────────────────────────────────────────────────────
if [ "$ACTION" = "capture" ]; then
    # Check if already running
    if [ -f "$PIDFILE" ]; then
        pid=$(cat "$PIDFILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            err "capture already running (pid $pid)"; exit 0
        fi
    fi

    [ -x "$TCPDUMP" ] || { err "tcpdump not found at $TCPDUMP"; exit 0; }

    # Auto-purge oldest if at cap
    count=$(ls "$HS_DIR"/*.pcap 2>/dev/null | wc -l)
    if [ "$count" -ge "$MAX_FILES" ]; then
        oldest=$(ls -t "$HS_DIR"/*.pcap 2>/dev/null | tail -1)
        [ -n "$oldest" ] && rm -f "$oldest"
    fi

    TS=$(date +%Y%m%d_%H%M%S)
    OUTFILE="$HS_DIR/hs_${TS}.pcap"
    IFACE=$(param iface)
    [ -z "$IFACE" ] && IFACE=wlan0

    # Start tcpdump in background; BPF captures EAPOL only
    "$TCPDUMP" -i "$IFACE" "ether proto 0x888e" -w "$OUTFILE" -U 2>/dev/null &
    PID=$!
    echo "$PID" > "$PIDFILE"

    ok "{\"pid\":$PID,\"file\":$(jstr "hs_${TS}.pcap"),\"iface\":$(jstr "$IFACE")}"
    exit 0
fi

# ── stop ──────────────────────────────────────────────────────────────────────
if [ "$ACTION" = "stop" ]; then
    if [ -f "$PIDFILE" ]; then
        pid=$(cat "$PIDFILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            sleep 1
            kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
            rm -f "$PIDFILE"
            ok "null"
        else
            rm -f "$PIDFILE"
            err "no active capture"
        fi
    else
        err "no active capture"
    fi
    exit 0
fi

# ── delete ────────────────────────────────────────────────────────────────────
if [ "$ACTION" = "delete" ]; then
    FILE=$(param file)
    FILE=$(basename "$FILE")
    case "$FILE" in *.pcap) ;; *)
        err "invalid filename"; exit 0;;
    esac
    FPATH="$HS_DIR/$FILE"
    [ -f "$FPATH" ] || { err "not found"; exit 0; }
    rm -f "$FPATH"
    ok "null"
    exit 0
fi

err "unknown action: $ACTION"
