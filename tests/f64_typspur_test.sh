#!/usr/bin/env bash
# tests/f64_typspur_test.sh — #1496, #1497, #1498, #1499, #1502, #1511, #1512, #1478.
#
# Acht Meldungen, eine Ursache: der Codegen entscheidet an EINER Stelle, ob ein
# Ausdruck Gleitkomma ist (cg_isF64Expr). Was diese Stelle nicht kennt, wird
# ganzzahlig auf den IEEE-Bits gerechnet — dieselbe Luecke wie beim Doppel-Cast
# (#905), beim Feldzugriff (#1203), bei der globalen Variablen (#1373) und beim
# Array-Element (#1374). Diesmal fehlten: das unaere Minus, die benannte
# Konstante, das Feld-Array und der Ganzzahl-Startwert.
#
# #1478 sitzt woanders (cg_parseFloat), fuhr aber mit: dieselbe Datei, dieselbe
# Suite, und ohne die Skalierung sind kleine Literale still null.
#
# GEPRUEFT WIRD DER WERT, und wo es auf das letzte Bit ankommt, das BITMUSTER
# gegen python struct.pack. Ein Test auf "uebersetzt" waere sinnlos — alle acht
# Faelle uebersetzten klaglos und lieferten Muell.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/p.lyx"; rm -f "$TMP/p"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p" >/dev/null 2>&1; then
    no "$1" "uebersetzt nicht: $("$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p" 2>&1 | grep -i error | head -1)"
    return
  fi
  got="$(timeout 30 "$TMP/p" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then no "$1" "ABSTURZ (rc=$rc)"; return; fi
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1" "'$got' erwartet '$3'"; fi
}

# ===========================================================================
# Die sieben Formen der Typspur
# ===========================================================================

out "#1496: negatives Literal als Operand" 'import std.io;
fn main(): int64 {
  var a: f64 := 2.0;
  PrintLn(FloatToStr(a * -2.0, 2));
  PrintLn(FloatToStr(-2.0 * a, 2));
  return 0;
}' "-4.00
-4.00"

out "#1512: unaeres Minus auf einer Variablen" 'import std.io;
fn main(): int64 {
  var a: f64 := 2.0;
  var b: f64 := 3.0;
  PrintLn(FloatToStr(-a - b, 2));
  PrintLn(FloatToStr(-a * b, 2));
  return 0;
}' "-5.00
-6.00"

out "#1499: f64-Konstante als Operand" 'import std.io;
con PI: f64 := 3.14159;
con ZWEI: f64 := 2.0;
fn main(): int64 {
  var r: f64 := 2.0;
  PrintLn(FloatToStr(r * PI, 4));
  PrintLn(FloatToStr(PI / ZWEI, 4));
  return 0;
}' "6.2832
1.5708"

out "#1498: Feld-Array vom Typ [N]f64" 'import std.io;
type S = struct { e: [3]f64; n: int64; };
fn main(): int64 {
  var s: S;
  s.e[0] := 1.5; s.e[1] := 2.5; s.e[2] := 4.0; s.n := 7;
  PrintLn(FloatToStr(s.e[0] + s.e[1], 2));
  PrintLn(FloatToStr(s.e[2] * s.e[0], 2));
  PrintLn(IntToStr(s.n));
  return 0;
}' "4.00
6.00
7"

out "#1502: Ganzzahlliteral im f64-Initialisierer" 'import std.io;
fn main(): int64 {
  var x: f64 := 1;
  var y: f64 := 0;
  var z: f64 := 7;
  PrintLn(FloatToStr(x, 2));
  PrintLn(FloatToStr(y, 2));
  PrintLn(FloatToStr(z * 2.0, 2));
  return 0;
}' "1.00
0.00
14.00"

out "#1511: Cast zwischen f32 und f64" 'import std.io;
fn main(): int64 {
  var f: f32 := 4.0;
  var d: f64 := 2.5;
  PrintLn(FloatToStr(f as f64, 2));
  PrintLn(FloatToStr(d as f32, 2));
  PrintLn(FloatToStr((f as f64) + d, 2));
  return 0;
}' "4.00
2.50
6.50"

out "#1497: PrintLn eines Rechenausdrucks" 'import std.io;
fn main(): int64 {
  var a: f64 := 2.0;
  var b: f64 := 4.0;
  PrintLn(a + b);
  PrintLn(a * b);
  PrintLn(-a);
  return 0;
}' "6.000000
8.000000
-2.000000"

# ===========================================================================
# Gegenproben: die Ganzzahlseite darf sich nicht mitverschieben
# ===========================================================================

out "Ganzzahlrechnung unveraendert" 'import std.io;
con N: int64 := 21;
fn main(): int64 {
  var a: int64 := 6;
  var b: int64 := 7;
  PrintLn(IntToStr(a * b));
  PrintLn(IntToStr(-a - b));
  PrintLn(IntToStr(N * 2));
  PrintLn(IntToStr(7 / 2));
  return 0;
}' "42
-13
42
3"

out "Vergleiche liefern weiterhin Ganzzahlen" 'import std.io;
fn main(): int64 {
  var a: f64 := 2.0;
  var b: f64 := 4.0;
  if (a < b) { PrintLn("kleiner"); } else { PrintLn("nicht"); }
  var t: int64 := 0;
  if (-a < 0.0) { t := 1; }
  PrintLn(IntToStr(t));
  return 0;
}' "kleiner
1"

# ===========================================================================
# #1478 — kleine Literale, bitgenau gegen python
# ===========================================================================

if command -v python3 >/dev/null 2>&1; then
  LITERALE="1.0e-15 2.5e-19 1.0e-18 5.0e-18 1.0e-20 4.9e-24 1.0e-25 1.0e-26 1.0e-27
0.1 1.995 3.14159265358979 1.0e10 1.0e100"
  {
    echo "import std.io;"
    echo "import std.alloc;"
    echo "fn bits(v: f64): int64 {"
    echo "  var t: int64 := alloc(8); pokef64(t, v);"
    echo "  var b: int64 := peek64(t); free(t, 8); return b;"
    echo "}"
    echo "fn main(): int64 {"
    for l in $LITERALE; do echo "  PrintLn(IntToStr(bits($l)));"; done
    echo "  return 0;"
    echo "}"
  } > "$TMP/b.lyx"
  if "$LYXC" --std-path="$ROOT" "$TMP/b.lyx" -o "$TMP/b" >/dev/null 2>&1; then
    timeout 30 "$TMP/b" > "$TMP/ist.txt" 2>&1
    python3 - "$TMP/soll.txt" <<PY
import struct, sys
lits = """$LITERALE""".split()
with open(sys.argv[1], "w") as f:
    for v in lits:
        f.write("%d\n" % struct.unpack("<q", struct.pack("<d", float(v)))[0])
PY
    anzahl="$(wc -l < "$TMP/ist.txt")"
    if diff -q "$TMP/ist.txt" "$TMP/soll.txt" >/dev/null; then
      ok "#1478: $anzahl Literale bitgleich mit python, bis hinunter zu 1e-27"
    else
      abw="$(paste "$TMP/ist.txt" "$TMP/soll.txt" | awk '$1!=$2{print NR": "$1" statt "$2}' | head -3 | tr '\n' ' ')"
      no "#1478: $anzahl Literale bitgleich mit python" "$abw"
    fi
  else
    no "#1478: Literale bitgleich mit python" "uebersetzt nicht"
  fi
else
  echo "SKIP kein python3 — die Bitmuster lassen sich nicht gegenrechnen"
fi

# Und der Wert kommt auch rechnerisch an, nicht nur als Bitmuster.
out "#1478: kleines Literal traegt durch die Rechnung" 'import std.io;
fn main(): int64 {
  var k: f64 := 1.0e-20;
  PrintLn(FloatToStr(k * 1.0e20, 2));
  var m: f64 := 4.9e-24;
  PrintLn(FloatToStr(m * 1.0e24, 2));
  return 0;
}' "1.00
4.90"

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
