#!/bin/sh
# fb_upload.cgi — Write raw RGB565 pixel data to /dev/fb0
# Also handles info query for framebuffer dimensions
# actions (GET): info  — returns JSON with width, height, bpp
# default POST:  write raw bytes to /dev/fb0 via dd

FB=/dev/fb0
SYSFS=/sys/class/graphics/fb0

if [ "$REQUEST_METHOD" = "POST" ]; then
    QUERY_STRING=$(cat "$QUERY_STRING" 2>/dev/null; printf '%s' "$QUERY_STRING")
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

ACTION=$(param action)

# ── info — return framebuffer geometry ───────────────────────────────────────
if [ "$ACTION" = "info" ] || ([ -z "$ACTION" ] && [ "$REQUEST_METHOD" = "GET" ]); then
    printf 'Content-Type: application/json\r\n\r\n'
    if [ ! -e "$FB" ]; then err "no /dev/fb0"; exit 0; fi

    WIDTH=$(cat "$SYSFS/virtual_size" 2>/dev/null | cut -d, -f1)
    HEIGHT=$(cat "$SYSFS/virtual_size" 2>/dev/null | cut -d, -f2)
    BPP=$(cat "$SYSFS/bits_per_pixel" 2>/dev/null)
    NAME=$(cat "$SYSFS/name" 2>/dev/null)

    [ -z "$WIDTH" ]  && WIDTH=128
    [ -z "$HEIGHT" ] && HEIGHT=128
    [ -z "$BPP" ]    && BPP=16

    ok "{\"width\":${WIDTH},\"height\":${HEIGHT},\"bpp\":${BPP},\"name\":\"${NAME}\"}"
    exit 0
fi

# ── POST — write pixels to /dev/fb0 ──────────────────────────────────────────
if [ "$REQUEST_METHOD" = "POST" ]; then
    printf 'Content-Type: application/json\r\n\r\n'

    if [ ! -e "$FB" ]; then err "no /dev/fb0"; exit 0; fi
    if [ ! -w "$FB" ]; then err "/dev/fb0 not writable (check group/root)"; exit 0; fi

    BYTES=$(dd bs=4096 of="$FB" 2>&1 | grep -oE '[0-9]+ bytes' | head -1 | grep -oE '[0-9]+')
    ok "{\"bytes_written\":${BYTES:-0}}"
    exit 0
fi

printf 'Content-Type: application/json\r\n\r\n'
err "use GET?action=info or POST with raw RGB565 data"
