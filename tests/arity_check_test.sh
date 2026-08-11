#!/usr/bin/env bash
# tests/arity_check_test.sh — sema prüft Argument-Anzahl bei Aufrufen regulärer Funktionen.
# Vorher fehlte JEDE Arity-Prüfung → zu wenige/viele Args wurden akzeptiert → fehlende Args
# = Garbage/Crash (z.B. DNSResolve(1 statt 4 Args) → Core-Dump). Nur same-module reguläre
# Lyx-Funktionen werden geprüft; extern/FFI + cross-module (modul-relative declNi) bleiben außen.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
# rc==expectFail: 1 = soll Compile-Fehler, 0 = soll kompilieren
chk(){ printf "%s" "$2" > "$TMP/c.lyx"; LYX_STD_PATH="$ROOT/std" "$LYXC" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq "$3" ] || { [ "$3" -eq 1 ] && [ "$rc" -ne 0 ]; }; then echo "PASS $1"; PASS=$((PASS+1));
  else echo "FAIL $1: rc=$rc erwartet $3"; FAIL=$((FAIL+1)); fi; }
chk "too_few_args"  'fn add(a: int64, b: int64): int64 { return a+b; } fn main(): int64 { return add(5); }' 1
chk "too_many_args" 'fn add(a: int64, b: int64): int64 { return a+b; } fn main(): int64 { return add(5,6,7); }' 1
chk "correct_2"     'fn add(a: int64, b: int64): int64 { return a+b; } fn main(): int64 { return add(5,6); }' 0
chk "correct_0"     'fn f(): int64 { return 7; } fn main(): int64 { return f(); }' 0
chk "correct_recurse" 'fn fib(n: int64): int64 { if n < 2 { return n; } return fib(n-1) + fib(n-2); } fn main(): int64 { return fib(6); }' 0
echo "Ergebnis: $PASS PASS, $FAIL FAIL"; [ "$FAIL" -eq 0 ]
