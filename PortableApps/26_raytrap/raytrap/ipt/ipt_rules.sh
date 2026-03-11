#!/bin/sh
# ipt_rules.sh — RC400L custom iptables ruleset
# Applied by ipt_daemon.sh on startup and on 'ipt_ctl.sh reload'
# Edit this file to change persistent rules.
#
# SAFETY CONTRACT:
#   - Only add rules to ORBIC_* chains (never touch QCMAP chains)
#   - Never change default policies (INPUT/FORWARD default DROP set by QCMAP)
#   - Never add MASQUERADE — QCMAP handles NAT via QMI hardware
#   - QCMAP critical rules:
#       -A FORWARD -i bridge0 -j ACCEPT  (WiFi client forwarding — must stay)
#       -A INPUT -i bridge0 -j ACCEPT    (device reachable from LAN — must stay)
#
# INTERFACES:
#   bridge0  — LAN bridge (WiFi clients + USB RNDIS tether)
#   wlan0    — WiFi AP interface
#   rmnet0   — LTE uplink (cellular data)
#
# WIFI CLIENT SUBNET: 192.168.1.0/24  (device IP: 192.168.1.1)

IPT="iptables"

# -------------------------------------------------------------------------
# SETUP — Create ORBIC custom chains (idempotent)
# -------------------------------------------------------------------------
# nat table — for PREROUTING redirect/DNAT
$IPT -t nat -N ORBIC_PREROUTING  2>/dev/null
$IPT -t nat -F ORBIC_PREROUTING

# mangle table — for marking, QoS, TEE mirroring
$IPT -t mangle -N ORBIC_MANGLE   2>/dev/null
$IPT -t mangle -F ORBIC_MANGLE

# filter table — for custom accept/drop rules
$IPT -t filter -N ORBIC_FILTER   2>/dev/null
$IPT -t filter -F ORBIC_FILTER

# -------------------------------------------------------------------------
# HOOK into main chains (insert at position 1, before QCMAP rules)
# -C checks existence first to avoid duplicates on daemon restart
# -------------------------------------------------------------------------
$IPT -t nat    -C PREROUTING -j ORBIC_PREROUTING 2>/dev/null || \
    $IPT -t nat    -I PREROUTING 1 -j ORBIC_PREROUTING

$IPT -t mangle -C PREROUTING -j ORBIC_MANGLE     2>/dev/null || \
    $IPT -t mangle -I PREROUTING 1 -j ORBIC_MANGLE

# Optional filter hook — uncomment if you need ORBIC_FILTER
# $IPT -t filter -C FORWARD -j ORBIC_FILTER 2>/dev/null || \
#     $IPT -t filter -I FORWARD 1 -j ORBIC_FILTER

echo "[ipt_rules] Chains ready: ORBIC_PREROUTING, ORBIC_MANGLE, ORBIC_FILTER"

# =========================================================================
# USER RULES — Edit below this line
# =========================================================================

# -------------------------------------------------------------------------
# [1] PORT 777 REDIRECT
# Redirect TCP port 777 from WiFi clients to a local service.
# Current target: rayhunter web UI on port 8080.
# Change --to-ports to any local port you want to redirect to.
# -------------------------------------------------------------------------
# Uncomment to enable:
# $IPT -t nat -A ORBIC_PREROUTING \
#     -i bridge0 -p tcp --dport 777 \
#     -j REDIRECT --to-ports 8080
# echo "[ipt_rules] Port 777 → 8080 redirect enabled"

# -------------------------------------------------------------------------
# [2] PORT 777 REDIRECT TO EXTERNAL HOST (DNAT)
# Forward port 777 to a specific host on the LAN instead of localhost.
# -------------------------------------------------------------------------
# $IPT -t nat -A ORBIC_PREROUTING \
#     -i bridge0 -p tcp --dport 777 \
#     -j DNAT --to-destination 192.168.1.50:8080
# echo "[ipt_rules] Port 777 → 192.168.1.50:8080 DNAT enabled"

# -------------------------------------------------------------------------
# [3] TRAFFIC MIRRORING via TEE
# Duplicate ALL packets from WiFi clients to a mirror host on the LAN.
# The mirror host receives a copy of every packet (use with Wireshark).
# WARNING: doubles traffic — use sparingly or for specific clients only.
# -------------------------------------------------------------------------
# Mirror all WiFi client traffic:
# $IPT -t mangle -A ORBIC_MANGLE \
#     -i bridge0 \
#     -j TEE --gateway 192.168.1.50
# echo "[ipt_rules] TEE mirror → 192.168.1.50 enabled"

# Mirror a single client:
# $IPT -t mangle -A ORBIC_MANGLE \
#     -i bridge0 -s 192.168.1.152 \
#     -j TEE --gateway 192.168.1.50
# echo "[ipt_rules] TEE mirror client 192.168.1.152 → 192.168.1.50"

# -------------------------------------------------------------------------
# [4] TRAFFIC MARKING for QoS / policy routing
# Mark packets from WiFi clients for use with tc/iproute2.
# -------------------------------------------------------------------------
# $IPT -t mangle -A ORBIC_MANGLE \
#     -i bridge0 \
#     -j MARK --set-mark 0x10
# echo "[ipt_rules] MARK 0x10 on all bridge0 ingress"

# -------------------------------------------------------------------------
# [5] DSCP marking (QoS priority field in IP header)
# -------------------------------------------------------------------------
# $IPT -t mangle -A ORBIC_MANGLE \
#     -i bridge0 -p tcp --dport 443 \
#     -j DSCP --set-dscp-class EF
# echo "[ipt_rules] DSCP EF on HTTPS from WiFi clients"

# -------------------------------------------------------------------------
# [6] CONNMARK — persist marks across connection lifetime
# -------------------------------------------------------------------------
# $IPT -t mangle -A ORBIC_MANGLE \
#     -i bridge0 -p tcp --dport 80 \
#     -j CONNMARK --set-mark 0x20
# $IPT -t mangle -A ORBIC_MANGLE \
#     -j CONNMARK --restore-mark
# echo "[ipt_rules] CONNMARK 0x20 on HTTP"

# -------------------------------------------------------------------------
# [7] RATE LIMITING — limit WiFi clients to N connections/sec
# -------------------------------------------------------------------------
# $IPT -t filter -A ORBIC_FILTER \
#     -i bridge0 -p tcp --syn \
#     -m limit --limit 20/sec --limit-burst 50 \
#     -j ACCEPT
# $IPT -t filter -A ORBIC_FILTER \
#     -i bridge0 -p tcp --syn \
#     -j DROP
# echo "[ipt_rules] Rate limit: 20 new TCP conns/sec from WiFi"

# -------------------------------------------------------------------------
# [8] LOG — log packets matching a rule (goes to kernel log / syslog)
# -------------------------------------------------------------------------
# $IPT -t mangle -A ORBIC_MANGLE \
#     -i bridge0 -p tcp --dport 777 \
#     -j LOG --log-prefix "[ORBIC-777] " --log-level 4
# echo "[ipt_rules] LOG port 777 traffic"

echo "[ipt_rules] Ruleset applied."
