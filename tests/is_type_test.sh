#!/usr/bin/env bash
# tests/is_type_test.sh — #1094: Typtest `is`.
#
# Der Operator wurde angenommen und übersetzt, lieferte zur Laufzeit aber
# KONSTANT `false` — auch dort, wo der Typ zutraf. Der negative Fall war
# deshalb zufällig richtig; ein Test, der nur `x is pchar` prüft, wäre grün
# gewesen und hätte nichts gemessen. Jeder Fall hier kommt daher paarweise:
# der zutreffende UND der nicht zutreffende.
#
# Die drei Wege endeten alle bei `false`: die erwartete VMT-Adresse wurde aus
# der eigenen Codeposition gerechnet statt aus der Patch-Tabelle, jeder
# Nicht-Klassentyp fiel auf `zeroRax`, ein frei erfundener Typname ebenso.
#
# Der wichtigste Fall ist die Vererbung: `b is A` bei `B extends A` muss wahr
# sein — genau dafür gibt es den Operator. Ein Test nur über `b is B` hätte
# eine Implementierung durchgehen lassen, die bloß die eigene VMT vergleicht.

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
  got="$(timeout 10 "$TMP/c" 2>/dev/null)"; rc=$?
  if [ "$rc" -ge 128 ]; then echo "FAIL $1: ABSTURZ (rc=$rc)"; FAIL=$((FAIL+1)); return; fi
  if [ "$got" = "$3" ]; then echo "PASS $1"; PASS=$((PASS+1))
  else echo "FAIL $1: '$got' erwartet '$3'"; FAIL=$((FAIL+1)); fi
}

rejects() { # name, quelltext, erwartete meldung
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  got=$("$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)
  if echo "$got" | grep -q "$3"; then echo "PASS $1 (abgewiesen)"; PASS=$((PASS+1))
  else echo "FAIL $1: nicht abgewiesen — '$(echo "$got" | tail -1)'"; FAIL=$((FAIL+1)); fi
}

# --- Eingebaute Typen: der Repro aus dem Issue ---------------------------
out "Repro: x is int64 bei int64" 'import std.io;
fn main(): int64 {
    var x: int64 := 1;
    if (x is int64) { PrintLn("wahr"); } else { PrintLn("falsch"); }
    return 0;
}' 'wahr'

# Die Gegenprobe zum Repro. Ohne sie bewiese ein „wahr" nur, dass jetzt
# konstant `true` herauskommt — der gleiche Fehler mit umgekehrtem Vorzeichen.
out "x is pchar bei int64 bleibt falsch" 'import std.io;
fn main(): int64 {
    var x: int64 := 1;
    if (x is pchar) { PrintLn("wahr"); } else { PrintLn("falsch"); }
    return 0;
}' 'falsch'

out "pchar, f64 und bool je zutreffend und nicht" 'import std.io;
fn main(): int64 {
    var s: pchar := "a"c;
    var f: f64   := 1.5;
    var b: bool  := true;
    if (s is pchar) { PrintLn("1"); } else { PrintLn("0"); }
    if (s is f64)   { PrintLn("1"); } else { PrintLn("0"); }
    if (f is f64)   { PrintLn("1"); } else { PrintLn("0"); }
    if (f is int64) { PrintLn("1"); } else { PrintLn("0"); }
    if (b is bool)  { PrintLn("1"); } else { PrintLn("0"); }
    if (b is pchar) { PrintLn("1"); } else { PrintLn("0"); }
    return 0;
}' '1
0
1
0
1
0'

# Schreibvarianten bezeichnen denselben Typ — u64 und uint64 duerfen sich
# nicht unterscheiden, sonst haenge die Antwort an der Schreibweise.
out "u64 und uint64 sind derselbe Typ" 'import std.io;
fn main(): int64 {
    var a: u64 := 1;
    if (a is uint64) { PrintLn("1"); } else { PrintLn("0"); }
    if (a is u64)    { PrintLn("1"); } else { PrintLn("0"); }
    if (a is u32)    { PrintLn("1"); } else { PrintLn("0"); }
    return 0;
}' '1
1
0'

# --- Klassen: Laufzeitpruefung ------------------------------------------
out "a is A bei Klasse" 'import std.io;
type A = class { v: int64; };
fn main(): int64 {
    var a: A := new A();
    if (a is A) { PrintLn("wahr"); } else { PrintLn("falsch"); }
    return 0;
}' 'wahr'

out "a is B bei unverwandter Klasse" 'import std.io;
type A = class { v: int64; };
type B = class { w: int64; };
fn main(): int64 {
    var a: A := new A();
    if (a is B) { PrintLn("wahr"); } else { PrintLn("falsch"); }
    return 0;
}' 'falsch'

# Der Kernfall: die Ableitung IST auch die Basis. Eine Implementierung, die
# nur die eigene VMT vergleicht, faellt genau hier durch.
out "b is A bei B extends A" 'import std.io;
type A = class { v: int64; };
type B = class extends A { w: int64; };
fn main(): int64 {
    var b: B := new B();
    if (b is B) { PrintLn("1"); } else { PrintLn("0"); }
    if (b is A) { PrintLn("1"); } else { PrintLn("0"); }
    return 0;
}' '1
1'

# ... aber nicht umgekehrt: eine Basis ist keine Ableitung.
out "a is B bei B extends A ist falsch" 'import std.io;
type A = class { v: int64; };
type B = class extends A { w: int64; };
fn main(): int64 {
    var a: A := new A();
    if (a is B) { PrintLn("wahr"); } else { PrintLn("falsch"); }
    return 0;
}' 'falsch'

# Der eigentliche Zweck des Operators: eine Variable des Basistyps, die zur
# LAUFZEIT eine Ableitung haelt. Statisch waere die Antwort hier `A` — nur die
# VMT weiss es besser. Die Klassen brauchen dafuer eine Methode: eine Klasse
# OHNE Methode bekommt struct-Layout und traegt gar keine VMT (§20.1).
out "Basistyp-Variable mit Ableitung darin" 'import std.io;
type A = class { v: int64; virtual fn K(): int64 { return 1; } };
type B = class extends A { w: int64; override fn K(): int64 { return 2; } };
fn hol(n: int64): A { if (n == 1) { return new B(); } return new A(); }
fn main(): int64 {
    var x: A := hol(1);
    var y: A := hol(0);
    if (x is B) { PrintLn("1"); } else { PrintLn("0"); }
    if (y is B) { PrintLn("1"); } else { PrintLn("0"); }
    if (y is A) { PrintLn("1"); } else { PrintLn("0"); }
    return 0;
}' '1
0
1'

# Ueber drei Stufen — die Vorfahrenkette muss ganz gelaufen werden, in beiden
# Faellen: zur Laufzeit ueber die VMT und statisch ueber die Layout-Kette.
out "Kette ueber drei Stufen (mit VMT)" 'import std.io;
type A = class { v: int64; virtual fn K(): int64 { return 1; } };
type B = class extends A { w: int64; };
type C = class extends B { u: int64; };
fn main(): int64 {
    var c: C := new C();
    if (c is A) { PrintLn("1"); } else { PrintLn("0"); }
    if (c is B) { PrintLn("1"); } else { PrintLn("0"); }
    if (c is C) { PrintLn("1"); } else { PrintLn("0"); }
    return 0;
}' '1
1
1'

out "Kette ueber drei Stufen (ohne VMT, statisch)" 'import std.io;
type A = class { v: int64; };
type B = class extends A { w: int64; };
type C = class extends B { u: int64; };
fn main(): int64 {
    var c: C := new C();
    if (c is A) { PrintLn("1"); } else { PrintLn("0"); }
    if (c is B) { PrintLn("1"); } else { PrintLn("0"); }
    if (c is C) { PrintLn("1"); } else { PrintLn("0"); }
    return 0;
}' '1
1
1'

# null ist kein T — und darf beim Pruefen nicht dereferenziert werden.
out "null ist kein T und stuerzt nicht ab" 'import std.io;
type A = class { v: int64; };
fn main(): int64 {
    var a: A := null;
    if (a is A) { PrintLn("wahr"); } else { PrintLn("falsch"); }
    PrintLn("weiter");
    return 0;
}' 'falsch
weiter'

# Klasse gegen eingebauten Typ und umgekehrt.
out "Klasse is int64 und int64 is Klasse" 'import std.io;
type A = class { v: int64; };
fn main(): int64 {
    var a: A := new A();
    var x: int64 := 1;
    if (a is int64) { PrintLn("1"); } else { PrintLn("0"); }
    if (x is A)     { PrintLn("1"); } else { PrintLn("0"); }
    return 0;
}' '0
0'

# --- Der Empfaenger wird ausgewertet ------------------------------------
# Auch im statisch entschiedenen Fall: `f() is A` darf f nicht verschlucken.
out "Empfaenger wird ausgewertet" 'import std.io;
var n: int64 := 0;
fn zaehl(): int64 { n := n + 1; return 1; }
fn main(): int64 {
    if (zaehl() is int64) { PrintLn("1"); } else { PrintLn("0"); }
    PrintLn(IntToStr(n));
    return 0;
}' '1
1'

# --- Was nicht entscheidbar ist, wird gemeldet ---------------------------
# Der zweite Teil des Issues: ein frei erfundener Typname wurde kommentarlos
# als `false` beantwortet.
rejects "unbekannter Typname wird gemeldet" 'import std.io;
fn main(): int64 {
    var x: int64 := 1;
    if (x is ZzzUnbekannt) { PrintLn("wahr"); }
    return 0;
}' "unbekannter Typ in .is.-Ausdruck"

# --- Gegenproben: der Bestand bleibt unveraendert ------------------------
# Ein Bezeichner, der mit „is" beginnt, ist kein Operator — sonst haette die
# Aenderung am Typtest den Bestand zerlegt.
out "Bezeichner mit is-Praefix unveraendert" 'import std.io;
fn main(): int64 {
    var isOk: int64 := 3;
    var island: int64 := 4;
    PrintLn(IntToStr(isOk + island));
    return 0;
}' '7'

# NICHT geprueft: `x in a..b`. Der Ausdruck uebersetzt und stuerzt zur Laufzeit
# ab — mit dem Compiler VOR dieser Aenderung genauso (eigenes Issue). Ein Test,
# der an einem fremden offenen Defekt haengt, misst nicht mehr, was er soll.

out "as-Cast unveraendert" 'import std.io;
fn main(): int64 {
    var f: f64 := 2.75;
    PrintLn(IntToStr(f as int64));
    return 0;
}' '2'

out "virtuelle Dispatch unveraendert" 'import std.io;
type A = class { v: int64; virtual fn F(): int64 { return 1; } };
type B = class extends A { override fn F(): int64 { return 2; } };
fn main(): int64 {
    var b: B := new B();
    var a: A := b;
    PrintLn(IntToStr(a.F()));
    return 0;
}' '2'

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
