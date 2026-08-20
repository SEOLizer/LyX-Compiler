#!/usr/bin/env bash
# tests/stdlib_z3_test.sh — #1501, #1542, #1495, #1500, #1492, #1491.
#
# Sechs Meldungen aus der stdlib. Vier davon melden Erfolg oder liefern eine
# plausible Zahl, obwohl etwas schiefging; eine stürzt in der Prüfung ab, die
# vor genau diesem Fall schützen soll.
#
#   #1501 VarIntSize passte nach dem ZickZack-Fix (#1463) nicht mehr zu
#         WriteVarInt — wer damit den Puffer bemaß, reservierte zu wenig. Und
#         die Abbildung lief ab 2^62 über: MAX und MIN kamen als EIN Byte raus.
#   #1542 SafeMul(-1, INT64_MIN) starb mit SIGFPE — die Überlaufprüfung
#         dividierte INT64_MIN durch -1. Nur in dieser Argumentreihenfolge.
#   #1495 RotateLeft32 maskierte nicht auf 32 Bit; Bits blieben oberhalb stehen.
#   #1500 ParseHex/Bin/Oct hatten keinen Fehlerkanal und behandelten Störzeichen
#         uneinheitlich: mal Abbruch, mal Überspringen ("12 34" → 4660).
#   #1492 Clamp64 und InRange64 waren in std.stats UND std.math pub — beide
#         Units zusammen ließen sich nicht importieren.
#   #1491 Die Map-Aggregate lasen ein HashMap-Layout, das es nicht gibt, und
#         lieferten immer 0.
#
# GEPRÜFT WIRD DER WEG, nicht nur das Ergebnis: bei #1501 die Übereinstimmung
# von geschriebener Bytezahl und VarIntSize (ein reiner Rundlauftest wäre grün
# gewesen), bei #1500 das ok-Flag (0 ist ein gültiges Ergebnis), bei #1542 der
# Exitcode (SIGFPE = 136).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! timeout 120 "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    echo "FAIL $1: uebersetzt nicht"; FAIL=$((FAIL+1)); return
  fi
  got="$(timeout 20 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then echo "FAIL $1: ABSTURZ rc=$rc"; FAIL=$((FAIL+1)); return; fi
  if [ "$got" = "$3" ]; then echo "PASS $1"; PASS=$((PASS+1))
  else echo "FAIL $1: '$got' erwartet '$3'"; FAIL=$((FAIL+1)); fi
}

# ===========================================================================
# #1501 — VarInt: Größe, Rundlauf und die Ränder
# ===========================================================================

# Geprüft wird beides in einem Durchgang: n == VarIntSize(v) UND der Rundlauf.
# Die Grenzwerte 64, 127 und 8192 zeigten die auseinandergelaufene Größe,
# 2^62, MAX und MIN den Überlauf der Abbildung.
out "#1501: VarIntSize passt zu WriteVarInt, Rundlauf haelt" 'import std.io;
import std.alloc;
import std.pack;
fn probe(v: int64): int64 {
  var b: int64 := alloc(32);
  var n: int64 := WriteVarInt(b, 0, v);
  if (n != VarIntSize(v)) { return 0; }
  if (ReadVarInt(b, 0) != v) { return 0; }
  return 1;
}
fn main(): int64 {
  var gut: int64 := 0;
  var n: int64 := 0;
  gut := gut + probe(0); n := n + 1;
  gut := gut + probe(1); n := n + 1;
  gut := gut + probe(0 - 1); n := n + 1;
  gut := gut + probe(63); n := n + 1;
  gut := gut + probe(0 - 63); n := n + 1;
  gut := gut + probe(64); n := n + 1;
  gut := gut + probe(0 - 64); n := n + 1;
  gut := gut + probe(127); n := n + 1;
  gut := gut + probe(0 - 127); n := n + 1;
  gut := gut + probe(128); n := n + 1;
  gut := gut + probe(8191); n := n + 1;
  gut := gut + probe(8192); n := n + 1;
  gut := gut + probe(0 - 1000); n := n + 1;
  gut := gut + probe(4611686018427387903); n := n + 1;
  gut := gut + probe(4611686018427387904); n := n + 1;
  gut := gut + probe(9223372036854775807); n := n + 1;
  gut := gut + probe(0 - 9223372036854775807 - 1); n := n + 1;
  PrintStr(IntToStr(gut)); PrintStr("/"); PrintLn(IntToStr(n));
  return 0;
}' "17/17"

# Die konkreten Bytezahlen aus der Meldung — hier war VarIntSize je eins zu
# klein, und wer damit allokierte, schrieb über den Puffer hinaus.
out "#1501: Bytezahlen an den Grenzen" 'import std.io;
import std.pack;
fn main(): int64 {
  PrintStr(IntToStr(VarIntSize(63))); PrintStr(" ");
  PrintStr(IntToStr(VarIntSize(64))); PrintStr(" ");
  PrintStr(IntToStr(VarIntSize(127))); PrintStr(" ");
  PrintStr(IntToStr(VarIntSize(8192))); PrintStr(" ");
  PrintStr(IntToStr(VarIntSize(0 - 65))); PrintStr(" ");
  PrintLn(IntToStr(VarIntSize(0 - 1000)));
  return 0;
}' "1 2 2 3 2 2"

# ===========================================================================
# #1542 — SafeMul stirbt nicht mehr an der eigenen Prüfung
# ===========================================================================

# Der Exitcode ist der Nachweis: SIGFPE wäre 136. Ein Test, der nur die
# Ausgabe vergleicht, hätte gar keine bekommen.
out "#1542: SafeMul(-1, INT64_MIN) meldet Ueberlauf statt zu sterben" 'import std.io;
import std.result;
fn main(): int64 {
  var mn: int64 := 0 - 9223372036854775807 - 1;
  var a: ResultInt64 := SafeMul(0 - 1, mn);
  var b: ResultInt64 := SafeMul(mn, 0 - 1);
  PrintStr(BoolToStr(ResultInt64IsErr(a))); PrintStr(" ");
  PrintLn(BoolToStr(ResultInt64IsErr(b)));
  return 0;
}' "true true"

# Gegenprobe: die gewöhnlichen Fälle bleiben, wie sie waren.
out "#1542: gueltige Produkte unveraendert" 'import std.io;
import std.result;
fn main(): int64 {
  var r: ResultInt64 := SafeMul(6, 7);
  var s: ResultInt64 := SafeMul(0 - 6, 7);
  var t: ResultInt64 := SafeMul(4611686018427387904, 4);
  PrintStr(IntToStr(ResultInt64Unwrap(r))); PrintStr(" ");
  PrintStr(IntToStr(ResultInt64Unwrap(s))); PrintStr(" ");
  PrintLn(BoolToStr(ResultInt64IsErr(t)));
  return 0;
}' "42 -42 true"

# ===========================================================================
# #1495 — 32-Bit-Rotation
# ===========================================================================

out "#1495: RotateLeft32 bleibt im 32-Bit-Bereich" 'import std.io;
import std.conv;
fn main(): int64 {
  PrintStr(IntToStr(RotateLeft32(2147483648, 1))); PrintStr(" ");
  PrintStr(IntToStr(RotateLeft32(4294967295, 4))); PrintStr(" ");
  PrintLn(IntToStr(RotateLeft32(305419896, 8)));
  return 0;
}' "1 4294967295 878082066"

# Rundlauf: links dann rechts um denselben Betrag ergibt den Ausgangswert.
# Faellt eine der beiden Richtungen aus dem Bereich, stimmt er nicht mehr.
out "#1495: Rundlauf und Randfaelle" 'import std.io;
import std.conv;
fn main(): int64 {
  PrintStr(IntToStr(RotateRight32(RotateLeft32(305419896, 7), 7))); PrintStr(" ");
  PrintStr(IntToStr(RotateLeft32(305419896, 0))); PrintStr(" ");
  PrintStr(IntToStr(RotateLeft32(305419896, 32))); PrintStr(" ");
  PrintLn(IntToStr(RotateRight32(305419896, 8)));
  return 0;
}' "305419896 305419896 305419896 2014458966"

# ===========================================================================
# #1500 — Parser mit Fehlerkanal
# ===========================================================================

out "#1500: Stoerzeichen melden Misserfolg" 'import std.io;
import std.alloc;
import std.conv;
fn Z(t: pchar): void {
  var ok: int64 := alloc(8);
  var v: int64 := ParseHexEx(t, ok);
  PrintStr(IntToStr(v)); PrintStr("/"); PrintLn(IntToStr(peek64(ok)));
}
fn main(): int64 {
  Z("FFxy"c); Z("12 34"c); Z("-FF"c); Z("ZZ"c);
  return 0;
}' "0/0
0/0
0/0
0/0"

# Die gültige Null muss von der fehlgeschlagenen Umwandlung unterscheidbar
# sein — vor dem Fix lieferten "0" und "ZZ" beide 0 ohne jeden Unterschied.
out "#1500: gueltige Null ist unterscheidbar" 'import std.io;
import std.alloc;
import std.conv;
fn main(): int64 {
  var ok: int64 := alloc(8);
  var a: int64 := ParseHexEx("0"c, ok);
  var okA: int64 := peek64(ok);
  var b: int64 := ParseHexEx("ZZ"c, ok);
  var okB: int64 := peek64(ok);
  PrintStr(IntToStr(a)); PrintStr("/"); PrintStr(IntToStr(okA)); PrintStr(" ");
  PrintStr(IntToStr(b)); PrintStr("/"); PrintLn(IntToStr(okB));
  return 0;
}' "0/1 0/0"

out "#1500: Praefixe und alle drei Basen" 'import std.io;
import std.conv;
fn main(): int64 {
  PrintStr(IntToStr(ParseHex("FF"c))); PrintStr(" ");
  PrintStr(IntToStr(ParseHex("0xFF"c))); PrintStr(" ");
  PrintStr(IntToStr(ParseHex("0X1A"c))); PrintStr(" ");
  PrintStr(IntToStr(ParseBin("1010"c))); PrintStr(" ");
  PrintStr(IntToStr(ParseBin("0b1101"c))); PrintStr(" ");
  PrintStr(IntToStr(ParseOct("777"c))); PrintStr(" ");
  PrintLn(IntToStr(ParseOct("0o17"c)));
  return 0;
}' "255 255 26 10 13 511 15"

# Basisfremde Ziffern: die 8 im Oktalwert und Buchstaben im Binaerwert waren
# vorher ein stiller Abbruch mit Teilergebnis (511 bzw. 10).
out "#1500: basisfremde Ziffern melden Misserfolg" 'import std.io;
import std.alloc;
import std.conv;
fn main(): int64 {
  var ok: int64 := alloc(8);
  var a: int64 := ParseOctEx("7778"c, ok); var okA: int64 := peek64(ok);
  var b: int64 := ParseBinEx("1010abc"c, ok); var okB: int64 := peek64(ok);
  PrintStr(IntToStr(a)); PrintStr("/"); PrintStr(IntToStr(okA)); PrintStr(" ");
  PrintStr(IntToStr(b)); PrintStr("/"); PrintLn(IntToStr(okB));
  return 0;
}' "0/0 0/0"

# Die Rundläufe aus der Meldung sind ausdrücklich als korrekt vermerkt und
# müssen es bleiben.
out "#1500: Rundlaeufe unveraendert" 'import std.io;
import std.conv;
fn main(): int64 {
  PrintStr(IntToStr(ParseHex(IntToHex32(305419896)))); PrintStr(" ");
  PrintLn(IntToStr(ParseBin(IntToBin16(4660))));
  return 0;
}' "305419896 4660"

# ===========================================================================
# #1492 — std.stats und std.math zusammen
# ===========================================================================

out "#1492: beide Units gemeinsam importierbar" 'import std.io;
import std.stats;
import std.math;
fn main(): int64 {
  PrintStr(IntToStr(Clamp64(150, 0, 100))); PrintStr(" ");
  PrintStr(BoolToStr(InRange64(5, 0, 10))); PrintStr(" ");
  PrintLn(IntToStr(IntSqrt(144)));
  return 0;
}' "100 true 12"

# Gegenprobe: std.stats allein bleibt brauchbar — die beiden Funktionen sind
# dort nur nicht mehr exportiert, die Unit selbst arbeitet weiter mit ihnen.
out "#1492: std.stats allein unveraendert" 'import std.io;
import std.stats;
import std.alloc;
fn main(): int64 {
  var a: int64 := alloc(24);
  poke64(a, 3); poke64(a + 8, 9); poke64(a + 16, 6);
  PrintStr(IntToStr(ArraySum(a, 3))); PrintStr(" ");
  PrintStr(IntToStr(ArrayMax(a, 3))); PrintStr(" ");
  PrintLn(IntToStr(Percentage64(25, 200)));
  return 0;
}' "18 9 12"

# ===========================================================================
# #1491 — Map-Aggregate
# ===========================================================================

out "#1491: Map-Aggregate lesen den Inhalt" 'import std.io;
import std.stats;
fn main(): int64 {
  var m: Map<pchar, int64> := {};
  m["a"] := 10; m["b"] := 25; m["c"] := 5; m["d"] := 60;
  PrintStr(IntToStr(MapCount(m as int64))); PrintStr(" ");
  PrintStr(IntToStr(MapSum(m as int64))); PrintStr(" ");
  PrintStr(IntToStr(MapMin(m as int64))); PrintStr(" ");
  PrintStr(IntToStr(MapMax(m as int64))); PrintStr(" ");
  PrintLn(IntToStr(MapAvg(m as int64)));
  return 0;
}' "4 100 5 60 25"

# Der Sonderfall: bei Map<int64,V> ist der Schluessel 0 gueltig, ein leerer
# Bucket sieht aber genauso aus. Der Eintrag (0 -> 0) darf deshalb nicht
# verschwinden — Count kommt aus length, Min traegt die fehlende 0 nach.
out "#1491: Ganzzahlschluessel 0 geht nicht verloren" 'import std.io;
import std.stats;
fn main(): int64 {
  var n: Map<int64, int64> := {};
  n[0] := 0; n[5] := 50; n[7] := 20;
  PrintStr(IntToStr(MapCount(n as int64))); PrintStr(" ");
  PrintStr(IntToStr(MapSum(n as int64))); PrintStr(" ");
  PrintStr(IntToStr(MapMin(n as int64))); PrintStr(" ");
  PrintLn(IntToStr(MapMax(n as int64)));
  return 0;
}' "3 70 0 50"

# Leere Map: kein Absturz, keine Division durch null.
out "#1491: leere Map" 'import std.io;
import std.stats;
fn main(): int64 {
  var m: Map<pchar, int64> := {};
  PrintStr(IntToStr(MapCount(m as int64))); PrintStr(" ");
  PrintStr(IntToStr(MapSum(m as int64))); PrintStr(" ");
  PrintStr(IntToStr(MapAvg(m as int64))); PrintStr(" ");
  PrintLn(IntToStr(MapMin(m as int64)));
  return 0;
}' "0 0 0 0"

# Nullzeiger statt Map — die Funktionen nehmen int64 entgegen, also ist das
# erreichbar und darf nicht abstuerzen.
out "#1491: Nullzeiger" 'import std.io;
import std.stats;
fn main(): int64 {
  PrintStr(IntToStr(MapCount(0))); PrintStr(" ");
  PrintStr(IntToStr(MapSum(0))); PrintStr(" ");
  PrintLn(IntToStr(MapAvg(0)));
  return 0;
}' "0 0 0"

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
