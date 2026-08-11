#!/usr/bin/env bash
# tests/lyxos_wp4_fields_test.sh — LYXOS-WP-4: Fields (structs) + Index (arrays).
# Disasm-Verifikation: die nativen lyxos-Programme nutzen Heap-alloc (lyxos-mmap-ABI),
# daher NICHT auf POSIX via lbf_run ausführbar — geprüft wird die korrekte Emission der
# Feld-/Index-Lade/Speicher-Sequenzen in der Text-Section.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

chk() { # name, source, instr-regex
  printf "%s" "$2" > "$TMP/t.lyx"
  LYX_STD_PATH="$ROOT/std" "$LYXC" --target=lyxos "$TMP/t.lyx" -o "$TMP/t.lyxnative" >/dev/null 2>&1
  if [ ! -f "$TMP/t.lyxnative" ]; then _f "$1" "kompiliert nicht"; return; fi
  dd if="$TMP/t.lyxnative" bs=1 skip=4160 count=900 2>/dev/null > "$TMP/tt.bin"
  if objdump -D -b binary -m i386:x86-64 -M intel "$TMP/tt.bin" 2>/dev/null | grep -qiE "$3"; then
    echo "PASS $1"; PASS=$((PASS+1))
  else
    echo "FAIL $1: Sequenz fehlt: $3"; FAIL=$((FAIL+1))
  fi
}
_f(){ echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# Struct-Feld: STORE_FIELD (mov [rcx+off],rax) + LOAD_FIELD (mov rax,[rax+off])
chk "FIELD_store" 'type P = class { x: int64; y: int64; }; fn main(): int64 { var p: P := new P(); p.x := 5; p.y := 7; return p.x + p.y; }' 'mov +QWORD PTR \[rcx\+0x8\],rax'
chk "FIELD_load"  'type P = class { x: int64; y: int64; }; fn main(): int64 { var p: P := new P(); p.x := 5; return p.x; }' 'mov +rax,QWORD PTR \[rax\+0x0\]'
# Array-Index: STORE_IDX (mov [rdx+rcx*8],rax) + LOAD_IDX (mov rax,[rax+rcx*8])
chk "IDX_store"   'fn main(): int64 { var arr: array := [5, 7, 9, 11]; arr[0] := 100; return arr[0]; }' 'mov +QWORD PTR \[rdx\+rcx\*8\],rax'
chk "IDX_load"    'fn main(): int64 { var arr: array := [5, 7, 9, 11]; return arr[0] + arr[1]; }' 'mov +rax,QWORD PTR \[rax\+rcx\*8\]'

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
