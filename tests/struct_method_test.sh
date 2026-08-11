#!/usr/bin/env bash
# tests/struct_method_test.sh — #1095: struct mit Methoden.
#
# `var p: P;` legt für ein struct den Speicher an — structs haben in Lyx
# Referenzsemantik, ein `new` gibt es für sie nicht. Diese Auto-Allokation
# hing daran, dass der Typ KEIN VMT hat. Ein struct MIT Methoden bekommt aber
# Klassen-Layout und fiel damit heraus: die Variable blieb uneingerichtet.
#
# Gemeldet war der Absturz beim `self`-Feldzugriff in der Methode. Tatsächlich
# reicht schon das erste `p.x := 5` — `self` ist gar nicht beteiligt. Der Test
# hält deshalb beides fest, sonst bliebe die halbe Ursache ungeprüft.
#
# Übersetzt wurde immer fehlerfrei; erst zur Laufzeit kam der Segfault. Der
# Test prüft daher die AUSFÜHRUNG, und zwar über den Exit-Code: ein rc >= 128
# ist ein Signal und wird ausdrücklich als solches gemeldet, damit ein Absturz
# nicht als „falsche Ausgabe" durchgeht.

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
  got="$(timeout 10 "$TMP/c" 2>/dev/null)"; rc=$?
  if [ "$rc" -ge 128 ]; then
    echo "FAIL $1: ABSTURZ (rc=$rc)"; FAIL=$((FAIL+1)); return
  fi
  if [ "$got" = "$3" ]; then echo "PASS $1"; PASS=$((PASS+1))
  else echo "FAIL $1: '$got' erwartet '$3'"; FAIL=$((FAIL+1)); fi
}

# --- Der Repro aus dem Issue ---------------------------------------------
out "Repro: self-Feldzugriff in struct-Methode" 'import std.io;
type P = struct {
    x: int64;
    fn Get(): int64 { return self.x; }
};
fn main(): int64 {
    var p: P;
    p.x := 5;
    PrintLn(IntToStr(p.Get()));
    return 0;
}' '5'

# --- Enger als gemeldet: schon das Feldschreiben stuerzte ab -------------
out "Feldschreiben allein, struct mit Methode" 'import std.io;
type P = struct { x: int64; fn Get(): int64 { return 42; } };
fn main(): int64 {
    var p: P;
    p.x := 5;
    PrintLn(IntToStr(p.x));
    return 0;
}' '5'

# --- Die Faelle, die schon vorher liefen, muessen es bleiben -------------
out "struct ohne Methoden" 'import std.io;
type P = struct { x: int64; };
fn main(): int64 {
    var p: P;
    p.x := 5;
    PrintLn(IntToStr(p.x));
    return 0;
}' '5'

out "struct-Methode ohne self" 'import std.io;
type P = struct { x: int64; fn Get(): int64 { return 42; } };
fn main(): int64 {
    var p: P;
    PrintLn(IntToStr(p.Get()));
    return 0;
}' '42'

out "class mit new unveraendert" 'import std.io;
type P = class { v: int64; fn Get(): int64 { return self.v; } };
fn main(): int64 {
    var p: P := new P();
    p.v := 7;
    PrintLn(IntToStr(p.Get()));
    return 0;
}' '7'

# --- Mehrere Felder und mehrere Instanzen -------------------------------
# Ohne diesen Fall bliebe unbemerkt, wenn alle Instanzen denselben Block
# bekaemen — die Auto-Allokation muss je Variable laufen.
out "zwei Instanzen sind unabhaengig" 'import std.io;
type P = struct {
    x: int64;
    y: int64;
    fn Sum(): int64 { return self.x + self.y; }
};
fn main(): int64 {
    var a: P;
    var b: P;
    a.x := 1; a.y := 2;
    b.x := 10; b.y := 20;
    PrintLn(IntToStr(a.Sum()));
    PrintLn(IntToStr(b.Sum()));
    return 0;
}' '3
30'

# --- Methode, die self schreibt -----------------------------------------
# (`Set` ist als Typname reserviert -- daher `Put`.)
out "Methode schreibt ueber self" 'import std.io;
type P = struct {
    x: int64;
    fn Put(v: int64): int64 { self.x := v; return self.x; }
};
fn main(): int64 {
    var p: P;
    PrintLn(IntToStr(p.Put(9)));
    PrintLn(IntToStr(p.x));
    return 0;
}' '9
9'

# --- struct-Local als Funktionsargument ---------------------------------
out "struct wird weitergereicht" 'import std.io;
type P = struct { x: int64; fn Get(): int64 { return self.x; } };
fn nimm(q: P): int64 { return q.Get(); }
fn main(): int64 {
    var p: P;
    p.x := 4;
    PrintLn(IntToStr(nimm(p)));
    return 0;
}' '4'

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
