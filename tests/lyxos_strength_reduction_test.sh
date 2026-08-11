#!/usr/bin/env bash
# tests/lyxos_strength_reduction_test.sh — Strength-Reduction *2^k / /2^k auf --target=lyxos.
# Regression für fix/lyxos-strength-reduction-shift: ir_optimize.strengthReduction setzte beim
# Umbau MUL→SHL / DIV→SHR den Shift-Count (power) als ROHEN Integer in src2 (setInstrSrc2(i,power)).
# IR-Backends lesen src2 als Temp-/Slot-Referenz → `shl rax, cl` mit cl aus Slot #power (fremde
# Variable) statt dem Shift-Betrag. Symptom: x*2/4/8/16→Garbage(oft 0), x/4/8→Garbage; non-pow2
# (×3,×5,÷3) ok, expliziter x<<2 ok (nur strength-reduced kaputt). lbfwin-Crash: DrawChar
# buf+(y*w+x)*4 (BGRA) → wilder Shift → #PF. Fix: den Wert des bereits von src2 referenzierten
# CONST_INT-Temps auf `power` ändern (setConstDefValue), src2-Referenz bleibt (wie x<<2).
# Native Ausführung via lbf_run (sys_exit=Linux 60), Exit-Code = Resultat.

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

# Multiplikation mit Zweierpotenz (strength-reduced → SHL)
run "mul2"   'fn main(): int64 { var x: int64 := 5; return x * 2; }' 10
run "mul4"   'fn main(): int64 { var x: int64 := 5; return x * 4; }' 20
run "mul8"   'fn main(): int64 { var x: int64 := 5; return x * 8; }' 40
run "mul16"  'fn main(): int64 { var x: int64 := 3; return x * 16; }' 48
run "mul1"   'fn main(): int64 { var x: int64 := 7; return x * 1; }' 7
# Division durch Zweierpotenz. NICHT mehr strength-reduced: Rechtsschieben rundet ab,
# Division trunkiert Richtung Null — bei negativem Dividenden mit Rest divergiert das.
# Exakt teilbare Werte kamen auch mit der alten SHR-Umformung richtig heraus, deshalb
# die negativen Fälle mit Rest direkt darunter.
run "div4"   'fn main(): int64 { var x: int64 := 20; return x / 4; }' 5
run "div8"   'fn main(): int64 { var x: int64 := 80; return x / 8; }' 10
# -21/4 muss -5 sein (Trunkierung), nicht -6 (Abrundung). +100 wegen Exit-Code.
run "div_neg_rest"   'fn main(): int64 { var x: int64 := 0 - 21; return x / 4 + 100; }' 95
run "div_neg_rest8"  'fn main(): int64 { var x: int64 := 0 - 30; return x / 8 + 100; }' 97
run "div_neg_exact"  'fn main(): int64 { var x: int64 := 0 - 20; return x / 4 + 100; }' 95
# 2^0: die alte DIV-Umformung lieferte hier konstant 1 statt x.
run "div1"   'fn main(): int64 { var x: int64 := 7; return x / 1; }' 7
run "div1_b" 'fn main(): int64 { var x: int64 := 42; return x / 1; }' 42
# MUL bleibt reduziert und ist auch für negative Werte exakt (Zweierkomplement).
run "mul_neg" 'fn main(): int64 { var x: int64 := 0 - 5; return x * 4 + 100; }' 80
# Geteiltes Const-Temp: MOD wird nicht reduziert, darf also nicht die auf log2
# umgeschriebene Konstante einer benachbarten MUL sehen.
run "mul_mod_shared_const" 'fn main(): int64 { var x: int64 := 6; var y: int64 := 9; return x * 4 + y % 4; }' 25
run "mul_div_shared_const" 'fn main(): int64 { var x: int64 := 6; var y: int64 := 40; return x * 4 + y / 4; }' 34
# Nicht-Zweierpotenz bleibt echte MUL/DIV
run "mul3"   'fn main(): int64 { var x: int64 := 5; return x * 3; }' 15
# Expliziter Shift unverändert korrekt
run "shl2"   'fn main(): int64 { var x: int64 := 5; return x << 2; }' 20
# Mehrere strength-reduced Ops in einer Funktion (Const-Temp-Mutation darf nicht leaken)
run "multi"  'fn main(): int64 { var a: int64 := 3; var b: int64 := 5; return a * 4 + b * 2; }' 22
# Operand nach strength-reduce weiter nutzbar
run "reuse"  'fn main(): int64 { var x: int64 := 6; var y: int64 := x * 4; return y + x; }' 30
# lbfwin DrawChar-Muster: (y*w+x)*4 (BGRA-Offset) — der ursprüngliche #PF
run "drawchar_offset" 'fn main(): int64 { var w: int64 := 10; var x: int64 := 2; var y: int64 := 1; return (y * w + x) * 4; }' 48

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
