#!/usr/bin/env bash
# tests/ir_lower_tempo_test.sh — #2023: der IR-Weg uebersetzt grosse
# Funktionen in linearer Zeit.
#
# lowerCall suchte bei JEDEM Aufruf die ganze Knotentabelle der Unit und aller
# Importe nach einer extern-Deklaration ab — vor der Builtin-Behandlung, also
# auch fuer jedes poke64. Bei Daten-Units (std/unicode_data.lyx) war das
# quadratisch: 400 s fuer arm64 gegen 6 s auf dem x86-Weg.
#
# Gemessen wird das WACHSTUM, nicht eine feste Zeitgrenze (die waere
# rechnerabhaengig): CPU-Zeit fuer 4000 gegen 1000 Aufrufe in einer Funktion.
# Linear sind das ~4x, quadratisch ~16x; die Schwelle liegt bei 8x. Dazu die
# Wirkung: ein uebersetztes Programm laeuft unter qemu und liefert die Summe.
set -uo pipefail
ulimit -c 0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
. "$(dirname "$0")/lib/qemu.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

erzeuge() {  # n, datei — Unit mit n poke64-Zeilen in einer Funktion
  python3 - "$1" > "$2" <<'PY'
import sys
n=int(sys.argv[1])
print('unit pz;')
print('pub fn Fill(p: int64): void {')
for i in range(n): print(f'  poke64(p+{i*8},{i});')
print('}')
PY
}
cpu() {  # datei → CPU-Sekunden (Hundertstel als ganze Zahl)
  /usr/bin/time -f "%U %S" -o "$TMP/t" "$LYXC" --std-path="$ROOT" --compile-unit --target=arm64 "$1" -o "$TMP/x.lyu" >/dev/null 2>&1
  awk '{printf "%d", ($1 + $2) * 100 + 1}' "$TMP/t"
}
erzeuge 1000 "$TMP/k.lyx"; erzeuge 4000 "$TMP/g.lyx"
cpu "$TMP/k.lyx" >/dev/null   # Aufwaermen (Seitencache)
k=$(cpu "$TMP/k.lyx"); g=$(cpu "$TMP/g.lyx")
faktor=$(( g * 10 / k ))
if [ "$faktor" -le 80 ]; then ok "4000 gegen 1000 Aufrufe: Faktor $((faktor/10)).$((faktor%10)) (linear ~4, quadratisch ~16)"
else nok "4000 gegen 1000 Aufrufe: Faktor $((faktor/10)).$((faktor%10)) — waechst ueberlinear"; fi

# Wirkung: 600 Werte schreiben und lesen, Summe pruefen — mit -O2, also durch
# den Optimierer, dessen Suchschleifen ersetzt sind. 600, nicht 4000: ab rund
# 750 Anweisungen in einer Funktion stuerzt das arm64-Erzeugnis ab, mit und
# ohne diese Aenderung — ein eigener offener Defekt (#2112), an dem dieser
# Test nicht haengen darf.
{
  echo 'import std.io;'
  echo 'import std.alloc;'
  echo 'fn fill(p: int64): void {'
  for i in $(seq 0 599); do echo "  poke64(p+$((i*8)),$i);"; done
  echo '}'
  echo 'fn main(): int64 { var p: int64 := alloc(4800); fill(p); var s: int64 := 0; var i: int64 := 0;'
  echo '  while (i < 600) { s := s + peek64(p + i * 8); i := i + 1; } PrintLn(IntToStr(s)); return 0; }'
} > "$TMP/w.lyx"
if [ -z "$QEMU_ARM64" ]; then nok "arm64-Emulator fehlt — Wirkung NICHT gemessen"
elif ( cd "$ROOT" && timeout 240 "$LYXC" --std-path="$ROOT" --target=arm64 "$TMP/w.lyx" -o "$TMP/w" ) >/dev/null 2>&1; then
  ist="$(timeout 60 "$QEMU_ARM64" "$TMP/w" 2>&1)"
  if [ "$ist" = "179700" ]; then ok "arm64 -O2: 600 Werte, Summe 179700"; else nok "arm64: Summe [$ist] statt 179700"; fi
else nok "arm64: grosses Programm uebersetzt nicht"; fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
