#!/usr/bin/env bash
# tests/klassenarray_1646_test.sh — #1646.
#
# Ein `[N]T`-Feld verhaelt sich unterschiedlich, je nachdem WAS T ist:
#   T = struct  -> Wert.    `arr[i] := s` kopiert den Inhalt (#1612).
#   T = class   -> Referenz. `arr[i] := o` legt den Zeiger ab; die Identitaet
#                  bleibt erhalten, wie bei jedem anderen Klassenwert auch.
#
# #1646 entstand, weil der Fix zu #1612 beides gleich behandelte: fuer Klassen
# wurde ebenfalls kopiert, und damit war `back == t` falsch und ein
# Schreibzugriff ueber das zurueckgelesene Objekt erreichte das Original nicht.
#
# Der Test haelt BEIDE Semantiken nebeneinander fest — an der Identitaet, nicht
# nur am Wert. Ein Test, der bloss den Wert direkt nach der Zuweisung liest,
# waere in beiden Faellen gruen gewesen.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
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
  [ "$got" = "$erwartet" ] && ok "$name" || no "$name" "erwartet [$(echo "$erwartet"|tr '\n' '|')], bekam [$(echo "$got"|tr '\n' '|')]"
}

# ===========================================================================
# Klassenelemente: Referenz, Identitaet bleibt
# ===========================================================================
# Der Repro aus dem Bericht.
lauf "#1646: [N]Klasse behaelt die Identitaet" \
'1
42' 'import std.io;
pub type TThing = class {
  Value: int64;
  fn Init(): void { self.Value := 0; }
}
pub type THolder = class {
  Slots: [4]TThing;
  Count: int64;
  fn Init(): void { self.Count := 0; }
  fn Add(t: TThing): void {
    self.Slots[self.Count] := t;
    self.Count := self.Count + 1;
  }
  fn At(i: int64): TThing { return self.Slots[i]; }
}
fn main(): int64 {
  var t: TThing := new TThing();
  t.Value := 1;
  var h: THolder := new THolder();
  h.Add(t);
  var back: TThing := h.At(0);
  PrintLn(back == t);
  back.Value := 42;
  PrintLn(t.Value);
  return 0;
}'

# Zweimal dasselbe Objekt ablegen heisst: zweimal dasselbe Objekt.
lauf "#1646: dasselbe Objekt in zwei Slots bleibt dasselbe" \
'7
7' 'import std.io;
type T = class { v: int64; }
type H = class { s: [3]T; }
fn main(): int64 {
  var t: T := new T();
  var h: H := new H();
  h.s[0] := t;
  h.s[1] := t;
  t.v := 7;
  PrintLn(IntToStr(h.s[0].v));
  PrintLn(IntToStr(h.s[1].v));
  return 0;
}'

# Dasselbe an einem LOKALEN Array — der Schreibpfad ist ein anderer.
lauf "#1646: lokales [N]Klasse ebenso" \
'1
9' 'import std.io;
type T = class { v: int64; }
fn main(): int64 {
  var arr: [3]T;
  var t: T := new T();
  t.v := 1;
  arr[0] := t;
  PrintLn(IntToStr(arr[0] == t));
  arr[0].v := 9;
  PrintLn(IntToStr(t.v));
  return 0;
}'

# ===========================================================================
# Structelemente: Wert, Kopie — die Regel aus #1612 gilt unveraendert
# ===========================================================================
lauf "#1646: [N]Struct kopiert weiterhin (Gegenprobe zu #1612)" \
'5 6
5 6' 'import std.io;
type P = struct { x: int64; y: int64 };
type C = class { items: [4]P; }
fn main(): int64 {
  var c: C := new C();
  var p: P;
  p.x := 5; p.y := 6;
  c.items[1] := p;
  PrintStr(IntToStr(c.items[1].x)); PrintStr(" "); PrintLn(IntToStr(c.items[1].y));
  p.x := 99; p.y := 98;
  PrintStr(IntToStr(c.items[1].x)); PrintStr(" "); PrintLn(IntToStr(c.items[1].y));
  return 0;
}'

lauf "#1646: lokales [N]Struct kopiert weiterhin" \
'5
5' 'import std.io;
type P = struct { x: int64; y: int64 };
fn main(): int64 {
  var arr: [3]P;
  var p: P;
  p.x := 5;
  arr[1] := p;
  PrintLn(IntToStr(arr[1].x));
  p.x := 99;
  PrintLn(IntToStr(arr[1].x));
  return 0;
}'

echo
echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
