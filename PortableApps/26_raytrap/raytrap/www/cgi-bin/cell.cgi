#!/bin/sh
# cell.cgi — Cell Intelligence: serving cell data + IMSI-catcher heuristics
# Polls AT commands, parses responses server-side, returns structured JSON.
# actions: poll (default GET)

SMD7=/dev/smd7
TMPOUT=/tmp/cell_cgi_resp.$$

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
jnum(){ printf '%s' "${1:-null}"; }

trap 'rm -f "$TMPOUT"; exec 3>&- 2>/dev/null' EXIT

# ── smd7 helpers ──────────────────────────────────────────────────────────────
open_smd7() { exec 3<>"$SMD7" 2>/dev/null; return $?; }

smd7_transact() {
    local cmd="$1" timeout="${2:-5}" i=0
    > "$TMPOUT"
    printf '%s\r\n' "$cmd" >&3
    cat <&3 >"$TMPOUT" &
    local rpid=$!
    while [ "$i" -lt "$timeout" ]; do
        sleep 1; i=$((i+1))
        grep -qF "$(printf 'OK\r')" "$TMPOUT" 2>/dev/null && {
            kill "$rpid" 2>/dev/null; wait "$rpid" 2>/dev/null
            exec 3>&-; return 0; }
        grep -qF "$(printf 'ERROR\r')" "$TMPOUT" 2>/dev/null && {
            kill "$rpid" 2>/dev/null; wait "$rpid" 2>/dev/null
            exec 3>&-; return 1; }
    done
    kill "$rpid" 2>/dev/null; wait "$rpid" 2>/dev/null
    exec 3>&-; return 2
}

at_run() {
    local cmd="$1" timeout="${2:-5}"
    open_smd7 || return 2
    smd7_transact "$cmd" "$timeout"
}

# ── check device ─────────────────────────────────────────────────────────────
[ ! -e "$SMD7" ] && { err "no $SMD7"; exit 0; }
[ ! -r "$SMD7" ] && { err "$SMD7 not readable"; exit 0; }

# ── [1] AT+CEREG=5 (set mode — non-fatal on error) ───────────────────────────
at_run "AT+CEREG=5" 4

# ── [2] AT+CEREG? — TAC, CI, AcT, reject_cause ───────────────────────────────
CEREG_TAC="" CEREG_CI="" CEREG_ACT="" CEREG_STAT="" CEREG_REJECT="" CEREG_OK=false
at_run "AT+CEREG?" 5
if grep -q '+CEREG:' "$TMPOUT" 2>/dev/null; then
    CEREG_LINE=$(grep '+CEREG:' "$TMPOUT" | head -1 | tr -d '\r')
    CEREG_VALS="${CEREG_LINE#+CEREG: }"
    # Extract fields: n,stat,tac,ci,act[,cause_type,reject]
    CEREG_STAT=$(printf '%s' "$CEREG_VALS" | cut -d, -f2 | tr -d ' ')
    CEREG_TAC=$(printf '%s' "$CEREG_VALS"  | cut -d, -f3 | tr -d '" ')
    CEREG_CI=$(printf '%s' "$CEREG_VALS"   | cut -d, -f4 | tr -d '" ')
    CEREG_ACT=$(printf '%s' "$CEREG_VALS"  | cut -d, -f5 | tr -d ' ')
    # reject_cause is field 7 when cause_type=0 in field 6
    CEREG_CT=$(printf '%s' "$CEREG_VALS"   | cut -d, -f6 | tr -d ' ')
    CEREG_REJECT=$(printf '%s' "$CEREG_VALS" | cut -d, -f7 | tr -d ' ')
    [ -n "$CEREG_TAC" ] && CEREG_OK=true
fi

# ── [3] AT+COPS=3,2 (set numeric PLMN format) ────────────────────────────────
at_run "AT+COPS=3,2" 4

# ── [4] AT+COPS? — PLMN, AcT ─────────────────────────────────────────────────
COPS_PLMN="" COPS_ACT="" COPS_MCC="" COPS_MNC=""
at_run "AT+COPS?" 5
if grep -q '+COPS:' "$TMPOUT" 2>/dev/null; then
    COPS_LINE=$(grep '+COPS:' "$TMPOUT" | head -1 | tr -d '\r')
    COPS_VALS="${COPS_LINE#+COPS: }"
    COPS_PLMN=$(printf '%s' "$COPS_VALS" | cut -d, -f3 | tr -d '" ')
    COPS_ACT=$(printf '%s' "$COPS_VALS"  | cut -d, -f4 | tr -d ' ')
    COPS_MCC="${COPS_PLMN%???}"   # first 3 chars
    COPS_MNC="${COPS_PLMN#???}"   # after 3 chars
fi

# ── [5] AT^SCELLINFO — band, EARFCN, PCI, RSRP, RSRQ, SINR ──────────────────
SCI_BAND="" SCI_EARFCN="" SCI_PCI="" SCI_RSRP="" SCI_RSRQ="" SCI_SINR="" SCI_OK=false
at_run "AT^SCELLINFO" 5
if grep -q '\^SCELLINFO:' "$TMPOUT" 2>/dev/null; then
    SCI_LINE=$(grep '\^SCELLINFO:' "$TMPOUT" | head -1 | tr -d '\r')
    SCI_VALS="${SCI_LINE#*SCELLINFO: }"
    # Format: LTE,<band>,<dl_earfcn>,<ul_earfcn>,<pci>,<rsrp>,<rsrq>,<sinr>,<ta>
    SCI_RAT=$(printf '%s' "$SCI_VALS"    | cut -d, -f1 | tr -d ' ')
    SCI_BAND=$(printf '%s' "$SCI_VALS"   | cut -d, -f2 | tr -d ' ')
    SCI_EARFCN=$(printf '%s' "$SCI_VALS" | cut -d, -f3 | tr -d ' ')
    SCI_PCI=$(printf '%s' "$SCI_VALS"    | cut -d, -f5 | tr -d ' ')
    SCI_RSRP=$(printf '%s' "$SCI_VALS"   | cut -d, -f6 | tr -d ' ')
    SCI_RSRQ=$(printf '%s' "$SCI_VALS"   | cut -d, -f7 | tr -d ' ')
    SCI_SINR=$(printf '%s' "$SCI_VALS"   | cut -d, -f8 | tr -d ' ')
    [ -n "$SCI_EARFCN" ] && SCI_OK=true
fi

# ── [6] AT$QCSQ — RSRP/RSRQ/SINR fallback ────────────────────────────────────
QCSQ_RSRP="" QCSQ_RSRQ="" QCSQ_SINR=""
at_run "AT\$QCSQ" 5
if grep -q '\$QCSQ:' "$TMPOUT" 2>/dev/null; then
    QCSQ_LINE=$(grep '\$QCSQ:' "$TMPOUT" | head -1 | tr -d '\r')
    QCSQ_VALS="${QCSQ_LINE#*QCSQ: }"
    # Format: <rat>,<rsrp_dbm>,<rsrq_db_x10>,<sinr_db_x10>
    QCSQ_RSRP=$(printf '%s' "$QCSQ_VALS" | cut -d, -f2 | tr -d ' ')
    QCSQ_RSRQ_RAW=$(printf '%s' "$QCSQ_VALS" | cut -d, -f3 | tr -d ' ')
    QCSQ_SINR_RAW=$(printf '%s' "$QCSQ_VALS" | cut -d, -f4 | tr -d ' ')
    # QCSQ RSRQ and SINR are ×10 — convert to integer for JS
fi

# ── [7] AT*CNTI=0 — current RAT ───────────────────────────────────────────────
CNTI_RAT=""
at_run "AT*CNTI=0" 5
if grep -q '\*CNTI:' "$TMPOUT" 2>/dev/null; then
    CNTI_LINE=$(grep '\*CNTI:' "$TMPOUT" | head -1 | tr -d '\r')
    CNTI_VALS="${CNTI_LINE#*CNTI: }"
    CNTI_RAT=$(printf '%s' "$CNTI_VALS" | cut -d, -f2 | tr -d ' ')
fi

# ── Assemble JSON ─────────────────────────────────────────────────────────────
# Use SCELLINFO values where available; fall back to QCSQ
RSRP="${SCI_RSRP:-${QCSQ_RSRP:-null}}"
RSRQ="${SCI_RSRQ:-null}"
SINR="${SCI_SINR:-null}"

[ "$RSRP" = "" ] && RSRP="null"
[ "$RSRQ" = "" ] && RSRQ="null"
[ "$SINR" = "" ] && SINR="null"
[ "$QCSQ_RSRQ_RAW" = "" ] && QCSQ_RSRQ_RAW="null"
[ "$QCSQ_SINR_RAW" = "" ] && QCSQ_SINR_RAW="null"

# Derive eNB ID and Cell ID from CI (28-bit: upper 20 = eNB, lower 8 = cell)
ENB_ID="null" CELL_ID="null"
if [ -n "$CEREG_CI" ]; then
    CI_INT=$(printf '%d' "0x${CEREG_CI}" 2>/dev/null)
    if [ -n "$CI_INT" ] && [ "$CI_INT" -ge 0 ] 2>/dev/null; then
        ENB_ID=$(( CI_INT >> 8 ))
        CELL_ID=$(( CI_INT & 255 ))
    fi
fi

# AcT name
act_name() {
    case "$1" in
        0) printf 'GSM' ;;  2) printf 'UTRAN' ;; 7) printf 'LTE' ;;
        13) printf 'LTE-M' ;; 9) printf 'NB-IoT' ;; *) printf '%s' "${1:-?}" ;;
    esac
}
ACT_NAME=$(act_name "${CEREG_ACT:-${COPS_ACT:-}}")

ok "$(printf '{
  "cereg":{"ok":%s,"stat":%s,"tac":%s,"ci":%s,"act":%s,"act_name":%s,"reject_cause":%s},
  "cops":{"plmn":%s,"mcc":%s,"mnc":%s},
  "cell":{"band":%s,"earfcn":%s,"pci":%s,"rsrp":%s,"rsrq":%s,"sinr":%s},
  "qcsq":{"rsrp":%s,"rsrq_x10":%s,"sinr_x10":%s},
  "cnti":%s,
  "enb_id":%s,
  "cell_id":%s
}' \
"$CEREG_OK" \
"$(jnum "$CEREG_STAT")" \
"$(jstr "${CEREG_TAC:-}")" \
"$(jstr "${CEREG_CI:-}")" \
"$(jnum "${CEREG_ACT:-null}")" \
"$(jstr "$ACT_NAME")" \
"$(jnum "${CEREG_REJECT:-null}")" \
"$(jstr "${COPS_PLMN:-}")" \
"$(jstr "${COPS_MCC:-}")" \
"$(jstr "${COPS_MNC:-}")" \
"$(jnum "${SCI_BAND:-null}")" \
"$(jnum "${SCI_EARFCN:-null}")" \
"$(jnum "${SCI_PCI:-null}")" \
"$RSRP" "$RSRQ" "$SINR" \
"$(jnum "${QCSQ_RSRP:-null}")" \
"$(jnum "${QCSQ_RSRQ_RAW:-null}")" \
"$(jnum "${QCSQ_SINR_RAW:-null}")" \
"$(jstr "${CNTI_RAT:-}")" \
"$ENB_ID" "$CELL_ID")"
