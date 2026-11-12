#!/usr/bin/env bash
# tests/ir_kein_stiller_ausdruck_test.sh — #2092: der IR-Weg uebersetzt keinen
# Ausdruck mehr still falsch.
#
# lowerExpr gab jeder Ausdrucksart ohne eigenen Zweig einen unbeschriebenen
# Temp. Gemessen ueber den ganzen Bestand erreichte genau eine Art den
# Default: NK_CLOSURE (tests/wp02_closures.lyx) — auf arm64 ein Absturz, auf
# riscv keine Ausgabe, uebersetzt hatte es fehlerfrei.
#
# Der Test verlangt NICHT, dass Closures auf dem IR-Weg fehlen (#2108): ist
# das Programm uebersetzbar, muss es das Richtige ausgeben; ist es das nicht,
# muss die Meldung den Grund nennen. Nur der dritte Ausgang — uebersetzt und
# falsch — ist rot.
set -uo pipefail
ulimit -c 0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
. "$(dirname "$0")/lib/qemu.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

for ziel in arm64 riscv; do
  pre="$QEMU_ARM64"; [ "$ziel" = "riscv" ] && pre="$QEMU_RISCV64"
  if ( cd "$ROOT" && timeout 240 "$LYXC" --std-path="$ROOT" --target="$ziel" tests/wp02_closures.lyx -o "$TMP/c_$ziel" ) >"$TMP/bl.log" 2>&1; then
    if [ -z "$pre" ]; then echo "FAIL [$ziel] qemu fehlt — NICHT gemessen"; FAIL=$((FAIL+1)); continue; fi
    ist="$( (timeout 30 $pre "$TMP/c_$ziel" 2>&1) | tr '\n' '|')"
    if [ "$ist" = "3|10|PASS|" ]; then echo "PASS [$ziel] Closures laufen: $ist"; PASS=$((PASS+1))
    else echo "FAIL [$ziel] uebersetzt, aber falsch: [$ist]"; FAIL=$((FAIL+1)); fi
  elif grep -q "IR-Weg kennt den Ausdruck nicht" "$TMP/bl.log"; then
    echo "PASS [$ziel] laut abgewiesen: $(grep -m1 'IR-Weg kennt' "$TMP/bl.log")"; PASS=$((PASS+1))
  else
    echo "FAIL [$ziel] abgewiesen, aber ohne Grund: $(grep -m1 -iE 'error' "$TMP/bl.log")"; FAIL=$((FAIL+1))
  fi
done

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
