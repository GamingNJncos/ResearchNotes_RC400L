#!/bin/sh
# stream_proxy.cgi — RayTrap rayhunter /api/stream proxy
# Proxies rayhunter's raw DIAG byte stream to the browser through the single
# ADB forward (127.0.0.1:8889 → device:8888).
#
# CRITICAL: 127.0.0.1:8080 on this device is intercepted by the Orbic
# management service. We MUST use the wlan0/bridge0 IP to reach rayhunter.
#
# action=status  → JSON: {"ok":true,"data":{"host":"...","port":8080}}
# (default GET)  → Content-Type: application/octet-stream, pipes stream

RAYHUNTER_PORT=8080

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

ACTION=$(param action)

# Resolve host IP: prefer wlan0, fallback to bridge0
# Never use 127.0.0.1 — Orbic management service intercepts port 8080 there.
rh_host() {
    local ip
    ip=$(ip addr show wlan0 2>/dev/null | grep 'inet ' | head -1 | \
         sed 's|.*inet \([0-9.]*\)/.*|\1|')
    [ -z "$ip" ] && \
        ip=$(ip addr show bridge0 2>/dev/null | grep 'inet ' | head -1 | \
             sed 's|.*inet \([0-9.]*\)/.*|\1|')
    printf '%s' "$ip"
}

# ── action=status ──────────────────────────────────────────────────────────────
if [ "$ACTION" = "status" ]; then
    printf 'Content-Type: application/json\r\n\r\n'
    HOST=$(rh_host)
    [ -z "$HOST" ] && { err "no wlan0/bridge0 IP found"; exit 0; }
    ok "{\"host\":\"$HOST\",\"port\":$RAYHUNTER_PORT}"
    exit 0
fi

# ── default: streaming proxy ───────────────────────────────────────────────────
HOST=$(rh_host)
if [ -z "$HOST" ]; then
    printf 'Content-Type: application/json\r\n\r\n'
    printf '{"ok":false,"error":"no wlan0/bridge0 IP — is AP interface up?"}\n'
    exit 0
fi

printf 'Content-Type: application/octet-stream\r\n'
printf 'Cache-Control: no-cache\r\n'
printf 'X-Rayhunter-Host: %s\r\n' "$HOST"
printf '\r\n'

exec wget -q -O - "http://${HOST}:${RAYHUNTER_PORT}/api/stream"
