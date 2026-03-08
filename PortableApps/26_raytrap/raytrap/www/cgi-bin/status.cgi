#!/bin/sh
# status.cgi — RayTrap system status endpoint
# GET /cgi-bin/status.cgi?action=all

printf 'Content-Type: application/json\r\n\r\n'

# ── helpers ──────────────────────────────────────────────────────────────────
pid_running() { [ -n "$1" ] && [ -d "/proc/$1" ] && return 0; return 1; }

find_pid() {
    local pat="$1"
    for p in $(ls /proc/ 2>/dev/null | grep -E '^[0-9]+$'); do
        local cmd=$(cat /proc/$p/cmdline 2>/dev/null | tr '\0' ' ')
        case "$cmd" in *${pat}*) echo "$p"; return;; esac
    done
}

bool() { [ "$1" = "1" ] || [ "$1" = "true" ] && printf 'true' || printf 'false'; }

jstr() { printf '"%s"' "$(echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }

# ── iptables daemon ───────────────────────────────────────────────────────────
IPT_PID=""
if [ -f /cache/ipt/daemon.pid ]; then
    IPT_PID=$(cat /cache/ipt/daemon.pid 2>/dev/null)
fi
if ! pid_running "$IPT_PID"; then
    IPT_PID=$(find_pid "ipt_daemon")
fi
IPT_RUN=false; [ -n "$IPT_PID" ] && [ -d "/proc/$IPT_PID" ] && IPT_RUN=true

# ── tinyproxy ─────────────────────────────────────────────────────────────────
PX_PID=""
if [ -f /cache/tinyproxy.pid ] || [ -f /cache/raytrap/tinyproxy.pid ]; then
    PX_PID=$(cat /cache/tinyproxy.pid 2>/dev/null || cat /cache/raytrap/tinyproxy.pid 2>/dev/null)
fi
if ! pid_running "$PX_PID"; then
    PX_PID=$(find_pid "tinyproxy")
fi
PX_RUN=false; [ -n "$PX_PID" ] && [ -d "/proc/$PX_PID" ] && PX_RUN=true

# ── wpa_supplicant ────────────────────────────────────────────────────────────
WPA_PID=$(find_pid "wpa_supplicant")
WPA_RUN=false; [ -n "$WPA_PID" ] && WPA_RUN=true

# ── wlan1 state ───────────────────────────────────────────────────────────────
WLAN1_UP=false
WLAN1_STATE="DOWN"
WLAN1_IP=""
if [ -d /sys/class/net/wlan1 ]; then
    STATE=$(cat /sys/class/net/wlan1/operstate 2>/dev/null)
    WLAN1_STATE="$STATE"
    [ "$STATE" = "up" ] && WLAN1_UP=true
    WLAN1_IP=$(ip addr show wlan1 2>/dev/null | grep 'inet ' | awk '{print $2}' | head -1)
fi

# ── tcpdump running ───────────────────────────────────────────────────────────
CAP_RUN=false
[ -f /cache/raytrap/captures/tcpdump.pid ] && \
    pid_running "$(cat /cache/raytrap/captures/tcpdump.pid 2>/dev/null)" && \
    CAP_RUN=true

# ── rule count (ORBIC chains) ─────────────────────────────────────────────────
RULE_COUNT=0
if $IPT_RUN; then
    MG=$(sh /cache/ipt/ipt_ctl.sh iptables -t mangle -L ORBIC_MANGLE -n 2>/dev/null | grep -c '^[A-Z]' 2>/dev/null || echo 0)
    NT=$(sh /cache/ipt/ipt_ctl.sh iptables -t nat -L ORBIC_PREROUTING -n 2>/dev/null | grep -c '^[A-Z]' 2>/dev/null || echo 0)
    FL=$(sh /cache/ipt/ipt_ctl.sh iptables -t filter -L ORBIC_FILTER -n 2>/dev/null | grep -c '^[A-Z]' 2>/dev/null || echo 0)
    RULE_COUNT=$(( MG + NT + FL ))
fi

# ── system info ───────────────────────────────────────────────────────────────
UPTIME=$(cat /proc/uptime 2>/dev/null | awk '{s=int($1); h=int(s/3600); m=int((s%3600)/60); printf "%dh %dm", h, m}')
CACHE_FREE=$(df /cache 2>/dev/null | tail -1 | awk '{printf "%.1f MB", $4/1024}')
DATA_FREE=$(df /data 2>/dev/null | tail -1 | awk '{printf "%.1f MB", $4/1024}')
KERNEL=$(uname -r 2>/dev/null)

# ── output ────────────────────────────────────────────────────────────────────
printf '{"ok":true,"data":{'
printf '"ipt_running":%s,' "$IPT_RUN"
printf '"ipt_pid":%s,' "${IPT_PID:-null}"
printf '"proxy_running":%s,' "$PX_RUN"
printf '"proxy_pid":%s,' "${PX_PID:-null}"
printf '"wpa_running":%s,' "$WPA_RUN"
printf '"wpa_pid":%s,' "${WPA_PID:-null}"
printf '"wlan1_up":%s,' "$WLAN1_UP"
printf '"wlan1_state":%s,' "$(jstr "$WLAN1_STATE")"
printf '"wlan1_ip":%s,' "$(jstr "$WLAN1_IP")"
printf '"cap_running":%s,' "$CAP_RUN"
printf '"rule_count":%d,' "$RULE_COUNT"
printf '"uptime":%s,' "$(jstr "$UPTIME")"
printf '"cache_free":%s,' "$(jstr "$CACHE_FREE")"
printf '"data_free":%s,' "$(jstr "$DATA_FREE")"
printf '"kernel":%s' "$(jstr "$KERNEL")"
printf '}}\n'
