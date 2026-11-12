#!/bin/bash
# Runde A: #1880, #1882, #1883, #1884, #1886
#
# Vier der fuenf sind ABWEISUNGEN — geprueft wird also, dass der Bau SCHEITERT
# und mit welcher Begruendung. Dazu gehoert jedes Mal die Gegenprobe, dass das
# RICHTIGE Programm weiter baut: eine Verschaerfung, die alles abweist, waere
# von der ersten Haelfte allein nicht zu unterscheiden.
#
# Die gemeinsame Wurzel von #1883, #1884 und #1886: sema gab Structs, Enums und
# Klassen einheitlich die Kennung TY_USER (sema.lyx:1407), warf die Identitaet
# also schon bei der Bestimmung weg. Jeder Vergleich sah danach nur
# "TY_USER == TY_USER".

cd "$(dirname "$0")/.." || exit 1
LYXC="${LYXC:-./lyxc}"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

# weist_ab <Name> <Quelle> <Textstueck der Meldung>
weist_ab() {
  local NAME="$1" SRC="$2" WANT="$3"
  printf '%s' "$SRC" > "$TMP/p.lyx"
  if $LYXC --std-path=. "$TMP/p.lyx" -o "$TMP/p" > "$TMP/p.log" 2>&1; then
    echo "FAIL $NAME: baut durch, obwohl es abgewiesen gehoert"
    FAIL=$((FAIL + 1))
  elif ! grep -q "$WANT" "$TMP/p.log"; then
    echo "FAIL $NAME: scheitert, aber nicht an der erwarteten Pruefung"
    grep -iE '^sema|^error' "$TMP/p.log" | head -2 | sed 's/^/    /'
    FAIL=$((FAIL + 1))
  else
    echo "PASS $NAME"
    PASS=$((PASS + 1))
  fi
}

# baut <Name> <Quelle> [erwartete Ausgabe]
baut() {
  local NAME="$1" SRC="$2" WANT="$3"
  printf '%s' "$SRC" > "$TMP/q.lyx"
  if ! $LYXC --std-path=. "$TMP/q.lyx" -o "$TMP/q" > "$TMP/q.log" 2>&1; then
    echo "FAIL $NAME: baut NICHT — die Pruefung schlaegt zu weit aus"
    grep -iE '^sema|^error' "$TMP/q.log" | head -2 | sed 's/^/    /'
    FAIL=$((FAIL + 1))
    return
  fi
  if [ -n "$WANT" ]; then
    local OUT; OUT=$("$TMP/q" 2>&1)
    if [ "$OUT" != "$WANT" ]; then
      echo "FAIL $NAME: Ausgabe '$OUT' statt '$WANT'"
      FAIL=$((FAIL + 1)); return
    fi
  fi
  echo "PASS $NAME"
  PASS=$((PASS + 1))
}

echo "-- #1883: Enums sind untereinander getrennt --"
weist_ab "Enum aus fremdem Enum initialisiert" \
'unit main;
enum A { X, Y }
enum B { P, Q }
fn main(): int64 { var a: A := B.Q; return 0; }
' "anderer benannter Typ"
baut "dasselbe Enum geht weiter" \
'unit main;
import std.io;
enum A { X, Y }
fn main(): int64 { var a: A := A.Y; PrintInt(a as int64); PrintLn(""c); return 0; }
' "1"

echo "-- #1886: Struct-Typen werden geprueft --"
weist_ab "fremder Struct in der Initialisierung" \
'unit main;
type A = struct { x: int64; }
type B = struct { x: int64; y: int64; }
fn main(): int64 { var b: B; var a: A := b; return 0; }
' "anderer benannter Typ"
weist_ab "fremder Struct in der Zuweisung" \
'unit main;
type A = struct { x: int64; }
type B = struct { x: int64; y: int64; }
fn main(): int64 { var b: B; var a: A; a := b; return 0; }
' "anderer benannter Typ"
weist_ab "fremder Struct als Argument" \
'unit main;
type A = struct { x: int64; }
type B = struct { x: int64; y: int64; }
fn nimmA(a: A): void { }
fn main(): int64 { var b: B; nimmA(b); return 0; }
' "anderer benannter Typ"
baut "derselbe Struct geht weiter" \
'unit main;
import std.io;
type A = struct { x: int64; }
fn nimmA(a: A): void { PrintInt(a.x); PrintLn(""c); }
fn main(): int64 { var a: A; a.x := 5; var b: A := a; nimmA(b); return 0; }
' "5"
# Ein Typ-ALIAS auf einen Grundtyp darf NICHT mitgezaehlt werden: `date` ist
# ein int64 und wird im Bestand durchgehend so benutzt (std/time.lyx).
baut "Alias auf einen Grundtyp bleibt vertraeglich" \
'unit main;
import std.io;
type datum = int64;
fn nimm(d: datum): void { PrintInt(d); PrintLn(""c); }
fn main(): int64 { var z: int64 := 7; nimm(z); return 0; }
' "7"

echo "-- Vererbung: das Kind gilt als der Elternteil --"
# Der erste Anlauf der Identitaetspruefung kannte die Kette nicht und hat
# legitime Polymorphie abgewiesen — aufgefallen an
# tests/regression/oop/vmt_abstract_test. Beide Richtungen gehoeren geprueft:
# ein Rechteck IST eine Form, eine Form ist kein Rechteck.
# `abstract` macht die Methode virtuell — ohne das greift kein Override, und
# der Aufruf ueber die Elternvariable landet beim Elternteil. Ein Test, der
# dann 15 erwartet und 0 bekommt, misst die falsche Sache.
baut "Kind darf dort stehen, wo der Elternteil verlangt ist" \
'unit main;
import std.io;
type Shape = class { abstract fn area(): int64; };
type Rect = class extends Shape { override fn area(): int64 { return 15; } };
fn main(): int64 { var r: Rect := new Rect(); var s: Shape := r; PrintInt(s.area()); PrintLn(""c); return 0; }
' "15"
weist_ab "Elternteil gilt NICHT als Kind" \
'unit main;
type Shape = class { fn area(): int64 { return 0; } };
type Rect = class extends Shape { fn nur(): int64 { return 1; } };
fn main(): int64 { var s: Shape := new Shape(); var r: Rect := s; return 0; }
' "anderer benannter Typ"

echo "-- Interfaces werden nicht beurteilt --"
# Eine Klasse erfuellt ein Interface in Lyx STRUKTURELL: der x86-Weg nimmt sie
# auch OHNE `implements` an und loest ueber Selektoren auf (#1133). Wer hier
# auf die Zusage bestuende, fuehrte eine Verschaerfung ein, die kein Issue
# verlangt — der erste Anlauf hat genau das getan und vier Faelle im Bestand
# rot gemacht (arm64 und riscv).
baut "Klasse MIT implements an eine Interface-Variable" \
'unit main;
import std.io;
pub type IF = interface { fn W(): int64; }
pub type TP = class implements IF { x: int64; fn Create() { self.x := 42; } fn W(): int64 { return self.x; } }
fn main(): int64 { var k: TP := new TP(); var i: IF := k; PrintInt(i.W()); PrintLn(""c); return 0; }
' "42"
baut "Klasse OHNE implements an eine Interface-Variable" \
'unit main;
import std.io;
pub type IF = interface { fn W(): int64; }
pub type TP = class { x: int64; fn Create() { self.x := 42; } fn W(): int64 { return self.x; } }
fn main(): int64 { var k: TP := new TP(); var i: IF := k; PrintInt(i.W()); PrintLn(""c); return 0; }
' "42"

echo "-- #1884: Enum-Cast wird geprueft --"
weist_ab "konstanter Wert ausserhalb der Varianten" \
'unit main;
enum Status { Ok, Warning, Error }
fn main(): int64 { var s: Status := 99 as Status; return 0; }
' "ausserhalb der Varianten"
baut "gueltige Variante geht weiter" \
'unit main;
import std.io;
enum Status { Ok, Warning, Error }
fn main(): int64 { var s: Status := 2 as Status; PrintInt(s as int64); PrintLn(""c); return 0; }
' "2"

echo "-- #1880: Bereichstyp am Parameter --"
weist_ab "konstantes Argument ausserhalb des Bereichs" \
'unit main;
type Speed = int64 range 0..300;
fn setze(v: Speed): void { }
fn main(): int64 { setze(500); return 0; }
' "ausserhalb des Bereichs"
baut "Argument im Bereich geht weiter" \
'unit main;
import std.io;
type Speed = int64 range 0..300;
fn setze(v: Speed): void { PrintInt(v); PrintLn(""c); }
fn main(): int64 { setze(250); return 0; }
' "250"

echo "-- #1882: wraps am Bereichstyp --"
# Die Grenzen sind EINSCHLIESSLICH: 0..359 rechnet modulo 360.
baut "wraps rechnet um" \
'unit main;
import std.io;
type Kurs = int64 wraps 0..359;
fn main(): int64 {
  var k: Kurs := 350;
  k := k + 20;  PrintInt(k); PrintStr(" "c);
  k := k + 300; PrintInt(k); PrintStr(" "c);
  k := 0;
  k := k - 1;   PrintInt(k); PrintLn(""c);
  return 0;
}
' "10 310 359"
# Gegenprobe: `range` verhaelt sich unveraendert, meldet also weiter.
weist_ab "range meldet weiterhin" \
'unit main;
type Speed = int64 range 0..300;
fn main(): int64 { var s: Speed := 500; return 0; }
' "ausserhalb des Bereichs"

echo
echo "$PASS PASS, $FAIL FAIL"
[ "$FAIL" = "0" ] || exit 1
echo "OK: Typidentitaet, Enum-Cast, Bereichstyp am Parameter, wraps"
exit 0
