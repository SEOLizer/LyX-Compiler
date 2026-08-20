#!/usr/bin/env bash
# tests/asm_block_test.sh — WSP-05: asm { "mnemonic" } Inline-Assembly (ELF).
# Feste Mnemonic-Tabelle → echte x86-Bytes; `asm` als Soft-Keyword; unbekannt → Fehler.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
run(){ printf "%s" "$2" > "$TMP/c.lyx"; LYX_STD_PATH="$ROOT/std" "$LYXC" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1 || { echo "FAIL $1: compile"; FAIL=$((FAIL+1)); return; }
  timeout 5 "$TMP/c" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq "$3" ]; then echo "PASS $1 (=$rc)"; PASS=$((PASS+1)); else echo "FAIL $1: exit=$rc erwartet $3"; FAIL=$((FAIL+1)); fi; }
# unprivilegierte Mnemonics laufen durch (nop/rdtsc/pause/lfence/mfence/cpuid)
run "run_unpriv" 'fn main(): int64 { asm { "nop" "rdtsc" "pause" "lfence" "mfence" } return 42; }' 42
run "run_cpuid"  'fn main(): int64 { asm { "cpuid" } return 7; }' 7
# asm als normaler Bezeichner (Soft-Keyword nur vor {)
run "asm_ident"  'fn main(): int64 { var asm: int64 := 5; return asm; }' 5
# Byte-Korrektheit: cli/sti/hlt/lgdt[rdi] müssen als fa fb f4 0f0117 im Binary stehen
printf 'fn k(): void { asm { "cli" "sti" "hlt" "lgdt [rdi]" } }\nfn main(): int64 { return 0; }' > "$TMP/k.lyx"
LYX_STD_PATH="$ROOT/std" "$LYXC" "$TMP/k.lyx" -o "$TMP/k" >/dev/null 2>&1
if python3 -c "import sys; d=open('$TMP/k','rb').read(); sys.exit(0 if bytes([0xFA,0xFB,0xF4,0x0F,0x01,0x17]) in d else 1)"; then
  echo "PASS bytes_kernel (cli/sti/hlt/lgdt)"; PASS=$((PASS+1)); else echo "FAIL bytes_kernel"; FAIL=$((FAIL+1)); fi
# unbekannte Mnemonic → Compile-Fehler (rc != 0)
printf 'fn main(): int64 { asm { "frobnicate" } return 0; }' > "$TMP/u.lyx"
if LYX_STD_PATH="$ROOT/std" "$LYXC" "$TMP/u.lyx" -o "$TMP/u" >/dev/null 2>&1; then echo "FAIL unknown_rejected: kompilierte"; FAIL=$((FAIL+1)); else echo "PASS unknown_rejected"; PASS=$((PASS+1)); fi
echo "Ergebnis: $PASS PASS, $FAIL FAIL"; [ "$FAIL" -eq 0 ]
