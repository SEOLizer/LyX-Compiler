#!/bin/bash
# tests/aes_ni_test.sh — AES-NI (#2383).
#
# Geprueft wird WAS HERAUSKOMMT und WAS EMITTIERT WIRD, nicht dass eine
# Funktion existiert:
#
#   1. FIPS-197 C.1 (AES-128) und C.3 (AES-256): Schluesselplan UND
#      Chiffrat byteweise. Ein Test, der nur "Laenge 16" oder "Rueckweg
#      ergibt den Klartext" prueft, waere auch von einer falschen,
#      selbstkonsistenten Chiffre erfuellt.
#   2. Beide Wege gegeneinander: derselbe Schluessel, derselbe Block,
#      einmal ueber AESENC und einmal gerechnet (AESForceSoftware(1)).
#      Dazu der ganze Schluesselplan — der tabellenfreie SubWord-Weg
#      (AESENCLAST gegen 0) muss Byte fuer Byte dieselben 176/240 Byte
#      liefern wie die S-Box.
#   3. Zweiseitig am Erzeugnis: mit AES-NI steht `66 0F 38 DC` (AESENC)
#      im Binary, in einem Programm ohne AES NICHT. Ohne die
#      Gegenrichtung waere der Nachweis von einem Binary erfuellt, in dem
#      die Bytes zufaellig irgendwo stehen.
#   4. Die Einheit muss fuer arm64 UEBERSETZEN: dort senkt ir_lower die
#      Builtins zu PANIC, und ein Uebersetzungsfehler waere eine
#      stdlib, die auf arm64 nicht mehr baut.
#
# Was dieser Test NICHT belegt: das Verhalten auf einer x86-CPU OHNE
# AES-NI. Die Entwicklungsmaschine hat das Bit; der Rechenweg wird
# deshalb ueber AESForceSoftware gemessen, nicht ueber eine fehlende
# Faehigkeit.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294: Ressourcengrenze um jeden lyxc-Aufruf
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
P=0; F=0
ok()  { echo "PASS: $1"; P=$((P+1)); }
bad() { echo "FAIL: $1${2:+ — $2}"; F=$((F+1)); }

HAS_AESNI=0
grep -qw aes /proc/cpuinfo 2>/dev/null && HAS_AESNI=1

# ---------------------------------------------------------------- Programm
cat > "$TMP/t.lyx" <<'LYX'
import std.crypto.aes;
import std.cpu.features;

fn hex(p: int64, n: int64) {
  var d: pchar := "0123456789abcdef";
  var i: int64 := 0;
  while (i < n) {
    var b: int64 := peek8(p + i);
    PrintStr(StrSub(d, (b >> 4) & 15, 1));
    PrintStr(StrSub(d, b & 15, 1));
    i := i + 1;
  }
  PrintLn("");
}

fn main(): int64 {
  var key16: pchar := alloc(32) as pchar;
  var key32: pchar := alloc(48) as pchar;
  var blk:   pchar := alloc(32) as pchar;
  var ek:    pchar := alloc(256) as pchar;
  var ek2:   pchar := alloc(256) as pchar;
  var i: int64 := 0;

  PrintStr("AESNI="); PrintInt(AESNIAvailable()); PrintLn("");

  // FIPS-197 C.1: key 000102…0f, plain 00112233445566778899aabbccddeeff
  i := 0; while (i < 16) { StrSetChar(key16, i, i); i := i + 1; }
  i := 0; while (i < 32) { StrSetChar(key32, i, i); i := i + 1; }

  AES128KeyExpand(key16, ek);
  PrintStr("RK128="); hex((ek as int64) + 160, 16);
  i := 0; while (i < 16) { StrSetChar(blk, i, i * 17); i := i + 1; }
  AESEncryptBlockWithKey(blk, ek, 10);
  PrintStr("CT128="); hex(blk as int64, 16);

  AES256KeyExpand(key32, ek2);
  PrintStr("RK256="); hex((ek2 as int64) + 224, 16);
  i := 0; while (i < 16) { StrSetChar(blk, i, i * 17); i := i + 1; }
  AESEncryptBlockWithKey(blk, ek2, 14);
  PrintStr("CT256="); hex(blk as int64, 16);

  // Rueckweg ueber den gerechneten Pfad: er muss das Hardware-Chiffrat
  // aufloesen — damit haengen beide Wege an DEMSELBEN Schluesselplan.
  AESDecryptBlockWithKey(blk, ek2, 14);
  PrintStr("PT256="); hex(blk as int64, 16);

  // Derselbe Lauf gerechnet. Schluesselplan und Chiffrat muessen gleich sein.
  AESForceSoftware(1);
  var eks: pchar := alloc(256) as pchar;
  AES128KeyExpand(key16, eks);
  var gleich: int64 := 1;
  i := 0;
  while (i < 176) {
    if (peek8((eks as int64) + i) != peek8((ek as int64) + i)) { gleich := 0; }
    i := i + 1;
  }
  var eks2: pchar := alloc(256) as pchar;
  AES256KeyExpand(key32, eks2);
  i := 0;
  while (i < 240) {
    if (peek8((eks2 as int64) + i) != peek8((ek2 as int64) + i)) { gleich := 0; }
    i := i + 1;
  }
  PrintStr("PLANGLEICH="); PrintInt(gleich); PrintLn("");

  i := 0; while (i < 16) { StrSetChar(blk, i, i * 17); i := i + 1; }
  AESEncryptBlockWithKey(blk, eks, 10);
  PrintStr("SW128="); hex(blk as int64, 16);
  i := 0; while (i < 16) { StrSetChar(blk, i, i * 17); i := i + 1; }
  AESEncryptBlockWithKey(blk, eks2, 14);
  PrintStr("SW256="); hex(blk as int64, 16);

  // CBC ueber beide Wege: 64 Byte Eingabe, PKCS#7 — der
  // Entschluessel-Plan (AESIMC) steckt nur im Hardware-Weg.
  var inbuf: pchar := alloc(128) as pchar;
  i := 0; while (i < 64) { StrSetChar(inbuf, i, (i * 7) & 255); i := i + 1; }
  var iv: pchar := alloc(32) as pchar;
  i := 0; while (i < 16) { StrSetChar(iv, i, 255 - i); i := i + 1; }
  var cbcA: pchar := alloc(160) as pchar;
  var cbcB: pchar := alloc(160) as pchar;
  AESForceSoftware(0);
  var la: int64 := AES256CBCEncrypt(key32, iv, inbuf, 64, cbcA);
  var pa: pchar := alloc(160) as pchar;
  var lp: int64 := AES256CBCDecrypt(key32, iv, cbcA, la, pa);
  AESForceSoftware(1);
  var lb: int64 := AES256CBCEncrypt(key32, iv, inbuf, 64, cbcB);
  var cbcgleich: int64 := 1;
  if (la != lb) { cbcgleich := 0; }
  i := 0;
  while (i < la) {
    if (peek8((cbcA as int64) + i) != peek8((cbcB as int64) + i)) { cbcgleich := 0; }
    i := i + 1;
  }
  if (lp != 64) { cbcgleich := 0; }
  i := 0;
  while (i < 64) {
    if (peek8((pa as int64) + i) != peek8((inbuf as int64) + i)) { cbcgleich := 0; }
    i := i + 1;
  }
  PrintStr("CBCGLEICH="); PrintInt(cbcgleich); PrintLn("");

  // AESNISubWord gegen die S-Box, alle 256 Bytewerte (je viermal im Wort).
  AESForceSoftware(0);
  var swok: int64 := 1;
  if (CpuHasAESNI() != 0) {
    var scr: pchar := alloc(64) as pchar;
    var v: int64 := 0;
    while (v < 256) {
      var w: int64 := (v << 24) | (v << 16) | (v << 8) | v;
      var got: int64 := AESNISubWord(w, scr);
      var sb: int64 := SubByte(v);
      var want: int64 := ((sb << 24) | (sb << 16) | (sb << 8) | sb) & 0xFFFFFFFF;
      if (got != want) { swok := 0; }
      v := v + 1;
    }
  }
  PrintStr("SUBWORD="); PrintInt(swok); PrintLn("");
  return 0;
}
LYX

if ! timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/t.lyx" -o "$TMP/t" > "$TMP/c.log" 2>&1; then
  bad "uebersetzt" "$(grep -iE 'error' "$TMP/c.log" | head -1)"
else
  ok "uebersetzt"
  OUT=$("$TMP/t" 2>&1)
  g() { printf '%s\n' "$OUT" | grep -m1 "^$1=" | cut -d= -f2; }

  # FIPS-197 A.1 / C.1 / C.3 — Werte aus der Norm, nicht aus einem Lauf.
  [ "$(g RK128)" = "13111d7fe3944a17f307a78b4d2b30c5" ] \
    && ok "FIPS-197 A.1: letzter AES-128-Rundenschluessel" \
    || bad "FIPS-197 A.1" "RK128=$(g RK128)"
  [ "$(g CT128)" = "69c4e0d86a7b0430d8cdb78070b4c55a" ] \
    && ok "FIPS-197 C.1: AES-128-Chiffrat" || bad "FIPS-197 C.1" "CT128=$(g CT128)"
  [ "$(g CT256)" = "8ea2b7ca516745bfeafc49904b496089" ] \
    && ok "FIPS-197 C.3: AES-256-Chiffrat" || bad "FIPS-197 C.3" "CT256=$(g CT256)"
  [ "$(g PT256)" = "00112233445566778899aabbccddeeff" ] \
    && ok "gerechneter Rueckweg loest das Chiffrat auf" || bad "Rueckweg" "PT256=$(g PT256)"

  [ "$(g PLANGLEICH)" = "1" ] \
    && ok "Schluesselplaene byteweise gleich (176 + 240 Byte)" \
    || bad "Schluesselplan weicht ab" "PLANGLEICH=$(g PLANGLEICH)"
  [ "$(g SW128)" = "$(g CT128)" ] && [ "$(g SW256)" = "$(g CT256)" ] \
    && ok "beide Wege liefern dasselbe Chiffrat" \
    || bad "Wege weichen ab" "SW128=$(g SW128) SW256=$(g SW256)"
  [ "$(g CBCGLEICH)" = "1" ] \
    && ok "AES-256-CBC: beide Wege gleich, Rundweg vollstaendig" \
    || bad "CBC weicht ab" "CBCGLEICH=$(g CBCGLEICH)"
  [ "$(g SUBWORD)" = "1" ] \
    && ok "AESNISubWord == S-Box fuer alle 256 Bytewerte" \
    || bad "AESNISubWord" "SUBWORD=$(g SUBWORD)"

  if [ "$HAS_AESNI" = "1" ]; then
    [ "$(g AESNI)" = "1" ] && ok "AESNIAvailable folgt dem CPUID-Bit" \
      || bad "AESNIAvailable" "CPUID meldet aes, Unit sagt $(g AESNI)"
  else
    [ "$(g AESNI)" = "0" ] && ok "AESNIAvailable folgt dem CPUID-Bit (kein aes)" \
      || bad "AESNIAvailable" "kein aes in /proc/cpuinfo, Unit sagt $(g AESNI)"
  fi

  # --- Erzeugnis, beide Richtungen. Lyx-Binaries haben keine Sektionen,
  # --- also Bytemuster, kein objdump (vgl. #2361).
  hat_aesenc() {
    python3 - "$1" <<'PY'
import sys
b=open(sys.argv[1],'rb').read()
print(1 if b'\x66\x0f\x38\xdc\xc1' in b else 0)
PY
  }
  [ "$(hat_aesenc "$TMP/t")" = "1" ] \
    && ok "AESENC (66 0F 38 DC C1) steht im Erzeugnis" \
    || bad "AESENC fehlt im Erzeugnis"

  printf 'fn main(): int64 { PrintInt(41 + 1); PrintLn(""); return 0; }\n' > "$TMP/n.lyx"
  if timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/n.lyx" -o "$TMP/n" >/dev/null 2>&1; then
    [ "$(hat_aesenc "$TMP/n")" = "0" ] \
      && ok "ohne AES keine AESENC-Bytes (Gegenrichtung)" \
      || bad "AESENC-Bytes in einem Programm ohne AES"
  else
    bad "Vergleichsprogramm uebersetzt nicht"
  fi
fi

# --- arm64: die Einheit muss uebersetzen (ir_lower senkt dort zu PANIC).
cat > "$TMP/a.lyx" <<'LYX'
import std.crypto.aes;
fn main(): int64 {
  var k: pchar := alloc(32) as pchar;
  var e: pchar := alloc(256) as pchar;
  AES128KeyExpand(k, e);
  PrintInt(AESNIAvailable());
  PrintLn("");
  return 0;
}
LYX
if timeout 300 "$LYXC" --std-path="$ROOT" --target=arm64 "$TMP/a.lyx" -o "$TMP/a.out" > "$TMP/a.log" 2>&1; then
  ok "std.crypto.aes uebersetzt fuer arm64"
else
  bad "arm64-Uebersetzung" "$(grep -iE 'error|unbekannt|fehler' "$TMP/a.log" | head -1)"
fi

echo "---"
echo "PASS=$P FAIL=$F"
[ "$F" -eq 0 ] || exit 1
exit 0
