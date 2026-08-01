#!/usr/bin/env bash
# tests/inline_fnptr_test.sh — A2: inline-fn/method-Typ als Klassenfeld OHNE Alias (ELF).
# `on_click: fn(TC): int64` (thin) bzw. `oc: method(TC): int64` (fat, self-Bindung).
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; LYXC="$ROOT/lyxc"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
run(){ printf "%s" "$2" > "$TMP/c.lyx"; LYX_STD_PATH="$ROOT/std" "$LYXC" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1 || { echo "FAIL $1: compile"; FAIL=$((FAIL+1)); return; }
  timeout 5 "$TMP/c" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq "$3" ]; then echo "PASS $1 (=$rc)"; PASS=$((PASS+1)); else echo "FAIL $1: exit=$rc erwartet $3"; FAIL=$((FAIL+1)); fi; }
# inline fn-Typ-Feld (thin): h(b.x=2)+40=42
run "inline_fn" 'type TC = class { x: int64; }; type TB = class extends TC { on_click: fn(TC): int64; }; fn h(s: TC): int64 { return s.x+40; } fn main(): int64 { var b: TB := new TB(); b.x := 2; b.on_click := h; return b.on_click(b as TC); }' 42
# inline method-Typ-Feld (fat, self): self.tag(30)+s.x(12)=42
run "inline_method" 'type TC = class { x: int64; }; type TForm = class { tag: int64; fn H(s: TC): int64 { return self.tag+s.x; } }; type TB = class extends TC { oc: method(TC): int64; }; fn main(): int64 { var f: TForm := new TForm(); f.tag := 30; var b: TB := new TB(); b.x := 12; b.oc := f.H; return b.oc(b as TC); }' 42
# inline method null-check
run "inline_method_null" 'type TC = class { x: int64; }; type TB = class extends TC { oc: method(TC): int64; }; fn main(): int64 { var b: TB := new TB(); if (b.oc != 0) { return 1; } return 7; }' 7

# --- #1003: derselbe Typ als LOKALE VARIABLE und als PARAMETER ---
# Als Klassenfeld (oben) funktionierte der inline geschriebene fn-Typ seit A2.
# Lokal und als Parameter stuerzte der Aufruf ab: der Aufrufpfad erkannte einen
# fn-Zeiger nur am NAMEN eines Typalias, und inline geschrieben gibt es keinen.
# Jeder Fall steht neben seiner Alias-Fassung — beide muessen dasselbe liefern.
ADD='fn add(a: int64, b: int64): int64 { return a + b; }'

run "lokal_inline"       "$ADD fn main(): int64 { var f: fn(int64, int64): int64 := add; return f(40, 2); }" 42
run "lokal_alias"        "type T2 = fn(int64, int64): int64; $ADD fn main(): int64 { var f: T2 := add; return f(40, 2); }" 42
run "lokal_0_args"       'fn g0(): int64 { return 42; } fn main(): int64 { var f: fn(): int64 := g0; return f(); }' 42
run "lokal_6_args"       'fn s6(a: int64,b: int64,c: int64,d: int64,e: int64,h: int64): int64 { return a+b+c+d+e+h; }
fn main(): int64 { var f: fn(int64,int64,int64,int64,int64,int64): int64 := s6; return f(1,2,3,4,5,27); }' 42
run "lokal_neuzuweisung" 'fn a1(): int64 { return 1; } fn a2(): int64 { return 42; }
fn main(): int64 { var f: fn(): int64 := a1; f := a2; return f(); }' 42
run "param_inline"       'fn g0(): int64 { return 42; } fn call(f: fn(): int64): int64 { return f(); }
fn main(): int64 { return call(g0); }' 42
run "param_inline_args"  'fn ad(a: int64,b: int64): int64 { return a+b; }
fn call2(f: fn(int64,int64): int64): int64 { return f(40,2); } fn main(): int64 { return call2(ad); }' 42
run "methodenparam"      'type CC = class { v: int64; fn run(f: fn(): int64): int64 { return f() + self.v; } }
fn g40(): int64 { return 40; }
fn main(): int64 { var c: CC := new CC(); c.v := 2; return c.run(g40); }' 42

echo "Ergebnis: $PASS PASS, $FAIL FAIL"; [ "$FAIL" -eq 0 ]
