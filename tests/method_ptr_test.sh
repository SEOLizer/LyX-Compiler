#!/usr/bin/env bash
# tests/method_ptr_test.sh — B2: method-pointer (fat pointer {code,data}), ELF.
# `ziel := obj.Method` bindet die Instanz; `ziel(args)` ruft mit self=obj.
#
# Bis 1.0.13A deckte diese Suite nur die FELD-Variante ab. Als lokale Variable
# uebersetzte derselbe Code klaglos und stuerzte beim Aufruf ab (#1106): die
# Bindung fand nicht statt, `f.Handle` wurde als FELD geladen — Offset 0, also
# der VMT-Zeiger, und der Aufruf sprang ins Leere. Die lokale Variante steht
# deshalb jetzt gleichberechtigt daneben; drei gruene Feldtests sagten ueber
# sie nichts aus.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
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

# --- #1106: dieselbe Bindung an einer LOKALEN Variablen -------------------
Q='type TC = class { x: int64; }; type TM = method(TC): int64; type TForm = class { tag: int64; fn Handle(s: TC): int64 { return self.tag + s.x; } };'
# Der Repro aus dem Issue: Initialisierung bindet, Aufruf trifft self.
run "local_init"     "$Q fn main(): int64 { var f: TForm := new TForm(); f.tag := 30; var c: TC := new TC(); c.x := 12; var m: TM := f.Handle; return m(c); }" 42
# Deklaration und Zuweisung getrennt — derselbe Weg, eine Anweisung spaeter.
run "local_assign"   "$Q fn main(): int64 { var f: TForm := new TForm(); f.tag := 30; var c: TC := new TC(); c.x := 12; var m: TM; m := f.Handle; return m(c); }" 42
# Umbinden auf eine andere Instanz: der zweite Aufruf muss das neue self sehen.
run "local_rebind"   "$Q fn main(): int64 { var f1: TForm := new TForm(); f1.tag := 5; var f2: TForm := new TForm(); f2.tag := 40; var c: TC := new TC(); c.x := 2; var m: TM := f1.Handle; m := f2.Handle; return m(c); }" 42
# Aus einem gebundenen FELD in eine lokale Variable kopieren: hier darf NICHT
# neu gebunden werden, der fat pointer wird schlicht uebernommen.
run "local_from_field" "$P fn main(): int64 { var f: TForm := new TForm(); f.tag := 30; var b: TButton := new TButton(); b.x := 12; b.on_click := f.Handle; var m: TM := b.on_click; return m(b as TC); }" 42
# Gegenprobe: ein gewoehnliches Feld gleicher Bauart wird weiterhin GELADEN
# und nicht als Methode gebunden.
run "plain_field_load" "$P fn main(): int64 { var b: TButton := new TButton(); b.x := 42; var v: int64 := b.x; return v; }" 42

echo "Ergebnis: $PASS PASS, $FAIL FAIL"; [ "$FAIL" -eq 0 ]
