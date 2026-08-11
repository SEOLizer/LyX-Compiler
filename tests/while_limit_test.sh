#!/usr/bin/env bash
# tests/while_limit_test.sh — #1103: `while (c) limit(N) { ... }`.
#
# Die Produktion steht in ebnf.md §12 (WhileStmt), der Parser wies sie ab:
# „expected {, got IDENT 'limit'". Zugleich hält §2.1 fest, dass `limit` KEIN
# reserviertes Wort ist — beides zusammen machte die Produktion unerfüllbar.
#
# Auflösung: `limit` ist ein WEICHES Schlüsselwort. Es zählt nur unmittelbar
# hinter der Bedingung und vor dem Block, gefolgt von einer Klammer; überall
# sonst bleibt es ein gewöhnlicher Bezeichner. Damit stimmen §12 und §2.1
# wieder überein — und genau das prüft dieser Test in beide Richtungen.
#
# Die Schranke wird DURCHGESETZT, nicht bloß vermerkt: sie ist in der
# Dokumentation das Mittel, um die Endlichkeit einer Schleife zuzusichern.
# Ein Vermerk, den niemand prüft, sagt darüber nichts aus (die Lehre aus
# #1099). Gemessen wird deshalb die Ausführung: die Schleife, die über die
# Schranke liefe, muss abbrechen.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    echo "FAIL $1: uebersetzt nicht"; FAIL=$((FAIL+1)); return
  fi
  got="$(timeout 10 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -ge 124 ]; then echo "FAIL $1: Abbruch/Endlosschleife (rc=$rc)"; FAIL=$((FAIL+1)); return; fi
  if [ "$got" = "$3" ]; then echo "PASS $1"; PASS=$((PASS+1))
  else echo "FAIL $1: '$got' erwartet '$3'"; FAIL=$((FAIL+1)); fi
}

panics() { # name, quelltext
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    echo "FAIL $1: uebersetzt nicht"; FAIL=$((FAIL+1)); return
  fi
  got="$(timeout 10 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then echo "FAIL $1: laeuft durch — die Schranke traegt nicht"; FAIL=$((FAIL+1)); return; fi
  if echo "$got" | grep -q "nie"; then echo "FAIL $1: rechnet nach der Schranke weiter"; FAIL=$((FAIL+1)); return; fi
  if echo "$got" | grep -q "Schleifenschranke"; then echo "PASS $1 (bricht ab)"; PASS=$((PASS+1))
  else echo "FAIL $1: bricht ab, aber ohne Schrankenmeldung — '$(echo "$got"|tail -1)'"; FAIL=$((FAIL+1)); fi
}

rejects() { # name, quelltext, erwartete meldung
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  got=$("$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)
  if echo "$got" | grep -q "$3"; then echo "PASS $1 (abgewiesen)"; PASS=$((PASS+1))
  else echo "FAIL $1: nicht abgewiesen — '$(echo "$got" | tail -1)'"; FAIL=$((FAIL+1)); fi
}

# --- Der Repro aus dem Issue ---------------------------------------------
out "Repro: while mit limit uebersetzt und laeuft" 'import std.io;
fn main(): int64 {
    var i: int64 := 0;
    while (i < 3) limit(10) { i := i + 1; }
    PrintLn(IntToStr(i));
    return 0;
}' '3'

# --- Die Schranke wird durchgesetzt --------------------------------------
panics "Schleife ueber der Schranke bricht ab" 'import std.io;
fn main(): int64 {
    var j: int64 := 0;
    while (j < 100) limit(5) { j := j + 1; }
    PrintLn("nie");
    return 0;
}'

# Die Schranke zaehlt DURCHLAEUFE und ist einschliesslich: genau N sind
# erlaubt, N+1 nicht. Ohne dieses Paar bliebe der Randfall offen.
out "genau N Durchlaeufe sind erlaubt" 'import std.io;
fn main(): int64 {
    var i: int64 := 0;
    while (i < 5) limit(5) { i := i + 1; }
    PrintLn(IntToStr(i));
    return 0;
}' '5'

panics "N+1 Durchlaeufe brechen ab" 'import std.io;
fn main(): int64 {
    var i: int64 := 0;
    while (i < 6) limit(5) { i := i + 1; }
    PrintLn("nie");
    return 0;
}'

# Der eigentliche Zweck: eine Schleife, die sonst NICHT endet, endet.
panics "Endlosschleife endet an der Schranke" 'import std.io;
fn main(): int64 {
    var i: int64 := 0;
    while (i >= 0) limit(1000) { i := i + 1; }
    PrintLn("nie");
    return 0;
}'

# --- Zaehler je Schleife und je Eintritt ---------------------------------
# Die innere Schranke muss bei jedem Eintritt neu zaehlen, sonst waere sie
# nach dem ersten Durchlauf der aeusseren Schleife verbraucht.
out "innere Schranke zaehlt je Eintritt neu" 'import std.io;
fn main(): int64 {
    var o: int64 := 0;
    var s: int64 := 0;
    while (o < 3) limit(3) {
        var inn: int64 := 0;
        while (inn < 2) limit(2) { inn := inn + 1; s := s + 1; }
        o := o + 1;
    }
    PrintLn(IntToStr(s));
    return 0;
}' '6'

# --- Zusammenspiel mit break, continue und Ausrollen ---------------------
out "break unveraendert" 'import std.io;
fn main(): int64 {
    var b: int64 := 0;
    while (b < 100) limit(50) { b := b + 1; if (b == 4) { break; } }
    PrintLn(IntToStr(b));
    return 0;
}' '4'

out "continue unveraendert" 'import std.io;
fn main(): int64 {
    var c: int64 := 0;
    var t: int64 := 0;
    while (c < 6) limit(6) { c := c + 1; if (c == 2) { continue; } t := t + 1; }
    PrintLn(IntToStr(t));
    return 0;
}' '5'

# Beim Ausrollen (@energy) wird der Rumpf mehrfach erzeugt. Jede Kopie ist ein
# Durchlauf — zaehlte nur eine, waere die Schranke um den Ausrollfaktor zu
# grosszuegig.
out "Ausrollen zaehlt jeden Durchlauf" 'import std.io;
@energy(5)
fn Lauf(): int64 {
    var i: int64 := 0;
    var s: int64 := 0;
    while (i < 8) limit(8) { i := i + 1; s := s + i; }
    return s;
}
fn main(): int64 {
    PrintLn(IntToStr(Lauf()));
    return 0;
}' '36'

panics "Ausrollen bricht an der Schranke ab" 'import std.io;
@energy(5)
fn Lauf(): int64 {
    var i: int64 := 0;
    while (i < 20) limit(8) { i := i + 1; }
    return i;
}
fn main(): int64 {
    PrintLn(IntToStr(Lauf()));
    PrintLn("nie");
    return 0;
}'

# --- Die Schranke muss konstant sein -------------------------------------
out "con als Schranke" 'import std.io;
con MAX: int64 := 4;
fn main(): int64 {
    var k: int64 := 0;
    while (k < 3) limit(MAX) { k := k + 1; }
    PrintLn(IntToStr(k));
    return 0;
}' '3'

rejects "berechnete Schranke wird abgewiesen" 'import std.io;
fn n(): int64 { return 5; }
fn main(): int64 {
    var k: int64 := 0;
    while (k < 3) limit(n()) { k := k + 1; }
    return 0;
}' "limit(N) verlangt eine Konstante"

# --- `limit` bleibt ein gewoehnlicher Bezeichner -------------------------
# §2.1 fuehrt limit ausdruecklich als NICHT reserviert. Ohne diese Proben
# waere die Umsetzung als hartes Schluesselwort unbemerkt geblieben — und
# haette den Bestand gebrochen.
out "limit als Funktionsname und Variablenpraefix" 'import std.io;
fn limit(a: int64): int64 { return a + 1; }
fn main(): int64 {
    var limit_var: int64 := 7;
    PrintLn(IntToStr(limit(1) + limit_var));
    return 0;
}' '9'

out "limit als Variablenname" 'import std.io;
fn main(): int64 {
    var limit: int64 := 12;
    PrintLn(IntToStr(limit));
    return 0;
}' '12'

# --- repeat/until fuehrt limit nicht (ebnf.md §12) -----------------------
# Vorher stand `limit` dort in Ausdrucksposition und die Meldung lautete
# „undefined function 'limit'" — sie nannte die Ursache nicht.
rejects "limit an repeat/until nennt den Grund" 'import std.io;
fn main(): int64 {
    var i: int64 := 0;
    repeat { i := i + 1; } until (i > 3) limit(10);
    return 0;
}' "gibt es nur an while"

# --- Gegenprobe: while ohne limit unveraendert ---------------------------
out "while ohne limit unveraendert" 'import std.io;
fn main(): int64 {
    var i: int64 := 0;
    while (i < 1000) { i := i + 1; }
    PrintLn(IntToStr(i));
    return 0;
}' '1000'

out "repeat/until ohne limit unveraendert" 'import std.io;
fn main(): int64 {
    var i: int64 := 0;
    repeat { i := i + 1; } until (i > 3);
    PrintLn(IntToStr(i));
    return 0;
}' '4'

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
