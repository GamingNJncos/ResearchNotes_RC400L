#!/bin/sh
# ipt_daemon.sh — RC400L iptables control daemon
# Runs as a respawn process under init (full capabilities via inittab escape)
# Spawned by init (PPid=1), inherits CapBnd=0x3fffffffff
#
# DO NOT run directly — install via deploy_xtables.sh
#
# Listens on a named pipe for iptables commands sent by ipt_ctl.sh
# Applies saved ruleset on startup/restart

FIFO=/cache/ipt/cmd.fifo
OUT=/cache/ipt/last_out
RULES=/cache/ipt/rules.sh
LOG=/cache/ipt/daemon.log
PIDFILE=/cache/ipt/daemon.pid

mkdir -p /cache/ipt
echo $$ > "$PIDFILE"

log() {
    echo "$(date '+%b %d %H:%M:%S') ipt_daemon[$$]: $*" >> "$LOG"
}

log "Started (CapEff=$(grep CapEff /proc/self/status | awk '{print $2}'))"

# Ensure named pipe exists
[ -p "$FIFO" ] || mkfifo "$FIFO"

# Apply saved ruleset on startup
if [ -f "$RULES" ]; then
    log "Applying ruleset: $RULES"
    sh "$RULES" > "$OUT" 2>&1
    echo "##DONE##" >> "$OUT"
    log "Ruleset applied (exit $?)"
else
    log "No ruleset found at $RULES — daemon ready, no rules loaded"
fi

# Command loop
log "Entering command loop on $FIFO"
while true; do
    # Read one command line from the FIFO (blocks until ipt_ctl writes)
    if read -r CMD < "$FIFO"; then
        [ -z "$CMD" ] && continue
        log "CMD: $CMD"
        > "$OUT"
        eval "$CMD" >> "$OUT" 2>&1
        echo "##DONE##" >> "$OUT"
        log "Done (exit $?)"
    fi
done
