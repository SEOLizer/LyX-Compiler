#!/usr/bin/env bash
# tests/fnptr_field_test.sh — A1: Fn-Typ-Alias als Klassen-Feld (ELF).
# fn-Name als Wert (Adresse), Zuweisung in Feld, Null-Check, direkter Feld-Call.
# Vorher: `b.on_click(...)` → Methoden-Mangle TButton_on_click (undefined); fn-Name → 0.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
run(){ printf "%s" "$2" > "$TMP/c.lyx"; LYX_STD_PATH="$ROOT/std" "$LYXC" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1 || { echo "FAIL $1: compile"; FAIL=$((FAIL+1)); return; }
  timeout 5 "$TMP/c" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq "$3" ]; then echo "PASS $1 (=$rc)"; PASS=$((PASS+1)); else echo "FAIL $1: exit=$rc erwartet $3"; FAIL=$((FAIL+1)); fi; }
P='type TControl = class { x: int64; }; type TNE = fn(TControl): int64; type TB = class extends TControl { tag: int64; on_click: TNE; }; fn h(s: TControl): int64 { return s.x + 40; }'
run "field_null_unset"  "$P fn main(): int64 { var b: TB := new TB(); if (b.on_click != 0) { return 1; } return 7; }" 7
run "field_store_check" "$P fn main(): int64 { var b: TB := new TB(); b.on_click := h; if (b.on_click != 0) { return 7; } return 0; }" 7
run "field_call"        "$P fn main(): int64 { var b: TB := new TB(); b.x := 2; b.on_click := h; return b.on_click(b as TControl); }" 42
echo "Ergebnis: $PASS PASS, $FAIL FAIL"; [ "$FAIL" -eq 0 ]
