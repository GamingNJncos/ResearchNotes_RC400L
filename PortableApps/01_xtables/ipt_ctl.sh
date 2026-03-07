#!/bin/sh
# ipt_ctl.sh — RC400L iptables control client
# Run from rootshell — sends commands to ipt_daemon.sh via named pipe
#
# Usage:
#   ipt_ctl.sh <iptables command>     — run a single iptables command
#   ipt_ctl.sh reload                 — reload /cache/ipt/rules.sh
#   ipt_ctl.sh flush                  — flush all ORBIC_* chains (safe — QCMAP chains untouched)
#   ipt_ctl.sh save                   — save current ORBIC rules to /cache/ipt/rules.sh
#   ipt_ctl.sh status                 — dump all tables
#   ipt_ctl.sh log                    — show daemon log
#   ipt_ctl.sh start                  — (re)start daemon via inittab if not running
#
# Examples:
#   ipt_ctl.sh iptables -L -n -v
#   ipt_ctl.sh iptables -t nat -L -n -v
#   ipt_ctl.sh iptables -t nat -A ORBIC_PREROUTING -i bridge0 -p tcp --dport 777 -j REDIRECT --to-ports 8080
#   ipt_ctl.sh iptables -t mangle -A ORBIC_MANGLE -i bridge0 -j TEE --gateway 192.168.1.50
#   ipt_ctl.sh flush
#   ipt_ctl.sh reload

FIFO=/cache/ipt/cmd.fifo
OUT=/cache/ipt/last_out
DAEMON_PID=/cache/ipt/daemon.pid
INITTAB=/etc/inittab

send_cmd() {
    local cmd="$1"
    local timeout="${2:-10}"

    # Check daemon is running
    if [ ! -p "$FIFO" ]; then
        echo "[!] FIFO not found — daemon not running. Run: ipt_ctl.sh start"
        return 1
    fi

    > "$OUT"
    echo "$cmd" > "$FIFO"

    # Wait for ##DONE## marker
    for i in $(seq 1 $timeout); do
        sleep 1
        if grep -q "##DONE##" "$OUT" 2>/dev/null; then
            grep -v "##DONE##" "$OUT"
            return 0
        fi
    done

    echo "[!] Timeout waiting for daemon response"
    cat "$OUT" 2>/dev/null
    return 1
}

CMD="$1"

case "$CMD" in
    "")
        echo "Usage: ipt_ctl.sh <command|reload|flush|save|status|log|start>"
        echo ""
        echo "Commands:"
        echo "  iptables ...     Run any iptables command via daemon"
        echo "  ip6tables ...    Run any ip6tables command via daemon"
        echo "  reload           Reload /cache/ipt/rules.sh"
        echo "  flush            Flush all ORBIC_* custom chains"
        echo "  save             Save current ORBIC rules back to rules.sh"
        echo "  status           Show all table rules"
        echo "  log              Show daemon log"
        echo "  start            Install and start daemon"
        ;;

    start)
        # Check if already running
        if [ -f "$DAEMON_PID" ] && [ -d "/proc/$(cat $DAEMON_PID 2>/dev/null)" ]; then
            echo "[*] Daemon already running (PID=$(cat $DAEMON_PID))"
            exit 0
        fi

        echo "[*] Starting ipt_daemon via inittab escape..."

        # Back up inittab
        cp "$INITTAB" /data/tmp/inittab.ipt.bak 2>/dev/null

        # Remove old daemon entries
        grep -v "^ipdm" "$INITTAB" > /data/tmp/inittab.new
        cp /data/tmp/inittab.new "$INITTAB"

        # Add respawn entry (permanent)
        echo "ipdm:5:respawn:/bin/sh /cache/ipt/ipt_daemon.sh" >> "$INITTAB"
        echo "[*] Added respawn entry to /etc/inittab"

        # Signal init
        kill -HUP 1
        echo "[*] Signaled init — waiting for daemon..."

        # Wait for FIFO to appear
        for i in $(seq 1 15); do
            sleep 1
            [ -p "$FIFO" ] && echo "[+] Daemon started (PID=$(cat $DAEMON_PID 2>/dev/null))" && exit 0
        done

        echo "[!] Daemon did not start — check /cache/ipt/daemon.log"
        ;;

    stop)
        echo "[*] Removing daemon from inittab..."
        grep -v "^ipdm" "$INITTAB" > /data/tmp/inittab.new
        cp /data/tmp/inittab.new "$INITTAB"
        kill -HUP 1
        PID=$(cat "$DAEMON_PID" 2>/dev/null)
        [ -n "$PID" ] && kill "$PID" 2>/dev/null && echo "[*] Killed daemon PID=$PID"
        ;;

    reload)
        echo "[*] Reloading /cache/ipt/rules.sh..."
        send_cmd "sh /cache/ipt/rules.sh"
        ;;

    flush)
        echo "[*] Flushing ORBIC_* chains..."
        send_cmd "iptables -t nat -F ORBIC_PREROUTING 2>/dev/null; iptables -t mangle -F ORBIC_MANGLE 2>/dev/null; iptables -t filter -F ORBIC_FILTER 2>/dev/null; echo 'Flushed'"
        ;;

    save)
        echo "[*] Saving current ruleset to /cache/ipt/rules.sh..."
        send_cmd "iptables-save > /data/tmp/ipt_full.txt 2>&1; echo save_done"
        # Extract just ORBIC rules and build a restore script
        sh /cache/ipt/ipt_ctl.sh _build_save
        echo "[+] Saved to /cache/ipt/rules.sh"
        ;;

    _build_save)
        cat > /cache/ipt/rules.sh << 'RULES_EOF'
#!/bin/sh
# Auto-saved iptables ruleset — edit manually to add/remove rules
# Applied by ipt_daemon.sh on startup and on 'ipt_ctl.sh reload'
RULES_EOF
        send_cmd "iptables-save" >> /dev/null
        grep "ORBIC" /data/tmp/ipt_full.txt 2>/dev/null | while read line; do
            case "$line" in
                ":ORBIC_"*)
                    chain=$(echo "$line" | cut -d: -f2 | cut -d' ' -f1)
                    table=$(grep -B 50 "$line" /data/tmp/ipt_full.txt | grep "^\*" | tail -1 | tr -d '*')
                    echo "iptables -t $table -N $chain 2>/dev/null" >> /cache/ipt/rules.sh
                    ;;
                "-A ORBIC_"*)
                    table=$(grep -B 200 "$line" /data/tmp/ipt_full.txt | grep "^\*" | tail -1 | tr -d '*')
                    echo "iptables -t $table $line" >> /cache/ipt/rules.sh
                    ;;
            esac
        done
        ;;

    status)
        echo "=== filter ==="
        send_cmd "iptables -L -n -v --line-numbers"
        echo ""
        echo "=== nat ==="
        send_cmd "iptables -t nat -L -n -v --line-numbers"
        echo ""
        echo "=== mangle ==="
        send_cmd "iptables -t mangle -L -n -v --line-numbers"
        echo ""
        echo "=== raw ==="
        send_cmd "iptables -t raw -L -n -v --line-numbers"
        ;;

    log)
        cat /cache/ipt/daemon.log 2>/dev/null || echo "No log found"
        ;;

    *)
        # Pass through directly to daemon
        shift 0
        send_cmd "$*"
        ;;
esac
