#!/usr/bin/env bash
# test_compile_units.sh — tests each std/*.lyx with --compile-unit in isolation
# A crash (SIGSEGV=139, abort=134, etc.) in a child does NOT kill this script.

LYXC="/home/andreas/PhpstormProjects/aurum/lyxc"
STD_DIR="/home/andreas/PhpstormProjects/aurum/std"
OUT_DIR="/tmp/lyu_test_out"
LOG_FILE="/tmp/lyu_test_results.txt"
TIMEOUT_S=15

mkdir -p "$OUT_DIR"
> "$LOG_FILE"

pass=0
fail=0
crash=0
timeout_c=0

for src in "$STD_DIR"/*.lyx; do
    name=$(basename "$src" .lyx)
    out="$OUT_DIR/${name}.lyu"

    result=$(timeout "$TIMEOUT_S" "$LYXC" --compile-unit "$src" -o "$out" 2>&1)
    code=$?

    if [ $code -eq 0 ]; then
        status="OK"
        pass=$((pass+1))
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

    echo "[$status] $name" | tee -a "$LOG_FILE"
    if [ "$status" != "OK" ]; then
        echo "  stdout/stderr:" >> "$LOG_FILE"
        echo "$result" | head -20 | sed 's/^/    /' >> "$LOG_FILE"
        echo "  stdout/stderr:"
        echo "$result" | head -10 | sed 's/^/    /'
    fi
done

echo ""
echo "========================================" | tee -a "$LOG_FILE"
echo "RESULTS: $pass OK, $fail failed, $crash crashed, $timeout_c timed out" | tee -a "$LOG_FILE"
echo "Full log: $LOG_FILE"
