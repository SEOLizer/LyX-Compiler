#!/usr/bin/env bash
# tests/stdlib_mathe_test.sh — #1572, #1577, #1591, #1547.
#
# Vier Punkte in der rechnenden Bibliothek:
#
#   #1572 std.ml_full exportierte eigene Fassungen von ExpF64, LogF64 und
#         SqrtF64 unter denselben Namen wie std.math — LogF64 gab fuer JEDE
#         Eingabe 0.0 zurueck, ExpF64 war eine Tabelle gerundeter Naeherungen
#         (exp(1) = 2.7). Welche Fassung ein Programm bekam, entschied die
#         Importreihenfolge.
#   #1577 Atan2F64 ignorierte das Vorzeichenbit einer Null: atan2(-0, -1) gab
#         +pi statt -pi. Still, denn das Ergebnis ist eine plausible Zahl.
#   #1591 std.svg schrieb ausschliesslich Nullen — svgF64x100 erwartete von
#         `as int64` ein Bitmuster, bekommt aber den umgewandelten Wert.
#   #1547 Bignum: der Bericht sagt "existiert nirgends". Nachgemessen.
#
# GEMESSEN WIRD GEGEN PYTHON, nicht gegen die eigene Bibliothek: bei den
# Winkelfunktionen ueber das Bitmuster (PrintFloat zeigt das Vorzeichen einer
# Null nicht), bei den grossen Zahlen ueber die Dezimaldarstellung.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >"$TMP/c.log" 2>&1; then
    no "$1" "uebersetzt nicht: $(grep -m1 -iE 'error|sema|Parse' "$TMP/c.log")"; return
  fi
  got="$(timeout 120 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then no "$1" "ABSTURZ rc=$rc"; return; fi
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1" "'$got' erwartet '$3'"; fi
}

# ===========================================================================
# #1572 — keine zweiten Fassungen mehr in std.ml_full
# ===========================================================================
# Die Werte stammen aus Python: e, exp(2), log(e), log(1000), sigmoid(0).
out "#1572: ml_full liefert die richtigen Exp/Log/Sqrt" 'import std.io;
import std.ml_full;
fn main(): int64 {
  PrintStr(FloatToStr(LogF64(2.718281828459045), 6)); PrintStr(" ");
  PrintStr(FloatToStr(LogF64(1000.0), 6)); PrintStr(" ");
  PrintStr(FloatToStr(ExpF64(1.0), 6)); PrintStr(" ");
  PrintStr(FloatToStr(ExpF64(2.0), 6)); PrintStr(" ");
  PrintStr(FloatToStr(SqrtF64(16.0), 6)); PrintStr(" ");
  PrintLn(FloatToStr(SigmoidF64(0.0), 6));
  return 0;
}' "1.000000 6.907755 2.718282 7.389056 4.000000 0.500000"

# Beide Units zusammen duerfen sich nicht mehr in die Quere kommen — genau das
# war der Kern: zwei Exporte gleichen Namens.
out "#1572: std.math und std.ml_full zusammen importierbar" 'import std.io;
import std.math;
import std.ml_full;
fn main(): int64 {
  PrintStr(FloatToStr(ExpF64(1.0), 6)); PrintStr(" ");
  PrintLn(FloatToStr(SquareF64(7.0), 1));
  return 0;
}' "2.718282 49.0"

# Sigmoid stimmt jetzt an Stellen, an denen die Naeherung danebenlag.
# Python: 1/(1+exp(-2)) = 0.880797, 1/(1+exp(-4)) = 0.982014.
out "#1572: Sigmoid rechnet statt zu raten" 'import std.io;
import std.ml_full;
fn main(): int64 {
  PrintStr(FloatToStr(SigmoidF64(2.0), 6)); PrintStr(" ");
  PrintLn(FloatToStr(SigmoidF64(4.0), 6));
  return 0;
}' "0.880797 0.982014"

# ===========================================================================
# #1577 — Vorzeichen der Null in Atan2F64
# ===========================================================================
# Bitmuster aus Python (math.atan2), in der Reihenfolge:
#   (-0,-1) (-0,+1) (-0,-0) (+0,-1) (-1,-0) (-1,+0) (+1,+1)
out "#1577: alle Null-Faelle nach C99 F.10.1.4" 'import std.io;
import std.math;
import std.feq;
fn Z(y: f64, x: f64) { PrintStr(IntToStr(FeqBits(Atan2F64(y, x)))); PrintStr(" "); }
fn main(): int64 {
  var nz: f64 := -0.0;
  Z(nz, -1.0); Z(nz, 1.0); Z(nz, nz);
  Z(0.0, -1.0); Z(-1.0, nz); Z(-1.0, 0.0); Z(1.0, 1.0);
  PrintLn("");
  return 0;
}' "-4609115380302729960 -9223372036854775808 -4609115380302729960 4614256656552045848 -4613618979930100456 -4613618979930100456 4605249457297304856 "

# Die gewoehnlichen Quadranten muessen unveraendert stimmen.
out "#1577: Quadranten unveraendert" 'import std.io;
import std.math;
fn main(): int64 {
  PrintStr(FloatToStr(Atan2F64(1.0, 1.0), 6)); PrintStr(" ");
  PrintStr(FloatToStr(Atan2F64(1.0, -1.0), 6)); PrintStr(" ");
  PrintStr(FloatToStr(Atan2F64(-1.0, -1.0), 6)); PrintStr(" ");
  PrintLn(FloatToStr(Atan2F64(-1.0, 1.0), 6));
  return 0;
}' "0.785398 2.356194 -2.356194 -0.785398"

# ===========================================================================
# #1591 — std.svg schreibt Werte statt Nullen
# ===========================================================================
out "#1591: Masse und Koordinaten stehen im Erzeugnis" 'import std.io;
import std.svg;
fn main(): int64 {
  var doc: int64 := SvgNew(800.0, 600.0);
  SvgSetFillHex(doc, "#FF0000"c);
  SvgCircle(doc, 200.0, 150.5, 50.0);
  SvgApply(doc);
  SvgRect(doc, 10.25, 20.0, 30.0, 40.0);
  SvgApply(doc);
  PrintLn(SvgToString(doc));
  SvgFree(doc);
  return 0;
}' '<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="800" height="600">
  <circle cx="200" cy="150.5" r="50" fill="#FF0000"/>
  <rect x="10.25" y="20" width="30" height="40"/>
</svg>'

# ===========================================================================
# #1547 — grosse Ganzzahlen: gemessen, nicht behauptet
# ===========================================================================
# Referenz (Python):
#   a*b, a+b, b//a, b%a, pow(a,65537,1000000007) mit
#   a = 123456789012345678901234567890, b = 987654321098765432109876543210
out "#1547: Grundrechenarten und Modexp gegen die Referenz" 'import std.io;
import std.bignum;
import std.alloc;
fn Zeig(p: int64) {
  var buf: int64 := alloc(4096);
  BigToDecimal(p, buf, 4096);
  PrintStr(buf as pchar); PrintStr(" ");
  free(buf, 4096);
}
fn main(): int64 {
  var a: int64 := BigNew(64); var b: int64 := BigNew(64); var c: int64 := BigNew(64);
  var q: int64 := BigNew(64); var r: int64 := BigNew(64);
  BigFromDecimal("123456789012345678901234567890"c as int64, a);
  BigFromDecimal("987654321098765432109876543210"c as int64, b);
  BigMul(a, b, c); Zeig(c);
  BigAdd(a, b, c); Zeig(c);
  BigDivRem(b, a, q, r); Zeig(q); Zeig(r);
  var m: int64 := BigNew(64); var e: int64 := BigNew(64); var res: int64 := BigNew(64);
  BigFromDecimal("65537"c as int64, e);
  BigFromDecimal("1000000007"c as int64, m);
  BigPowMod(a, e, m, res); Zeig(res);
  PrintLn("");
  return 0;
}' "121932631137021795226185032733622923332237463801111263526900 1111111110111111111011111111100 8 9000000000900000000090 921051386 "

# Die Groessenordnung, um die es im Bericht geht: ein echter 1024-Bit-Modul
# (RSA-Kern). Referenz: pow(b, 65537, m) in Python.
out "#1547: 1024-Bit-Modexp" 'import std.io;
import std.bignum;
import std.alloc;
fn main(): int64 {
  var m: int64 := BigNew(80); var b: int64 := BigNew(80);
  var e: int64 := BigNew(80); var res: int64 := BigNew(80);
  BigFromDecimal("113367188111228571209367387211363752029984350685705113194498032396321547267616816180958370019783584704244493330051169546708159195197503283807991156348891031514802965149775944361893267999596883534187107027550867465192967138906660435899865328069321514287447484494365216564439324566129329071266878824531527906361"c as int64, m);
  BigFromDecimal("17515027794491702087477057010565624195658099654733491449771982177490603119292282992038848845550170872063173718723052802365951043734106861566838090293384126787399011025330062474601898205378553160484753734933455788004592273294563609187279194225610129680040232955272460402040299547025771980652506083863901992629"c as int64, b);
  BigFromDecimal("65537"c as int64, e);
  BigPowMod(b, e, m, res);
  var buf: int64 := alloc(4096);
  BigToDecimal(res, buf, 4096);
  PrintLn(buf as pchar);
  return 0;
}' "47900771388592019932310634145450069407988968513353328354342254528563629761290405254755148614654157348962563249264179088638428355474376375571567544416824699085208153666724572073915830693779117494866946517817298387398052555973329469501097154652577570149863180986669342737534493987069981500567742690853453389736"

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
