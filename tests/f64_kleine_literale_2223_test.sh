#!/usr/bin/env bash
# tests/f64_kleine_literale_2223_test.sh — kleine f64-Literale auf den IR-Zielen (#2223).
#
# ir_lower._parseFloatBits trug noch die Fassung von #1478: der Nenner wuchs,
# bis er nicht mehr in int64 passte, dann halbierte ein Notzweig den Zaehler
# bis 0. Jedes Literal ab etwa 1e-28 wurde auf arm64, riscv und lyxos still
# zu 0 — `1.0e-40 > 0.0` war falsch. x86 hatte das mit #1569 behoben; die
# zweite Stelle war nicht nachgezogen.
#
# Geprueft werden die BITMUSTER, nicht ein Vergleich mit 0: jede Abweichung
# um ein ULP faellt so auf, nicht nur die Null. Bezug ist Python (IEEE-754
# des Rechners), auf x86, arm64 und riscv.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
. "$(dirname "$0")/lib/qemu.sh"   # #2048
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ulimit -c 0
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

WERTE="1.0e-10 1.0e-27 1.0e-28 1.0e-40 1.0e-50 3.14e-100 1.0e-300 2.2250738585072014e-308 4.9e-324 1.5e-45 6.02214076e-23"
ERWARTET=$(python3 -c "
import struct,sys
print(' '.join(str(struct.unpack('<q',struct.pack('<d',float(w)))[0]) for w in sys.argv[1:]))" $WERTE)

{ echo 'import std.io;'; echo 'fn main(): int64 {'
  i=0; for w in $WERTE; do echo "  var w$i: f64 := $w; var b$i: int64 := peek64(@w$i); PrintLn(b$i);"; i=$((i+1)); done
  echo '  return 0;'; echo '}'; } > "$TMP/l.lyx"

lauf() { # name ziel runner
  local opt=""; [ -n "$2" ] && opt="--target=$2"
  if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" $opt "$TMP/l.lyx" -o "$TMP/l.$1" >"$TMP/l.$1.log" 2>&1); then
    no "$1" "uebersetzt nicht: $(grep -v Copyright "$TMP/l.$1.log" | head -2 | tr '\n' ' ')"; return; fi
  if [ "$1" != x86 ] && [ -z "$3" ]; then echo "HINWEIS: qemu fuer $1 fehlt — nur uebersetzt."; ok "$1 uebersetzt"; return; fi
  local got; got=$(cd "$TMP" && timeout 30 $3 "$TMP/l.$1" 2>/dev/null | tr '\n' ' '); got="${got% }"
  if [ "$got" = "$ERWARTET" ]; then ok "$1: 11 Bitmuster gleich Python"
  else no "$1" "bekam '$got' erwartet '$ERWARTET'"; fi
}
lauf x86 "" ""
lauf arm64 arm64 "$QEMU_ARM64"
lauf riscv riscv "$QEMU_RISCV64"

echo "f64_kleine_literale_2223: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
