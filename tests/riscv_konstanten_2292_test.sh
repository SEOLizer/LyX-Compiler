#!/usr/bin/env bash
# tests/riscv_konstanten_2292_test.sh — Ganzzahlkonstanten sind auf jedem Ziel
# dieselben (#2292).
#
# Der riscv-Weg lud die obersten 2048 Werte des positiven 32-Bit-Bereichs
# falsch. LUI schreibt auf RV64 sein 20-Bit-Feld um zwoelf verschoben und
# VORZEICHENERWEITERT, ADDI liest sein Immediate ebenfalls vorzeichenbehaftet:
#
#   imm  = 0x7FFFFFFF
#   lo12 = 0xFFF -> -1 ; hi20 = 0x80000
#   LUI  rd, 0x80000 -> 0xFFFFFFFF80000000   (Bit 19 gesetzt)
#   ADDI rd, rd, -1  -> 0xFFFFFFFF7FFFFFFF   statt 0x7FFFFFFF
#
# Gemessen war `2147483647` auf riscv -2147483649, und damit
# `1073741824 <= 2147483647` FALSCH. Das ist im Compiler selbst genau die
# Grenzkonstante von cg_emitBinOpImm: der riscv-gebaute lyxc faltete deshalb
# keinen Konstantenvergleich mehr ins Immediate und erzeugte ein 53 KiB
# groesseres x86-Abbild (Rest aus #2276). Bei NEGATIVEN Werten ist die
# Vorzeichenerweiterung gerade richtig — `0 - 2147483648` stimmte, was die
# Suche in die falsche Richtung lenkte.
#
# rv_LI64 prueft jetzt nicht den Bereich, sondern das ERGEBNIS: trifft
# LUI+ADDI den Wert nicht, geht er den sechsteiligen Weg (sechs Stuecke zu je
# elf Bit, #1764), der jeden 64-Bit-Wert traegt.
#
# GEMESSEN WIRD DER WERT als Bitmuster, auf x86_64, arm64 und riscv
# zeichengleich. Enthalten sind die Grenzen selbst (0x7FFFF7FF noch im
# Schnellweg, 0x7FFFF800 der erste betroffene Wert, 0x7FFFFFFF der Fall aus
# dem Melderbefund), die Gegenseite (negative Werte, Werte ueber 32 Bit, ein
# f64-Bitmuster) und die WIRKUNG: der Vergleich, an dem der Compiler haengt.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
. "$(dirname "$0")/lib/qemu.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ulimit -c 0
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

ZIELE="x86"
[ -n "$QEMU_ARM64" ] && ZIELE="$ZIELE arm64" || echo "HINWEIS: Emulator fuer arm64 fehlt"
[ -n "$QEMU_RISCV64" ] && ZIELE="$ZIELE riscv" || echo "HINWEIS: Emulator fuer riscv fehlt"

# Sollwerte gegengerechnet, nicht abgeschrieben.
ERW=$(python3 - <<'PY'
import struct
w = [2147481599, 2147481600, 2147483647, 2147483648, 4294967295,
     -2147483648, -2147483649, 9223372036854775807]
f = struct.unpack('<q', struct.pack('<d', 1.5))[0]
print(' '.join(str(x) for x in w) + f' {f} ja')
PY
)

cat > "$TMP/c.lyx" <<'LYX'
unit main;
import std.io;
import std.alloc;
fn main(): int64 {
  // Grenzen des 32-Bit-Schnellwegs
  PrintInt(2147481599); PrintStr(" "c);      // 0x7FFFF7FF — noch im Schnellweg
  PrintInt(2147481600); PrintStr(" "c);      // 0x7FFFF800 — erster betroffener Wert
  PrintInt(2147483647); PrintStr(" "c);      // 0x7FFFFFFF — der Melderfall
  PrintInt(2147483648); PrintStr(" "c);      // ueber 32 Bit
  PrintInt(4294967295); PrintStr(" "c);
  // Gegenseite: negative Werte, bei denen die Vorzeichenerweiterung richtig ist
  PrintInt(0 - 2147483648); PrintStr(" "c);
  PrintInt(0 - 2147483649); PrintStr(" "c);
  PrintInt(9223372036854775807); PrintStr(" "c);
  // f64-Literal geht als IEEE-Bitmuster durch dieselbe Konstantenladung
  var b: int64 := alloc(8);
  pokef64(b, 1.5);
  PrintInt(peek64(b)); PrintStr(" "c);
  // WIRKUNG: genau der Vergleich, an dem cg_emitBinOpImm haengt
  var c: int64 := 1073741824;
  if (c >= 0 - 2147483648 && c <= 2147483647) { PrintStr("ja"c); } else { PrintStr("NEIN"c); }
  PrintStr("\n"c);
  return 0;
}
LYX

for z in $ZIELE; do
  opt=""; q=""
  [ "$z" = arm64 ] && { opt="--target=arm64"; q="$QEMU_ARM64"; }
  [ "$z" = riscv ] && { opt="--target=riscv"; q="$QEMU_RISCV64"; }
  if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" $opt "$TMP/c.lyx" -o "$TMP/c.$z" >"$TMP/c.$z.log" 2>&1); then
    no "$z" "uebersetzt nicht: $(grep -m1 -iE 'error|lyxc:' "$TMP/c.$z.log")"; continue
  fi
  got=$( cd "$TMP" && timeout 60 $q "$TMP/c.$z" 2>&1 | tr -d '\n' )
  if [ "$got" = "$ERW" ]; then ok "$z: $got"
  else no "$z" "'$got' erwartet '$ERW'"; fi
done

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
