#!/usr/bin/env bash
# tests/defer_argument_zeitpunkt_2380_test.sh — die Argumente eines `defer`
# werden bei der ANMELDUNG ausgewertet, nicht beim Ablauf (#1030), und zwar
# auf BEIDEN Wegen, auf denen defers emittiert werden (#2380).
#
# Es gibt drei Stellen, die aufgeschobene Anweisungen ausgeben:
#
#   cg_emitDefersDownTo   am Blockende (#1006) — setzte dfReplay schon
#   cg_emitDefers         an den return-Punkten — setzte es NICHT (#2380)
#   cg_emitDeferLandepunkt  am Ausnahmeweg — setzt es bewusst auf 0, weil die
#                         verdeckten Argument-Slots zum Rumpf gehoeren und der
#                         Landepunkt dahinter liegt (#1334)
#
# Weil die zweite Stelle dfReplay nicht setzte, wertete sie die Argumente am
# return-Punkt NEU aus. `defer g(v)` mit einem spaeteren `v := 999` gab 999
# statt des Wertes bei der Anmeldung. Still falsch: sichtbar nur dort, wo das
# Argument sich nach der Anmeldung noch aendert — und genau dort ist es
# gefaehrlich, denn `defer free(b, n)` auf einer wiederverwendeten Variablen
# gibt dann zweimal dieselbe Adresse frei.
#
# WARUM DIE ALTEN defer-TESTS DAS NICHT FANDEN: ihre Argumente sind Literale
# oder Variablen, die nach der Anmeldung unveraendert bleiben. Dann liefern
# beide Zeitpunkte denselben Wert. Dieser Test aendert die Variable
# ABSICHTLICH zwischen Anmeldung und Ablauf — das ist der einzige Aufbau, der
# die beiden Zeitpunkte unterscheidet.
#
# Geprueft wird der WERT, nicht die Uebersetzbarkeit, und die Reihenfolge
# gleich mit (LIFO beim Verlassen des Rahmens, ebnf.md:983).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

pruefe() { # $1 = Name, $2 = Erwartung, $3 = Quelltext
  printf "%s" "$3" > "$TMP/$1.lyx"
  if ! ( ulimit -c 0; cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/$1.lyx" -o "$TMP/$1.x" >"$TMP/$1.log" 2>&1 ); then
    echo "FAIL $1: uebersetzte nicht"; sed -n '1,3p' "$TMP/$1.log"; FAIL=$((FAIL+1)); return
  fi
  local got
  got=$( ulimit -c 0; cd "$TMP" && timeout 60 "$TMP/$1.x" 2>/dev/null | tr '\n' ' ' )
  got="${got% }"
  if [ "$got" = "$2" ]; then echo "PASS $1 ($got)"; PASS=$((PASS+1))
  else echo "FAIL $1: '$got' erwartet '$2'"; FAIL=$((FAIL+1)); fi
}

KOPF='unit main;
import std.io;
fn g(a: int64) { PrintInt(a); PrintStr(" "c); }
fn f(a: int64, b: int64, c: int64, d: int64, e: int64) { PrintInt(a); PrintStr(" "c); }
'

# ── ein Argument, Variable danach ueberschrieben ────────────────────────────
pruefe ein_argument "2" "$KOPF"'
fn p(): int64 {
  var v: int64 := 2;
  defer g(v);
  v := 999;
  return 0;
}
fn main(): int64 { p(); return 0; }
'

# ── fuenf Argumente: der Weg ueber cg_captureDeferArgs mit mehreren Slots ───
pruefe fuenf_argumente "1" "$KOPF"'
fn p(): int64 {
  var v: int64 := 1;
  defer f(v, 0, 0, 0, 0);
  v := 999;
  return 0;
}
fn main(): int64 { p(); return 0; }
'

# ── drei defer: Reihenfolge UND Zeitpunkt zusammen ──────────────────────────
pruefe drei_defer "30 20 10" "$KOPF"'
fn p(): int64 {
  var x: int64 := 10;
  var y: int64 := 20;
  var z: int64 := 30;
  defer g(x);
  defer g(y);
  defer g(z);
  x := 999; y := 999; z := 999;
  return 0;
}
fn main(): int64 { p(); return 0; }
'

# ── Blockende statt return: der Weg, der schon vorher stimmte ───────────────
# Steht mit im Test, damit eine Aenderung an cg_emitDefersDownTo nicht
# unbemerkt bleibt — die beiden Wege muessen uebereinstimmen.
pruefe blockende "7 8" "$KOPF"'
fn p(): int64 {
  var i: int64 := 0;
  while (i < 2) {
    var v: int64 := 7 + i;
    defer g(v);
    v := 999;
    i := i + 1;
  }
  return 0;
}
fn main(): int64 { p(); return 0; }
'

# ── vorzeitiges return aus einem inneren Block ──────────────────────────────
pruefe frueher_ausstieg "5 4" "$KOPF"'
fn p(): int64 {
  var a: int64 := 4;
  defer g(a);
  var i: int64 := 0;
  while (i < 3) {
    var b: int64 := 5;
    defer g(b);
    b := 999;
    a := 999;
    return 0;
  }
  return 1;
}
fn main(): int64 { p(); return 0; }
'

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
