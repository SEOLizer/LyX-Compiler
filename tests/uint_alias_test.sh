#!/usr/bin/env bash
# tests/uint_alias_test.sh — #1010: uintN ist die zweite Schreibweise von uN.
#
# Der eigentliche Defekt war die UNEINIGKEIT der beiden Wege: im var-Deklarator
# wurde `uint8` abgewiesen, als Struct-Feld stillschweigend akzeptiert — dort
# aber mit 8 Byte statt 1 belegt. Geprüft wird deshalb nicht nur, dass es
# übersetzt, sondern die tatsächliche Feldbreite.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; LYXC="$ROOT/lyxc"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

run(){ printf "%s" "$2" > "$TMP/c.lyx"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    echo "FAIL $1: uebersetzt nicht"; FAIL=$((FAIL+1)); return; fi
  timeout 5 "$TMP/c" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq "$3" ]; then echo "PASS $1 (=$rc)"; PASS=$((PASS+1))
  else echo "FAIL $1: exit=$rc erwartet $3"; FAIL=$((FAIL+1)); fi; }

# var-Deklarator: vor dem Fix "unknown type in var decl 'uint8'"
run "var_uint8"   'fn main(): int64 { var x: uint8  := 42;    return x as int64; }' 42
run "var_uint16"  'fn main(): int64 { var x: uint16 := 300;   return x as int64; }' 44   # 300 & 0xFF im Exitcode
run "var_uint32"  'fn main(): int64 { var x: uint32 := 70000; return (x as int64) - 69958; }' 42

# Cast auf uintN schneidet wie auf uN
run "cast_uint8"  'fn main(): int64 { var x: int64 := 300; return (x as uint8) as int64; }' 44

# Als Feldtyp akzeptiert und Werte kommen unveraendert zurueck. Die tatsaechliche
# FELDBREITE laesst sich hier nicht pruefen: @packed wird im x86-Codegen derzeit
# ignoriert (jedes Feld belegt 8 Byte, unabhaengig vom Typ) — eigener Defekt,
# siehe Issue #1038.
run "feldtyp"    'struct S { a: uint8; b: uint16; c: uint32; }
fn main(): int64 {
  var s: S;
  s.a := 7; s.b := 300; s.c := 70000;
  if (s.a != 7)     { return 1; }
  if (s.b != 300)   { return 2; }
  if (s.c != 70000) { return 3; }
  return 42;
}' 42

# uN bleibt selbstverständlich gültig
run "u8_weiterhin" 'fn main(): int64 { var x: u8 := 42; return x as int64; }' 42

echo "Ergebnis: $PASS PASS, $FAIL FAIL"; [ "$FAIL" -eq 0 ]
