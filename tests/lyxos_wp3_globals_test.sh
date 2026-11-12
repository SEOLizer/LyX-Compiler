#!/usr/bin/env bash
# tests/lyxos_wp3_globals_test.sh — LYXOS-WP-3: Globals (LOAD_GLOBAL/STORE_GLOBAL/ADDR).
# Globals liegen im an den Code angehängten Daten-Pool (Init-Werte aus IR globalBuffer),
# RIP-relativ adressiert. Native Ausführung via lbf_run (sys_exit==Linux 60), Resultat=Exit-Code.
# (Getrennte .data-Section mit RW-prot folgt in WP-5.)

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

run "G_init"  'var g: int64 := 7; fn main(): int64 { return g; }' 7
run "G_store" 'var g: int64 := 0; fn main(): int64 { g := 5; return g; }' 5
run "G_rmw"   'var g: int64 := 10; fn main(): int64 { g := g + 4; return g; }' 14
run "G_accum" 'var c: int64 := 0; fn main(): int64 { var i: int64 := 0; while i < 3 { c := c + 2; i := i + 1; } return c; }' 6
run "G_two"   'var a: int64 := 3; var b: int64 := 4; fn main(): int64 { return a * b; }' 12

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
