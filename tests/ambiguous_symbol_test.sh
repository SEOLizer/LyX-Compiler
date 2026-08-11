#!/usr/bin/env bash
# tests/ambiguous_symbol_test.sh — #1028: gleichnamige Exporte zweier importierter
# Units muessen gemeldet werden, statt still an eine der beiden zu binden.
#
# Geprueft wird der Weg, nicht das Ergebnis: ein Ergebnistest kann hier nichts
# finden, weil beide Implementierungen plausible Werte liefern -- der Defekt war
# gerade, dass die Bindung unbemerkt von der Import-Reihenfolge abhing.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

# erwartet_fehler <name> <quelltext>
expect_error() {
  printf "%s" "$2" > "$TMP/c.lyx"
  out="$("$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)"
  if echo "$out" | grep -q "mehrdeutiges Symbol"; then
    echo "PASS $1 (Kollision gemeldet)"; PASS=$((PASS+1))
  else
    echo "FAIL $1: keine Kollisionsmeldung"; FAIL=$((FAIL+1))
  fi
}

# erwartet_ok <name> <quelltext>
expect_ok() {
  printf "%s" "$2" > "$TMP/c.lyx"
  out="$("$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)"
  if echo "$out" | grep -q "mehrdeutiges Symbol"; then
    echo "FAIL $1: unerwartete Kollisionsmeldung"; echo "$out" | grep "mehrdeutiges Symbol" | head -3
    FAIL=$((FAIL+1))
  else
    echo "PASS $1 (keine Kollision)"; PASS=$((PASS+1))
  fi
}

# 1. Der Fall aus dem Issue: std.fs und src.std.fs teilen 19 Exportnamen mit
#    unterschiedlicher Semantik (flacher Puffer vs. Hashmap).
expect_error "std_fs_vs_src_std_fs" \
  'import std.fs;
import src.std.fs;
fn main(): int64 { return 0; }'

# 2. Ein einzelner Import derselben Unit ist selbstverstaendlich in Ordnung.
expect_ok "einzelner_import" \
  'import std.fs;
fn main(): int64 { return 0; }'

# 3. Unit-private Helfer duerfen weiterhin gleich heissen: nur `pub` ist ein
#    Angebot an den Aufrufer. Sonst waere jede zweite Unit mit einem internen
#    AlignUp ploetzlich unuebersetzbar.
expect_ok "private_helfer_kollidieren_nicht" \
  'import src.backend.elf.write_elf;
import src.backend.pe.write_pe;
fn main(): int64 { return 0; }'

# 4. Eine Unit darf einen Builtin-Namen ueberdecken (std/io.lyx tut das seit je).
expect_ok "builtin_shadowing_erlaubt" \
  'import std.io;
fn main(): int64 { return 0; }'

echo "Ergebnis: $PASS PASS, $FAIL FAIL"; [ "$FAIL" -eq 0 ]
