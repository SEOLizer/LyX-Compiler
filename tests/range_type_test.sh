#!/usr/bin/env bash
# tests/range_type_test.sh — #1082: Bereichstypen.
#
# Zwei Befunde lagen zusammen:
#
#   1. Die in ebnf.md §7 (RangeTypeDef) und in der Dokumentation verwendete
#      Form `type X = int64 range 0..100;` parste nicht.
#   2. `type X = int64[0..100];` übersetzte fehlerfrei und liess Werte
#      ausserhalb des Bereichs kommentarlos durch. Das war kein Bereichstyp,
#      sondern ein Array fester Grösse, dessen „Grösse" ein Bereichsausdruck
#      war — der Bereich wurde geparst und verworfen.
#
# Punkt 2 ist der gefährlichere: ein Typ, der eine Zusicherung verspricht und
# sie stillschweigend nicht einhält, ist schlechter als gar kein Bereichstyp.
# Er wird deshalb jetzt ABGELEHNT, nicht repariert — ein Bereich ist keine
# Arraygrösse.
#
# Geprüft wird beides, und zwar in beide Richtungen: gültige Werte müssen
# durchgehen (sonst wäre eine zu strenge Regel unbemerkt), ungültige müssen
# gemeldet werden.
#
# NICHT abgedeckt und bewusst nicht behauptet: Laufzeitprüfung berechneter
# Werte sowie Parameter, Rückgaben und Strukturfelder. Siehe den Kopf von
# ebnf.md §20.1 und das Folge-Issue.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

runs() { # name, quelltext, erwarteter exit
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    echo "FAIL $1: uebersetzt nicht"; FAIL=$((FAIL+1)); return
  fi
  timeout 10 "$TMP/c" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq "$3" ]; then echo "PASS $1"; PASS=$((PASS+1))
  else echo "FAIL $1: exit=$rc erwartet $3"; FAIL=$((FAIL+1)); fi
}

rejects() { # name, quelltext, erwartete meldung
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  got=$("$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)
  if echo "$got" | grep -q "$3"; then echo "PASS $1 (abgewiesen)"; PASS=$((PASS+1))
  else echo "FAIL $1: nicht abgewiesen — '$(echo "$got" | tail -1)'"; FAIL=$((FAIL+1)); fi
}

# --- Die dokumentierte Syntax übersetzt ----------------------------------
runs "Repro 1: dokumentierte Syntax" 'type Altitude = int64 range -1000..60000;
type Speed    = int64 range 0..300;
fn main(): int64 { return 0; }' 0

runs "Wert im Bereich" 'type Alt = int64 range 0..100;
fn main(): int64 { var a: Alt := 50; return a; }' 50

runs "Grenzen sind eingeschlossen" 'type Alt = int64 range 0..100;
fn main(): int64 { var a: Alt := 0; var b: Alt := 100; return a + b; }' 100

runs "negativer Bereich" 'type S = int64 range -100..-10;
fn main(): int64 { var a: S := 0 - 50; return 0; }' 0

# --- Werte ausserhalb des Bereichs werden gemeldet -----------------------
rejects "Repro 2: Initialisierung ueber der Grenze" 'type Alt = int64 range 0..100;
fn main(): int64 { var a: Alt := 500; return 0; }' "ausserhalb des Bereichs"

rejects "Initialisierung unter der Grenze" 'type Alt = int64 range 0..100;
fn main(): int64 { var a: Alt := 0 - 7; return 0; }' "ausserhalb des Bereichs"

rejects "Zuweisung ausserhalb des Bereichs" 'type Alt = int64 range 0..100;
fn main(): int64 { var a: Alt := 50; a := 500; return 0; }' "ausserhalb des Bereichs"

rejects "negativer Bereich, Wert daneben" 'type S = int64 range -100..-10;
fn main(): int64 { var a: S := 0 - 5; return 0; }' "ausserhalb des Bereichs"

# Konstanten zählen als konstanter Wert.
rejects "con-Wert ausserhalb des Bereichs" 'con LIMIT: int64 := 500;
type Alt = int64 range 0..100;
fn main(): int64 { var a: Alt := LIMIT; return 0; }' "ausserhalb des Bereichs"

# --- Der stille Fall wird abgelehnt --------------------------------------
rejects "Bereich als Arraygroesse" 'type Alt = int64[0..100];
fn main(): int64 { var a: Alt := 500; return 0; }' "Bereich ist keine Arraygroesse"

rejects "Bereich als Arraygroesse, Praefixform" 'fn main(): int64 { var a: [0..100]int64; return 0; }' "Bereich ist keine Arraygroesse"

# --- Gegenproben: nichts Bestehendes darf brechen ------------------------
runs "Array fester Groesse bleibt gueltig" 'fn main(): int64 {
  var a: int64[4];
  a[0] := 42;
  return a[0];
}' 42

runs "schlichter Typ-Alias bleibt gueltig" 'type Zahl = int64;
fn main(): int64 { var a: Zahl := 500; return 0; }' 0

# `range` bleibt als Bezeichner benutzbar — es ist ein weiches Schluesselwort.
runs "range bleibt als Bezeichner nutzbar" 'fn main(): int64 {
  var range: int64 := 7;
  return range;
}' 7

runs "for i in range() unveraendert" 'import std.io;
fn main(): int64 {
  var s: int64 := 0;
  for i in range(4) { s := s + i; }
  return s;
}' 6

rejects "Bereichsgrenze muss Literal sein" 'con LO: int64 := 0;
type Alt = int64 range LO..100;
fn main(): int64 { return 0; }' "Bereichsgrenze muss ein Ganzzahlliteral sein"

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
