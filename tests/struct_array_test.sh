#!/usr/bin/env bash
# tests/struct_array_test.sh — #1109: Arrays mit Struct- oder Klassen-Elementtyp.
#
# `var arr: S[3];` lieferte still 0: der Elementtyp wurde am Local nicht
# vermerkt, `cg_arrayElemClassIdx` fand die Klasse nicht, und `arr[0].v` bekam
# Feldoffset -1 — der bekannte "unbekanntes Feld → Offset 0"-Fall. Das ELEMENT
# selbst kam korrekt an; `var q: S := arr[0]` las den richtigen Wert. Sichtbar
# wurde der Fehler also nur ueber den Feldzugriff.
#
# Dahinter lag ein zweiter, aelterer Fehler: die Allokation forderte N*8 Byte
# an, der Zugriff ueberspringt aber einen 16-Byte-{cap,len}-Kopf. Beide Seiten
# waren gleich verschoben, deshalb fiel es bei skalaren Elementen nie auf —
# gedeckt war das nur durch die Seitengroesse der mmap.
#
# Semantik: ZEIGER-Slots. `arr[i] := s` teilt das Objekt mit `s`, wie die
# Struct-Zuweisung sonst auch; die Slots werden bei der Deklaration mit
# frischen Objekten belegt, damit `arr[0].v := 42` ohne vorheriges `new` geht —
# genauso wie ein `var s: S;` seit WP-10d angelegt wird.
#
# Geprueft wird der WERT nach dem Schreiben. Ein Test auf Uebersetzbarkeit
# waere gruen gewesen: uebersetzt wurde immer, nur eben Falsches.

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
  got="$(timeout 10 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then echo "FAIL $1: ABSTURZ (rc=$rc)"; FAIL=$((FAIL+1)); return; fi
  if [ "$got" = "$3" ]; then echo "PASS $1"; PASS=$((PASS+1))
  else echo "FAIL $1: '$got' erwartet '$3'"; FAIL=$((FAIL+1)); fi
}

K='import src.std.io;
type S = struct { v: int64; };
type S2 = struct { v: int64; w: int64; };
type C = class { v: int64; fn Get(): int64 { return self.v; } };'

# --- Der Repro aus dem Issue ---------------------------------------------
out "Repro: Element ablegen und Feld lesen" "$K
fn main(): int64 {
    var arr: S[3];
    var s: S;
    s.v := 1;
    arr[0] := s;
    PrintLn(arr[0].v);
    return 0;
}" '1'

# Ohne vorheriges Ablegen: der Slot ist bei der Deklaration belegt worden.
out "Feld ohne vorheriges Ablegen" "$K
fn main(): int64 {
    var arr: S[3];
    arr[0].v := 42;
    PrintLn(arr[0].v);
    return 0;
}" '42'

# --- Mehrere Felder, mehrere Elemente ------------------------------------
out "zwei Felder je Element" "$K
fn main(): int64 {
    var arr: S2[2];
    arr[1].v := 7;
    arr[1].w := 9;
    PrintLn(arr[1].v);
    PrintLn(arr[1].w);
    return 0;
}" '7
9'

# Der letzte Slot muss innerhalb des angeforderten Speichers liegen. Vor dem
# Fix lagen die Zugriffe um einen {cap,len}-Kopf dahinter.
out "alle Slots, letzter zuletzt" "$K
fn main(): int64 {
    var arr: S[4];
    arr[0].v := 1;
    arr[1].v := 2;
    arr[2].v := 3;
    arr[3].v := 4;
    PrintLn(arr[3].v);
    PrintLn(arr[0].v);
    return 0;
}" '4
1'

out "Schleife ueber alle Elemente" "$K
fn main(): int64 {
    var arr: S[4];
    var i: int64 := 0;
    while (i < 4) { arr[i].v := i * 10; i := i + 1; }
    PrintLn(arr[3].v);
    return 0;
}" '30'

# --- Klassen als Elementtyp ----------------------------------------------
out "Klasse: Feld" "$K
fn main(): int64 {
    var cs: C[2];
    cs[1].v := 77;
    PrintLn(cs[1].v);
    return 0;
}" '77'

out "Klasse: Methode auf dem Element" "$K
fn main(): int64 {
    var cs: C[2];
    cs[1].v := 77;
    PrintLn(cs[1].Get());
    return 0;
}" '77'

# --- Zeiger-Semantik ------------------------------------------------------
# `arr[i] := s` teilt das Objekt. Wer das Element aendert, aendert `s` mit.
out "Ablegen teilt das Objekt" "$K
fn main(): int64 {
    var arr: S[2];
    var s: S;
    s.v := 5;
    arr[0] := s;
    arr[0].v := 42;
    PrintLn(s.v);
    return 0;
}" '42'

# Das Element als Ganzes lesen — lief schon vor dem Fix und muss es weiter.
out "Element in eine Variable uebernehmen" "$K
fn main(): int64 {
    var arr: S[2];
    var s: S;
    s.v := 8;
    arr[1] := s;
    var q: S := arr[1];
    PrintLn(q.v);
    return 0;
}" '8'

# --- Gegenproben ----------------------------------------------------------
# Skalare Arrays duerfen sich nicht aendern.
out "skalares Array unveraendert" "$K
fn main(): int64 {
    var a: int64[3];
    a[0] := 7;
    a[2] := 9;
    PrintLn(a[0]);
    PrintLn(a[2]);
    return 0;
}" '7
9'

out "len() bei fester Groesse" "$K
fn main(): int64 {
    var arr: S[5];
    PrintLn(len(arr));
    return 0;
}" '5'

# Der Index-Operator einer Klasse MIT `Get` muss weiter ueberladen werden —
# die Unterscheidung ist \"Variable IST ein Klassenobjekt\" gegen \"Variable ist
# ein Array davon\".
out "Index-Operator einer Klasse bleibt ueberladen" "import src.std.io;
type Box = class { a: int64; fn Get(i: int64): int64 { return self.a + i; } };
fn main(): int64 {
    var b: Box := new Box();
    b.a := 100;
    PrintLn(b[5]);
    return 0;
}" '105'

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
test "$FAIL" -eq 0
