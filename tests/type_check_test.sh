#!/usr/bin/env bash
# tests/type_check_test.sh — #1135, erste Stufe: Typpruefung bei
# Initialisierung, Zuweisung, Rueckgabe und Argumenten.
#
# Geprueft wurden bisher NAMEN und STELLIGKEIT, nicht aber Typen. `var x:
# pchar := 42` uebersetzte und stuerzte beim ersten Lesen ab, eine Funktion
# mit int64-Rueckgabetyp durfte einen f64 zurueckgeben.
#
# Die Ableitung bleibt bewusst klein und sicher: sie kennt Literale, Variablen
# mit deklariertem Typ, den `as`-Cast und den Rueckgabetyp einer im selben Lauf
# deklarierten Funktion. Alles andere -- Builtins, Importiertes, Feld- und
# Indexzugriffe, Methodenaufrufe -- bleibt unbestimmt und wird NICHT gemeldet.
#
# DREI Ausnahmen, jede durch den Bestand erzwungen und hier festgehalten:
#
#   1. `as`-Cast wird nie bemaengelt — er IST die ausdrueckliche Umwandlung.
#   2. Zeichenkette in ein GANZZAHL-Ziel bleibt zugelassen: `int64` ist in Lyx
#      zugleich der Zeigertyp, und die stdlib nutzt ihn durchgehend so
#      (`pub fn CreditCardTypeName(...): int64 { return "Visa"; }`). Ein
#      Messlauf mit scharfer Regel ergab 473 Fundstellen in 15 stdlib-Dateien
#      — das ist ein eigenes Paket.
#   3. Die Null in einem pchar-Ziel (`var p: pchar := 0;`) ist der uebliche
#      Nullzeiger.
#
# Geprueft wird, dass der Compiler MELDET beziehungsweise SCHWEIGT — und die
# Gegenproben halten fest, welche Muster weiterhin durchgehen muessen.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

fails() { # name, quelltext, erwarteter meldungsteil
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  msg="$("$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)"
  if [ -f "$TMP/c" ]; then echo "FAIL $1: uebersetzt, statt zu melden"; FAIL=$((FAIL+1)); return; fi
  case "$msg" in
    *"$3"*) echo "PASS $1"; PASS=$((PASS+1)) ;;
    *) echo "FAIL $1: Meldung ohne '$3'"; FAIL=$((FAIL+1)) ;;
  esac
}

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

K='import src.std.io;'

# --- Der Absturzfall aus dem Issue ---------------------------------------
# `var x: pchar := 42` uebersetzte und starb beim ersten Lesen (Exit 139).
fails "Repro: Zahl in pchar-Ziel" "$K
fn main(): int64 { var x: pchar := 42; PrintStrLn(x); return 0; }" "pchar erwartet, int64 gegeben"

fails "Zuweisung einer Zahl an eine pchar-Variable" "$K
fn main(): int64 { var s: pchar := \"a\"; var n: int64 := 5; s := n; PrintStrLn(s); return 0; }" "pchar erwartet"

# --- Gleitkomma und Ganzzahl werden nicht mehr vermengt ------------------
fails "f64 in int64-Ziel" "$K
fn main(): int64 { var f: f64 := 1.5; var x: int64 := f; PrintLn(x); return 0; }" "int64 erwartet, f64 gegeben"

fails "int64-Variable in f64-Ziel" "$K
fn main(): int64 { var i: int64 := 3; var f: f64 := i; PrintStrLn(\"x\"); return 0; }" "f64 erwartet, int64 gegeben"

fails "Zuweisung f64 an int64-Variable" "$K
fn main(): int64 { var x: int64 := 1; var f: f64 := 2.5; x := f; PrintLn(x); return 0; }" "Zuweisung: int64 erwartet, f64 gegeben"

fails "Rueckgabe f64 bei int64-Rueckgabetyp" "$K
fn F(): int64 { var f: f64 := 1.5; return f; }
fn main(): int64 { PrintLn(F()); return 0; }" "Rueckgabe: int64 erwartet, f64 gegeben"

fails "Argument f64 an int64-Parameter" "$K
fn F(a: int64): int64 { return a; }
fn main(): int64 { var f: f64 := 1.5; PrintLn(F(f)); return 0; }" "Argument: int64 erwartet, f64 gegeben"

fails "Argument f64 an pchar-Parameter" "$K
fn F(s: pchar): int64 { PrintStrLn(s); return 0; }
fn main(): int64 { var f: f64 := 1.5; return F(f); }" "pchar erwartet, f64 gegeben"

# Der Rueckgabetyp einer im selben Lauf deklarierten Funktion wird abgeleitet.
fails "Rueckgabewert einer Funktion, falscher Typ" "$K
fn G(): f64 { return 1.5; }
fn main(): int64 { var x: int64 := G(); PrintLn(x); return 0; }" "int64 erwartet, f64 gegeben"

# Ein Aufruf, dessen Name auch in einer importierten Unit vorkommt, darf den
# Rueckgabetyp nicht aus dem fremden Baum nehmen. `alloc` liefert int64 --
# ohne den Namensabgleich meldete die Ableitung hier "pchar gegeben".
out "Aufruf-Typ wird nicht aus einer fremden Unit geraten" "$K
fn main(): int64 {
    var p: int64 := alloc(512);
    poke64(p, 7);
    PrintLn(peek64(p));
    return 0;
}" '7'

# --- Gegenproben: der `as`-Cast ist der vorgesehene Weg ------------------
out "as-Cast wird nicht bemaengelt" "$K
fn main(): int64 {
    var f: f64 := 1.5;
    var x: int64 := f as int64;
    var s: pchar := \"abc\";
    var a: int64 := s as int64;
    if (a != 0) { PrintLn(x); }
    return 0;
}" '1'

out "Nullzeiger bleibt zulaessig" "$K
fn main(): int64 { var p: pchar := 0; if ((p as int64) == 0) { PrintStrLn(\"null\"); } return 0; }" 'null'

out "ganzzahliges Literal in f64 bleibt zulaessig" "$K
fn main(): int64 { var f: f64 := 0; var g: f64 := 1.5; PrintStrLn(\"ok\"); return 0; }" 'ok'

# #1221: `int64` diente in der stdlib durchgehend als Zeigertyp; das ist
# aufgeraeumt (470 Stellen in 16 Dateien tragen jetzt pchar). Seit 1.0.14I
# wird auch diese Richtung gemeldet — der Haupt-Repro aus #1135.
fails "Repro #1135: Zeichenkette in int64-Ziel" "$K
fn main(): int64 { var x: int64 := \"text\"; PrintLn(x); return 0; }" "int64 erwartet, pchar gegeben"

fails "Zeichenkette als Rueckgabe bei int64" "$K
fn Name(): int64 { return \"Visa\"; }
fn main(): int64 { PrintLn(Name()); return 0; }" "Rueckgabe: int64 erwartet, pchar gegeben"

fails "Zeichenkette als Argument an int64-Parameter" "$K
fn F(a: int64): int64 { return a * 2; }
fn main(): int64 { PrintLn(F(\"x\")); return 0; }" "Argument: int64 erwartet, pchar gegeben"

# Der Weg dorthin bleibt der Cast.
out "Zeichenkette in int64 mit Cast" "$K
fn main(): int64 { var x: int64 := \"text\" as int64; if (x != 0) { PrintStrLn(\"ok\"); } return 0; }" 'ok'

# --- Gegenproben: richtige Programme laufen unveraendert -----------------
out "korrektes Programm" "$K
fn F(a: int64): int64 { return a * 2; }
fn main(): int64 {
    var x: int64 := 21;
    PrintLn(F(x));
    var s: pchar := \"hi\";
    PrintStrLn(s);
    return 0;
}" '42
hi'

out "Breiten mischen sich weiterhin" "$K
fn main(): int64 { var a: uint8 := 200; var b: int64 := a; var c: int64 := 7; var d: uint8 := c; PrintLn(b); PrintLn(d); return 0; }" '200
7'

out "f64-Rechnung unveraendert" "$K
fn Half(x: f64): f64 { return x / 2.0; }
fn main(): int64 { var f: f64 := 3.0; var h: f64 := Half(f); PrintLn(h as int64); return 0; }" '1'

out "Unbestimmtes wird nicht gemeldet" "$K
fn main(): int64 {
    var p: int64 := alloc(16);
    poke64(p, 7);
    var v: int64 := peek64(p);
    PrintLn(v);
    return 0;
}" '7'

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
test "$FAIL" -eq 0
