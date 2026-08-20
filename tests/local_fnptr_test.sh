#!/usr/bin/env bash
# tests/local_fnptr_test.sh — lokaler plain-fn-ptr-Call + benannte fn/method-Typ-Params (ELF).
# Vorher: `var f := fn; f()` crashte (WP-02-Closure-Pfad las plain fn-ptr als {fnPtr,env}).
# Vorher: `fn(s: T)` / `method(s: T)` Parse-Fehler.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
run(){ printf "%s" "$2" > "$TMP/c.lyx"; LYX_STD_PATH="$ROOT/std" "$LYXC" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1 || { echo "FAIL $1: compile"; FAIL=$((FAIL+1)); return; }
  timeout 5 "$TMP/c" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq "$3" ]; then echo "PASS $1 (=$rc)"; PASS=$((PASS+1)); else echo "FAIL $1: exit=$rc erwartet $3"; FAIL=$((FAIL+1)); fi; }
# lokaler plain-fn-ptr-Call (#1)
run "local_1arg" 'type T = fn(int64): int64; fn dbl(x: int64): int64 { return x*2; } fn main(): int64 { var f: T := dbl; return f(21); }' 42
run "local_2arg" 'type T = fn(int64, int64): int64; fn add(a: int64, b: int64): int64 { return a+b; } fn main(): int64 { var f: T := add; return f(30, 12); }' 42
run "local_0arg" 'type T = fn(): int64; fn g(): int64 { return 42; } fn main(): int64 { var f: T := g; return f(); }' 42
# benannte Params in fn/method-Typ (#2)
run "fn_named_param" 'type T = fn(x: int64): int64; fn dbl(x: int64): int64 { return x*2; } fn main(): int64 { var f: T := dbl; return f(21); }' 42
run "method_named_param" 'type TC = class { x: int64; }; type TM = method(sender: TC): int64; type TForm = class { tag: int64; fn H(s: TC): int64 { return self.tag; } }; type TB = class extends TC { oc: TM; }; fn main(): int64 { var f: TForm := new TForm(); f.tag := 42; var b: TB := new TB(); b.oc := f.H; return b.oc(b as TC); }' 42
echo "Ergebnis: $PASS PASS, $FAIL FAIL"; [ "$FAIL" -eq 0 ]
