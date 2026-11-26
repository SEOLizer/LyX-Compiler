#!/usr/bin/env bash
# tests/vaes_ctr_2393_test.sh — VAES: zwei AES-Bloecke je Aufruf (#2393).
#
# ZWEISTUFIGER NACHWEIS, und das ist keine Bequemlichkeit, sondern die Lage:
# der Entwicklungsrechner (i5-8250U, Kaby Lake R) hat KEIN VAES -- das gibt es
# erst ab Ice Lake und Zen 3. Die CI-Laeufer (EPYC Zen 3/4) haben es. Ein Test,
# der die Faehigkeit voraussetzt, waere hier rot ohne Codefehler; einer, der sie
# nur am Erzeugnis prueft, belegt die WERTE nicht.
#
#   Teil 1 (laeuft UEBERALL): die Bytes am Erzeugnis. VEX-kodierte VAESENC/
#           VAESENCLAST, VBROADCASTI128 und VZEROUPPER muessen drinstehen --
#           und ohne die Faehigkeitszusage NICHT. Beide Richtungen (#1823).
#   Teil 2 (nur MIT vaes, sonst SKIP): der WERT. Die VAES-Strecke muss
#           bitgleich dasselbe liefern wie der Einzelblockweg.
#
# WARUM VBROADCASTI128 IM TEST STEHT: der Schluesselplan ist 16 Byte je Runde,
# die VAES-Befehle brauchen ihn in BEIDEN Spuren. Mit VMOVDQU waere der zweite
# Block mit dem Schluessel der NAECHSTEN Runde verschluesselt -- still und
# plausibel aussehend. Der Befehl ist also kein Detail, sondern die Bedingung.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$ROOT/tests/lib/lyxc_guard.sh"; [ -f "$_g" ] && . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ulimit -c 0 2>/dev/null
ok() { PASS=$((PASS+1)); echo "PASS $1"; }
no() { FAIL=$((FAIL+1)); echo "FAIL $1: $2"; }

# --- Teil 1: Bytes am Erzeugnis ------------------------------------------
cat > "$TMP/b.lyx" <<'LYX'
import std.io;
import std.alloc;
fn main(): int64 {
  var dst: int64 := alloc(64);
  var src: int64 := alloc(64);
  var rk:  int64 := alloc(240);
  aes_enc2_block(dst, src, rk, 14);
  aes_dec2_block(dst, src, rk, 14);
  aes_enc4_block(dst, src, rk, 14);
  aes_dec4_block(dst, src, rk, 14);
  PrintLn(peek8(dst) & 0xFF);
  return 0;
}
LYX
if ! ( cd "$ROOT" && timeout 600 "$LYXC" --std-path="$ROOT" "$TMP/b.lyx" -o "$TMP/b" ) >"$TMP/b.log" 2>&1; then
  no "Byteprobe uebersetzt nicht" "$(grep -m1 -i error "$TMP/b.log")"
  echo ""; echo "Ergebnis: $PASS PASS, $FAIL FAIL"; exit 1
fi
ok "Byteprobe uebersetzt"

# Das Erzeugnis hat keine Sektionen, die objdump -d findet (#1370) -- deshalb
# am rohen Byteinhalt suchen, wie tests/lyxos_builtin_ids_test.sh es macht.
hat() { # name, hexfolge
  if xxd -p "$TMP/b" | tr -d '\n' | grep -q "$2"; then ok "$1 steht im Erzeugnis"
  else no "$1 fehlt im Erzeugnis" "Folge $2 nicht gefunden"; fi
}
hat "VBROADCASTI128 ymm1,[rdx]" "c4e27d5a0a"
hat "VAESENC ymm0,ymm0,ymm1"    "c4e27ddcc1"
hat "VAESENCLAST"               "c4e27dddc1"
hat "VAESDEC"                   "c4e27ddec1"
hat "VAESDECLAST"               "c4e27ddfc1"
hat "VZEROUPPER"                "c5f877"
# Die Vierblockform: zweiter Zustand in ymm2, Versatz 32 in den Speicherformen.
hat "vmovdqu ymm2,[rsi+32]"     "c5fe6f5620"
hat "VAESENC ymm2,ymm2,ymm1"    "c4e26ddcd1"
hat "VAESENCLAST ymm2"          "c4e26dddd1"
hat "vmovdqu [rdi+32],ymm2"     "c5fe7f5720"
# Die Gegenrichtung: ein Programm OHNE diese Builtins darf die Folgen nicht
# tragen. Ohne sie waere der Test auch von einem Erzeugnis erfuellt, das die
# Bytes aus einem anderen Grund enthaelt.
cat > "$TMP/c.lyx" <<'LYX'
import std.io;
fn main(): int64 { PrintLn(41 + 1); return 0; }
LYX
if ( cd "$ROOT" && timeout 600 "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" ) >/dev/null 2>&1; then
  if xxd -p "$TMP/c" | tr -d '\n' | grep -q "c4e27ddcc1"; then
    no "Gegenprobe" "VAESENC steht in einem Programm, das es nicht ruft"
  else
    ok "Gegenprobe: ohne Aufruf keine VAES-Bytes"
  fi
else
  no "Gegenprobe uebersetzt nicht" "siehe Log"
fi

# --- Teil 2: der WERT, nur mit vaes --------------------------------------
cat > "$TMP/w.lyx" <<'LYX'
import std.io;
import std.alloc;
import std.cpu.features;
import std.crypto.aes;

// Zaehler um eins erhoehen, big-endian ueber 16 Byte -- dieselbe Rechnung wie
// ctr_inc in std/crypto/aes.lyx (dort nicht oeffentlich). Steht hier, damit
// der Test nur die OEFFENTLICHE API braucht: eine Funktion fuer einen Test
// `pub` zu machen waere eine API-Aenderung fuer eine Messung.
fn zaehlerPlus(ctr: int64) {
  var i: int64 := 15;
  var weiter: int64 := 1;
  while (i >= 0 && weiter != 0) {
    var v: int64 := (peek8(ctr+i) & 255) + 1;
    poke8(ctr+i, v & 255);
    if (v < 256) { weiter := 0; }
    i := i - 1;
  }
}

fn main(): int64 {
  if (CpuHasVAES() == 0 || CpuHasAESNI() == 0) { PrintLn("KEIN-VAES"); return 0; }
  var key: int64 := alloc(32);
  var iv:  int64 := alloc(16);
  var iv2: int64 := alloc(16);
  var inp: int64 := alloc(128);
  var o1:  int64 := alloc(128);
  var o2:  int64 := alloc(128);
  var i: int64 := 0;
  while (i < 32) { poke8(key+i, (i * 7 + 1) & 255); i := i+1; }
  i := 0; while (i < 16) { poke8(iv+i, (i * 13 + 5) & 255); i := i+1; }
  i := 0; while (i < 128) { poke8(inp+i, (i * 3 + 9) & 255); i := i+1; }

  // Die Probe: EIN Aufruf ueber n Byte nimmt mit vaes den Zweiblockweg.
  // Dieselben Daten blockweise in 16-Byte-Stuecken mit fortgeschaltetem
  // Zaehler nehmen den EINZELblockweg (pos + 32 > inLen bei inLen = 16).
  // Derselbe Schluesselstrom, also muessen beide bitgleich sein.
  var laenge: int64 := 0;
  var fehler: int64 := 0;
  var welche: int64 := 0;
  while (welche < 5) {
    if (welche == 0) { laenge := 96; }    // genau drei Zweierschritte
    if (welche == 1) { laenge := 77; }    // zwei Schritte plus 13 Byte Rest
    if (welche == 2) { laenge := 33; }    // ein Zweierschritt plus 1 Byte Rest
    if (welche == 3) { laenge := 128; }   // genau zwei Viererschritte
    if (welche == 4) { laenge := 109; }   // ein Vierer, ein Zweier, 13 Byte Rest
    AES256CTR(key, iv, inp, laenge, o1);
    i := 0; while (i < 16) { poke8(iv2+i, peek8(iv+i)); i := i+1; }
    var pos: int64 := 0;
    while (pos < laenge) {
      var rem: int64 := laenge - pos;
      if (rem > 16) { rem := 16; }
      AES256CTR(key, iv2, inp + pos, rem, o2 + pos);
      zaehlerPlus(iv2);
      pos := pos + rem;
    }
    var gleich: int64 := 1;
    i := 0;
    while (i < laenge) { if (peek8(o1+i) != peek8(o2+i)) { gleich := 0; } i := i+1; }
    Print("bitgleich-"); PrintInt(laenge); Print(" "); PrintInt(gleich); PrintLn("");
    if (gleich == 0) { fehler := 1; }
    welche := welche + 1;
  }
  Print("alle-gleich "); PrintInt(1 - fehler); PrintLn("");
  return 0;
}
LYX
if ( cd "$ROOT" && timeout 600 "$LYXC" --std-path="$ROOT" "$TMP/w.lyx" -o "$TMP/w" ) >"$TMP/w.log" 2>&1 \
   && [ -x "$TMP/w" ]; then
  ok "Wertprobe uebersetzt"
  AUS="$( ulimit -v 4000000; timeout 120 "$TMP/w" 2>&1 )"
  if echo "$AUS" | grep -q 'KEIN-VAES'; then
    echo "SKIP Wert: diese CPU hat kein VAES (erst Ice Lake / Zen 3) -- Teil 1 gilt"
  elif echo "$AUS" | grep -q 'alle-gleich 1'; then
    ok "VAES-Strecke bitgleich zum Einzelblockweg (96, 77, 33, 128, 109 Byte)"
  else
    no "VAES-Strecke weicht ab" "$(echo "$AUS" | tr '\n' ' ')"
  fi
else
  no "Wertprobe uebersetzt nicht" "$(grep -m1 -i error "$TMP/w.log")"
fi

echo ""
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
