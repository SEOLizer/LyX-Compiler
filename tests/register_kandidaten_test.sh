#!/usr/bin/env bash
# tests/register_kandidaten_test.sh — mehr Locals in r12..r15 (#2228).
#
# Die Registerzuteilung aus #2114 nahm nur int64/uint64 und band ueber den
# NAMEN: eine zweite Deklaration desselben Namens (`var i` in zwei
# Schleifen) schloss den Namen ganz aus, weil sonst ein verdeckendes inneres
# `i` das Register des aeusseren ueberschrieben haette — sema laesst
# Verdecken zu. Jetzt wird ueber den Deklarationsknoten gebunden; dazu sind
# pchar, Klassenreferenzen und in Methoden `self` Kandidaten. Gemessen an den
# std-Kernen: HashMap −8 %, Sortieren −7 %, SHA-256 −5 %, Suche −10 %.
#
# Die Gefahr liegt in Stellen, die den Slot direkt lesen statt ueber
# cg_loadRax — sie laesen einen veralteten Wert. Deshalb die vielen WERT-
# Faelle unten: Verdecken in beide Richtungen, Zeiger, Objekte, self mit
# Rekursion und Feldschreiben, Wert-Structs (bleiben im Rahmen).
#
# Der WEG wird ueber Vergleichsprogramme gemessen: zwei gleichnamige
# Deklarationen muessen so viele Registerzugriffe bekommen wie zwei
# verschieden benannte, ein pchar-Zeiger so viele wie ein int64-Zeiger.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

laeuft() { # name quelle erwartet
  printf '%s\n' "$2" > "$TMP/p.lyx"; rm -f "$TMP/p"
  if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p" >"$TMP/p.log" 2>&1); then
    no "$1" "uebersetzt nicht: $(grep -v Copyright "$TMP/p.log" | head -2 | tr '\n' ' ')"; return
  fi
  local got; got=$( ulimit -c 0; cd "$TMP" && timeout 30 "$TMP/p" 2>/dev/null | tr '\n' ' ' ); got="${got% }"
  if [ "$got" = "$3" ]; then ok "$1 ($got)"; else no "$1" "erwartet '$3', bekam '$got'"; fi
}

laeuft "Verdecken: inneres i aendert aeusseres nicht" 'import std.io;
fn f(n: int64): int64 {
  var s: int64 := 0;
  var i: int64 := 0;
  while (i < n) {
    if (i == 2) { var i: int64 := 100; while (i < 103) { s := s + i; i += 1; } }
    s := s + i;
    i += 1;
  }
  return s * 1000 + i;
}
fn main(): int64 { PrintLn(f(5)); return 0; }' "313005"

laeuft "drei gleichnamige Deklarationen nacheinander und geschachtelt" 'import std.io;
fn f(n: int64): int64 {
  var s: int64 := 0;
  var i: int64 := 0;
  while (i < n) { s := s + i; i += 1; }
  if (s > 0) { var i: int64 := 7; while (i < n) { s := s + i * 2; i += 1; } }
  var k: int64 := 0;
  while (k < n) { var i: int64 := k * 3; s := s + i; k += 1; }
  return s;
}
fn main(): int64 { PrintLn(f(10)); return 0; }' "228"

laeuft "pchar-Zeiger laeuft durch einen Text" 'import std.io;
fn zaehle(t: pchar, c: int64): int64 {
  var p: pchar := t;
  var n: int64 := 0;
  while (StrCharAt(p, 0) != 0) {
    if (StrCharAt(p, 0) == c) { n += 1; }
    p := (p as int64 + 1) as pchar;
  }
  return n;
}
fn main(): int64 { PrintLn(zaehle("abracadabra", 97)); PrintLn(zaehle("", 97)); return 0; }' "5 0"

laeuft "Objektreferenzen tauschen, Felder schreiben" 'import std.io;
type Knoten = class {
  v: int64;
  fn Setze(a: int64) { self.v := a; }
};
fn main(): int64 {
  var a: Knoten := new Knoten(); a.Setze(1);
  var b: Knoten := new Knoten(); b.Setze(2);
  var i: int64 := 0;
  while (i < 5) {
    var t: Knoten := a; a := b; b := t;
    a.v := a.v * 10 + i;
    i += 1;
  }
  PrintLn(a.v); PrintLn(b.v);
  return 0;
}' "2024 113"

laeuft "self: Schleife, Feldschreiben, Rekursion, Aufruf auf self" 'import std.io;
type Zaehler = class {
  summe: int64;
  schritt: int64;
  fn Init(s: int64) { self.summe := 0; self.schritt := s; }
  fn Lauf(n: int64): int64 {
    var i: int64 := 0;
    while (i < n) { self.summe := self.summe + self.schritt * i; i += 1; }
    return self.summe;
  }
  fn Fak(n: int64): int64 { if (n <= 1) { return 1; } return n * self.Fak(n - 1); }
  fn Beides(n: int64): int64 { return self.Lauf(n) + self.Fak(n); }
};
fn main(): int64 {
  var z: Zaehler := new Zaehler(); z.Init(3);
  var y: Zaehler := new Zaehler(); y.Init(5);
  PrintLn(z.Beides(5)); PrintLn(y.Lauf(4)); PrintLn(z.summe);
  return 0;
}' "150 30 30"

laeuft "Wert-Struct bleibt im Rahmen" 'import std.io;
type P = struct { x: int64; y: int64; };
fn main(): int64 {
  var p: P;
  p.x := 3; p.y := 4;
  var i: int64 := 0;
  while (i < 3) { p.x := p.x + p.y; i += 1; }
  PrintLn(p.x);
  return 0;
}' "15"

laeuft "Adresse eines pchar-Locals (@p) bleibt im Speicher" 'import std.io;
fn setze(q: int64) { poke64(q, "neu" as int64); }
fn main(): int64 {
  var p: pchar := "alt";
  setze(@p);
  PrintLn(p);
  return 0;
}' "neu"

# --- Weg ---------------------------------------------------------------------
regs() {
  printf '%s\n' "$1" > "$TMP/c.lyx"
  (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" --emit=obj "$TMP/c.lyx" -o "$TMP/c.o" >/dev/null 2>&1) || { echo -1; return; }
  objdump -d -z --no-show-raw-insn "$TMP/c.o" 2>/dev/null | grep -cE '%r1[2-5]'
}
gleich() { # name quelle1 quelle2
  local a b; a=$(regs "$2"); b=$(regs "$3")
  if [ "$a" -lt 0 ] || [ "$b" -lt 0 ]; then no "$1" "uebersetzt nicht"
  elif [ "$a" -eq "$b" ]; then ok "$1 ($a = $b Registerzugriffe)"
  else no "$1" "$a gegen $b Registerzugriffe"; fi
}
# Genau vier Kandidaten (s, k und die beiden Schleifenlocals) — mit mehr
# bekaemen die beiden i so oder so kein Register, und der Vergleich waere
# blind.
ZWEI='import std.io;
@export
fn f(): int64 {
  var s: int64 := 0;
  var k: int64 := 0;
  while (k < 4) { var i: int64 := k * 3; s := s + i; k += 1; }
  k := 0;
  while (k < 4) { var NAME: int64 := k * 5; s := s + NAME; k += 1; }
  return s;
}
fn main(): int64 { PrintLn(f()); return 0; }'
gleich "Weg: zweites i im Register wie ein j" "${ZWEI//NAME/i}" "${ZWEI//NAME/j}"

ZEIGER='import std.io;
@export
fn z(t: int64): int64 {
  var p: TYP := t as TYP;
  var n: int64 := 0;
  while (peek8(p as int64) != 0) { n += 1; p := (p as int64 + 1) as TYP; }
  return n;
}
fn main(): int64 { PrintLn(z("abc" as int64)); return 0; }'
gleich "Weg: pchar-Zeiger im Register wie int64" "${ZEIGER//TYP/pchar}" "${ZEIGER//TYP/int64}"

echo "register_kandidaten: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
