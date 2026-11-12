#!/usr/bin/env bash
# tests/ffi_herkunft_2202_test.sh — FFI-Vertrauen beim Import haengt an der
# Herkunft der Datei, nicht am Unit-Namen (#2202).
#
# Bis 1.2.20C galt jede Unit `std.*`/`src.*` als Binding-Layer und durfte ein
# unbekanntes FFI-Symbol deklarieren. Der Resolver sucht aber ZUERST relativ
# zum Arbeitsverzeichnis — ein mitgeliefertes `std/` neben dem Programm wurde
# als std.* aufgeloest und bekam das Vertrauen, ohne es zu beantragen.
#
# Beide Seiten (eine allein waere auch von der alten Fassung erfuellt):
#   1. dieselbe Unit im genannten Baum (--std-path) darf es weiterhin;
#   2. eine gleichnamige aus dem Arbeitsverzeichnis eines fremden Projekts
#      wird fail-closed abgewiesen;
#   3. dasselbe fremde Projekt, das seinen eigenen Baum ausdruecklich als
#      --std-path nennt, bekommt das Vertrauen — die Entscheidung liegt beim
#      Aufrufer, nicht beim uebersetzten Baum.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"
SONDE="$ROOT/std/_ffi_herkunft_sonde.lyx"
trap 'rm -rf "$TMP" "$SONDE"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

UNIT='unit std._ffi_herkunft_sonde;
extern fn lyx_herkunft_unbekannt(a: int64): int64 link "libherkunft.so";
pub fn sonde(): int64 { return 1; }'
MAIN='import std._ffi_herkunft_sonde;
fn main(): int64 { return sonde() - 1; }'

# 1. Im genannten Baum: vertrauenswuerdig.
printf '%s\n' "$UNIT" > "$SONDE"
printf '%s\n' "$MAIN" > "$TMP/main1.lyx"
if out=$(cd "$ROOT" && "$LYXC" --std-path="$ROOT" "$TMP/main1.lyx" -o "$TMP/p1" 2>&1); then
  ok "Unit aus --std-path darf unbekanntes FFI-Symbol deklarieren"
else no "Baum" "abgewiesen: $(echo "$out" | grep -m1 -i error)"; fi

# 2. Fremdes Projekt mit eigenem std/: abgewiesen.
mkdir -p "$TMP/projekt/std"
printf '%s\n' "$UNIT" > "$TMP/projekt/std/_ffi_herkunft_sonde.lyx"
printf '%s\n' "$MAIN" > "$TMP/projekt/main.lyx"
rm -f "$SONDE"   # damit nur die Projektkopie gefunden werden kann
out=$(cd "$TMP/projekt" && "$LYXC" --std-path="$ROOT" main.lyx -o "$TMP/p2" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "Fail-Closed"; then
  ok "gleichnamige Unit aus dem Arbeitsverzeichnis fail-closed"
else no "Arbeitsverzeichnis" "rc=$rc — std/ neben dem Programm bekam das Vertrauen (Bypass)"; fi

# 3. Dasselbe Projekt nennt sich selbst als Baum: Vertrauen auf Antrag.
out=$(cd "$TMP/projekt" && "$LYXC" --std-path=. main.lyx -o "$TMP/p3" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then ok "mit --std-path=. ausdruecklich vertrauenswuerdig"
else no "ausdruecklich" "rc=$rc: $(echo "$out" | grep -m1 -i error)"; fi

echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
