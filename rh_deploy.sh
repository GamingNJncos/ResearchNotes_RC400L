#!/bin/bash
# Deploy rayhunter-daemon-fork to device over ADB
# Run from rc400l/ directory after rh_build.sh completes.
# Device serial auto-detected from first connected ADB device.
# Override: ADB_SERIAL=<serial> ./rh_deploy.sh

ADB="$(dirname "$0")/adb"
BINARY="$(dirname "$0")/rayhunter-daemon-fork"
DEVICE_BIN="/data/rayhunter/rayhunter-daemon"

set -e

# Auto-detect device serial if not set
if [ -z "$ADB_SERIAL" ]; then
    ADB_SERIAL=$("$ADB" devices | grep -v "^List" | grep "device$" | head -1 | cut -f1)
fi
if [ -z "$ADB_SERIAL" ]; then
    echo "ERROR: no ADB device found. Connect device and retry, or set ADB_SERIAL." >&2
    exit 1
fi
echo "=== Using device: $ADB_SERIAL ==="

echo "=== Stopping rayhunter on device ==="
"$ADB" -s "$ADB_SERIAL" shell '/bin/rootshell -c "/etc/init.d/rayhunter_daemon stop"' 2>/dev/null || true
sleep 2

echo "=== Pushing new binary ==="
"$ADB" -s "$ADB_SERIAL" push "$BINARY" "$DEVICE_BIN"

echo "=== Setting executable bit via ipt_daemon FIFO ==="
# rootshell has no CAP_FOWNER — must use ipt_daemon (CapEff=0x3fffffffff) to chmod
"$ADB" -s "$ADB_SERIAL" shell '/bin/rootshell -c "echo chmod 755 /data/rayhunter/rayhunter-daemon > /cache/ipt/cmd.fifo"'
sleep 1
"$ADB" -s "$ADB_SERIAL" shell '/bin/rootshell -c "ls -la /data/rayhunter/rayhunter-daemon"'

echo "=== Starting rayhunter via ipt_daemon FIFO ==="
# start-stop-daemon also fails (rootshell cap limitation); launch via ipt_daemon with full caps
"$ADB" -s "$ADB_SERIAL" shell '/bin/rootshell -c "rm -f /tmp/rayhunter.pid; echo \"RUST_LOG=info /data/rayhunter/rayhunter-daemon /data/rayhunter/config.toml > /data/rayhunter/rayhunter.log 2>&1 &\" > /cache/ipt/cmd.fifo"'
sleep 3
"$ADB" -s "$ADB_SERIAL" shell '/bin/rootshell -c "ps | grep rayhunter-daemon | grep -v grep"'

echo "=== Done — rayhunter fork running. Access via: adb forward tcp:8080 tcp:8080 ==="
