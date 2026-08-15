#!/usr/bin/env bash
# tests/struct_ausrichtung_test.sh — #1516: ABI-Ausrichtung von Struct-Feldern.
#
# Jedes Feld nach dem ersten begann bei Offset 8*n, unabhängig von seiner
# Typbreite. Drei `int8` belegten damit 17 Byte statt 3, zwei `int16` zehn statt
# vier. Das Speicherbild passte zu keinem C-Struct — jedes per `extern fn`
# übergebene Struct mit schmalen Feldern kam auf der Gegenseite als Müll an.
#
# Die Regel widersprach sich außerdem selbst: 9 und 17 sind keine Vielfachen von
# 8, ein Array aus solchen Structs richtete also nicht einmal das erste Feld des
# zweiten Elements aus.
#
# GEPRÜFT WIRD DAS SPEICHERBILD, nicht nur `sizeof`. Beim Beheben zeigte sich
# genau dort die zweite Lücke: `sizeof` rechnete in einer EIGENEN Schleife über
# dieselben Felder — mit der Breite aus dem Flag statt aus dem Layout und ohne
# Aufrundung. `sizeof` sagte 17, ein Array aus demselben Struct rechnete mit 24.
# Ein Test, der nur eine der beiden Zahlen liest, sieht diesen Widerspruch nicht.

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
  if [ "$rc" -ge 128 ]; then echo "FAIL $1: ABSTURZ rc=$rc"; FAIL=$((FAIL+1)); return; fi
  if [ "$got" = "$3" ]; then echo "PASS $1"; PASS=$((PASS+1))
  else echo "FAIL $1: '$got' erwartet '$3'"; FAIL=$((FAIL+1)); fi
}

# ===========================================================================
# Die Größen aus der Meldung — jede gegen den C-Wert
# ===========================================================================

out "sizeof entspricht C" 'import std.io;
type A = struct { a: int8; }
type B = struct { a: int8; b: int8; }
type C = struct { a: int8; b: int8; c: int8; }
type D = struct { a: int16; b: int16; }
type E = struct { a: int64; b: int64; }
fn main(): int64 {
  PrintStr(IntToStr(sizeof(A))); PrintStr(" ");
  PrintStr(IntToStr(sizeof(B))); PrintStr(" ");
  PrintStr(IntToStr(sizeof(C))); PrintStr(" ");
  PrintStr(IntToStr(sizeof(D))); PrintStr(" ");
  PrintLn(IntToStr(sizeof(E)));
  return 0;
}' "1 2 3 4 16"

# Fuellbytes UND Aufrundung in einem Fall: int8, int64, int8 ergibt in C
# 1 + 7 Fuellung + 8 + 1 + 7 Aufrundung = 24. Die alte Rechnung kam auf 17 —
# also weder das Fuellbyte noch die Aufrundung.
out "Fuellbytes und Aufrundung" 'import std.io;
type F = struct { a: int8; b: int64; c: int8; }
fn main(): int64 { PrintLn(IntToStr(sizeof(F))); return 0; }' "24"

# Gemischte Breiten ohne Aufrundungsbedarf: int32@0, int8@4, int16@6 = 8.
out "gemischte Breiten" 'import std.io;
type G = struct { a: int32; b: int8; c: int16; }
fn main(): int64 { PrintLn(IntToStr(sizeof(G))); return 0; }' "8"

# ===========================================================================
# Das Speicherbild — hier faellt eine reine sizeof-Korrektur durch
# ===========================================================================

# Geschrieben wird ueber die Felder, gelesen byteweise: nur so zeigt sich, ob
# die Felder wirklich dort liegen, wo die Groesse es behauptet.
out "Bytes liegen wie in C" 'import std.io;
import std.alloc;
type S = struct { a: uint8; b: uint32; c: uint8; }
fn main(): int64 {
  var m: int64 := alloc(64);
  var k: int64 := 0;
  while (k < 64) { poke8(m + k, 0); k := k + 1; }
  var s: S := m as S;
  s.a := 17; s.b := 1; s.c := 9;
  k := 0;
  while (k < 10) { Print(IntToStr(peek8(m + k))); Print(" "); k := k + 1; }
  PrintLn("");
  return 0;
}' "17 0 0 0 1 0 0 0 9 0 "

# Nachbarschaft: ein schmales Feld darf beim Schreiben das folgende nicht
# mitloeschen. Ohne Ausrichtung lagen sie acht Byte auseinander, das verdeckte
# jeden zu breiten Schreibzugriff.
out "schmales Schreiben trifft nur sein Feld" 'import std.io;
type T = struct { a: int8; b: int8; c: int16; d: int32; }
fn main(): int64 {
  var t: T;
  t.a := 1; t.b := 2; t.c := 3; t.d := 4;
  t.b := 99;
  PrintStr(IntToStr(t.a)); PrintStr(" "); PrintStr(IntToStr(t.b)); PrintStr(" ");
  PrintStr(IntToStr(t.c)); PrintStr(" "); PrintLn(IntToStr(t.d));
  return 0;
}' "1 99 3 4"

# ===========================================================================
# Array aus schmalen Structs — der selbstwidersprüchliche Fall
# ===========================================================================

# Bei Groesse 17 (kein Vielfaches von 8) begann jedes zweite Element schief.
# Mit 3 Byte je Element muessen zehn Elemente lueckenlos hintereinander liegen.
out "Array aus 3-Byte-Structs liegt dicht" 'import std.io;
import std.alloc;
type C3 = struct { a: int8; b: int8; c: int8; }
fn main(): int64 {
  var n: int64 := sizeof(C3);
  var m: int64 := alloc(n * 10);
  var i: int64 := 0;
  while (i < 10) {
    var e: C3 := (m + i * n) as C3;
    e.a := i; e.b := i + 10; e.c := i + 20;
    i := i + 1;
  }
  i := 0;
  var summe: int64 := 0;
  while (i < 10) {
    var e2: C3 := (m + i * n) as C3;
    summe := summe + e2.a + e2.b + e2.c;
    i := i + 1;
  }
  PrintStr(IntToStr(n)); PrintStr(" "); PrintLn(IntToStr(summe));
  return 0;
}' "3 435"

# ===========================================================================
# Gegenproben
# ===========================================================================

# @packed richtet NICHT aus und rundet NICHT auf — sonst waere der einzige Weg
# zu einem dichten Speicherbild verloren.
out "@packed unveraendert dicht" 'import std.io;
type P = packed struct { a: int16; b: int8; c: int16; }
type Q = packed struct { a: uint8; b: uint32; }
fn main(): int64 {
  PrintStr(IntToStr(sizeof(P))); PrintStr(" "); PrintLn(IntToStr(sizeof(Q)));
  return 0;
}' "5 5"

# Reine int64-Structs sind der haeufigste Fall im Bestand — sie duerfen sich
# nicht bewegt haben.
out "int64-Felder unveraendert" 'import std.io;
type R = struct { a: int64; b: int64; c: int64; }
fn main(): int64 {
  var r: R;
  r.a := 11; r.b := 22; r.c := 33;
  PrintStr(IntToStr(sizeof(R))); PrintStr(" ");
  PrintStr(IntToStr(r.a)); PrintStr(" "); PrintStr(IntToStr(r.b)); PrintStr(" ");
  PrintLn(IntToStr(r.c));
  return 0;
}' "24 11 22 33"

# KLASSEN bleiben Referenztypen mit acht Byte je Feld: ihre Offsets tragen die
# Vererbungskette, eine Umstellung wuerde geerbte Felder verschieben.
out "Klasse behaelt 8-Byte-Felder" 'import std.io;
type K = class { a: int8; b: int8;
  fn Summe(): int64 { return self.a + self.b; }
}
fn main(): int64 {
  var k: K := new K();
  k.a := 3; k.b := 4;
  PrintLn(IntToStr(k.Summe()));
  return 0;
}' "7"

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
