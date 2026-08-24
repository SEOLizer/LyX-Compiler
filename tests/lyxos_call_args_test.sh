#!/usr/bin/env bash
# tests/lyxos_call_args_test.sh — user-Funktions-Calls auf lyxos (Bug 2 / emitCall).
# emitCall war ein Stub (CALL rel32=0, keine Args, kein Result) → alle user-fn-Calls kaputt;
# u. a. `g := Sys...(...)` lieferte 0 (Symptom „Mehr-Arg-Syscall-Resultat / globale Var=0").
# Fix: Args via System-V-Register (rdi,rsi,rdx,rcx,r8,r9), CALL-rel32-Patch auf Funktions-
# Offset, Result rax→dest, Callee-Param-Spill Register→Slots. Native Ausführung via lbf_run
# (Resultat = Exit-Code).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
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

run "CALL_2arg"     'fn add(a: int64, b: int64): int64 { return a + b; } fn main(): int64 { return add(3, 4); }' 7
run "CALL_to_global" 'fn f(): int64 { return 42; } var g: int64 := 0; fn main(): int64 { g := f(); return g; }' 42
run "CALL_5arg"     'fn f(a: int64, b: int64, c: int64, d: int64, e: int64): int64 { return a + b + c + d + e; } fn main(): int64 { return f(1, 2, 3, 4, 5); }' 15
run "CALL_5arg_global" 'fn f(a: int64, b: int64, c: int64, d: int64, e: int64): int64 { return e; } var g: int64 := 0; fn main(): int64 { g := f(10, 20, 30, 40, 55); return g; }' 55
run "CALL_6arg"     'fn f(a: int64, b: int64, c: int64, d: int64, e: int64, x: int64): int64 { return a + x; } fn main(): int64 { return f(1, 2, 3, 4, 5, 6); }' 7
run "CALL_nested"   'fn sq(n: int64): int64 { return n * n; } fn main(): int64 { return sq(sq(2)); }' 16
# Regression: DCE incorrectly eliminated LOAD_LOCAL(dest=0) when no instr uses slot 0 as src
run "CALL_return_last_param" 'fn f(a: int64, b: int64, c: int64, d: int64, e: int64): int64 { return e; } var g: int64 := 0; fn main(): int64 { g := f(10, 20, 30, 40, 55); return g; }' 55
# Regression: getInstrCount() divided instrLen by IR_INSTR_SIZE; cross-fn reg collision
run "CALL_add5_150" 'fn add5(a: int64, b: int64, c: int64, d: int64, e: int64): int64 { return a + b + c + d + e; } var gw: int64 := 0; fn main(): int64 { gw := add5(10, 20, 30, 40, 50); return gw; }' 150

# #1761: Argumente ab dem siebten liefen ueber den Stapel — Aufrufseite verwarf sie
# still, der Callee las sie nie und rechnete mit dem letzten Registerwert weiter.
run "CALL_7arg_last"  'fn f(a: int64, b: int64, c: int64, d: int64, e: int64, f: int64, g: int64): int64 { return g; } fn main(): int64 { return f(1,2,3,4,5,6,77); }' 77
run "CALL_8arg_last"  'fn f(a: int64, b: int64, c: int64, d: int64, e: int64, f: int64, g: int64, h: int64): int64 { return h; } fn main(): int64 { return f(1,2,3,4,5,6,7,88); }' 88
run "CALL_8arg_sum"   'fn f(a: int64, b: int64, c: int64, d: int64, e: int64, f: int64, g: int64, h: int64): int64 { return a+b+c+d+e+f+g+h; } fn main(): int64 { return f(1,2,3,4,5,6,7,8); }' 36
run "CALL_9arg_sum"   'fn f(a: int64, b: int64, c: int64, d: int64, e: int64, f: int64, g: int64, h: int64, i: int64): int64 { return a+b+c+d+e+f+g+h+i; } fn main(): int64 { return f(1,2,3,4,5,6,7,8,9); }' 45
# Stapelausrichtung: ungerade Zahl Stapelargumente braucht ein Fuellwort, sonst laeuft der
# Callee mit rsp%16==0 weiter. Verschachtelt, damit ein Versatz den zweiten Aufruf trifft.
run "CALL_7arg_nested" 'fn f(a: int64, b: int64, c: int64, d: int64, e: int64, f: int64, g: int64): int64 { return a+g; } fn main(): int64 { return f(1,2,3,4,5,6, f(1,2,3,4,5,6,20)); }' 22
# #1761: emitCallIndirect kannte nur fuenf Register — arg6 (r9) fehlte, arg7+ fielen weg.
run "CALLIND_6arg"    'fn f(a: int64, b: int64, c: int64, d: int64, e: int64, x: int64): int64 { return x; } fn main(): int64 { var p: fn(int64,int64,int64,int64,int64,int64): int64 := f; return p(1,2,3,4,5,66); }' 66
run "CALLIND_7arg"    'fn f(a: int64, b: int64, c: int64, d: int64, e: int64, x: int64, g: int64): int64 { return g; } fn main(): int64 { var p: fn(int64,int64,int64,int64,int64,int64,int64): int64 := f; return p(1,2,3,4,5,6,70); }' 70

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
