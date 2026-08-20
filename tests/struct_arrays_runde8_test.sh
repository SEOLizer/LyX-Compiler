#!/usr/bin/env bash
# tests/struct_arrays_runde8_test.sh — #1597, #1612, #1636.
#
# Ein Array von Structs traegt in Lyx ZEIGER-Slots: jedes Element ist ein
# eigenes Objekt, das der Deklarationspfad seit #1109 anlegt. Alle drei
# Meldungen kommen daher, dass eine Stelle dieses Modell nicht kannte.
#
# GEPRUEFT WIRD DER WEG:
#   #1597 daran, dass der Empfaenger DENSELBEN Zeiger sieht wie der Aufrufer —
#         ein Test auf die Summe allein koennte durch Zufall stimmen.
#   #1612 daran, dass eine spaetere Aenderung an der QUELLE das Element NICHT
#         mehr veraendert. Genau das ist der Unterschied zwischen Kopie und
#         geteiltem Objekt, und am Wert direkt nach der Zuweisung sieht man ihn
#         nicht.
#   #1636 an einem Nachbarfeld: lief der Schreibzugriff ins Leere, war nicht
#         nur das Element kaputt, sondern der Absturz verdeckte alles weitere.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

lauf() {
  local name="$1" erwartet="$2" quelle="$3"
  printf '%s\n' "$quelle" > "$TMP/t.lyx"
  if ! timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/t.lyx" -o "$TMP/t" >"$TMP/c.log" 2>&1; then
    no "$name" "uebersetzt nicht: $(grep -m1 -iE 'sema error|codegen error|^error' "$TMP/c.log")"
    return
  fi
  local got; got="$(timeout 60 "$TMP/t" 2>&1 | tr -d '\r' \
    | grep -vE 'Capabilit|^===|^Programm:|^  o |^  [A-Za-z-]+ |^$|^Runtime')"
  if [ "$got" = "$erwartet" ]; then ok "$name"; else
    no "$name" "erwartet [$(echo "$erwartet"|tr '\n' '|')], bekam [$(echo "$got"|tr '\n' '|')]"
  fi
}

# ===========================================================================
# #1597 — [N]Struct als Parameter
# ===========================================================================
lauf "#1597: der Empfaenger sieht dieselben Elemente wie der Aufrufer" \
'gleich
7' 'import std.io;
type P = struct { x: int64; y: int64 };
fn Pruef(a: [3]P, erwartet: int64): void {
  if ((a[0] as int64) == erwartet) { PrintLn("gleich"); } else { PrintLn("VERSCHOBEN"); }
}
fn Summe(a: [3]P): int64 { return a[0].x + a[1].x + a[2].x; }
fn main(): int64 {
  var arr: [3]P;
  arr[0].x := 1; arr[1].x := 2; arr[2].x := 4;
  Pruef(arr, arr[0] as int64);
  PrintLn(IntToStr(Summe(arr)));
  return 0;
}'

# Schreiben im Empfaenger muss beim Aufrufer ankommen — das Array ist ein
# Verweis, keine Kopie.
lauf "#1597: eine Aenderung im Empfaenger ist draussen sichtbar" '42' 'import std.io;
type P = struct { x: int64; y: int64 };
fn Setze(a: [2]P): void { a[1].x := 42; }
fn main(): int64 {
  var arr: [2]P;
  Setze(arr);
  PrintLn(IntToStr(arr[1].x));
  return 0;
}'

# Gegenprobe: [N]int64 an derselben Stelle war nie kaputt und bleibt es nicht.
lauf "#1597: [N]int64 unveraendert" '7' 'import std.io;
fn Summe(a: [3]int64): int64 { return a[0] + a[1] + a[2]; }
fn main(): int64 {
  var a: [3]int64;
  a[0] := 1; a[1] := 2; a[2] := 4;
  PrintLn(IntToStr(Summe(a)));
  return 0;
}'

# ===========================================================================
# #1612 — Zuweisung kopiert, statt das Objekt zu teilen
# ===========================================================================
lauf "#1612: lokales Array — die Quelle danach zu aendern beruehrt das Element nicht" \
'5 6
5 6' 'import std.io;
type P = struct { x: int64; y: int64 };
fn main(): int64 {
  var arr: [3]P;
  var p: P;
  p.x := 5; p.y := 6;
  arr[1] := p;
  PrintStr(IntToStr(arr[1].x)); PrintStr(" "); PrintLn(IntToStr(arr[1].y));
  p.x := 99; p.y := 98;
  PrintStr(IntToStr(arr[1].x)); PrintStr(" "); PrintLn(IntToStr(arr[1].y));
  return 0;
}'

lauf "#1612: dasselbe an einem Klassenfeld" \
'55 66' 'import std.io;
type P = struct { x: int64; y: int64 };
type C = class { items: [4]P; }
fn main(): int64 {
  var c: C := new C();
  var p: P;
  p.x := 55; p.y := 66;
  c.items[1] := p;
  p.x := 99; p.y := 98;
  PrintStr(IntToStr(c.items[1].x)); PrintStr(" "); PrintLn(IntToStr(c.items[1].y));
  return 0;
}'

# Zwei Elemente aus derselben Quelle muessen unabhaengig sein.
lauf "#1612: zwei Elemente aus derselben Quelle bleiben unabhaengig" \
'1 2' 'import std.io;
type P = struct { x: int64; y: int64 };
fn main(): int64 {
  var arr: [3]P;
  var p: P;
  p.x := 1; arr[0] := p;
  p.x := 2; arr[1] := p;
  PrintStr(IntToStr(arr[0].x)); PrintStr(" "); PrintLn(IntToStr(arr[1].x));
  return 0;
}'

# ===========================================================================
# #1636 — Klassenfeld [N]Struct
# ===========================================================================
lauf "#1636: Schreiben und Lesen ueber das ganze Feld, Nachbarfeld unversehrt" \
'0: 10 11
3: 30 33
tag=7' 'import std.io;
type P = struct { x: int64; y: int64 };
type C = class { items: [4]P; tag: int64; }
fn main(): int64 {
  var c: C := new C();
  c.tag := 7;
  c.items[0].x := 10; c.items[0].y := 11;
  c.items[3].x := 30; c.items[3].y := 33;
  PrintStr("0: "); PrintStr(IntToStr(c.items[0].x)); PrintStr(" "); PrintLn(IntToStr(c.items[0].y));
  PrintStr("3: "); PrintStr(IntToStr(c.items[3].x)); PrintStr(" "); PrintLn(IntToStr(c.items[3].y));
  PrintStr("tag="); PrintLn(IntToStr(c.tag));
  return 0;
}'

# Jedes Element braucht ein EIGENES Objekt — sonst schriebe [0] auch [1].
lauf "#1636: die Elemente eines Feldes sind voneinander getrennt" \
'10 20' 'import std.io;
type P = struct { x: int64; y: int64 };
type C = class { items: [4]P; }
fn main(): int64 {
  var c: C := new C();
  c.items[0].x := 10;
  c.items[1].x := 20;
  PrintStr(IntToStr(c.items[0].x)); PrintStr(" "); PrintLn(IntToStr(c.items[1].x));
  return 0;
}'

# Der Konstruktor darf die Elemente schon benutzen.
lauf "#1636: der Konstruktor sieht die Elemente bereits" '5' 'import std.io;
type P = struct { x: int64; y: int64 };
type C = class {
  items: [3]P;
  fn Create(): void { self.items[2].x := 5; }
}
fn main(): int64 {
  var c: C := new C();
  PrintLn(IntToStr(c.items[2].x));
  return 0;
}'

# Gegenprobe: ein Feld mit skalaren Elementen bleibt, wie es war.
lauf "#1636: [N]int64 als Klassenfeld unveraendert" '1 2 3' 'import std.io;
type C = class { zahlen: [3]int64; }
fn main(): int64 {
  var c: C := new C();
  c.zahlen[0] := 1; c.zahlen[1] := 2; c.zahlen[2] := 3;
  PrintStr(IntToStr(c.zahlen[0])); PrintStr(" ");
  PrintStr(IntToStr(c.zahlen[1])); PrintStr(" ");
  PrintLn(IntToStr(c.zahlen[2]));
  return 0;
}'

echo
echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
