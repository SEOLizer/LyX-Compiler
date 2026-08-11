#!/usr/bin/env bash
# tests/lbf_native_emit_test.sh — LX-30: nativer lyxos-LYX!-Emit (--target=lyxos)
# Kompiliert ein triviales Programm zu nativem LYX! und prüft Magic + Block-Geometrie.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
_p(){ echo "PASS $1"; PASS=$((PASS+1)); }
_f(){ echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

printf 'fn main(): int64 { return 42; }' > "$TMP/p.lyx"
LYX_STD_PATH="$ROOT/std" "$LYXC" --target=lyxos "$TMP/p.lyx" -o "$TMP/p.lyxnative" >/dev/null 2>&1

# 1: Datei erzeugt
if [ -f "$TMP/p.lyxnative" ]; then _p 1; else _f 1 "keine Ausgabe"; echo "Ergebnis: $PASS PASS, $FAIL FAIL"; exit 1; fi
# 2: Magic LYX! (4C 59 58 21)
magic=$(head -c4 "$TMP/p.lyxnative" | xxd -p)
if [ "$magic" = "4c595821" ]; then _p 2; else _f 2 "Magic=$magic (erw 4c595821)"; fi
# 3: Größe Vielfaches von 4096
sz=$(stat -c%s "$TMP/p.lyxnative")
if [ $((sz % 4096)) -eq 0 ] && [ "$sz" -ge 4096 ]; then _p 3; else _f 3 "size=$sz nicht 4096-aligned"; fi

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
