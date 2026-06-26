#!/usr/bin/env bash
# tests/method_ptr_test.sh — B2: method-pointer (fat pointer {code,data}) als Klassenfeld (ELF).
# `field := obj.Method` bindet Instanz; `field(args)` ruft mit self=obj → Handler-self-Zugriff.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; LYXC="$ROOT/lyxc"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
run(){ printf "%s" "$2" > "$TMP/c.lyx"; LYX_STD_PATH="$ROOT/std" "$LYXC" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1 || { echo "FAIL $1: compile"; FAIL=$((FAIL+1)); return; }
  timeout 5 "$TMP/c" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq "$3" ]; then echo "PASS $1 (=$rc)"; PASS=$((PASS+1)); else echo "FAIL $1: exit=$rc erwartet $3"; FAIL=$((FAIL+1)); fi; }
P='type TC = class { x: int64; }; type TM = method(TC): int64; type TForm = class { tag: int64; fn Handle(s: TC): int64 { return self.tag + s.x; } }; type TButton = class extends TC { on_click: TM; };'
# self-Bindung: Handle nutzt self.tag(30) + arg s.x(12) = 42
run "self_binding"   "$P fn main(): int64 { var f: TForm := new TForm(); f.tag := 30; var b: TButton := new TButton(); b.x := 12; b.on_click := f.Handle; return b.on_click(b as TC); }" 42
# null-check: ungesetztes method-Feld = 0
run "null_unset"     "$P fn main(): int64 { var b: TButton := new TButton(); if (b.on_click != 0) { return 1; } return 7; }" 7
# andere Instanz → andere self-Bindung
run "distinct_self"  "$P fn main(): int64 { var f1: TForm := new TForm(); f1.tag := 5; var f2: TForm := new TForm(); f2.tag := 50; var b: TButton := new TButton(); b.x := 0; b.on_click := f2.Handle; return b.on_click(b as TC); }" 50
echo "Ergebnis: $PASS PASS, $FAIL FAIL"; [ "$FAIL" -eq 0 ]
