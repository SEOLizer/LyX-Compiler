#!/usr/bin/env bash
# tests/lyxos_wp5_sections_test.sh — LYXOS-WP-5: Multi-Section-Metadaten (.text/.rodata/.data).
# Kernel-Modell (LX-34): contiguous-4032 @ VA 0x400000, uniform RW, entry_point = volle VA,
# SECTION_MAP = Block-Ranges + prot (per-Sektion-prot deferred). Prüft:
#  (1) Genesis-Section-Counts text/rodata/data > 0 für Programm mit Code+String+Global.
#  (2) entry_point == 0x400000.
#  (3) Ausführung weiterhin korrekt (Loader lädt ganzes Image via Dateigröße).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
_p(){ echo "PASS $1"; PASS=$((PASS+1)); }
_f(){ echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# u16 little-endian an Datei-Offset lesen
rd16() { local off=$1; local b; b=$(dd if="$TMP/m.lyxnative" bs=1 skip=$off count=2 2>/dev/null | xxd -p); echo $(( 0x${b:2:2}${b:0:2} )); }

printf 'var g: int64 := 9; fn main(): int64 { PrintStr("hello world rodata payload"); return g; }' > "$TMP/m.lyx"
LYX_STD_PATH="$ROOT/std" "$LYXC" --target=lyxos "$TMP/m.lyx" -o "$TMP/m.lyxnative" >/dev/null 2>&1

if [ ! -f "$TMP/m.lyxnative" ]; then _f compile "keine Ausgabe"; echo "Ergebnis: $PASS PASS, $((FAIL+1)) FAIL"; exit 1; fi

# Genesis-Payload @64: text_blocks@+16(0x50), rodata@+18(0x52), data@+20(0x54)
t=$(rd16 80); r=$(rd16 82); d=$(rd16 84)
[ "$t" -gt 0 ] && _p "text_blocks>0 ($t)" || _f text "=$t"
[ "$r" -gt 0 ] && _p "rodata_blocks>0 ($r)" || _f rodata "=$r"
[ "$d" -gt 0 ] && _p "data_blocks>0 ($d)" || _f data "=$d"

# entry_point @ +4 (0x44), u64 → erwarte 0x400000 (= 00 00 40 00 ...)
ep=$(dd if="$TMP/m.lyxnative" bs=1 skip=68 count=4 2>/dev/null | xxd -p)
[ "$ep" = "00004000" ] && _p "entry_point=0x400000" || _f entry "bytes=$ep"

# Ausführung: globaler Wert 9 via lbf_run (ganzes Image geladen trotz Multi-Section-Counts)
printf 'import src.tools.lbf.loader;\nfn main(): int64 { lbf_run("%s/m.lyxnative"c); return 111; }' "$TMP" > "$TMP/r.lyx"
LYX_STD_PATH="$ROOT/std" "$LYXC" "$TMP/r.lyx" -o "$TMP/r" >/dev/null 2>&1
timeout 5 "$TMP/r" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 9 ] && _p "Ausführung global=9 ($rc)" || _f exec "exit=$rc erwartet 9"

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
