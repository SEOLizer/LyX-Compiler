#!/usr/bin/env bash
# tests/static_method_call_test.sh — `TypeName.Method()` (Aufruf über den Typnamen).
#
# Aus dem 0.9.9B-Report (BUG-6): ein statischer Aufruf wurde stillschweigend akzeptiert
# und mit undefiniertem self ausgeführt. Der damalige Crash-Pfad (e8-cc-Platzhalter-CALL,
# BUG-2) ist inzwischen zu einem harten Compile-Fehler geworden.
#
# Was hier geprüft wird: eine Methode, die `self` benutzt, darf NICHT über den Typnamen
# aufgerufen werden — der Empfänger fehlt, sie würde an einer beliebigen Adresse
# arbeiten. Methoden ohne self-Zugriff (Static-Factory-Stil) bleiben erlaubt, weil das
# Muster in src/std/ verbreitet ist; ihr getrenntes Laufzeitproblem ist in
# work/static-method-call-codegen.md beschrieben.
#
# Ebenfalls abgesichert: `TypeName.field` (Byte-Offset) bleibt gültig — das ist ein
# dokumentiertes Pattern und darf vom Check nicht miterschlagen werden.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

run() { # name, source, expected-exit
  printf "%s" "$2" > "$TMP/c.lyx"
  if ! LYX_STD_PATH="$ROOT/std" "$LYXC" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    echo "FAIL $1: compile fehlgeschlagen"; FAIL=$((FAIL+1)); return
  fi
  timeout 5 "$TMP/c" >/dev/null 2>&1; local rc=$?
  if [ "$rc" -eq "$3" ]; then echo "PASS $1 (=$rc)"; PASS=$((PASS+1));
  else echo "FAIL $1: exit=$rc erwartet $3"; FAIL=$((FAIL+1)); fi
}

compile_fail() { # name, source, expected-message
  printf "%s" "$2" > "$TMP/c.lyx"
  rm -f "$TMP/c"
  local out
  out=$(LYX_STD_PATH="$ROOT/std" "$LYXC" "$TMP/c.lyx" -o "$TMP/c" 2>&1)
  if [ ! -f "$TMP/c" ] && echo "$out" | grep -q "$3"; then
    echo "PASS $1 (compile-fail)"; PASS=$((PASS+1));
  else echo "FAIL $1: erwartete Meldung '$3' / kein Binary"; FAIL=$((FAIL+1)); fi
  rm -f "$TMP/c"
}

# --- self-nutzende Methode über den Typnamen: muss abgelehnt werden ---
compile_fail "static_call_uses_self" 'pub type Box = class { value: int64;
  pub fn Get(): int64 { return self.value; } };
fn main(): int64 { return Box.Get(); }' "braucht eine Instanz"

compile_fail "static_call_writes_self" 'pub type Box = class { value: int64;
  pub fn Put(v: int64) { self.value := v; } };
fn main(): int64 { Box.Put(1); return 0; }' "braucht eine Instanz"

# self-Nutzung tief im Rumpf (nicht nur als erste Anweisung)
compile_fail "static_call_nested_self" 'pub type Box = class { value: int64;
  pub fn Sum(n: int64): int64 { var t: int64 := 0; var i: int64 := 0;
    while (i < n) { if (i > 0) { t += self.value; } i += 1; } return t; } };
fn main(): int64 { return Box.Sum(3); }' "braucht eine Instanz"

# --- kein Fehlalarm ---
# Instanz-Aufruf derselben Methode bleibt gültig
run "instance_call_ok" 'pub type Box = class { value: int64;
  pub fn Put(v: int64) { self.value := v; }
  pub fn Get(): int64 { return self.value; } };
fn main(): int64 { var b: Box := new Box(); b.Put(42); return b.Get(); }' 42

# Methode ohne self-Zugriff darf weiterhin über den Typnamen aufgerufen werden
run "static_call_no_self" 'pub type Pair = class { first: int64; second: int64; third: int64;
  pub fn SecondOffset(): int64 { return Pair.second; } };
fn main(): int64 { return Pair.SecondOffset(); }' 16

# TypeName.field (Byte-Offset) bleibt gültig — Report-BUG-1-Pattern
run "typename_field_offsets" 'pub type Pair = class { first: int64; second: int64; third: int64; };
fn main(): int64 { var m: int64 := mmap(0, 4096, 3, 34, 0-1, 0);
  poke64(m + Pair.first, 11); poke64(m + Pair.second, 22); poke64(m + Pair.third, 33);
  if (peek64(m + 0) != 11) { return 1; }
  if (peek64(m + 8) != 22) { return 2; }
  if (peek64(m + 16) != 33) { return 3; }
  return 42; }' 42

# Gleichnamige Methode in einer anderen Klasse darf nicht verwechselt werden
run "same_name_other_class" 'pub type A = class { v: int64; pub fn Get(): int64 { return self.v; } };
pub type B = class { v: int64; pub fn Get(): int64 { return 7; } };
fn main(): int64 { return B.Get(); }' 7

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
