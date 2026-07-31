#!/usr/bin/env bash
# test_compile_units.sh — übersetzt JEDE Unit-Quelle mit --compile-unit.
#
# Bis 2026-07-31 lief die Schleife über "$STD_DIR"/*.lyx — also nur die oberste
# Ebene. Der Sweep meldete 92 OK / 0 failed, während std/cloud/, std/lyxvision/,
# std/net/, std/crypto/, std/svg/ und data/ nie geprüft wurden: 88 von 390 Units
# waren nicht übersetzbar, ohne dass es jemand sah. Deshalb läuft er jetzt
# rekursiv über std/ UND data/.
#
# Bekannte Fehlschläge stehen in KNOWN_FAILURES und zählen nicht als Fehler,
# werden aber als [KNOWN] ausgewiesen. Läuft eine davon wieder durch, meldet das
# Skript das als [FIXED] und schlägt fehl — damit die Liste nicht stillschweigend
# veraltet. Begründungen: work/units-not-precompilable.md
#
# Ein Absturz (SIGSEGV=139, abort=134, …) im Kind beendet dieses Skript nicht.

ROOT="$(cd "$(dirname "$0")" && pwd)"
LYXC="$ROOT/lyxc"
OUT_DIR="/tmp/lyu_test_out"
LOG_FILE="/tmp/lyu_test_results.txt"
TIMEOUT_S=90

# Units, die bekannt nicht übersetzen — mit Grund.
# Beide brauchen eine Entscheidung, keine Reparatur (siehe work/-Dokument).
KNOWN_FAILURES="
std/cloud/ec2.lyx|verschachtelte Helfer mutieren buf/off der umgebenden Funktion
std/net/ssh.lyx|OS-Klassen-extern ohne @capabilities (Policy)
"

is_known() {
    printf '%s\n' "$KNOWN_FAILURES" | grep -q "^$1|"
}
known_reason() {
    printf '%s\n' "$KNOWN_FAILURES" | grep "^$1|" | cut -d'|' -f2
}

mkdir -p "$OUT_DIR"
> "$LOG_FILE"

pass=0
fail=0
crash=0
timeout_c=0
known=0
fixed=0

for src in $(find "$ROOT/std" "$ROOT/data" -name '*.lyx' | sort); do
    rel="${src#$ROOT/}"
    out="$OUT_DIR/$(echo "$rel" | tr '/' '_' | sed 's/\.lyx$/.lyu/')"

    result=$(cd "$ROOT" && timeout "$TIMEOUT_S" "$LYXC" --compile-unit "$rel" -o "$out" 2>&1)
    code=$?

    if [ $code -eq 0 ]; then
        if is_known "$rel"; then
            status="FIXED"
            fixed=$((fixed+1))
        else
            status="OK"
            pass=$((pass+1))
        fi
    elif is_known "$rel"; then
        status="KNOWN"
        known=$((known+1))
    elif [ $code -eq 124 ]; then
        status="TIMEOUT"
        timeout_c=$((timeout_c+1))
    elif [ $code -eq 139 ]; then
        status="CRASH(SIGSEGV)"
        crash=$((crash+1))
    elif [ $code -eq 134 ]; then
        status="CRASH(SIGABRT)"
        crash=$((crash+1))
    elif [ $code -eq 136 ]; then
        status="CRASH(SIGFPE)"
        crash=$((crash+1))
    elif [ $code -eq 132 ]; then
        status="CRASH(SIGILL)"
        crash=$((crash+1))
    else
        status="FAIL(exit=$code)"
        fail=$((fail+1))
    fi

    if [ "$status" = "KNOWN" ]; then
        echo "[KNOWN] $rel — $(known_reason "$rel")" | tee -a "$LOG_FILE"
    elif [ "$status" = "FIXED" ]; then
        echo "[FIXED] $rel — übersetzt wieder, aus KNOWN_FAILURES entfernen" | tee -a "$LOG_FILE"
    else
        echo "[$status] $rel" | tee -a "$LOG_FILE"
    fi

    if [ "$status" != "OK" ] && [ "$status" != "KNOWN" ] && [ "$status" != "FIXED" ]; then
        echo "  stdout/stderr:" >> "$LOG_FILE"
        echo "$result" | head -20 | sed 's/^/    /' >> "$LOG_FILE"
        echo "  stdout/stderr:"
        echo "$result" | head -10 | sed 's/^/    /'
    fi
done

echo ""
echo "========================================" | tee -a "$LOG_FILE"
echo "RESULTS: $pass OK, $fail failed, $crash crashed, $timeout_c timed out, $known known, $fixed unexpectedly fixed" | tee -a "$LOG_FILE"
echo "Full log: $LOG_FILE"

# Ein bekannter Fehlschlag ist kein Fehler; eine veraltete Liste schon.
[ $((fail + crash + timeout_c + fixed)) -eq 0 ]
