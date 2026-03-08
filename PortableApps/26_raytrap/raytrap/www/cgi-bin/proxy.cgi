#!/bin/sh
# proxy.cgi — RayTrap tinyproxy control

CONF=/cache/raytrap/tinyproxy.conf
LOG=/cache/tinyproxy.log
PIDFILE=/cache/tinyproxy.pid
BIN=/cache/bin/tinyproxy
INITTAB=/etc/inittab

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

ACTION=$(param action)

pid_running() { [ -n "$1" ] && [ -d "/proc/$1" ] && return 0; return 1; }

find_tinyproxy() {
    local pid
    pid=$(cat "$PIDFILE" 2>/dev/null)
    pid_running "$pid" && echo "$pid" && return
    for p in $(ls /proc/ 2>/dev/null | grep -E '^[0-9]+$'); do
        local cmd=$(cat /proc/$p/cmdline 2>/dev/null | tr '\0' ' ')
        case "$cmd" in *tinyproxy*) echo "$p"; return;; esac
    done
}

# Check if transparent redirect rule exists
transp_active() {
    sh /cache/ipt/ipt_ctl.sh iptables -t nat -L ORBIC_PREROUTING -n 2>/dev/null | grep -q 'REDIRECT.*8118'
}

# ── status ────────────────────────────────────────────────────────────────────
if [ "$ACTION" = "status" ]; then
    PID=$(find_tinyproxy)
    RUNNING=false; [ -n "$PID" ] && RUNNING=true
    TRANSP=false; transp_active && TRANSP=true
    printf '{"ok":true,"data":{"running":%s,"pid":%s,"transparent":%s}}\n' \
        "$RUNNING" "${PID:-null}" "$TRANSP"
    exit 0
fi

# ── log ───────────────────────────────────────────────────────────────────────
if [ "$ACTION" = "log" ]; then
    LOGDATA=""
    if [ -f "$LOG" ]; then
        LOGDATA=$(tail -30 "$LOG" 2>/dev/null | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' '|' | sed 's/|/\\n/g')
    fi
    printf '{"ok":true,"data":"%s"}\n' "$LOGDATA"
    exit 0
fi

# ── start ─────────────────────────────────────────────────────────────────────
if [ "$ACTION" = "start" ]; then
    PID=$(find_tinyproxy)
    if [ -n "$PID" ]; then ok '"already_running"'; exit 0; fi

    [ ! -f "$BIN" ] && { err "tinyproxy not installed at $BIN"; exit 0; }
    [ ! -f "$CONF" ] && { err "config not found at $CONF — run deploy_tinyproxy.sh first"; exit 0; }

    # Inject once entry via inittab escape
    TAG="px$(( ($$ % 9) + 1 ))$(date +%S 2>/dev/null | cut -c3 || echo 0)"
    grep -v "^px[0-9]" "$INITTAB" > /data/tmp/inittab.px.new 2>/dev/null
    cp /data/tmp/inittab.px.new "$INITTAB"
    rm -f /data/tmp/inittab.px.new
    echo "${TAG}:5:once:${BIN} -c ${CONF}" >> "$INITTAB"
    kill -HUP 1
    sleep 3
    grep -v "^${TAG}" "$INITTAB" > /data/tmp/inittab.px.clean 2>/dev/null
    cp /data/tmp/inittab.px.clean "$INITTAB"
    rm -f /data/tmp/inittab.px.clean
    kill -HUP 1

    PID=$(find_tinyproxy)
    [ -n "$PID" ] && ok '"started"' || err "tinyproxy did not start — check $LOG"
    exit 0
fi

# ── stop ──────────────────────────────────────────────────────────────────────
if [ "$ACTION" = "stop" ]; then
    PID=$(find_tinyproxy)
    [ -z "$PID" ] && { ok '"not_running"'; exit 0; }
    kill "$PID" 2>/dev/null
    sleep 1
    pid_running "$PID" && kill -9 "$PID" 2>/dev/null
    rm -f "$PIDFILE"
    ok '"stopped"'
    exit 0
fi

# ── enable_transparent ────────────────────────────────────────────────────────
if [ "$ACTION" = "enable_transparent" ]; then
    transp_active && { ok '"already_enabled"'; exit 0; }
    OUT=$(sh /cache/ipt/ipt_ctl.sh iptables -t nat -A ORBIC_PREROUTING \
        -i bridge0 -p tcp --dport 80 '!' -d 192.168.1.1 \
        -j REDIRECT --to-ports 8118 2>&1)
    [ $? -eq 0 ] && ok '"enabled"' || err "$OUT"
    exit 0
fi

# ── disable_transparent ───────────────────────────────────────────────────────
if [ "$ACTION" = "disable_transparent" ]; then
    transp_active || { ok '"already_disabled"'; exit 0; }
    OUT=$(sh /cache/ipt/ipt_ctl.sh iptables -t nat -D ORBIC_PREROUTING \
        -i bridge0 -p tcp --dport 80 '!' -d 192.168.1.1 \
        -j REDIRECT --to-ports 8118 2>&1)
    [ $? -eq 0 ] && ok '"disabled"' || err "$OUT"
    exit 0
fi

# ── set_config ────────────────────────────────────────────────────────────────
if [ "$ACTION" = "set_config" ]; then
    PORT=$(param port); LOGLEVEL=$(param loglevel)
    ALLOW=$(param allow); MAXCLIENTS=$(param maxclients)
    TIMEOUT=$(param timeout)

    # Validate port is numeric
    echo "$PORT" | grep -qE '^[0-9]+$' || { err "invalid port"; exit 0; }

    cat > "$CONF" << CONF
# tinyproxy.conf — RayTrap managed config
Listen 192.168.1.1
Port ${PORT:-8118}
Timeout ${TIMEOUT:-90}
LogFile /cache/tinyproxy.log
LogLevel ${LOGLEVEL:-Connect}
PidFile /cache/tinyproxy.pid
MaxClients ${MAXCLIENTS:-100}
MinSpareServers 2
MaxSpareServers 5
Allow ${ALLOW:-192.168.1.0/24}
DisableViaHeader Yes
CONF

    ok '"saved"'
    exit 0
fi

err "Unknown action: $ACTION"
