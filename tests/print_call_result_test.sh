#!/usr/bin/env bash
# tests/print_call_result_test.sh — Print/PrintLn mit dem Ergebnis eines
# Aufrufs (Issue #1058).
#
# `cg_inferPrintType` kannte Literale und Bezeichner, aber keine Aufrufknoten.
# Ein `CGN_CALL` fiel auf „Ganzzahl", weshalb `PrintLn(StrFromInt(42))` den
# ZEIGER ausgab: `x = 133882772930580`. Über eine Zwischenvariable war dieselbe
# Rechnung korrekt — ein Hinweis darauf, dass nicht die Funktion falsch ist,
# sondern die Typbestimmung der Ausdrucksform.
#
# Geprüft wird der ausgegebene WERT, dazu die Gegenrichtung: eine Funktion mit
# int64-Rückgabe muss weiterhin als Zahl ausgegeben werden. Ohne diese
# Gegenprobe wäre eine zu breite Regel („jeder Aufruf liefert eine Zeichenkette")
# unbemerkt geblieben.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    echo "FAIL $1: uebersetzt nicht"; FAIL=$((FAIL+1)); return
  fi
  got="$(timeout 5 "$TMP/c" 2>&1)"
  if [ "$got" = "$3" ]; then echo "PASS $1"; PASS=$((PASS+1))
  else echo "FAIL $1: '$got' erwartet '$3'"; FAIL=$((FAIL+1)); fi
}

out "StrFromInt (Repro aus dem Issue)" 'import std.io;
fn main(): int64 { Print("x = "); PrintLn(StrFromInt(42)); return 0; }' 'x = 42'

out "StrConcat" 'import std.io;
fn main(): int64 { PrintLn(StrConcat("ab"c, "cd"c)); return 0; }' 'abcd'

out "FloatToStr" 'import std.io;
fn main(): int64 { var f: f64 := 1.5; PrintLn(FloatToStr(f)); return 0; }' '1.500000'

out "Benutzerfunktion mit pchar-Rueckgabe" 'import std.io;
fn name(): pchar { return "Lyx"c; }
fn main(): int64 { PrintLn(name()); return 0; }' 'Lyx'

# Gegenprobe: die Regel darf nicht auf jeden Aufruf greifen.
out "Benutzerfunktion mit int64 bleibt Zahl" 'import std.io;
fn n(): int64 { return 42; }
fn main(): int64 { PrintLn(n()); return 0; }' '42'

# Der Weg über eine Zwischenvariable war schon vorher richtig und muss es
# bleiben — beide Wege müssen dasselbe ergeben.
out "Zwischenvariable liefert dasselbe" 'import std.io;
fn main(): int64 {
  var s: pchar := StrFromInt(42);
  PrintLn(s);
  PrintLn(StrFromInt(42));
  return 0; }' '42
42'

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
