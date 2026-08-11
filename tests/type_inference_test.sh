#!/usr/bin/env bash
# tests/type_inference_test.sh — #1085: `var x := <ausdruck>` ohne Typangabe.
#
# Wurde eine Variable ohne Typangabe initialisiert, blieb ihr Typ leer, und
# alles, was ihn braucht, nahm stillschweigend „Ganzzahl" an:
#
#   var n := "Lyx";      PrintLn(n)  gab die ADRESSE aus
#   var p := new Foo();  p.v         lieferte 0, Methodenaufrufe brachen ab
#   var f := 1.5;        PrintLn(f)  gab das rohe Bitmuster aus
#   var b := true;       PrintLn(b)  gab 1 aus
#   var s := StrFromInt(7);          gab den Zeiger aus
#
# Alles ohne Fehler und ohne Warnung. Die Dokumentation führt genau diese
# Zeilen als Beispiel mit dem Vermerk „Typ inferiert".
#
# Der Test prüft die AUSGABE, nicht die Übersetzbarkeit — der Fehler lag ja
# gerade darin, dass alles fehlerfrei übersetzte. Dazu die Gegenprobe, dass
# eine ausdrückliche Typangabe weiterhin gilt und nicht von der Inferenz
# überschrieben wird.

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
  got="$(timeout 10 "$TMP/c" 2>&1)"
  if [ "$got" = "$3" ]; then echo "PASS $1"; PASS=$((PASS+1))
  else echo "FAIL $1: '$got' erwartet '$3'"; FAIL=$((FAIL+1)); fi
}

# --- Der Repro aus dem Issue, wörtlich -----------------------------------
out "Repro: Zeichenkettenliteral" 'import std.io;
fn main(): int64 {
    var n := "Lyx";
    PrintLn(n);
    return 0;
}' 'Lyx'

# --- Der Fall aus dem Kommentar: Klasseninstanz --------------------------
out "new Klasse: Feldzugriff" 'import std.io;
type P = class { v: int64; };
fn main(): int64 {
    var p := new P();
    p.v := 9;
    PrintLn(IntToStr(p.v));
    return 0;
}' '9'

out "new Klasse: Methodenaufruf" 'import std.io;
type P = class { v: int64; pub fn get(): int64 { return self.v + 1; } };
fn main(): int64 {
    var p := new P();
    p.v := 41;
    PrintLn(IntToStr(p.get()));
    return 0;
}' '42'

# --- Die Nachbarn, die ebenso still danebenlagen -------------------------
out "Float-Literal" 'import std.io;
fn main(): int64 {
    var f := 1.5;
    PrintLn(f);
    return 0;
}' '1.500000'

out "Bool-Literal" 'import std.io;
fn main(): int64 {
    var b := true;
    PrintLn(b);
    return 0;
}' 'true'

out "Ergebnis eines Builtin-Aufrufs" 'import std.io;
fn main(): int64 {
    var s := StrFromInt(7);
    PrintLn(s);
    return 0;
}' '7'

out "Ergebnis einer Benutzerfunktion" 'import std.io;
fn name(): pchar { return "Lyx"c; }
fn wert(): f64 { return 2.5; }
fn main(): int64 {
    var a := name();
    var b := wert();
    PrintLn(a);
    PrintLn(b);
    return 0;
}' 'Lyx
2.500000'

# --- Gegenproben ---------------------------------------------------------
# Ganzzahl bleibt Ganzzahl — die Inferenz darf nicht zu breit greifen.
out "Ganzzahl-Literal unveraendert" 'import std.io;
fn main(): int64 {
    var z := 42;
    PrintLn(IntToStr(z));
    return z;
}' '42'

# Eine ausdrückliche Typangabe gilt und wird nicht überschrieben.
out "ausdrueckliche Typangabe gilt" 'import std.io;
fn main(): int64 {
    var p: pchar := "Lyx";
    var i: int64 := 7;
    PrintLn(p);
    PrintLn(IntToStr(i));
    return 0;
}' 'Lyx
7'

# Eine Benutzerfunktion mit int64-Rueckgabe darf nicht als Zeichenkette gelten.
out "int64-Rueckgabe bleibt Zahl" 'import std.io;
fn n(): int64 { return 42; }
fn main(): int64 {
    var v := n();
    PrintLn(IntToStr(v));
    return 0;
}' '42'

# Rechnen mit einer inferierten Ganzzahl bleibt möglich.
out "inferierte Ganzzahl bleibt rechenbar" 'import std.io;
fn main(): int64 {
    var a := 40;
    var b := 2;
    PrintLn(IntToStr(a + b));
    return 0;
}' '42'

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
