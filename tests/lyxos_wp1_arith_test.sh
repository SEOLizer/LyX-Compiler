#!/usr/bin/env bash
# tests/lyxos_wp1_arith_test.sh — LYXOS-WP-1: Arithmetik + Vergleiche im nativen lyxos-Emit.
# Kompiliert lyxos-Programme zu nativem LYX!, disassembliert die Text-Section (Block 1,
# Datei-Offset 4160) und prüft, dass die erwarteten x86-64-Binop-Instruktionen vorkommen.
# (lyxos-Code nutzt lyxos-Syscalls → nicht auf POSIX ausführbar; daher Disasm-Verifikation.)

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
_p(){ echo "PASS $1"; PASS=$((PASS+1)); }
_f(){ echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

chk() { # name, source, instr-regex
  printf "%s" "$2" > "$TMP/t.lyx"
  LYX_STD_PATH="$ROOT/std" "$LYXC" --target=lyxos "$TMP/t.lyx" -o "$TMP/t.lyxnative" >/dev/null 2>&1
  if [ ! -f "$TMP/t.lyxnative" ]; then _f "$1" "kompiliert nicht"; return; fi
  dd if="$TMP/t.lyxnative" bs=1 skip=4160 count=600 2>/dev/null > "$TMP/tt.bin"
  if objdump -D -b binary -m i386:x86-64 -M intel "$TMP/tt.bin" 2>/dev/null | grep -qiE "$3"; then
    _p "$1"
  else
    _f "$1" "Instruktion fehlt: $3"
  fi
}

chk "ADD"     'fn main(): int64 { var a: int64 := 5; var b: int64 := 7; return a + b; }'  'add +rax,rcx'
chk "SUB"     'fn main(): int64 { var a: int64 := 9; var b: int64 := 2; return a - b; }'  'sub +rax,rcx'
chk "IMUL"    'fn main(): int64 { var a: int64 := 6; var b: int64 := 7; return a * b; }'  'imul +rax,rcx'
chk "IDIV"    'fn main(): int64 { var a: int64 := 20; var b: int64 := 4; return a / b; }' 'idiv +rcx'
chk "CMP_LT"  'fn main(): int64 { var a: int64 := 6; var b: int64 := 7; if a < b { return 1; } return 0; }' 'setl +al'
chk "BITAND"  'fn main(): int64 { var a: int64 := 6; var b: int64 := 3; return a & b; }'  'and +rax,rcx'

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
