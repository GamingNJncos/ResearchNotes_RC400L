#!/bin/sh
# start.sh — RayTrap busybox httpd watchdog
# Run via inittab: rtw1:5:respawn:/bin/sh /cache/raytrap/start.sh
#
# Launches busybox httpd (which daemonizes itself), then watches its PID.
# When httpd dies, this script exits so init respawns it automatically.

PIDFILE=/cache/raytrap/httpd.pid
WWW=/cache/raytrap/www

# Kill any stale instance
if [ -f "$PIDFILE" ]; then
    OLD=$(cat "$PIDFILE" 2>/dev/null)
    [ -n "$OLD" ] && kill "$OLD" 2>/dev/null
    rm -f "$PIDFILE"
fi

# Launch busybox httpd (daemonizes automatically)
busybox httpd -p 8888 -h "$WWW"

# Wait for httpd process to appear (up to 10s)
PID=""
for i in 1 2 3 4 5 6 7 8 9 10; do
    for p in $(ls /proc/ 2>/dev/null | grep -E '^[0-9]+$'); do
        cmd=$(cat /proc/$p/cmdline 2>/dev/null | tr '\0' ' ')
        case "$cmd" in *busybox*httpd*-p*8888*)
            PID=$p; break 2
        ;; esac
    done
    sleep 1
done

if [ -z "$PID" ] || [ ! -d "/proc/$PID" ]; then
    echo "$(date) [!] httpd failed to start" >> /cache/raytrap/httpd.log
    sleep 5
    exit 1  # init will respawn us
fi

echo "$PID" > "$PIDFILE"
echo "$(date) [+] httpd started PID=$PID" >> /cache/raytrap/httpd.log

# Watch for death; exit when dead (init respawns wrapper)
while [ -d "/proc/$PID" ]; do
    sleep 5
done

echo "$(date) [!] httpd (PID=$PID) died — respawning" >> /cache/raytrap/httpd.log
