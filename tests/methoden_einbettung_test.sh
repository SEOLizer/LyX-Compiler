#!/usr/bin/env bash
# tests/methoden_einbettung_test.sh — Einbettung direkter Methodenaufrufe (#2228).
#
# #2208 bettete nur freie Funktionen ein. Die heissesten Funktionen des
# Compilers und jeder Getter in Anwenderprogrammen sind aber Methoden
# (`self.cg_nkind(i)`, `p.X()`). Eingebettet wird jetzt der DIREKTE Aufruf:
# kein `super`, kein statischer Aufruf, kein VMT-Platz in der Klasse des
# Empfaengers, die Methode ohne Flags, der Empfaenger ein schlichtes Local —
# er wird im Rumpf fuer `self` eingesetzt. Ein Getter-Kern lief damit 2,4x
# schneller (1336 -> 555 ms bei 1e8 Runden, gleiche Summe).
#
# Gemessen wird in beiden Richtungen:
#   * WERTE fuer jeden Fall — gerade die abgelehnten Faelle (virtuell,
#     ueberschrieben) wuerden eingebettet still den falschen Rumpf rechnen.
#   * der WEG: ein zweiter Aufruf derselben Methode darf keinen `call` mehr
#     kosten, wenn eingebettet wird, und muss genau einen kosten, wenn nicht.
#     Nur Werte waeren auch von einem Compiler erfuellt, der nie einbettet;
#     nur die Zaehlung auch von einer Einbettung, die das Falsche rechnet.

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
    no "$1" "uebersetzt nicht: $(sed -n '1,3p' "$TMP/p.log" | tr '\n' ' ')"; return
  fi
  local got; got=$( ulimit -c 0; cd "$TMP" && timeout 20 "$TMP/p" 2>/dev/null | tr '\n' ' ' ); got="${got% }"
  if [ "$got" = "$3" ]; then ok "$1 ($got)"; else no "$1" "erwartet '$3', bekam '$got'"; fi
}

# Zahl der `call` im Objekt (--emit=obj: das fertige Programm hat keine
# Section-Header, objdump zaehlte dort still null).
calls() {
  printf '%s\n' "$1" > "$TMP/c.lyx"
  (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" --emit=obj "$TMP/c.lyx" -o "$TMP/c.o" >/dev/null 2>&1) || { echo -1; return; }
  objdump -d -z --no-show-raw-insn "$TMP/c.o" 2>/dev/null | grep -c call
}

# weg NAME KOPF AUFRUF SOLL — KOPF ist alles bis vor `fn main`, AUFRUF ein
# Ausdruck. Verglichen wird main mit EINEM gegen main mit ZWEI Aufrufen.
weg() {
  local eins zwei
  eins=$(calls "$2
fn main(): int64 { var s: int64 := 0; $3 s := s + $4; PrintLn(s); return 0; }")
  zwei=$(calls "$2
fn main(): int64 { var s: int64 := 0; $3 s := s + $4; s := s + $4; PrintLn(s); return 0; }")
  if [ "$eins" -lt 0 ] || [ "$zwei" -lt 0 ]; then no "$1 (Weg)" "uebersetzt nicht"; return; fi
  local diff=$((zwei - eins))
  if [ "$5" = ein ]; then
    if [ "$diff" -eq 0 ]; then ok "$1 (Weg: eingebettet, kein call mehr)"
    else no "$1 (Weg)" "zweiter Aufruf kostet $diff call — nicht eingebettet"; fi
  else
    if [ "$diff" -eq 1 ]; then ok "$1 (Weg: Aufruf bleibt)"
    else no "$1 (Weg)" "zweiter Aufruf kostet $diff call, erwartet 1 — doch eingebettet?"; fi
  fi
}

P='import std.io;
type Punkt = class {
  x: int64;
  y: int64;
  fn Setze(a: int64, b: int64) { self.x := a; self.y := b; }
  fn X(): int64 { return self.x; }
  fn Skal(k: int64): int64 { var t: int64 := self.x * k; return t + self.y; }
  fn Abstand(o: Punkt): int64 { return o.X() * 100 + self.X(); }
};'
INI='var p: Punkt := new Punkt(); p.Setze(3, 4); var q: Punkt := new Punkt(); q.Setze(5, 7);'

laeuft "Getter auf zwei Objekten, aus main und aus einer Methode" "$P
fn main(): int64 {
  $INI
  PrintLn(p.X()); PrintLn(q.X()); PrintLn(q.Skal(10)); PrintLn(p.Abstand(q)); PrintLn(q.Abstand(p));
  return 0;
}" "3 5 57 503 305"
weg "Getter" "$P" "$INI" "p.X()" ein
weg "Methode mit Parameter und Zwischenwert" "$P" "$INI" "q.Skal(3)" ein

# Ein Parameter der Methode heisst wie ein Local des Aufrufers.
laeuft "Parametername gleich Local des Aufrufers" "$P
fn main(): int64 {
  $INI
  var k: int64 := 100;
  PrintLn(p.Skal(k)); PrintLn(k);
  return 0;
}" "304 100"

# Virtuell und ueberschrieben: der Rumpf entscheidet sich erst zur Laufzeit.
# Eingebettet wuerde der statische Typ (Basis) gewinnen — still falsch.
V='import std.io;
type Basis = class {
  w: int64;
  fn Init(a: int64) { self.w := a; }
  virtual fn Wert(): int64 { return self.w; }
};
type Abgeleitet = class extends Basis {
  override fn Wert(): int64 { return self.w * 10; }
};'
laeuft "virtuell: Rumpf der Laufzeitklasse" "$V
fn main(): int64 {
  var b: Basis := new Abgeleitet();
  b.Init(4);
  var c: Basis := new Basis();
  c.Init(4);
  PrintLn(b.Wert()); PrintLn(c.Wert());
  return 0;
}" "40 4"
weg "virtuell" "$V" "var b: Basis := new Abgeleitet(); b.Init(4);" "b.Wert()" bleibt

# Geerbte, nicht virtuelle Methode auf einer abgeleiteten Instanz: Felder
# der Basis liegen an derselben Stelle.
laeuft "geerbte Methode auf abgeleiteter Instanz" 'import std.io;
type Basis = class {
  w: int64;
  fn Init(a: int64) { self.w := a; }
  fn Doppelt(): int64 { return self.w * 2; }
};
type Kind = class extends Basis {
  z: int64;
  fn Setz(a: int64) { self.z := a; }
};
fn main(): int64 {
  var k: Kind := new Kind();
  k.Init(21); k.Setz(5);
  PrintLn(k.Doppelt());
  return 0;
}' "42"

# Empfaenger als Ausdruck (kein schlichtes Local): bleibt Aufruf, Wert stimmt.
laeuft "Empfaenger aus einem Aufruf" "$P
fn hole(a: Punkt, b: Punkt, w: int64): Punkt { if (w > 0) { return a; } return b; }
fn main(): int64 {
  $INI
  PrintLn(hole(p, q, 1).X()); PrintLn(hole(p, q, 0).X());
  return 0;
}" "3 5"

# Eine Annotation am Rahmen (@flight_crit) sperrt wie bei freien Funktionen.
weg "@flight_crit an der Methode" 'import std.io;
type Z = class {
  v: int64;
  @flight_crit
  fn V(): int64 { return self.v; }
};' "var z: Z := new Z();" "z.V()" bleibt

echo "methoden_einbettung: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
