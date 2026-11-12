#!/usr/bin/env bash
# tests/builtin_dispatch_test.sh — #1308, #1316 und #1311.
#
# Zwei Luecken in der Auswahl, welcher Code fuer einen Aufruf erzeugt wird.
#
# #1308/#1316: `PrintLn(x as pchar)` druckte die ADRESSE. cg_inferPrintType
#   kannte Literale, Aufrufe, Verkettungen und Bezeichner — aber keinen
#   Cast-Knoten; der fiel bis zum abschliessenden `return 0` durch und galt als
#   Ganzzahl. Ueber eine Zwischenvariable ging es, weil dort der deklarierte Typ
#   gelesen wird. Genau derselbe Riss wie bei cg_isF64Expr in #905.
#
# #1311: Sieben Namen existieren sowohl als Builtin als auch als `pub fn` in
#   std/ — ArgvGetStr, FileSize, FloatToStr, Print, StrFind, StrSplit, StrTrim.
#   Der Builtin gewann IMMER, unabhaengig von der Argumentzahl; ueberzaehlige
#   Argumente verpufften und die Unit-Funktion war unerreichbar. Belegt im
#   eigenen Bestand: tests/feature_checks/strings/test_stringbuilder.lyx ruft
#   die Vier-Argument-Form von StrSplit, tests/feature_checks/stdlib/
#   test_filereadall.lyx die Drei-Argument-Form von ArgvGetStr — beide liefen
#   still falsch.
#
# Geprueft wird in beide Richtungen: die bisher falsche Form MUSS jetzt
# stimmen, und die Builtin-Form MUSS unveraendert bleiben. Ein Test nur auf die
# erste Haelfte waere auch dann gruen, wenn der Builtin ganz verschwunden waere.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    no "$1" "uebersetzt nicht"; return
  fi
  got="$(timeout 30 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then no "$1" "ABSTURZ (rc=$rc)"; return; fi
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1" "'$got' erwartet '$3'"; fi
}

# ===========================================================================
# #1308 / #1316 — der Cast in der Print-Auswahl
# ===========================================================================

out "Print und PrintLn nehmen den Cast an" 'import std.io;
fn main(): int64 {
  var buf: int64 := alloc(16);
  poke8(buf, 65); poke8(buf + 1, 66); poke8(buf + 2, 0);
  PrintLn(buf as pchar);
  Print(buf as pchar); PrintLn("");
  var p: pchar := buf as pchar;
  PrintLn(p);
  return 0;
}' "AB
AB
AB"

# Gegenprobe: ein Cast nach int64 muss weiterhin die Zahl drucken — sonst waere
# aus der Luecke eine neue in der Gegenrichtung geworden.
out "Cast nach int64 druckt weiterhin die Zahl" 'import std.io;
fn main(): int64 {
  var p: pchar := "AB"c;
  var n: int64 := 42;
  PrintLn(n as int64);
  PrintLn(IntToStr(StrLen(p)));
  return 0;
}' "42
2"

out "Cast nach f64 und bool" 'import std.io;
fn main(): int64 {
  var i: int64 := 3;
  PrintLn(i as f64);
  var t: bool := true;
  PrintLn(t as bool);
  return 0;
}' "3.000000
true"

# ===========================================================================
# #1311 — Argumentzahl entscheidet, welche Funktion gemeint ist
# ===========================================================================

out "StrSplit: beide Formen liefern ihr eigenes Ergebnis" 'import std.io;
import std.string;
fn main(): int64 {
  var parts: int64 := alloc(256);
  PrintLn(IntToStr(StrSplit("a,b,c"c, ","c, parts, 8)));
  var p0: pchar := peek64(parts) as pchar;
  PrintLn(p0);
  var p1: pchar := peek64(parts + 8) as pchar;
  PrintLn(p1);
  var arr: pchar[] := StrSplit("x,y"c, ","c);
  PrintLn(IntToStr(len(arr)));
  return 0;
}' "3
a
b
2"

out "FloatToStr: prec wirkt, die Builtin-Form bleibt" 'import std.io;
fn main(): int64 {
  PrintLn(FloatToStr(3.5, 2));
  PrintLn(FloatToStr(3.25, 3));
  PrintLn(FloatToStr(3.5));
  return 0;
}' "3.50
3.250
3.500000"

# Der Bestand, der bisher still falsch lief — beide Aufrufstellen stammen aus
# tests/feature_checks/ und sind der Beleg dafuer, dass die Verdeckung nicht
# theoretisch war.
out "die Vier-Argument-Form aus dem Bestand liefert die Teile" 'import std.io;
import std.string;
fn main(): int64 {
  var s: pchar := "eins,zwei,drei"c;
  var parts: int64 := alloc(256);
  var n: int64 := StrSplit(s, ","c, parts, 10);
  PrintLn(IntToStr(n));
  var i: int64 := 0;
  while (i < n) {
    var pi: pchar := peek64(parts + i * 8) as pchar;
    PrintLn(pi);
    i := i + 1;
  }
  return 0;
}' "3
eins
zwei
drei"

# ===========================================================================
# Gegenprobe: die uebrigen betroffenen Namen in ihrer Builtin-Form
# ===========================================================================
# Ohne diese Probe koennte die Weiche zu weit greifen und Aufrufe, die den
# Builtin meinen, an eine Unit-Funktion schicken.

out "StrFind und StrTrim in der Builtin-Form unveraendert" 'import std.io;
fn main(): int64 {
  PrintLn(IntToStr(StrFind("hello world"c, "world"c)));
  PrintLn(StrTrim("  hallo  "c));
  return 0;
}' "6
hallo"

echo
echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
