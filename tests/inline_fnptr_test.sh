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
echo "Ergebnis: $PASS PASS, $FAIL FAIL"; [ "$FAIL" -eq 0 ]
