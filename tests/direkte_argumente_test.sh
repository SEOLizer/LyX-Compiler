#!/usr/bin/env bash
# tests/direkte_argumente_test.sh — hintere Argumente direkt ins Register (#2228).
#
# Jedes Argument ging ueber den Stapel: auswerten, `push rax`, spaeter
# `pop reg`. Im Selbstbau 134 000 Stellen; push/pop lag auf dem kritischen
# Pfad (Store->Load-Weiterleitung). Jetzt werden die HINTEREN Argumente,
# die nur ein Literal oder ein schlichtes Local sind, nach den Pops direkt in
# ihr Register geladen. Selbstbau 3,66 -> 3,48 s.
#
# Die Sorgfalt liegt in den Faellen, in denen das NICHT gehen darf: ein
# Argument mit Wirkung (Aufruf) vor einem schlichten — der schlichte wird
# trotzdem erst danach gelesen, darf also durch den Aufruf nicht veraendert
# sein; ein @redundant-Local (Mehrheitslesen ueber weitere Register); ein
# eingefangenes Local im Lambda; Vorgabewerte, die HINTER den Argumenten
# nachgeschoben werden. Jeder dieser Faelle steht unten mit seinem Wert.
#
# Der Weg wird am Erzeugnis gezaehlt: ein Aufruf mit drei schlichten
# Argumenten darf kein `pop` in ein Argumentregister mehr kosten.

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

# Sechs Argumente gemischt: Aufruf vorn, schlichte hinten — jedes Register
# bekommt seinen Wert.
laeuft "sechs Argumente, Register richtig belegt" 'import std.io;
fn f6(a: int64, b: int64, c: int64, d: int64, e: int64, g: int64): int64 {
  return a * 100000 + b * 10000 + c * 1000 + d * 100 + e * 10 + g;
}
fn eins(): int64 { return 1; }
fn main(): int64 {
  var x: int64 := 2; var y: int64 := 3;
  PrintLn(f6(eins(), x, y, 4, x + y, 6));
  PrintLn(f6(1, 2, 3, 4, 5, 6));
  PrintLn(f6(eins(), eins(), eins(), eins(), eins(), x));
  return 0;
}' "123456 123456 111112"

# Ein Aufruf VOR einem schlichten Argument veraendert dessen Local ueber
# einen Zeiger. Der echte Aufruf liest x VOR der Wirkung (Reihenfolge links
# nach rechts) — hier muss x also hinter dem Aufruf NICHT zurueckgehalten
# werden: das letzte nicht-schlichte Argument steht HINTER x.
laeuft "Wirkung auf ein vorderes schlichtes Argument" 'import std.io;
fn setze(p: int64): int64 { poke64(p, 99); return 7; }
fn f3(a: int64, b: int64, c: int64): int64 { return a * 10000 + b * 100 + c; }
fn main(): int64 {
  var x: int64 := 5;
  PrintLn(f3(x, setze(@x), 1));
  PrintLn(x);
  return 0;
}' "50701 99"

laeuft "Methode: self und Argumente direkt" 'import std.io;
type K = class {
  v: int64;
  fn Setze(a: int64) { self.v := a; }
  fn Rechne(a: int64, b: int64, c: int64): int64 { if (a < 0) { return 0; } return self.v * 1000 + a * 100 + b * 10 + c; }
};
fn main(): int64 {
  var k: K := new K(); k.Setze(9);
  var a: int64 := 1; var b: int64 := 2;
  PrintLn(k.Rechne(a, b, 3));
  return 0;
}' "9123"

laeuft "Vorgabewert hinter den Argumenten" 'import std.io;
fn f(a: int64, b: int64, c: int64 = 7): int64 { return a * 100 + b * 10 + c; }
fn main(): int64 {
  var x: int64 := 1; var y: int64 := 2;
  PrintLn(f(x, y));
  PrintLn(f(x, y, 3));
  return 0;
}' "127 123"

laeuft "@redundant-Local als Argument" 'import std.io;
fn f(a: int64, b: int64): int64 { return a * 10 + b; }
fn main(): int64 {
  @redundant
  var r: int64 := 4;
  var y: int64 := 2;
  PrintLn(f(y, r));
  return 0;
}' "24"

laeuft "eingefangenes Local im Lambda als Argument" 'import std.io;
fn f(a: int64, b: int64): int64 { return a * 10 + b; }
fn main(): int64 {
  var aussen: int64 := 6;
  var g := fn(z: int64): int64 { return f(z, aussen); };
  PrintLn(g(3));
  return 0;
}' "36"

# Weg: drei schlichte Argumente kosten kein pop in ein Argumentregister.
pops() {
  printf '%s\n' "$1" > "$TMP/c.lyx"
  (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" --emit=obj "$TMP/c.lyx" -o "$TMP/c.o" >/dev/null 2>&1) || { echo -1; return; }
  objdump -d -z --no-show-raw-insn "$TMP/c.o" 2>/dev/null | grep -cE 'pop +%(rdi|rsi|rdx|rcx|r8|r9)$'
}
KOPF='import std.io;
@export
fn f3(a: int64, b: int64, c: int64): int64 { return a + b + c; }'
ohne=$(pops "$KOPF
fn main(): int64 { var x: int64 := 1; var y: int64 := 2; PrintLn(x + y); return 0; }")
mit=$(pops "$KOPF
fn main(): int64 { var x: int64 := 1; var y: int64 := 2; PrintLn(f3(x, y, 3)); return 0; }")
if [ "$ohne" -lt 0 ] || [ "$mit" -lt 0 ]; then no "Weg" "uebersetzt nicht"
elif [ "$mit" -eq "$ohne" ]; then ok "Weg: f3(x, y, 3) ohne pop ($ohne vs $mit)"
else no "Weg" "f3(x, y, 3) kostet $((mit - ohne)) pop"; fi

echo "direkte_argumente: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
