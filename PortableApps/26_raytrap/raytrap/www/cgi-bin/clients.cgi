#!/bin/sh
# clients.cgi — Connected client discovery: ARP + dnsmasq leases
# GET: returns JSON array of known LAN clients

printf 'Content-Type: application/json\r\n\r\n'

ok()  { printf '{"ok":true,"data":%s}\n' "${1:-null}"; }
err() { printf '{"ok":false,"error":"%s"}\n' "$(printf '%s' "$1" | sed 's/"/\\"/g')"; }

# ── dnsmasq lease file — try both common paths ────────────────────────────────
LEASE_FILE=""
for f in /var/lib/misc/dnsmasq.leases /data/misc/dhcp/dnsmasq.leases /tmp/dnsmasq.leases; do
    [ -f "$f" ] && { LEASE_FILE="$f"; break; }
done

# Build hostname lookup from leases: key=mac → hostname
# Lease format: expiry mac ip hostname client_id
build_leases() {
    [ -z "$LEASE_FILE" ] && return
    awk '{
        mac=tolower($2); host=$4
        if (host == "*" || host == "") host=""
        leases[mac] = host
    } END {
        for (m in leases) printf "%s\t%s\n", m, leases[m]
    }' "$LEASE_FILE" 2>/dev/null
}

# Parse /proc/net/arp — filter to bridge0/wlan0 (LAN), skip 00:00:00:00:00:00
# Columns: IP HW-type Flags MAC Mask Device
ARP_DATA=$(awk '
NR == 1 { next }
$4 == "00:00:00:00:00:00" { next }
($6 == "bridge0" || $6 == "wlan0" || $6 == "wlan1") {
    print $1, tolower($4), $3, $6
}
' /proc/net/arp 2>/dev/null)

if [ -z "$ARP_DATA" ]; then
    ok "[]"
    exit 0
fi

# Build hostname lookup table
LEASES=$(build_leases)

# Merge ARP + leases into JSON
JSON=$(printf '%s\n' "$ARP_DATA" | awk -v leases="$LEASES" '
BEGIN {
    # Load lease map
    n = split(leases, ls, "\n")
    for (i = 1; i <= n; i++) {
        if (split(ls[i], kv, "\t") == 2)
            lmap[kv[1]] = kv[2]
    }
}
{
    ip=$1; mac=$2; flags=$3; iface=$4
    hostname = (mac in lmap && lmap[mac] != "") ? lmap[mac] : ""
    if (NR > 1) printf ","
    printf "{\"ip\":\"%s\",\"mac\":\"%s\",\"hostname\":\"%s\",\"iface\":\"%s\",\"flags\":\"%s\"}",
        ip, mac, hostname, iface, flags
}
END { }
' 2>/dev/null)

ok "[${JSON}]"
