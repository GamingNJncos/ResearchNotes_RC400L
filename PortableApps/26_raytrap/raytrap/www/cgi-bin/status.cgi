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

# ── rmnet0 state ──────────────────────────────────────────────────────────────
RMNET0_UP=false
RMNET0_IP=""
if [ -d /sys/class/net/rmnet0 ]; then
    RMNET0_UP=true
    RMNET0_IP=$(ip addr show rmnet0 2>/dev/null | grep 'inet ' | awk '{print $2}' | head -1)
fi

# ── wlan0 state ───────────────────────────────────────────────────────────────
WLAN0_UP=false
if [ -d /sys/class/net/wlan0 ]; then
    [ "$(cat /sys/class/net/wlan0/operstate 2>/dev/null)" = "up" ] && WLAN0_UP=true
fi

# ── usb0 state ────────────────────────────────────────────────────────────────
USB0_UP=false
if [ -d /sys/class/net/usb0 ]; then
    [ "$(cat /sys/class/net/usb0/operstate 2>/dev/null)" = "up" ] && USB0_UP=true
fi

# ── rayhunter process ─────────────────────────────────────────────────────────
RH_PID=$(find_pid "rayhunter")
RH_RUN=false; [ -n "$RH_PID" ] && RH_RUN=true

# ── httpd (busybox thttpd/httpd) ──────────────────────────────────────────────
# Always true when this CGI executes — we are being served
HTTPD_RUN=true

# ── tcpdump running ───────────────────────────────────────────────────────────
CAP_RUN=false
[ -f /cache/raytrap/captures/tcpdump.pid ] && \
    pid_running "$(cat /cache/raytrap/captures/tcpdump.pid 2>/dev/null)" && \
    CAP_RUN=true

# ── rule count (ORBIC chains) ─────────────────────────────────────────────────
# ipt_ctl.sh prints iptables errors to stdout; sanitize output to bare integer.
_ipt_count() { sh /cache/ipt/ipt_ctl.sh iptables "$@" 2>/dev/null | grep -c '^[A-Z]' 2>/dev/null || true; }
_to_int()    { printf '%s' "$1" | tr -dc '0-9' | head -c 6; }
RULE_COUNT=0
if $IPT_RUN; then
    MG=$(_to_int "$(_ipt_count -t mangle -L ORBIC_MANGLE     -n)"); MG=${MG:-0}
    NT=$(_to_int "$(_ipt_count -t nat    -L ORBIC_PREROUTING  -n)"); NT=${NT:-0}
    FL=$(_to_int "$(_ipt_count -t filter -L ORBIC_FILTER      -n)"); FL=${FL:-0}
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
printf '"rmnet0_up":%s,' "$RMNET0_UP"
printf '"rmnet0_ip":%s,' "$(jstr "$RMNET0_IP")"
printf '"wlan0_up":%s,' "$WLAN0_UP"
printf '"usb0_up":%s,' "$USB0_UP"
printf '"rayhunter_running":%s,' "$RH_RUN"
printf '"rayhunter_pid":%s,' "${RH_PID:-null}"
printf '"httpd_running":%s,' "$HTTPD_RUN"
printf '"cap_running":%s,' "$CAP_RUN"
printf '"rule_count":%d,' "$RULE_COUNT"
printf '"uptime":%s,' "$(jstr "$UPTIME")"
printf '"cache_free":%s,' "$(jstr "$CACHE_FREE")"
printf '"data_free":%s,' "$(jstr "$DATA_FREE")"
printf '"kernel":%s' "$(jstr "$KERNEL")"
printf '}}\n'
