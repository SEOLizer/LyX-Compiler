#!/usr/bin/env bash
# tests/locals_merker_2316_test.sh — #2316: Merker fuer cg_findLocalIdx.
#
# Der Merker beantwortet eine Namenssuche aus der letzten Antwort, wenn Name,
# Tabelle, Anzahl, Untergrenze und Generation uebereinstimmen.
#
# WAS DIESER TEST IST: eine Klammer um das Verhalten bei Verdeckung und beim
# Abschneiden von Gueltigkeitsbereichen. Geprueft werden WERTE, nicht
# Uebersetzbarkeit — jeder Fall rechnet ein Ergebnis aus, das nur stimmt, wenn
# der richtige Slot gelesen wurde. Die Erwartungswerte sind von Hand
# gegengerechnet und je Fall hergeleitet.
#
# WAS DIESER TEST NICHT IST: ein Nachweis, dass die GENERATION im Schluessel
# noetig ist. Das wurde ausprobiert: mit einer Fassung ohne
# `localGen == flGen` bleiben alle fuenf Faelle gruen, der Selbstbau erzeugt
# BITGLEICH dasselbe Erzeugnis, und der Beispiel-Sweep ist unveraendert. Der
# gefaehrliche Fall braucht dieselbe NAMENSSTELLE unter zwei Fenstern mit
# gleicher Anzahl und verschiedenem Inhalt; er liess sich nicht herstellen.
#
# Die Generation bleibt trotzdem im Schluessel: sie kostet einen Vergleich,
# und der Fehlerfall waere ein STILL falscher Slot — die Art Defekt, die #1966
# teuer gemacht hat. Wer sie entfernt, hat damit keinen roten Test, sondern
# nur kein Netz; diesen Absatz dann mitlesen.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ulimit -c 0
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

lauf() {   # name quelle erwartet
  local nm="$1" src="$2" erw="$3"
  printf '%s' "$src" > "$TMP/t.lyx"
  if ! (cd "$TMP" && timeout 120 "$LYXC" --std-path="$ROOT" "$TMP/t.lyx" -o "$TMP/t" >"$TMP/b.log" 2>&1); then
    no "$nm" "uebersetzt nicht: $(grep -v Copyright "$TMP/b.log" | grep -m1 -iE 'error|lyxc:')"
    return
  fi
  local ist
  ist=$( cd "$TMP" && timeout 30 ./t 2>&1 )
  if [ "$ist" = "$erw" ]; then ok "$nm: $ist"; else no "$nm" "'$ist' erwartet '$erw'"; fi
}

# 1. Zwei GESCHWISTERBEREICHE, gleiche Slotzahl, verschiedene Namen.
#    Nach dem ersten Block wird abgeschnitten; `b` landet auf dem Platz von
#    `a`. Wer den Merker ohne Generation fragt, bekommt fuer `b` den Slot von
#    `a` — und damit 11 statt 22.
#    Erwartet: 11 und 22, Summe 33.
lauf "geschwisterbereiche" 'unit main;
import std.io;
fn main(): int64 {
  var s: int64 := 0;
  if (1 == 1) { var a: int64 := 11; s := s + a; }
  if (1 == 1) { var b: int64 := 22; s := s + b; }
  PrintInt(s); PrintStr("\n");
  return 0;
}
' '33'

# 2. VERDECKUNG: ein innerer gleichnamiger Local verdeckt den aeusseren.
#    Der innere gewinnt INNEN (7), nach dem Block gilt wieder der aeussere (3).
#    Erwartet: 7 und 3 -> "7 3".
lauf "verdeckung" 'unit main;
import std.io;
fn main(): int64 {
  var x: int64 := 3;
  if (1 == 1) { var x: int64 := 7; PrintInt(x); PrintStr(" "); }
  PrintInt(x); PrintStr("\n");
  return 0;
}
' '7 3'

# 3. DERSELBE NAME in zwei Schleifen. Jede Schleife legt ihr `i` neu an; die
#    Namensstelle im Quelltext ist je Schleife eine andere, der Rumpf wird aber
#    mehrfach durchlaufen. Summen: 0+1+2 = 3 und 0+1+2+3 = 6 -> "3 6".
lauf "zwei schleifen gleicher name" 'unit main;
import std.io;
fn main(): int64 {
  var s1: int64 := 0;
  var i: int64 := 0;
  while (i < 3) { s1 := s1 + i; i := i + 1; }
  var s2: int64 := 0;
  var j: int64 := 0;
  while (j < 4) { s2 := s2 + j; j := j + 1; }
  PrintInt(s1); PrintStr(" "); PrintInt(s2); PrintStr("\n");
  return 0;
}
' '3 6'

# 4. Abgeschnitten und NEU ANGELEGT, dazwischen gelesen: der aeussere Wert
#    darf nicht vom inneren ueberschrieben erscheinen.
#    a = 5; Block legt c = 100 an (Platz wie a+1), danach a weiter 5.
#    Erwartet: 100 und 5 -> "100 5".
lauf "abschneiden und neu anlegen" 'unit main;
import std.io;
fn main(): int64 {
  var a: int64 := 5;
  if (1 == 1) { var c: int64 := 100; PrintInt(c); PrintStr(" "); }
  if (1 == 1) { var d: int64 := 200; }
  PrintInt(a); PrintStr("\n");
  return 0;
}
' '100 5'

# 5. Gegenseite zum Merker: ZWEI Namen abwechselnd gefragt. Ein Merker mit nur
#    einem Platz muss dabei jedes Mal neu suchen und darf nicht die Antwort des
#    anderen Namens liefern. p=2, q=3 -> 2+3+2+3 = 10.
lauf "abwechselnde namen" 'unit main;
import std.io;
fn main(): int64 {
  var p: int64 := 2;
  var q: int64 := 3;
  var s: int64 := p + q + p + q;
  PrintInt(s); PrintStr("\n");
  return 0;
}
' '10'

echo "=== PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
