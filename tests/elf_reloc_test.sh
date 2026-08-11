#!/usr/bin/env bash
# tests/elf_reloc_test.sh — LyxOS-Reloc Step 1: WriteELF emittiert PT_LYXRELOC (0x6FFFAA00)
# für Release-Builds mit Base-Relocs (Klassen/VMT). Linux ignoriert das Segment → läuft normal.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
chk(){ if [ "$2" = "$3" ]; then echo "PASS $1 ($2)"; PASS=$((PASS+1)); else echo "FAIL $1: $2 != $3"; FAIL=$((FAIL+1)); fi; }

# vtable-Programm → PT_LYXRELOC vorhanden, läuft =42
printf 'type A = class { x: int64; fn f(): int64 { return self.x + 40; } }; fn main(): int64 { var a: A := new A(); a.x := 2; return a.f(); }' > "$TMP/v.lyx"
LYX_STD_PATH="$ROOT/std" "$LYXC" "$TMP/v.lyx" -o "$TMP/v" >/dev/null 2>&1
timeout 5 "$TMP/v" >/dev/null 2>&1; chk "vtable_runs" "$?" "42"
HAS=$(python3 -c "
import struct,sys; d=open('$TMP/v','rb').read()
phoff=struct.unpack('<Q',d[32:40])[0]; phnum=struct.unpack('<H',d[56:58])[0]; n=0
for i in range(phnum):
  if struct.unpack('<I',d[phoff+i*56:phoff+i*56+4])[0]==0x6FFFAA00: n+=1
print(n)")
chk "vtable_has_lyxreloc" "$HAS" "1"

# Reloc-Count > 0 + erste rva plausibel (innerhalb Datei)
CNT=$(python3 -c "
import struct; d=open('$TMP/v','rb').read()
phoff=struct.unpack('<Q',d[32:40])[0]; phnum=struct.unpack('<H',d[56:58])[0]
for i in range(phnum):
  p=d[phoff+i*56:phoff+i*56+56]
  if struct.unpack('<I',p[0:4])[0]==0x6FFFAA00:
    off=struct.unpack('<Q',p[8:16])[0]; print(struct.unpack('<Q',d[off:off+8])[0]); break")
if [ "$CNT" -ge 1 ] 2>/dev/null; then echo "PASS reloc_count_positive ($CNT)"; PASS=$((PASS+1)); else echo "FAIL reloc_count_positive ($CNT)"; FAIL=$((FAIL+1)); fi

# Programm OHNE Klassen → kein PT_LYXRELOC (baseRelocCount=0 → Alt-Pfad, e_phnum=2), läuft =7
printf 'fn main(): int64 { return 7; }' > "$TMP/p.lyx"
LYX_STD_PATH="$ROOT/std" "$LYXC" "$TMP/p.lyx" -o "$TMP/p" >/dev/null 2>&1
timeout 5 "$TMP/p" >/dev/null 2>&1; chk "plain_runs" "$?" "7"
PN=$(python3 -c "import struct; d=open('$TMP/p','rb').read(); print(struct.unpack('<H',d[56:58])[0])")
chk "plain_no_reloc_phnum2" "$PN" "2"

echo "Ergebnis: $PASS PASS, $FAIL FAIL"; [ "$FAIL" -eq 0 ]
