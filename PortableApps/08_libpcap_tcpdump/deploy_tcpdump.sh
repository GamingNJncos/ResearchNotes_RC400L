#!/bin/sh
# deploy_tcpdump.sh — RC400L tcpdump deployer
# Requires: rootshell access via adb (or serial)
# Run as: rootshell -c "sh /data/tmp/deploy_tcpdump.sh [iface] [count] [outfile]"
#
# HOW TO USE MANUALLY (from rootshell):
# -----------------------------------------------
# 1. Push binary and this script from PC:
#      adb push tcpdump /data/tmp/tcpdump
#      adb push deploy_tcpdump.sh /data/tmp/deploy_tcpdump.sh
#
# 2. Get rootshell:
#      adb shell
#      rootshell
#
# 3. Create root-owned executable copy:
#      cp /data/tmp/tcpdump /data/tmp/tcpdump_r
#      chmod +x /data/tmp/tcpdump_r
#
# 4. Run this deploy script to capture via inittab escape:
#      sh /data/tmp/deploy_tcpdump.sh wlan0 100 /data/tmp/cap.pcap
#
# 5. Pull the pcap to PC:
#      adb pull /data/tmp/cap.pcap cap.pcap
#
# INTERFACES (use whichever has traffic):
#   wlan0    — WiFi clients connected to Orbic hotspot  (RECOMMENDED)
#   bridge0  — LAN bridge, includes wlan0 + rndis0 traffic
#   rmnet0   — LTE cellular uplink (requires active data session)
#   any      — All interfaces (may warn about promiscuous mode)
#
# WHY INITTAB ESCAPE:
#   rootshell runs uid=0 but CapBnd=0x00c0 (SETUID+SETGID only).
#   CAP_NET_RAW (required for raw packet capture) is NOT in the
#   bounding set. init (PID 1) has CapBnd=0x3fffffffff (full caps).
#   By injecting a `once` entry into /etc/inittab and sending
#   kill -HUP 1, init spawns tcpdump directly with full caps.
#   The spawned tcpdump has CapEff=0x3fffffffff and can open
#   AF_PACKET sockets freely.
#
# ARGUMENTS:
#   $1 = interface  (default: wlan0)
#   $2 = pkt count  (default: 100, use 0 for unlimited)
#   $3 = output     (default: /data/tmp/cap.pcap)

IFACE="${1:-wlan0}"
COUNT="${2:-100}"
OUTFILE="${3:-/data/tmp/cap.pcap}"
TCPDUMP_SRC="/data/tmp/tcpdump"
TCPDUMP_BIN="/data/tmp/tcpdump_r"
INITTAB="/etc/inittab"
INITTAB_BAK="/data/tmp/inittab.orig.bak"

# Unique tag per run — busybox inittab id field is max 4 chars
# Use last 2 digits of second + pid last digit for uniqueness
TAG="t$(( ($$ % 9) + 1 ))$(date +%S 2>/dev/null | cut -c3 || echo 0)"

echo "========================================"
echo " RC400L tcpdump deploy"
echo "========================================"
echo " iface  : $IFACE"
echo " count  : $COUNT (0=unlimited)"
echo " output : $OUTFILE"
echo " tag    : $TAG"
echo ""

# --- Preflight: verify binary ---
if [ ! -f "$TCPDUMP_SRC" ]; then
    echo "[!] $TCPDUMP_SRC not found."
    echo "    Push it first: adb push tcpdump /data/tmp/tcpdump"
    exit 1
fi

# --- Create root-owned executable copy ---
echo "[1] Creating root-owned copy..."
cp "$TCPDUMP_SRC" "$TCPDUMP_BIN" || { echo "[!] cp failed — not root?"; exit 1; }
chmod +x "$TCPDUMP_BIN" || { echo "[!] chmod failed"; exit 1; }
echo "    $(ls -la $TCPDUMP_BIN)"
echo ""

# --- Quick sanity check ---
echo "[2] Checking binary..."
"$TCPDUMP_BIN" --version 2>&1 | head -1
echo "    Interfaces available:"
"$TCPDUMP_BIN" -D 2>&1 | grep -E "wlan0|bridge0|rmnet0|rndis0|any" | sed 's/^/      /'
echo ""

# --- Backup inittab (only on first run) ---
if [ ! -f "$INITTAB_BAK" ]; then
    echo "[3] Backing up /etc/inittab to $INITTAB_BAK"
    cp "$INITTAB" "$INITTAB_BAK" || { echo "[!] inittab backup failed"; exit 1; }
else
    echo "[3] Using existing backup: $INITTAB_BAK"
fi

# --- Clean any previous tc* entries and stale output ---
grep -v "^tc" "$INITTAB" > /data/tmp/inittab.new
cp /data/tmp/inittab.new "$INITTAB"
rm -f /data/tmp/inittab.new "$OUTFILE" /data/tmp/tcpdump_err.log

# --- Build inittab command (handle unlimited capture) ---
if [ "$COUNT" = "0" ]; then
    TCPDUMP_CMD="$TCPDUMP_BIN -i $IFACE -w $OUTFILE 2>/data/tmp/tcpdump_err.log"
else
    TCPDUMP_CMD="$TCPDUMP_BIN -i $IFACE -c $COUNT -w $OUTFILE 2>/data/tmp/tcpdump_err.log"
fi

# --- Inject inittab entry ---
echo "[4] Injecting inittab once entry (tag=$TAG)..."
echo "${TAG}:5:once:${TCPDUMP_CMD}" >> "$INITTAB"
echo "    Entry: $(tail -1 $INITTAB)"
echo ""

# --- Signal init ---
echo "[5] Signaling init (kill -HUP 1)..."
kill -HUP 1
echo ""

# --- Wait for tcpdump to start ---
echo "[6] Waiting for tcpdump to start (up to 10s)..."
TPID=""
for i in $(seq 1 10); do
    sleep 1
    for p in $(ls /proc/ | grep -E "^[0-9]+$"); do
        cmdline=$(cat /proc/$p/cmdline 2>/dev/null | tr '\0' ' ')
        case "$cmdline" in
            *tcpdump_r*-i*) TPID=$p; break 2 ;;
        esac
    done
done

if [ -z "$TPID" ]; then
    echo "[!] tcpdump did not start after 10s"
    echo "    Check stderr: cat /data/tmp/tcpdump_err.log"
    grep "${TAG}" "$INITTAB" && echo "    Entry still in inittab"
    cp "$INITTAB_BAK" "$INITTAB" && kill -HUP 1
    exit 1
fi

echo "    tcpdump PID=$TPID"
grep CapEff /proc/$TPID/status 2>/dev/null | awk '{printf "    CapEff: %s\n", $2}'
echo ""

# --- Show stderr log to confirm listening ---
sleep 1
echo "[7] tcpdump status:"
cat /data/tmp/tcpdump_err.log 2>/dev/null | sed 's/^/    /'
echo ""

# --- Wait for capture to complete (or timeout at 120s for unlimited) ---
if [ "$COUNT" = "0" ]; then
    WAIT=120
    echo "[8] Unlimited capture — waiting ${WAIT}s (kill PID $TPID manually to stop early):"
    echo "    rootshell -c 'kill $TPID'"
else
    WAIT=120
    echo "[8] Waiting for $COUNT packets (max ${WAIT}s)..."
fi

for i in $(seq 1 $WAIT); do
    sleep 1
    if [ ! -d "/proc/$TPID" ]; then
        echo "    Done after ${i}s"
        break
    fi
    if [ $((i % 10)) -eq 0 ]; then
        SIZE=$(ls -la "$OUTFILE" 2>/dev/null | awk '{print $5}')
        echo "    ${i}s elapsed — pcap: ${SIZE:-0} bytes"
    fi
done

# Kill if still running (unlimited mode)
[ -d "/proc/$TPID" ] && kill "$TPID" 2>/dev/null && sleep 1

# --- Restore inittab ---
echo ""
echo "[9] Restoring /etc/inittab..."
cp "$INITTAB_BAK" "$INITTAB"
kill -HUP 1
echo "    Done."
echo ""

# --- Result ---
if [ -f "$OUTFILE" ]; then
    SIZE=$(ls -la "$OUTFILE" | awk '{print $5}')
    if [ "$SIZE" -gt 24 ]; then
        echo "========================================"
        echo " SUCCESS"
        echo "========================================"
        ls -la "$OUTFILE"
        echo ""
        echo " Pull to PC:  adb pull $OUTFILE cap.pcap"
        echo " Open in:     wireshark cap.pcap"
    else
        echo "[!] Capture file is empty (${SIZE} bytes)"
        echo "    Either no traffic on $IFACE during capture,"
        echo "    or tcpdump failed. Check:"
        echo "      cat /data/tmp/tcpdump_err.log"
        echo ""
        echo "    Retry with traffic flowing, e.g.:"
        echo "      Connect a device to Orbic WiFi and browse"
        echo "      sh /data/tmp/deploy_tcpdump.sh wlan0 100"
    fi
else
    echo "[!] No output file found at $OUTFILE"
    echo "    cat /data/tmp/tcpdump_err.log for errors"
fi
