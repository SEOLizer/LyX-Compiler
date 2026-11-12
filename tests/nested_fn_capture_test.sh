#!/usr/bin/env bash
# tests/nested_fn_capture_test.sh — verschachtelte Funktionen und äußere Locals.
#
# Verschachtelte Funktionen werden als gewöhnliche Funktionen emittiert und
# bekommen keinen Static Link. Ein Zugriff auf eine lokale Variable der
# umgebenden Funktion lief deshalb still falsch: der Wert kam als 0 an, ohne
# jede Meldung. Das ist jetzt ein sema-Fehler.
#
# Die Gegenprobe ist genauso wichtig: globale `con`/`var`, Parameter der
# verschachtelten Funktion selbst und deren eigene Locals müssen weiter gehen,
# sonst wäre der Check unbrauchbar streng.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

reject() { # name, source
  printf "%s" "$2" > "$TMP/c.lyx"
  rm -f "$TMP/c"
  out=$("$LYXC" "$TMP/c.lyx" -o "$TMP/c" 2>&1)
  if [ ! -f "$TMP/c" ] && echo "$out" | grep -q "verschachtelte Funktion"; then
    echo "PASS $1 (abgelehnt)"; PASS=$((PASS+1))
  else
    echo "FAIL $1: erwartete Ablehnung, bekam: $(echo "$out" | head -1)"; FAIL=$((FAIL+1))
  fi
}

accept() { # name, source, expected-exit
  printf "%s" "$2" > "$TMP/c.lyx"
  rm -f "$TMP/c"
  if ! "$LYXC" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    echo "FAIL $1: compile fehlgeschlagen"; FAIL=$((FAIL+1)); return
  fi
  timeout 5 "$TMP/c" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq "$3" ]; then echo "PASS $1 (=$rc)"; PASS=$((PASS+1));
  else echo "FAIL $1: exit=$rc erwartet $3"; FAIL=$((FAIL+1)); fi
}

# --- muss abgelehnt werden: Zugriff auf Local der umgebenden Funktion ---
reject "liest aeussere Local" 'fn o(x: int64): int64 {
  var base: int64 := 10;
  fn f(v: int64): int64 { return v + base; }
  return f(x);
}
fn main(): int64 { return o(32); }'

reject "schreibt aeussere Local" 'fn o(x: int64): int64 {
  var acc: int64 := 0;
  fn f(v: int64) { acc := acc + v; }
  f(x);
  return acc;
}
fn main(): int64 { return o(42); }'

reject "aeusserer Parameter" 'fn o(x: int64): int64 {
  fn f(): int64 { return x; }
  return f();
}
fn main(): int64 { return o(42); }'

# --- muss durchgehen ---
accept "globales con" 'con G: int64 := 10;
fn o(x: int64): int64 { fn f(v: int64): int64 { return v + G; } return f(x); }
fn main(): int64 { return o(32); }' 42

accept "globales var" 'var GV: int64 := 10;
fn o(x: int64): int64 { fn f(v: int64): int64 { return v + GV; } return f(x); }
fn main(): int64 { return o(32); }' 42

accept "eigene Parameter und Locals" 'fn o(x: int64): int64 {
  fn f(v: int64): int64 { var t: int64 := v * 2; return t; }
  return f(x);
}
fn main(): int64 { return o(21); }' 42

accept "globale Funktion aufrufen" 'fn helper(v: int64): int64 { return v + 1; }
fn o(x: int64): int64 { fn f(v: int64): int64 { return helper(v); } return f(x); }
fn main(): int64 { return o(41); }' 42

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
