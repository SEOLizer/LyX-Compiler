#!/usr/bin/env bash
# tests/rechtsshift_2236_test.sh — Rechtsshift mit und ohne Vorzeichen auf allen Zielen (#2236).
#
# Das IR kannte bis 1.2.19N nur EINEN Rechtsshift (IRO_SHR), und jedes
# Backend legte ihn anders aus: arm64 als ASR (arithmetisch), riscv, arm-cm,
# xtensa und lyxos als logischen Shift. x86 (eigener Codegen) unterscheidet
# nach dem Vorzeichen des linken Operanden. Gemessen:
#   (x as uint64) >> 60 mit x = -16:  x86 15, arm64 -1, riscv 15
#   x >> 60 (vorzeichenbehaftet):    x86 -1, arm64 -1, riscv 15
# Seitdem gibt es IRO_SAR; ir_lower waehlt nach derselben Regel wie
# cg_isUnsignedExpr, und die Konstantenfaltung rechnet IRO_SHR logisch.
#
# Gemessen werden die WERTE, und zwar beide Richtungen auf jedem Ziel — ein
# Test nur fuer den vorzeichenlosen Fall waere von einem Backend erfuellt,
# das immer logisch schiebt (so war riscv). Auf den 32-Bit-Zielen (int64 ist
# dort ein Wort) nur Weiten unter 32 und Werte in 32 Bit.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
. "$(dirname "$0")/lib/qemu.sh"   # #2048
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ulimit -c 0
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

QARM="$(command -v qemu-system-arm || true)"
HUELLE="$ROOT/tests/lib/xtensa_huelle.py"

# Gemeinsamer Teil: Weiten < 32, Werte in 32 Bit. Rueckgabe 0 oder die
# Nummer der ersten Abweichung (die Xtensa-Huelle meldet nur den Exit-Code).
cat > "$TMP/k32.lyx" <<'LYX'
fn pruefe32(): int64 {
  var x: int64 := 0 - 16;
  var n: int64 := 3;
  var r: int64 := 0;
  r := (x as uint32) >> 28;  if (r != 15) { return 1; }
  r := x >> 28;              if (r != 0 - 1) { return 2; }
  r := x >> 2;               if (r != 0 - 4) { return 3; }
  r := x >> n;               if (r != 0 - 2) { return 4; }
  r := (x as uint32) >> n;   if (r != 536870910) { return 5; }
  var u: uint32 := x as uint32;
  r := u >> 4;               if (r != 268435455) { return 6; }
  r := (0 - 16) >> 2;        if (r != 0 - 4) { return 7; }
  r := ((0 - 16) as uint32) >> 28; if (r != 15) { return 8; }
  var p: int64 := 1000;
  r := p >> 3;               if (r != 125) { return 9; }
  return 0;
}
LYX
# Nur 64 Bit: Weiten ab 32, volle 64-Bit-Werte.
cat > "$TMP/k64.lyx" <<'LYX'
fn pruefe64(): int64 {
  var x: int64 := 0 - 16;
  var n: int64 := 60;
  var r: int64 := 0;
  r := (x as uint64) >> 60;  if (r != 15) { return 21; }
  r := (x as uint64) >> n;   if (r != 15) { return 22; }
  r := x >> 60;              if (r != 0 - 1) { return 23; }
  r := x >> n;               if (r != 0 - 1) { return 24; }
  var u: uint64 := x as uint64;
  r := u >> 61;              if (r != 7) { return 25; }
  r := ((0 - 16) as uint64) >> 60; if (r != 15) { return 26; }
  r := (0 - 16) >> 60;       if (r != 0 - 1) { return 27; }
  return 0;
}
LYX
{ cat "$TMP/k32.lyx" "$TMP/k64.lyx"; echo 'fn main(): int64 { var e: int64 := pruefe32(); if (e != 0) { return e; } return pruefe64(); }'; } > "$TMP/voll.lyx"
{ cat "$TMP/k32.lyx"; echo 'fn main(): int64 { return pruefe32(); }'; } > "$TMP/w32.lyx"
{ echo 'import std.io;'; cat "$TMP/k32.lyx"; echo 'fn main(): int64 { var e: int64 := pruefe32(); PrintInt(e); PrintLn(""c); return 0; }'; } > "$TMP/druck32.lyx"

uebersetze() { # quelle, ziel(leer = x86), ausgabe
  local opt=""; [ -n "$2" ] && opt="--target=$2"
  (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" $opt "$1" -o "$3" >"$3.log" 2>&1)
}
lauf64() { # name ziel runner
  if ! uebersetze "$TMP/voll.lyx" "$2" "$TMP/v.$1"; then no "$1" "uebersetzt nicht: $(grep -v Copyright "$TMP/v.$1.log" | head -2 | tr '\n' ' ')"; return; fi
  if [ "$1" != x86 ] && [ -z "$3" ]; then echo "HINWEIS: qemu fuer $1 fehlt — nur uebersetzt."; ok "$1 uebersetzt"; return; fi
  (cd "$TMP" && timeout 30 $3 "$TMP/v.$1" >/dev/null 2>&1); local rc=$?
  if [ "$rc" -eq 0 ]; then ok "$1: 16 Faelle mit und ohne Vorzeichen"; else no "$1" "Abweichung Nr. $rc"; fi
}
lauf64 x86 "" ""
lauf64 arm64 arm64 "$QEMU_ARM64"
lauf64 riscv riscv "$QEMU_RISCV64"

# arm-cm4: Semihosting-Ausgabe
if uebersetze "$TMP/druck32.lyx" arm-cm4 "$TMP/d.cm4"; then
  if [ -z "$QARM" ]; then echo "HINWEIS: qemu-system-arm fehlt — arm-cm4 nur uebersetzt."; ok "arm-cm4 uebersetzt"
  else
    got="$(timeout 20 "$QARM" -M olimex-stm32-h405 -nographic -semihosting -kernel "$TMP/d.cm4" 2>&1 </dev/null | tr -d '\r' | grep -vE 'terminating on signal|^qemu-system-arm:|^qemu:' | head -1)"
    if [ "$got" = "0" ]; then ok "arm-cm4: 9 Faelle (32 Bit)"; else no "arm-cm4" "Abweichung Nr. '$got'"; fi
  fi
else no "arm-cm4" "uebersetzt nicht: $(grep -m1 -iE 'error' "$TMP/d.cm4.log")"; fi

# esp32: Rueckgabewert ueber die Xtensa-Huelle
if uebersetze "$TMP/w32.lyx" esp32 "$TMP/w.esp"; then
  if [ -z "$QEMU_XTENSA" ]; then echo "HINWEIS: qemu-xtensa fehlt — esp32 nur uebersetzt."; ok "esp32 uebersetzt"
  elif ! python3 "$HUELLE" "$TMP/w.esp" "$TMP/w.run" >/dev/null 2>&1; then no "esp32" "Huelle konnte das Abbild nicht umpacken"
  else
    (cd "$TMP" && timeout 60 "$QEMU_XTENSA" "$TMP/w.run" >/dev/null 2>&1); rc=$?
    if [ "$rc" -eq 0 ]; then ok "esp32: 9 Faelle (32 Bit)"; else no "esp32" "Abweichung Nr. $rc"; fi
  fi
else no "esp32" "uebersetzt nicht: $(grep -m1 -iE 'error' "$TMP/w.esp.log")"; fi

# lyxos: am Erzeugnis — der vorzeichenbehaftete Shift ist `sar rax, cl`
# (48 D3 F8), der vorzeichenlose `shr rax, cl` (48 D3 E8).
for f in "x >> n:f8" "(x as uint64) >> n:e8"; do
  ausdr="${f%%:*}"; byte="${f##*:}"
  printf 'fn main(): int64 { var x: int64 := 0 - 16; var n: int64 := 3; var r: int64 := %s; return r; }\n' "$ausdr" > "$TMP/l.lyx"
  if uebersetze "$TMP/l.lyx" lyxos "$TMP/l.out"; then
    if od -An -v -tx1 "$TMP/l.out" | tr -s ' \n' ' ' | grep -q " 48 d3 $byte"; then ok "lyxos: $ausdr -> 48 d3 $byte"
    else no "lyxos $ausdr" "48 d3 $byte fehlt im Erzeugnis"; fi
  else no "lyxos $ausdr" "uebersetzt nicht"; fi
done

echo "rechtsshift_2236: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
