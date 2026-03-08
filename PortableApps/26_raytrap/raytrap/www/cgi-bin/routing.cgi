#!/bin/sh
# routing.cgi — RayTrap policy routing (ip rule / ip route)
#
# Tables:
#   100 = LTE-only  (default dev rmnet0)
#   200 = wlan1-STA (default dev wlan1)
#
# Per-client routing: ip rule add from <client-ip> lookup <table>
# Priority range: 1000-1999 (below main 32766, above local 0)

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
jstr(){ printf '"%s"' "$(echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }

ACTION=$(param action)

# ── list ──────────────────────────────────────────────────────────────────────
if [ "$ACTION" = "list" ]; then
    # Parse ip rule show into JSON array (only our custom rules, prio 1000-1999)
    RULES_JSON=""
    FIRST=1

    TMPFILE=/tmp/rt_rules_$$.json
    printf '' > "$TMPFILE"

    while IFS= read -r line; do
        prio=$(echo "$line" | cut -d: -f1 | tr -d ' ')
        echo "$prio" | grep -qE '^[0-9]+$' || continue
        [ "$prio" -eq 0 ] || [ "$prio" -ge 32766 ] && continue

        from=$(echo "$line" | grep -o 'from [^ ]*' | awk '{print $2}')
        table=$(echo "$line" | grep -o 'lookup [^ ]*' | awk '{print $2}')

        desc=""
        [ "$table" = "100" ] && desc="LTE (rmnet0)"
        [ "$table" = "200" ] && desc="wlan1 STA"

        printf '{"priority":%s,"from":%s,"table":%s,"desc":%s}\n' \
            "$prio" "$(jstr "$from")" "$(jstr "$table")" "$(jstr "$desc")" >> "$TMPFILE"
    done << EOF
$(ip rule show 2>/dev/null)
EOF

    RULES=$(awk 'NR>1{printf ","} {printf "%s",$0}' "$TMPFILE" 2>/dev/null)
    rm -f "$TMPFILE"

    # Raw dump for display
    RAW=$(ip rule show 2>/dev/null; echo "---"; ip route show table 100 2>/dev/null | sed 's/^/table100: /'; ip route show table 200 2>/dev/null | sed 's/^/table200: /')
    RAW_ESC=$(echo "$RAW" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' '|' | sed 's/|/\\n/g')

    printf '{"ok":true,"data":{"rules":[%s],"raw":"%s"}}\n' "$RULES" "$RAW_ESC"
    exit 0
fi

# ── setup_tables ──────────────────────────────────────────────────────────────
if [ "$ACTION" = "setup_tables" ]; then
    ERRORS=""

    # Table 100 — LTE via rmnet0
    ip route add default dev rmnet0 table 100 2>/dev/null || true
    ip route add 192.168.1.0/24 dev bridge0 table 100 2>/dev/null || true

    # Table 200 — wlan1 STA
    ip route add default dev wlan1 table 200 2>/dev/null || true
    ip route add 192.168.1.0/24 dev bridge0 table 200 2>/dev/null || true

    ok '"tables_initialized"'
    exit 0
fi

# ── add_client ────────────────────────────────────────────────────────────────
if [ "$ACTION" = "add_client" ]; then
    SRC=$(param src); VIA=$(param via)
    [ -z "$SRC" ] || [ -z "$VIA" ] && { err "src and via required"; exit 0; }

    # Validate IP (basic)
    echo "$SRC" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(/[0-9]+)?$' || \
        { err "invalid source IP"; exit 0; }

    case "$VIA" in
        lte)   TABLE=100; DESC="LTE" ;;
        wlan1) TABLE=200; DESC="wlan1" ;;
        *)     err "via must be lte or wlan1"; exit 0 ;;
    esac

    # Find next free priority in 1000-1999
    PRIO=1000
    while ip rule show 2>/dev/null | grep -q "^${PRIO}:"; do
        PRIO=$(( PRIO + 10 ))
        [ "$PRIO" -ge 2000 ] && { err "priority range exhausted"; exit 0; }
    done

    OUT=$(ip rule add from "$SRC" lookup "$TABLE" priority "$PRIO" 2>&1)
    RC=$?

    # Also add MARK rule in iptables so traffic from this src gets marked
    # (useful for fwmark-based routing as alternative path)
    sh /cache/ipt/ipt_ctl.sh iptables -t mangle -A ORBIC_MANGLE \
        -s "$SRC" -j MARK --set-mark "$TABLE" 2>/dev/null || true

    [ $RC -eq 0 ] && ok "{\"priority\":$PRIO,\"table\":$TABLE,\"desc\":\"$DESC\"}" || err "$OUT"
    exit 0
fi

# ── delete_rule ───────────────────────────────────────────────────────────────
if [ "$ACTION" = "delete_rule" ]; then
    PRIO=$(param priority); FROM=$(param from)
    echo "$PRIO" | grep -qE '^[0-9]+$' || { err "invalid priority"; exit 0; }

    if [ -n "$FROM" ] && [ "$FROM" != "all" ]; then
        OUT=$(ip rule del from "$FROM" priority "$PRIO" 2>&1)
    else
        OUT=$(ip rule del priority "$PRIO" 2>&1)
    fi
    RC=$?
    [ $RC -eq 0 ] && ok '"deleted"' || err "$OUT"
    exit 0
fi

err "Unknown action: $ACTION"
