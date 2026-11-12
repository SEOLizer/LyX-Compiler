#!/usr/bin/env bash
# tests/lyxos_pchar_var_test.sh — pchar-Variable an PrintStr (lyxos-Backend).
# Bug: `var x: pchar := "..."; PrintStr(x)` fiel in Legacy-CALL_BUILTIN ohne slot-0-Setup
# → falscher rodata-Pointer (null-flood auf LX-34). Fix: PrintStr(non-literal)-Pfad
# (slot0=ptr, slot1=-1) + Runtime-strlen in emitPrintStr.
# PrintStr nutzt lyxos-write-Syscall (0x0203) → nicht POSIX-ausführbar; daher Disasm-Verifikation.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
_p(){ echo "PASS $1"; PASS=$((PASS+1)); }
_f(){ echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

printf 'fn main(): int64 { var x: pchar := "HELLO"; PrintStr(x); return 0; }' > "$TMP/v.lyx"
LYX_STD_PATH="$ROOT/std" "$LYXC" --target=lyxos "$TMP/v.lyx" -o "$TMP/v.lyxnative" >/dev/null 2>&1
if [ ! -f "$TMP/v.lyxnative" ]; then _f compile "keine Ausgabe"; echo "Ergebnis: $PASS PASS, $((FAIL+1)) FAIL"; exit 1; fi
dd if="$TMP/v.lyxnative" bs=1 skip=4160 count=300 2>/dev/null > "$TMP/t.bin"
D=$(objdump -D -b binary -m i386:x86-64 -M intel "$TMP/t.bin" 2>/dev/null)

# (1) String-Pointer aus slot 0 (rbp-0x8) nach rsi
echo "$D" | grep -qiE "mov +rsi,QWORD PTR \[rbp-0x8\]" && _p "slot0→rsi (ptr-Setup)" || _f slot0 "rsi nicht aus [rbp-0x8]"
# (2) Runtime-strlen-Loop: CMP byte[rsi+rdx],0
echo "$D" | grep -qiE "cmp +BYTE PTR \[rsi\+rdx" && _p "strlen-Loop (cmp byte[rsi+rdx])" || _f strlen "kein strlen-Loop"
# (3) len<0-Gate: TEST rdx,rdx + JNS
echo "$D" | grep -qiE "test +rdx,rdx" && _p "len-Sentinel-Gate (test rdx)" || _f gate "kein test rdx,rdx"
# (4) lyxos-write-Syscall 0x203
echo "$D" | grep -qiE "0x203" && _p "write-Syscall 0x203" || _f wr "kein 0x203"

# (5) End-to-End: pchar-Var zeigt auf rodata-Literal (nicht Symbol-Tabelle).
#     x[0] muss 'H' (72) sein — via lbf_run nativ ausgeführt (Pointer korrekt = byte 0).
printf 'fn main(): int64 { var x: pchar := "HELLO"; return x[0]; }' > "$TMP/e.lyx"
LYX_STD_PATH="$ROOT/std" "$LYXC" --target=lyxos "$TMP/e.lyx" -o "$TMP/e.lyxnative" >/dev/null 2>&1
printf 'import src.tools.lbf.loader;\nfn main(): int64 { lbf_run("%s/e.lyxnative"c); return 111; }' "$TMP" > "$TMP/er.lyx"
LYX_STD_PATH="$ROOT/std" "$LYXC" "$TMP/er.lyx" -o "$TMP/er" >/dev/null 2>&1
timeout 5 "$TMP/er" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 72 ] && _p "pchar-Var → rodata (x[0]='H'=72)" || _f ptr "x[0]=$rc erwartet 72 (zeigt evtl. falsche Tabelle)"

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
