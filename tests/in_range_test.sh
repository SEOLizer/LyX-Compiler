#!/usr/bin/env bash
# tests/in_range_test.sh — #1129: `x in a..b` und `for i in a..b`.
#
# `if (i in 0..3)` uebersetzte und stuerzte zur Laufzeit ab (SIGSEGV). Ursache:
# JEDES `in` lief in den Woerterbuch-Zweig. `_lyx_map_has` bekam als "Map" das,
# was der Bereichsknoten hinterliess — kein Zeiger, sondern die obere Grenze,
# waehrend die untere unbalanciert auf dem Stack liegen blieb.
#
# `for i in 0..3` wies der Parser ab ("expected :=, got in"), obwohl `in` und
# `..` als Ausdruck beide existieren.
#
# Beides ist jetzt umgesetzt: der Bereichstest vergleicht EINSCHLIESSLICH
# beider Grenzen (wie das Bereichsmuster in `match` und der Bereichstyp), die
# Schleifenform laeuft auf dieselbe Schleife wie `for i := a to b`.
#
# ACHTUNG bei den Erwartungswerten: `in a..b` schliesst b EIN, `in range(a, b)`
# schliesst b AUS. Die beiden Formen sind nicht dasselbe, und der Test haelt
# genau das fest.
#
# Geprueft wird das Verhalten zur Laufzeit. Ein Test auf Uebersetzbarkeit waere
# fuer den Ausdruck immer gruen gewesen — er uebersetzte ja und stuerzte erst
# beim Laufen ab.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    echo "FAIL $1: uebersetzt nicht"; FAIL=$((FAIL+1)); return
  fi
  got="$(timeout 10 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then echo "FAIL $1: ABSTURZ (rc=$rc)"; FAIL=$((FAIL+1)); return; fi
  if [ "$got" = "$3" ]; then echo "PASS $1"; PASS=$((PASS+1))
  else echo "FAIL $1: '$got' erwartet '$3'"; FAIL=$((FAIL+1)); fi
}

fails() { # name, quelltext, erwarteter meldungsteil
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  msg="$("$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)"
  if [ -f "$TMP/c" ]; then echo "FAIL $1: uebersetzt, statt zu melden"; FAIL=$((FAIL+1)); return; fi
  case "$msg" in
    *"$3"*) echo "PASS $1"; PASS=$((PASS+1)) ;;
    *) echo "FAIL $1: Meldung ohne '$3'"; FAIL=$((FAIL+1)) ;;
  esac
}

K='import src.std.io;'

# --- Der Repro aus dem Issue ---------------------------------------------
out "Repro: i in 0..3 stuerzt nicht mehr ab" "$K
fn main(): int64 {
    var i: int64 := 2;
    if (i in 0..3) { PrintStrLn(\"drin\"c); } else { PrintStrLn(\"draussen\"c); }
    return 0;
}" 'drin'

out "ausserhalb des Bereichs" "$K
fn main(): int64 {
    var i: int64 := 9;
    if (i in 0..3) { PrintStrLn(\"drin\"c); } else { PrintStrLn(\"draussen\"c); }
    return 0;
}" 'draussen'

# --- Die Grenzen gehoeren dazu -------------------------------------------
# Ein Test nur mit einem Wert in der Mitte wuerde eine ausschliessende
# Implementierung nicht bemerken.
out "beide Grenzen einschliesslich" "$K
fn main(): int64 {
    if (0 in 0..3) { PrintStrLn(\"lo\"c); }
    if (3 in 0..3) { PrintStrLn(\"hi\"c); }
    return 0;
}" 'lo
hi'

out "knapp ausserhalb, beide Seiten" "$K
fn main(): int64 {
    var a: int64 := 0 - 1;
    var b: int64 := 4;
    if (a in 0..3) { PrintStrLn(\"FEHLER-lo\"c); } else { PrintStrLn(\"unter\"c); }
    if (b in 0..3) { PrintStrLn(\"FEHLER-hi\"c); } else { PrintStrLn(\"ueber\"c); }
    return 0;
}" 'unter
ueber'

out "negativer Bereich" "$K
fn main(): int64 {
    var x: int64 := 0 - 5;
    if (x in (0-10)..(0-1)) { PrintStrLn(\"ja\"c); } else { PrintStrLn(\"nein\"c); }
    return 0;
}" 'ja'

# --- Die Grenzen sind beliebige Ausdruecke -------------------------------
out "Variablen als Grenzen" "$K
fn main(): int64 {
    var lo: int64 := 5; var hi: int64 := 10; var x: int64 := 7;
    if (x in lo..hi) { PrintStrLn(\"ja\"c); } else { PrintStrLn(\"nein\"c); }
    return 0;
}" 'ja'

# Aufrufe in den Grenzen: die Auswertung darf den Stapel nicht verlieren —
# genau daran starb der alte Weg.
out "Funktionsaufrufe als Grenzen" "$K
fn L(): int64 { PrintStr(\"L\"c); return 2; }
fn H(): int64 { PrintStr(\"H\"c); return 8; }
fn main(): int64 {
    var x: int64 := 5;
    if (x in L()..H()) { PrintStrLn(\"ja\"c); } else { PrintStrLn(\"nein\"c); }
    return 0;
}" 'LHja'

# --- Der Test ist ein Ausdruck, nicht nur eine if-Bedingung --------------
out "in einer while-Bedingung" "$K
fn main(): int64 {
    var i: int64 := 0; var n: int64 := 0;
    while (i in 0..3) { n := n + i; i := i + 1; }
    PrintLn(n);
    return 0;
}" '6'

out "mit && verknuepft" "$K
fn main(): int64 {
    var x: int64 := 2; var y: int64 := 8;
    if (x in 0..3 && y in 5..10) { PrintStrLn(\"beide\"c); } else { PrintStrLn(\"nein\"c); }
    return 0;
}" 'beide'

# --- for i in a..b -------------------------------------------------------
out "for i in 0..3 laeuft einschliesslich" "$K
fn main(): int64 {
    var s: int64 := 0;
    for i in 0..3 { s := s + i; }
    PrintLn(s);
    return 0;
}" '6'

out "for mit Variablen als Grenzen" "$K
fn main(): int64 {
    var lo: int64 := 2; var hi: int64 := 4; var t: int64 := 0;
    for j in lo..hi { t := t + j; }
    PrintLn(t);
    return 0;
}" '9'

out "for-Variable ist im Rumpf sichtbar" "$K
fn main(): int64 {
    for i in 1..3 { PrintLn(i); }
    return 0;
}" '1
2
3'

# `break` und `continue` wirken wie in jeder anderen Schleife.
out "break in for-in" "$K
fn main(): int64 {
    var s: int64 := 0;
    for i in 0..9 { if (i == 4) { break; } s := s + i; }
    PrintLn(s);
    return 0;
}" '6'

# --- Gegenproben: die anderen Formen bleiben -----------------------------
# `range(a, b)` schliesst das Ende AUS — die beiden Formen sind nicht dasselbe.
out "for in range() bleibt ausschliesslich" "$K
fn main(): int64 {
    var v: int64 := 0;
    for m in range(0, 3) { v := v + m; }
    PrintLn(v);
    return 0;
}" '3'

out "for := to unveraendert" "$K
fn main(): int64 {
    var u: int64 := 0;
    for k := 0 to 3 { u := u + k; }
    PrintLn(u);
    return 0;
}" '6'

out "for := downto unveraendert" "$K
fn main(): int64 {
    var d: int64 := 0;
    for k := 3 downto 1 { d := d * 10 + k; }
    PrintLn(d);
    return 0;
}" '321'

# Steht rechts von `in` kein Bereich, gilt weiter die Woerterbuch-Zugehoerigkeit.
# #1152: der Fall stand hier bis 1.0.15A mit einem pchar-Schluessel und der
# Erwartung 'nein' — also mit dem DEFEKT als Sollwert: `in` war auf einer Map
# immer falsch. Beides ist behoben: `in` antwortet richtig, und ein
# pchar-Schluessel wird abgewiesen (die Laufzeit vergliche Adressen, #1291).
out "Woerterbuch-Zugehoerigkeit unveraendert" "$K
fn main(): int64 {
    var m: Map<int64, int64> = {7: 1};
    if (7 in m) { PrintStrLn(\"ja\"c); } else { PrintStrLn(\"nein\"c); }
    if (8 in m) { PrintStrLn(\"ja\"c); } else { PrintStrLn(\"nein\"c); }
    return 0;
}" 'ja
nein'

# `for ... in` ohne Bereich und ohne range() meldet, statt etwas zu raten.
fails "for in ohne Bereich meldet" "$K
fn main(): int64 {
    var x: int64 := 3;
    for i in x { PrintLn(i); }
    return 0;
}" "erwartet einen Bereich"

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
test "$FAIL" -eq 0
