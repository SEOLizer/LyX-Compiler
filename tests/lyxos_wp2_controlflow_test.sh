#!/usr/bin/env bash
# tests/lyxos_wp2_controlflow_test.sh — LYXOS-WP-2: Control-Flow (JMP/BR_TRUE/BR_FALSE/LABEL).
# Führt compute-only lyxos-Programme NATIV aus: lyxos sys_exit == Linux syscall 60, daher
# lädt lbf_run die LYX!-Datei (mmap+jump) und der Rückgabewert landet als Exit-Code.
# Verifiziert echte Ausführung (nicht nur Disasm) von if/else + while + verschachtelten Schleifen.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

run() { # name, source, expected-exit
  printf "%s" "$2" > "$TMP/c.lyx"
  LYX_STD_PATH="$ROOT/std" "$LYXC" --target=lyxos "$TMP/c.lyx" -o "$TMP/c.lyxnative" >/dev/null 2>&1
  printf 'import src.tools.lbf.loader;\nfn main(): int64 { lbf_run("%s/c.lyxnative"c); return 111; }' "$TMP" > "$TMP/r.lyx"
  LYX_STD_PATH="$ROOT/std" "$LYXC" "$TMP/r.lyx" -o "$TMP/r" >/dev/null 2>&1
  timeout 5 "$TMP/r" >/dev/null 2>&1; local rc=$?
  if [ "$rc" -eq "$3" ]; then echo "PASS $1 (=$rc)"; PASS=$((PASS+1));
  else echo "FAIL $1: exit=$rc erwartet $3"; FAIL=$((FAIL+1)); fi
}

run "ARITH_add"  'fn main(): int64 { var a: int64 := 5; var b: int64 := 7; return a + b; }' 12
run "ARITH_mul"  'fn main(): int64 { return 6 * 7; }' 42
run "IF_false"   'fn main(): int64 { var a: int64 := 9; if a < 5 { return 1; } return 7; }' 7
run "IF_true"    'fn main(): int64 { var a: int64 := 3; if a < 5 { return 1; } return 7; }' 1
run "WHILE_sum"  'fn main(): int64 { var s: int64 := 0; var i: int64 := 0; while i < 5 { s := s + 2; i := i + 1; } return s; }' 10
run "WHILE_nest" 'fn main(): int64 { var s: int64 := 0; var i: int64 := 0; while i < 4 { var j: int64 := 0; while j < 3 { s := s + 1; j := j + 1; } i := i + 1; } return s; }' 12

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
