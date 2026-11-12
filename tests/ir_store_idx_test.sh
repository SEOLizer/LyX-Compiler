#!/usr/bin/env bash
# tests/ir_store_idx_test.sh — #2085: Schreiben mit variablem Index trifft das
# richtige Element, auf x86_64, arm64 und riscv.
#
# IRO_STORE_IDX traegt den Index im dest-Feld. Die Dead-Code-Elimination
# (src/ir_optimize.lyx) zaehlte nur src1..src3 als Verwendung und strich die
# Instruktion, die den Index berechnet: `a[i] := 7` schrieb auf arm64 und
# riscv nach a[0]. Lesen mit variablem Index stimmte — deshalb fiel es nur
# an einem Programm auf, das schreibt UND danach liest (das Sieb in
# examples/algorithms/eratosthenes.lyx gab alle Zahlen aus).
set -uo pipefail
ulimit -c 0   # ein Absturz unter qemu legt sonst eine .core-Datei ins Repo
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
. "$(dirname "$0")/lib/qemu.sh"   # #2048: beide Paketnamen
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

alle_ziele() {  # $1 Beschreibung, $2 Quelle, $3 Soll mit |
  local was="$1" src="$2" erw="$3"
  for ziel in x86_64 arm64 riscv; do
    local bin="$TMP/b_$ziel" pre=""
    case "$ziel" in
      arm64) pre="$QEMU_ARM64" ;;
      riscv) pre="$QEMU_RISCV64" ;;
    esac
    if ! ( cd "$ROOT" && timeout 240 "$LYXC" --std-path="$ROOT" --target="$ziel" "$src" -o "$bin" ) >"$TMP/bl.log" 2>&1; then
      nok "$was [$ziel]: uebersetzt nicht ($(grep -m1 -iE '^lyxc:|error' "$TMP/bl.log"))"; continue
    fi
    if [ "$ziel" != "x86_64" ] && [ -z "$pre" ]; then nok "$was [$ziel]: qemu fehlt — NICHT gemessen"; continue; fi
    local ist; ist="$( (timeout 60 $pre "$bin" 2>&1) | tr '\n' '|')"
    if [ "$ist" = "$erw" ]; then ok "$was [$ziel] = $erw"
    else nok "$was [$ziel]: [$ist] statt [$erw]"; fi
  done
}

echo "--- variabler Index beim Schreiben ---"
cat > "$TMP/a.lyx" <<'EOF'
unit main;
import std.io;
fn main(): int64 {
  var a: int64[3];
  a[0] := 0; a[1] := 5;
  var i: int64 := 2;
  a[i] := 7;
  PrintLn(IntToStr(a[0])); PrintLn(IntToStr(a[1])); PrintLn(IntToStr(a[2]));
  return 0;
}
EOF
alle_ziele "a[0]=0, a[1]=5, a[i=2]=7" "$TMP/a.lyx" "0|5|7|"

echo
echo "--- Schleife: jedes Element bekommt seinen eigenen Wert ---"
cat > "$TMP/b.lyx" <<'EOF'
unit main;
import std.io;
fn main(): int64 {
  var w := [0, 0, 0, 0, 0];
  var i: int64 := 0;
  while (i < 5) { w[i] := i * 11 + 1; i := i + 1; }
  PrintLn(IntToStr(w[0])); PrintLn(IntToStr(w[1])); PrintLn(IntToStr(w[2]));
  PrintLn(IntToStr(w[3])); PrintLn(IntToStr(w[4]));
  return 0;
}
EOF
alle_ziele "w[i] := i*11+1 fuer i = 0..4" "$TMP/b.lyx" "1|12|23|34|45|"

echo
echo "--- das Sieb aus examples/algorithms/eratosthenes.lyx ---"
# Erst der Beispielteil zaehlt: die letzte Zeile "Primes found: 25".
if ( cd "$ROOT/examples/algorithms" && timeout 240 "$LYXC" --std-path="$ROOT" --target=arm64 eratosthenes.lyx -o "$TMP/sieb" ) >"$TMP/sb.log" 2>&1; then
  if [ -z "$QEMU_ARM64" ]; then nok "Sieb [arm64]: qemu fehlt — NICHT gemessen"
  else
    aus="$(timeout 60 $QEMU_ARM64 "$TMP/sieb" 2>&1)"
    case "$aus" in
      *"Primes found: 25"*) ok "Sieb [arm64]: 25 Primzahlen bis 100" ;;
      *) nok "Sieb [arm64]: $(echo "$aus" | tail -1 | cut -c1-60)" ;;
    esac
  fi
else
  nok "Sieb [arm64]: uebersetzt nicht ($(grep -m1 -iE 'error' "$TMP/sb.log"))"
fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
