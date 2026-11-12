#!/usr/bin/env bash
# tests/vektor_reduktion_2335_test.sh — #2335: Ganzzahl-Reduktionen
# vektorisieren.
#
#   while (i < n) { s := s + peekW(a + i * W); i += 1; }
#
# Warum das OHNE Freigabe geht: #2194 Schritt 5 verlangt fuer Reduktionen
# eine ausdrueckliche Freigabe, weil Umordnung das Ergebnis aendert — das
# gilt fuer GLEITKOMMA. Ganzzahladdition ist assoziativ, auch modulo 2^64.
#
# Die zwei Fallen, und beide sind der Grund fuer die Werteliste unten:
#
#   1. DIE BREITE DER TEILSUMMEN. `peek16` liefert bis 65535; eine
#      Teilsummierung mit PADDD laeuft nach rund 65536 Gliedern ueber, lange
#      bevor die int64-Gesamtsumme es taete. Ein Test mit kleinen Werten oder
#      kurzen Feldern sieht das NICHT. Deshalb laeuft eine Fassung mit
#      durchgehend 0xFF bzw. 0xFFFFFFFF und 300000 Elementen.
#   2. `peek32` ERWEITERT VORZEICHENBEHAFTET (peek32 auf 0xFFFFFFFF ergibt
#      -1), `peek8` und `peek16` nicht. Steht `& 0xFFFFFFFF` da, ist der Wert
#      vorzeichenlos gemeint und wird mit Null aufgefuellt; fehlt die Maske,
#      muss das Vorzeichen fortgesetzt werden. Das sind zwei verschiedene
#      Rechnungen, beide werden geprueft — mit gesetztem obersten Bit, sonst
#      ist der Unterschied unsichtbar.
#
# Geprueft wird in vier Richtungen:
#   1. WERT, differentiell gegen den skalaren Weg (Hilfsvariable im Rumpf
#      verhindert dort die Erkennung), ueber 3 Wertemuster x 7 Laengen x 4
#      Fassungen. Die Laengen treffen 0, 1, 15, 16, 17 — also den leeren
#      Fall, den Rest-Durchgang allein und den Rest nach einem Block.
#   2. AM ERZEUGNIS, BEIDE SEITEN.
#   3. GEGENSEITEN: fuenf Formen, die NICHT passen duerfen.
#   4. f64 bleibt unberuehrt — solange die Freigabe aus #2194 Schritt 5 nicht
#      existiert, darf eine Gleitkomma-Reduktion diesen Weg nicht nehmen.

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
         (cd "$TMP" && timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/$1.lyx" -o "$TMP/$1" >"$TMP/$1.log" 2>&1); }

# ---------------------------------------------------------------- 1
Q_WERTE='unit main;
import std.io;
import std.alloc;

// erkannte Form
fn v8(a: int64, n: int64): int64 {
  var s: int64 := 0; var i: int64 := 0;
  while (i < n) { s := s + peek8(a + i); i += 1; }
  return s;
}
fn v16(a: int64, n: int64): int64 {
  var s: int64 := 0; var i: int64 := 0;
  while (i < n) { var o: int64 := i * 2; s := s + peek16(a + o); i += 1; }
  return s;
}
fn v32u(a: int64, n: int64): int64 {
  var s: int64 := 0; var i: int64 := 0;
  while (i < n) { var o: int64 := i * 4; s := s + (peek32(a + o) & 0xFFFFFFFF); i += 1; }
  return s;
}
fn v32s(a: int64, n: int64): int64 {
  var s: int64 := 0; var i: int64 := 0;
  while (i < n) { var o: int64 := i * 4; s := s + peek32(a + o); i += 1; }
  return s;
}
// skalarer Vergleichsweg: die Hilfsvariable traegt KEIN i * K, damit
// greift die Erkennung dort nicht.
fn s8(a: int64, n: int64): int64 {
  var s: int64 := 0; var i: int64 := 0;
  while (i < n) { var t: int64 := peek8(a + i); s := s + t; i += 1; }
  return s;
}
fn s16(a: int64, n: int64): int64 {
  var s: int64 := 0; var i: int64 := 0;
  while (i < n) { var t: int64 := peek16(a + i * 2); s := s + t; i += 1; }
  return s;
}
fn s32u(a: int64, n: int64): int64 {
  var s: int64 := 0; var i: int64 := 0;
  while (i < n) { var t: int64 := peek32(a + i * 4) & 0xFFFFFFFF; s := s + t; i += 1; }
  return s;
}
fn s32s(a: int64, n: int64): int64 {
  var s: int64 := 0; var i: int64 := 0;
  while (i < n) { var t: int64 := peek32(a + i * 4); s := s + t; i += 1; }
  return s;
}
fn prf(name: pchar, nn: int64, v: int64, sk: int64): int64 {
  if (v == sk) { return 0; }
  Print("ABWEICHUNG "); Print(name); Print(" n="); Print(IntToStr(nn));
  Print(": vektor="); Print(IntToStr(v));
  Print(" skalar="); PrintLn(IntToStr(sk));
  return 1;
}
fn main(): int64 {
  var schlecht: int64 := 0;
  var geprueft: int64 := 0;
  var ns: int64 := 7;
  var nn: int64 := alloc(ns * 8);
  poke64(nn, 0); poke64(nn + 8, 1); poke64(nn + 16, 15); poke64(nn + 24, 16);
  poke64(nn + 32, 17); poke64(nn + 40, 1000); poke64(nn + 48, 300000);
  var f: int64 := 0;
  while (f < 3) {
    var k: int64 := 0;
    while (k < ns) {
      var n: int64 := peek64(nn + k * 8);
      var a: int64 := alloc((n + 4) * 4);
      var i: int64 := 0;
      while (i < n + 4) {
        // f == 0: alles auf Maximum — hier laeuft eine 32-Bit-Teilsumme ueber
        // f == 1: oberstes Bit gesetzt — trennt peek32 mit Maske von ohne
        // f == 2: gemischt
        if (f == 0) { poke32(a + i * 4, 4294967295); }
        if (f == 1) { poke32(a + i * 4, 2147483648 + (i & 255)); }
        if (f == 2) { poke32(a + i * 4, (i * 2654435761) & 0xFFFFFFFF); }
        i += 1;
      }
      schlecht += prf("8"c,   n, v8(a, n),   s8(a, n));
      schlecht += prf("16"c,  n, v16(a, n),  s16(a, n));
      schlecht += prf("32u"c, n, v32u(a, n), s32u(a, n));
      schlecht += prf("32s"c, n, v32s(a, n), s32s(a, n));
      geprueft := geprueft + 4;
      k += 1;
    }
    f += 1;
  }
  Print("GEPRUEFT "); PrintLn(IntToStr(geprueft));
  if (schlecht == 0) { PrintLn("REDUKTION OK"); return 0; }
  Print("REDUKTION ROT "); PrintLn(IntToStr(schlecht));
  return 1;
}'
if baue werte "$Q_WERTE"; then
  aus=$( cd "$TMP" && timeout 200 ./werte 2>&1 )
  ANZ="$(printf '%s' "$aus" | sed -n 's/^GEPRUEFT //p')"
  if printf '%s' "$aus" | grep -q '^REDUKTION OK$' && [ "${ANZ:-0}" -ge 84 ]; then
    ok "Wert: $ANZ Vergleiche gegen den skalaren Weg (3 Wertemuster x 7 Laengen x 4 Fassungen)"
  else
    no "Wert" "$(printf '%s' "$aus" | head -5)"
  fi
  N=$(vek_zahl "$TMP/werte.lyx" 'psadbw|vpsadbw|paddq|vpaddq')
  if [ "$N" -ge 4 ]; then ok "Erzeugnis: Reduktion vektorisiert ($N PSADBW/PADDQ)"
  else no "Erzeugnis" "nur $N PSADBW/PADDQ — nicht erkannt"; fi
else
  no "Wert" "uebersetzt nicht: $(grep -v Copyright "$TMP/werte.log" | grep -m1 -iE 'error|lyxc:')"
fi

# ---------------------------------------------------------------- 2
# Gegenseiten, jede einzeln, damit ein Treffer zuordenbar bleibt.
nein_fall() {
  local Q='unit main;
import std.io;
import std.alloc;
fn k(a: int64, n: int64): int64 {
  var s: int64 := 0; var t: int64 := 7; var i: int64 := 0;
  while (i < n) { '"$2"' }
  return s;
}
fn main(): int64 {
  var a: int64 := alloc(512);
  return k(a, 64) * 0;
}'
  if baue "nein_$1" "$Q"; then
    local N; N=$(vek_zahl "$TMP/nein_$1.lyx" 'psadbw|vpsadbw|paddq|vpaddq')
    if [ "$N" -eq 0 ]; then ok "Gegenseite $1: kein PSADBW/PADDQ"
    else no "Gegenseite $1" "$N PSADBW/PADDQ — die Bedingung ist zu weit"; fi
  else
    no "Gegenseite $1" "uebersetzt nicht: $(grep -v Copyright "$TMP/nein_$1.log" | grep -m1 -iE 'error|lyxc:')"
  fi
}
# linker Summand ist nicht der Sammler
nein_fall fremd 's := t + peek8(a + i); i += 1;'
# rechte Seite ist kein peek
nein_fall kein_peek 's := s + peek8(a + i) * 2; i += 1;'
# nicht Addition
nein_fall nicht_plus 's := s * peek8(a + i); i += 1;'
# Maske trifft die Breite nicht: 0xFF auf peek16 schneidet wirklich ab,
# der Vektorweg wuerde den ganzen Wert nehmen
nein_fall falsche_maske 'var o: int64 := i * 2; s := s + (peek16(a + o) & 0xFF); i += 1;'
# Abhaengigkeit zwischen den Durchlaeufen
nein_fall abhaengig 's := s + peek8(a + i) * s; i += 1;'

# ---------------------------------------------------------------- 3
# f64 bleibt unberuehrt und rechnet richtig.
Q_F64='unit main;
import std.io;
fn main(): int64 {
  var a: parallel Array<f32> := parallel Array<f32>(8);
  var i: int64 := 0;
  while (i < 8) { a[i] := 1.5; i += 1; }
  var s: f64 := 0.0;
  var k: int64 := 0;
  while (k < 8) { s := s + (a[k] as f64); k += 1; }
  if (s < 11.9 || s > 12.1) { return 1; }
  return 0;
}'
if baue f64 "$Q_F64"; then
  "$TMP/f64"; RC=$?
  if [ $RC -eq 0 ]; then ok "f64-Reduktion rechnet richtig (8 x 1.5 == 12.0)"
  else no "f64-Reduktion" "rc=$RC"; fi
else
  no "f64-Reduktion" "uebersetzt nicht: $(grep -v Copyright "$TMP/f64.log" | grep -m1 -iE 'error|lyxc:')"
fi

echo "=== PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
