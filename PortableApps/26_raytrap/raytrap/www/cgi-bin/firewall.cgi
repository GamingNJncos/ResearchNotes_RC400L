#!/bin/sh
# firewall.cgi — RayTrap iptables/xtables control
# Routes all rule changes through /cache/ipt/ipt_ctl.sh (daemon FIFO)

IPT="sh /cache/ipt/ipt_ctl.sh iptables"

printf 'Content-Type: application/json\r\n\r\n'

# ── CGI parsing ───────────────────────────────────────────────────────────────
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
jstr(){ printf '"%s"' "$(echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\n/\\n/g')"; }

ACTION=$(param action)

# ── Validate daemon is running ────────────────────────────────────────────────
check_daemon() {
    [ -p /cache/ipt/cmd.fifo ] && return 0
    err "iptables daemon not running — run: sh /cache/ipt/ipt_ctl.sh start"; exit 0
}

# ── Parse a single iptables rule line into JSON ───────────────────────────────
# Input: line like "1    TEE   all  --  0.0.0.0/0  0.0.0.0/0   TEE gw:1.2.3.4"
# Args: $1=table, $2=chain, $3=line
rule_to_json() {
    local table="$1" chain="$2" line="$3"
    local num target proto src dst opts friendly

    num=$(echo "$line"    | awk '{print $1}')
    target=$(echo "$line" | awk '{print $2}')
    proto=$(echo "$line"  | awk '{print $3}')
    src=$(echo "$line"    | awk '{print $5}')
    dst=$(echo "$line"    | awk '{print $6}')
    opts=$(echo "$line"   | awk '{$1=$2=$3=$4=$5=$6=""; sub(/^[[:space:]]+/,"",$0); print}')

    # Human-friendly description
    local src_desc dst_desc
    [ "$src" = "0.0.0.0/0" ] && src_desc="any" || src_desc="$src"
    [ "$dst" = "0.0.0.0/0" ] && dst_desc="any" || dst_desc="$dst"

    case "$target" in
        TEE)
            local gw=$(echo "$opts" | grep -o 'gw:[^ ]*' | cut -d: -f2)
            friendly="Mirror ${src_desc} → ${gw:-?}"
            ;;
        REDIRECT)
            local dpt=$(echo "$opts" | grep -o 'dpt:[^ ]*' | cut -d: -f2)
            local to=$(echo "$opts"  | grep -o 'redir ports [0-9]*' | awk '{print $3}')
            friendly="Redirect ${proto}:${dpt:-?} → port ${to:-?}"
            ;;
        DNAT)
            local dpt=$(echo "$opts" | grep -o 'dpt:[^ ]*' | cut -d: -f2)
            local to=$(echo "$opts"  | grep -o 'to:[^ ]*' | cut -d: -f2-)
            friendly="Forward ${proto}:${dpt:-?} → ${to:-?}"
            ;;
        DROP)
            friendly="Block ${src_desc}"
            ;;
        ACCEPT)
            friendly="Allow ${src_desc} → ${dst_desc}"
            ;;
        MARK)
            local mk=$(echo "$opts" | grep -o 'MARK set [^ ]*' | awk '{print $3}')
            friendly="Mark ${src_desc} with ${mk:-?}"
            ;;
        *)
            friendly="${target} ${src_desc} → ${dst_desc} ${opts}"
            ;;
    esac

    printf '{"num":%s,"table":"%s","chain":"%s","target":"%s","src":"%s","dst":"%s","opts":"%s","friendly":"%s"}' \
        "$num" "$table" "$chain" "$target" \
        "$(echo "$src" | sed 's/"/\\"/g')" \
        "$(echo "$dst" | sed 's/"/\\"/g')" \
        "$(echo "$opts" | sed 's/"/\\"/g')" \
        "$(echo "$friendly" | sed 's/"/\\"/g')"
}

# ── list ──────────────────────────────────────────────────────────────────────
if [ "$ACTION" = "list" ]; then
    check_daemon

    # Use temp file to accumulate rules — avoids pipe-subshell variable loss
    TMPFILE=/tmp/fw_rules_$$.json
    printf '' > "$TMPFILE"

    for SPEC in "mangle:ORBIC_MANGLE" "nat:ORBIC_PREROUTING" "filter:ORBIC_FILTER"; do
        TABLE=$(echo "$SPEC" | cut -d: -f1)
        CHAIN=$(echo "$SPEC" | cut -d: -f2)

        OUT=$(sh /cache/ipt/ipt_ctl.sh iptables -t "$TABLE" -L "$CHAIN" -n --line-numbers 2>&1)

        # Use heredoc so while runs in current shell (no subshell, vars persist)
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            num=$(echo "$line" | awk '{print $1}')
            echo "$num" | grep -qE '^[0-9]+$' || continue
            JSON=$(rule_to_json "$TABLE" "$CHAIN" "$line")
            echo "$JSON" >> "$TMPFILE"
        done << EOF
$(echo "$OUT" | tail -n +3)
EOF
    done

    # Build comma-separated JSON array from file
    JSON_RULES=$(awk 'NR>1{printf ","} {printf "%s",$0}' "$TMPFILE" 2>/dev/null)
    rm -f "$TMPFILE"

    printf '{"ok":true,"data":[%s]}\n' "$JSON_RULES"
    exit 0
fi

# ── add_mirror ────────────────────────────────────────────────────────────────
if [ "$ACTION" = "add_mirror" ]; then
    check_daemon
    GW=$(param gw); SRC=$(param src); IFACE=$(param iface)
    [ -z "$GW" ] && { err "gw required"; exit 0; }

    CMD="iptables -t mangle -A ORBIC_MANGLE"
    [ -n "$IFACE" ] && CMD="$CMD -i $IFACE"
    [ -n "$SRC"   ] && CMD="$CMD -s $SRC"
    CMD="$CMD -j TEE --gateway $GW"

    OUT=$(sh /cache/ipt/ipt_ctl.sh $CMD 2>&1)
    RC=$?
    [ $RC -eq 0 ] && ok '"added"' || err "$OUT"
    exit 0
fi

# ── add_redirect ──────────────────────────────────────────────────────────────
if [ "$ACTION" = "add_redirect" ]; then
    check_daemon
    PROTO=$(param proto); DPORT=$(param dport); TOPORT=$(param toport); SRC=$(param src)
    [ -z "$PROTO" ] || [ -z "$DPORT" ] || [ -z "$TOPORT" ] && { err "proto/dport/toport required"; exit 0; }

    CMD="iptables -t nat -A ORBIC_PREROUTING -i bridge0 -p $PROTO --dport $DPORT"
    [ -n "$SRC" ] && CMD="$CMD -s $SRC"
    CMD="$CMD ! -d 192.168.1.1 -j REDIRECT --to-ports $TOPORT"

    OUT=$(sh /cache/ipt/ipt_ctl.sh $CMD 2>&1)
    RC=$?
    [ $RC -eq 0 ] && ok '"added"' || err "$OUT"
    exit 0
fi

# ── add_dnat ──────────────────────────────────────────────────────────────────
if [ "$ACTION" = "add_dnat" ]; then
    check_daemon
    PROTO=$(param proto); DPORT=$(param dport); TOIP=$(param toip); TOPORT=$(param toport)
    [ -z "$PROTO" ] || [ -z "$DPORT" ] || [ -z "$TOIP" ] || [ -z "$TOPORT" ] && { err "all fields required"; exit 0; }

    CMD="iptables -t nat -A ORBIC_PREROUTING -i bridge0 -p $PROTO --dport $DPORT -j DNAT --to-destination ${TOIP}:${TOPORT}"

    OUT=$(sh /cache/ipt/ipt_ctl.sh $CMD 2>&1)
    RC=$?
    [ $RC -eq 0 ] && ok '"added"' || err "$OUT"
    exit 0
fi

# ── add_block ─────────────────────────────────────────────────────────────────
if [ "$ACTION" = "add_block" ]; then
    check_daemon
    SRC=$(param src); DIR=$(param dir)
    [ -z "$SRC" ] && { err "src required"; exit 0; }

    if [ "$DIR" = "out" ]; then
        CMD="iptables -t filter -A ORBIC_FILTER -d $SRC -j DROP"
    else
        CMD="iptables -t filter -A ORBIC_FILTER -s $SRC -j DROP"
    fi

    OUT=$(sh /cache/ipt/ipt_ctl.sh $CMD 2>&1)
    RC=$?
    [ $RC -eq 0 ] && ok '"added"' || err "$OUT"
    exit 0
fi

# ── add_mark ──────────────────────────────────────────────────────────────────
if [ "$ACTION" = "add_mark" ]; then
    check_daemon
    SRC=$(param src); MARK=$(param mark)
    [ -z "$SRC" ] || [ -z "$MARK" ] && { err "src and mark required"; exit 0; }

    CMD="iptables -t mangle -A ORBIC_MANGLE -s $SRC -j MARK --set-mark $MARK"

    OUT=$(sh /cache/ipt/ipt_ctl.sh $CMD 2>&1)
    RC=$?
    [ $RC -eq 0 ] && ok '"added"' || err "$OUT"
    exit 0
fi

# ── delete ────────────────────────────────────────────────────────────────────
if [ "$ACTION" = "delete" ]; then
    check_daemon
    TABLE=$(param table); CHAIN=$(param chain); NUM=$(param num)
    [ -z "$TABLE" ] || [ -z "$CHAIN" ] || [ -z "$NUM" ] && { err "table/chain/num required"; exit 0; }
    # Validate num is integer
    echo "$NUM" | grep -qE '^[0-9]+$' || { err "invalid rule number"; exit 0; }

    OUT=$(sh /cache/ipt/ipt_ctl.sh iptables -t "$TABLE" -D "$CHAIN" "$NUM" 2>&1)
    RC=$?
    [ $RC -eq 0 ] && ok '"deleted"' || err "$OUT"
    exit 0
fi

# ── flush ─────────────────────────────────────────────────────────────────────
if [ "$ACTION" = "flush" ]; then
    check_daemon
    sh /cache/ipt/ipt_ctl.sh flush 2>&1
    ok '"flushed"'
    exit 0
fi

err "Unknown action: $ACTION"
