#!/bin/sh
# arp.cgi — RayTrap ARP table dump
# Reads /proc/net/arp and returns JSON array of entries.
# actions: list (default)

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

printf 'Content-Type: application/json\r\n\r\n'

ARP=/proc/net/arp
if [ ! -f "$ARP" ]; then
    err "no /proc/net/arp"; exit 0
fi

# Parse ARP table — skip header line
# Format: IP address | HW type | Flags | HW address | Mask | Device
entries=$(awk 'NR>1 && $4 != "00:00:00:00:00:00" {
    printf "{\"ip\":\"%s\",\"mac\":\"%s\",\"flags\":\"%s\",\"iface\":\"%s\"}",
           $1, $4, $3, $6
    count++
} END { if (!count) print "none" }' "$ARP" | \
    # join with commas
    awk 'BEGIN{ORS=""}{if(NR>1)print ","; print}')

if [ "$entries" = "none" ] || [ -z "$entries" ]; then
    ok "[]"; exit 0
fi

ok "[${entries}]"
