#!/usr/bin/env bash
# tests/struct_inline_wert_test.sh — #1513, #1351, #1493.
#
#   #1513  Ein Struct ALS FELD eines Structs segfaultete bei jedem Zugriff:
#          das Layout gab dem Feld pauschal acht Byte, und der Zugriff LAS die
#          Stelle als Zeiger — `a.innen.wert` benutzte den Wert 5 als Adresse.
#   #1351  Structs hatten keine Wertsemantik: `var b: T := a` und `b := a`
#          teilten den Speicher, Schreiben auf die Kopie traf das Original.
#          Der PARAMETERfall folgte in #1528: Wertsemantik als Vorgabe, `ref`
#          fuer die 51 stdlib-Funktionen, die ihren Parameter mit Absicht
#          aendern.
#   #1493  Ein Array mit KLASSEN-Elementtyp als Klassenfeld lieferte still 0:
#          der Elementtyp war nur bei `Array<T>` vermerkt, nicht bei inline
#          `[N]T` — `b.kids[0].x` wusste nicht, welche Klasse dort liegt.
#
# GEPRUEFT WIRD DER WERT, nicht die Uebersetzung: alle drei uebersetzten
# klaglos. Zwei davon lieferten still eine falsche Zahl, einer stuerzte ab.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/p.lyx"; rm -f "$TMP/p"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p" >/dev/null 2>&1; then
    no "$1" "uebersetzt nicht: $("$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p" 2>&1 | grep -i error | head -1)"
    return
  fi
  got="$(timeout 30 "$TMP/p" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then no "$1" "ABSTURZ (rc=$rc)"; return; fi
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1" "'$got' erwartet '$3'"; fi
}

# ===========================================================================
# #1513 — Struct als Feld
# ===========================================================================

out "#1513: Repro aus der Meldung" 'import std.io;
type Innen = struct { wert: int64; };
type Aussen = struct { innen: Innen; zahl: int64; };
fn main(): int64 {
  var a: Aussen;
  a.innen.wert := 5; a.zahl := 4;
  PrintLn(IntToStr(a.innen.wert * a.zahl));
  return 0;
}' "20"

# Das Nachbarfeld darf nicht ueberlappt werden: das innere Struct belegt zwei
# Slots, `nach` liegt also erst dahinter. Mit der alten Rechnung (8 Byte fuer
# jedes Feld) haetten sich `a.y` und `nach` dieselbe Stelle geteilt.
out "#1513: Felder vor und nach dem inneren Struct" 'import std.io;
type A = struct { x: int64; y: int64; };
type B = struct { vor: int64; a: A; nach: int64; };
fn main(): int64 {
  var b: B;
  b.vor := 1; b.a.x := 2; b.a.y := 3; b.nach := 4;
  PrintLn(IntToStr(b.vor * 1000 + b.a.x * 100 + b.a.y * 10 + b.nach));
  return 0;
}' "1234"

out "#1513: drei Ebenen tief" 'import std.io;
type A = struct { x: int64; y: int64; };
type B = struct { vor: int64; a: A; nach: int64; };
type C = struct { b: B; z: int64; };
fn main(): int64 {
  var c: C;
  c.b.vor := 9; c.b.a.x := 8; c.z := 7;
  PrintLn(IntToStr(c.b.vor * 100 + c.b.a.x * 10 + c.z));
  return 0;
}' "987"

out "#1513: Struct als Feld einer Klasse" 'import std.io;
type A = struct { x: int64; y: int64; };
type K = class { s: A; n: int64; };
fn main(): int64 {
  var k: K := new K();
  k.s.x := 5; k.s.y := 6; k.n := 7;
  PrintLn(IntToStr(k.s.x * 100 + k.s.y * 10 + k.n));
  return 0;
}' "567"

# sizeof muss dem Layout folgen — sonst rechnet jeder, der Platz reserviert,
# mit der alten Feldzahl mal acht.
out "#1513: sizeof zaehlt das innere Struct voll" 'import std.io;
type A = struct { x: int64; y: int64; };
type B = struct { vor: int64; a: A; nach: int64; };
fn main(): int64 {
  PrintStr(IntToStr(sizeof(A))); PrintStr(" ");
  PrintLn(IntToStr(sizeof(B)));
  return 0;
}' "16 32"

# ===========================================================================
# #1351 — Wertsemantik bei Zuweisung
# ===========================================================================

out "#1351: var b: T := a kopiert" 'import std.io;
type Pt = struct { x: int64; y: int64; };
fn main(): int64 {
  var a: Pt; a.x := 1; a.y := 2;
  var b: Pt := a;
  b.x := 5;
  PrintStr(IntToStr(a.x)); PrintStr(" "); PrintLn(IntToStr(b.x));
  return 0;
}' "1 5"

out "#1351: b := a kopiert den Inhalt" 'import std.io;
type Pt = struct { x: int64; y: int64; };
fn main(): int64 {
  var a: Pt; a.x := 1; a.y := 2;
  var b: Pt; b.x := 9; b.y := 9;
  b := a;
  b.x := 5;
  PrintStr(IntToStr(a.x)); PrintStr(" ");
  PrintStr(IntToStr(b.x)); PrintStr(" ");
  PrintLn(IntToStr(b.y));
  return 0;
}' "1 5 2"

out "#1351: Struct in ein Struct-Feld zuweisen kopiert" 'import std.io;
type Pt = struct { x: int64; y: int64; };
type Box = struct { p: Pt; n: int64; };
fn main(): int64 {
  var a: Pt; a.x := 3; a.y := 4;
  var bx: Box; bx.n := 9;
  bx.p := a;
  bx.p.x := 8;
  PrintStr(IntToStr(bx.p.x)); PrintStr(" ");
  PrintStr(IntToStr(bx.p.y)); PrintStr(" ");
  PrintStr(IntToStr(bx.n)); PrintStr(" ");
  PrintLn(IntToStr(a.x));
  return 0;
}' "8 4 9 3"

# GEGENPROBE, und zwar die wichtigere: ein CAST bleibt eine SICHT auf den
# Speicher. So legt die stdlib Binaerformate ueber einen Puffer; eine Kopie
# schnitte die Sicht ab, und jedes Schreiben ginge still ins Leere.
out "#1351: Cast auf Struct kopiert NICHT" 'import std.io;
import std.alloc;
type S = struct { a: int64; b: int64; };
fn main(): int64 {
  var m: int64 := alloc(64);
  poke64(m, 0); poke64(m + 8, 0);
  var s: S := m as S;
  s.a := 7; s.b := 8;
  PrintStr(IntToStr(peek64(m))); PrintStr(" "); PrintLn(IntToStr(peek64(m + 8)));
  return 0;
}' "7 8"

# #1528: Der PARAMETERfall ist behoben — Struct-Parameter sind Werte, und
# `ref` drueckt das Gegenteil aus. Hier steht die Kurzprobe; die ausfuehrliche
# Absicherung samt stdlib-Gegenproben liegt in tests/ref_parameter_test.sh.
out "#1528: Struct-Parameter ist ein Wert, ref aendert das Original" 'import std.io;
type Pt = struct { x: int64; y: int64; };
fn wert(p: Pt): int64 { p.x := 999; return 0; }
fn refer(ref p: Pt): int64 { p.x := 999; return 0; }
fn main(): int64 {
  var a: Pt; a.x := 1;
  wert(a);
  var b: Pt; b.x := 1;
  refer(b);
  PrintStr(IntToStr(a.x)); PrintStr(" "); PrintLn(IntToStr(b.x));
  return 0;
}' "1 999"

# ===========================================================================
# #1493 — Array mit Klassen-Elementtyp als Klassenfeld
# ===========================================================================

out "#1493: Repro aus der Meldung" 'import std.io;
type TCtl = class { x: int64; }
type TBox = class { kids: [8]TCtl; n: int64; }
fn main(): int64 {
  var b: TBox := new TBox();
  var c: TCtl := new TCtl(); c.x := 7;
  b.n := 5;
  b.kids[0] := c;
  PrintStr(IntToStr(b.n)); PrintStr(" "); PrintLn(IntToStr(b.kids[0].x));
  return 0;
}' "5 7"

# Mehrere Plaetze, und das Nachbarfeld bleibt heil.
out "#1493: mehrere Slots und das Nachbarfeld" 'import std.io;
type TCtl = class { x: int64; }
type TBox = class { n: int64; kids: [8]TCtl; m: int64; }
fn main(): int64 {
  var b: TBox := new TBox();
  b.n := 1; b.m := 2;
  var c0: TCtl := new TCtl(); c0.x := 10;
  var c3: TCtl := new TCtl(); c3.x := 30;
  b.kids[0] := c0;
  b.kids[3] := c3;
  PrintStr(IntToStr(b.kids[0].x)); PrintStr(" ");
  PrintStr(IntToStr(b.kids[3].x)); PrintStr(" ");
  PrintStr(IntToStr(b.n)); PrintStr(" ");
  PrintLn(IntToStr(b.m));
  return 0;
}' "10 30 1 2"

# Gegenprobe: das skalare Feld-Array war nie betroffen.
out "#1493: skalares Feld-Array unveraendert" 'import std.io;
type TBox = class { a: [8]int64; n: int64; }
fn main(): int64 {
  var b: TBox := new TBox();
  b.a[2] := 42; b.n := 3;
  PrintStr(IntToStr(b.a[2])); PrintStr(" "); PrintLn(IntToStr(b.n));
  return 0;
}' "42 3"

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
