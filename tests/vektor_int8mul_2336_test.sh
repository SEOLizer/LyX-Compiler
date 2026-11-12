#!/usr/bin/env bash
# tests/vektor_int8mul_2336_test.sh — #2336: Byte-Multiplikation vektorisieren.
#
# `int8_add` lag auf gcc-Niveau, `int8_mul` 8,2x dahinter — bei IDENTISCHER
# Rumpfform. Die Erkennung aus #2327 greift bei beiden; der Grund ist ein
# anderer: SSE und AVX2 haben KEIN gepacktes Byte-Multiplikat. Es gibt PMULLW
# (16 Bit) und PMULLD (32 Bit), aber kein PMULLB.
#
# Gerechnet wird deshalb ueber Entpacken auf 16 Bit, zwei PMULLW und
# Zurueckpacken.
#
# DIE FALLE, und sie ist der ganze Grund fuer die Werte unten: PACKUSWB
# SAETTIGT. Ohne vorherige Maskierung wird jedes Produkt ueber 255 zu 255
# statt zu seinen unteren acht Bit:
#
#     16 * 16  = 256   -> muss 0 ergeben, gesaettigt waere es 255
#     255 * 255 = 65025 -> muss 1 ergeben, gesaettigt waere es 255
#
# EIN TEST MIT KLEINEN FAKTOREN BESTAETIGT DIE FALSCHE FASSUNG. Deshalb
# stehen diese beiden Paare an fester Stelle im Feld und werden einzeln
# nachgesehen, nicht nur ueber den Differenzvergleich.
#
# Geprueft wird in vier Richtungen:
#   1. Die beiden Saettigungsfaelle namentlich.
#   2. WERT, differentiell gegen den skalaren Weg ueber ein Feld, dessen
#      Laenge kein Vielfaches von 16 ist (Rest-Durchgang laeuft mit).
#   3. AM ERZEUGNIS, BEIDE SEITEN: die Folge muss PMULLW und PACKUSWB
#      enthalten; eine Form, die nicht erkannt sein darf, keines von beiden.
#   4. GATING: auch mit --target-cpu=avx2 muss uebersetzt werden UND dasselbe
#      herauskommen. Der Sonderweg ist nur als SSE2-Folge gebaut; ohne die
#      Weiche in cg_vmEmit liefe er dort in den internen Fehler von
#      cg_emitAVX2BinOp und braeche die Uebersetzung ab.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
_v="$(dirname "$0")/lib/vektorzahl.sh"; [ -f "$_v" ] || _v="$(dirname "$0")/../lib/vektorzahl.sh"; . "$_v"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ulimit -c 0
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

baue() { printf '%s' "$2" > "$TMP/$1.lyx"
         (cd "$TMP" && timeout 300 "$LYXC" --std-path="$ROOT" ${3:-} "$TMP/$1.lyx" -o "$TMP/$1" >"$TMP/$1.log" 2>&1); }

# ---------------------------------------------------------------- 1 + 2
Q_WERTE='unit main;
import std.io;
import std.alloc;
fn vmul(a: int64, b: int64, c: int64, n: int64) {
  var i: int64 := 0;
  while (i < n) { poke8(c + i, (peek8(a + i) * peek8(b + i)) & 0xFF); i += 1; }
}
// Vergleichsweg: die Hilfsvariable traegt kein i * K, die Erkennung greift
// dort also nicht.
fn smul(a: int64, b: int64, c: int64, n: int64) {
  var i: int64 := 0;
  while (i < n) { var t: int64 := peek8(a + i) * peek8(b + i); poke8(c + i, t & 0xFF); i += 1; }
}
fn main(): int64 {
  var n: int64 := 301;
  var a: int64 := alloc(n); var b: int64 := alloc(n);
  var c1: int64 := alloc(n); var c2: int64 := alloc(n);
  var i: int64 := 0;
  while (i < n) {
    // Feste Stellen fuer die Saettigungsfaelle, Rest gemischt.
    if (i % 4 == 0) { poke8(a + i, 16);  poke8(b + i, 16); }
    if (i % 4 == 1) { poke8(a + i, 255); poke8(b + i, 255); }
    if (i % 4 == 2) { poke8(a + i, 17);  poke8(b + i, 15); }
    if (i % 4 == 3) { poke8(a + i, i & 255); poke8(b + i, (i * 7 + 3) & 255); }
    i += 1;
  }
  vmul(a, b, c1, n);
  smul(a, b, c2, n);
  var schlecht: int64 := 0;
  i := 0;
  while (i < n) {
    if (peek8(c1 + i) != peek8(c2 + i)) {
      Print("ABWEICHUNG i="); Print(IntToStr(i));
      Print(" a="); Print(IntToStr(peek8(a + i)));
      Print(" b="); Print(IntToStr(peek8(b + i)));
      Print(" vektor="); Print(IntToStr(peek8(c1 + i)));
      Print(" skalar="); PrintLn(IntToStr(peek8(c2 + i)));
      schlecht += 1;
      if (schlecht > 4) { return 1; }
    }
    i += 1;
  }
  // Die zwei Saettigungsfaelle namentlich, auch im VEKTORteil (Index 0 und 1
  // liegen im ersten vollen Block) und im REST (die letzten Elemente).
  Print("16x16="); PrintLn(IntToStr(peek8(c1)));
  Print("255x255="); PrintLn(IntToStr(peek8(c1 + 1)));
  Print("17x15="); PrintLn(IntToStr(peek8(c1 + 2)));
  Print("rest16x16="); PrintLn(IntToStr(peek8(c1 + 296)));
  Print("rest255x255="); PrintLn(IntToStr(peek8(c1 + 297)));
  if (schlecht == 0) { PrintLn("I8MUL OK"); return 0; }
  Print("I8MUL ROT "); PrintLn(IntToStr(schlecht));
  return 1;
}'
if baue werte "$Q_WERTE"; then
  aus=$( cd "$TMP" && timeout 120 ./werte 2>&1 )
  if printf '%s' "$aus" | grep -q '^I8MUL OK$'; then
    ok "Wert: 301 Elemente gleich dem skalaren Weg (Rest-Durchgang laeuft mit)"
  else
    no "Wert" "$(printf '%s' "$aus" | head -6)"
  fi
  # Die Saettigung einzeln, im Vektorteil UND im Rest.
  g() { printf '%s' "$aus" | sed -n "s/^$1=//p"; }
  if [ "$(g 16x16)" = "0" ] && [ "$(g 255x255)" = "1" ] && [ "$(g 17x15)" = "255" ]; then
    ok "Saettigung im Vektorteil: 16x16=0, 255x255=1, 17x15=255"
  else
    no "Saettigung im Vektorteil" "16x16=$(g 16x16) (0), 255x255=$(g 255x255) (1), 17x15=$(g 17x15) (255)"
  fi
  if [ "$(g rest16x16)" = "0" ] && [ "$(g rest255x255)" = "1" ]; then
    ok "Saettigung im Rest-Durchgang: 16x16=0, 255x255=1"
  else
    no "Saettigung im Rest" "16x16=$(g rest16x16) (0), 255x255=$(g rest255x255) (1)"
  fi
else
  no "Wert" "uebersetzt nicht: $(grep -v Copyright "$TMP/werte.log" | grep -m1 -iE 'error|lyxc:')"
fi

# ---------------------------------------------------------------- 3
N=$(vek_zahl "$TMP/werte.lyx" 'pmullw|vpmullw')
M=$(vek_zahl "$TMP/werte.lyx" 'packuswb|vpackuswb')
if [ "$N" -ge 2 ] && [ "$M" -ge 1 ]; then
  ok "Erzeugnis: $N PMULLW und $M PACKUSWB"
else
  no "Erzeugnis" "PMULLW=$N (>=2), PACKUSWB=$M (>=1)"
fi

# Gegenseite: `i += 2` ist nicht die erkannte Form, es darf keine
# Byte-Multiplikationsfolge entstehen.
Q_NEIN='unit main;
import std.io;
import std.alloc;
fn k(a: int64, b: int64, c: int64, n: int64) {
  var i: int64 := 0;
  while (i < n) { poke8(c + i, (peek8(a + i) * peek8(b + i)) & 0xFF); i += 2; }
}
fn main(): int64 {
  var a: int64 := alloc(64); var b: int64 := alloc(64); var c: int64 := alloc(64);
  k(a, b, c, 64);
  return 0;
}'
if baue nein "$Q_NEIN"; then
  N=$(vek_zahl "$TMP/nein.lyx" 'pmullw|vpmullw|packuswb|vpackuswb')
  if [ "$N" -eq 0 ]; then ok "Gegenseite: kein PMULLW/PACKUSWB (i += 2 ist nicht die Form)"
  else no "Gegenseite" "$N Befehle — die Bedingung ist zu weit"; fi
else
  no "Gegenseite" "uebersetzt nicht: $(grep -v Copyright "$TMP/nein.log" | grep -m1 -iE 'error|lyxc:')"
fi

# ---------------------------------------------------------------- 4
# Mit --target-cpu=avx2 muss uebersetzt werden und dasselbe herauskommen.
# Ohne die Weiche in cg_vmEmit braeche cg_emitAVX2BinOp hier ab (Opcode -1).
if baue avx2 "$Q_WERTE" "--target-cpu=avx2"; then
  aus2=$( cd "$TMP" && timeout 120 ./avx2 2>&1 )
  if printf '%s' "$aus2" | grep -q '^I8MUL OK$'; then
    ok "--target-cpu=avx2 uebersetzt und rechnet gleich"
  else
    no "--target-cpu=avx2" "$(printf '%s' "$aus2" | head -4)"
  fi
else
  no "--target-cpu=avx2" "uebersetzt nicht (Weiche in cg_vmEmit?): $(grep -v Copyright "$TMP/avx2.log" | grep -m1 -iE 'error|lyxc:')"
fi

echo "=== PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
