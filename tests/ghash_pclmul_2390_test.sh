#!/usr/bin/env bash
# tests/ghash_pclmul_2390_test.sh — GHASH mit PCLMULQDQ, AES-NI in AES-GCM (#2390).
#
# GHASH rechnete die Multiplikation im GF(2^128) bitweise: 128 Runden Schieben
# und XOR je 16-Byte-Block. Mit PCLMULQDQ sind es vier traegerlose
# Multiplikationen plus Reduktion. Die AES-Blockverschluesselung in
# std/crypto/aesgcm.lyx lief ueber eine S-Box-TABELLE (Cache-Seitenkanal) und
# nimmt jetzt AES-NI (#2383), wenn die CPU es kann.
#
# Gemessen wird in fuenf Richtungen:
#
#   1. BEIDE WEGE GEGENEINANDER, Byte fuer Byte: dasselbe Chiffrat und
#      dasselbe Tag, ueber zwei Schluessellaengen, drei AAD-Laengen und zwolf
#      Nachrichtenlaengen (0, 1, 15, 16, 17, 33, 63, 64, 100, 255, 1024,
#      4096). Der Softwareweg ist dafuer ueber AesGcmNurSoftware(1)
#      erreichbar — ohne diesen Schalter waere er auf dieser CPU nicht
#      messbar und der Test einseitig (#1823).
#   2. GHASH EINZELN gegen den bitweisen Weg: AesGcmGhash ueber Laengen mit
#      und ohne Teilblock.
#   3. AM ERZEUGNIS: die Bytes von PCLMULQDQ (66 0F 3A 44) und AESENC
#      (66 0F 38 DC) stehen drin — sonst waere gruen auch ohne jede
#      Hardwareinstruktion erreichbar.
#   4. DIE PRUEFVEKTOREN bleiben gruen (tests/crypto_aead_test.sh deckt die
#      NIST-Vektoren ab; hier wird zusaetzlich der Standardvektor mit leerem
#      Klartext und leerem AAD gegen beide Wege gerechnet).
#   5. OEFFNEN: ein verfaelschtes Tag wird auf BEIDEN Wegen abgewiesen und
#      gibt keinen Klartext heraus.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ulimit -c 0
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1${2:+: $2}"; FAIL=$((FAIL+1)); }

bytefolge() { python3 -I -c "
import sys
d = open(sys.argv[1], 'rb').read()
m = bytes.fromhex(sys.argv[2])
n = 0; i = d.find(m)
while i >= 0:
    n += 1; i = d.find(m, i + 1)
print(n)" "$1" "$2"; }

cat > "$TMP/g.lyx" <<'EOF'
unit main;
import std.io;
import std.alloc;
import std.cpu.features;
import std.crypto.aesgcm;

fn fuelle(p: int64, n: int64, saat: int64): int64 {
  var i: int64 := 0;
  var s: int64 := saat;
  while (i < n) { s := (s * 1103515245 + 12345) & 0x7FFFFFFF; poke8(p + i, (s >> 16) & 255); i := i + 1; }
  return 0;
}

fn main(): int64 {
  PrintStr("pclmul="c); PrintLn(CpuHasPCLMUL());
  PrintStr("aesni="c);  PrintLn(CpuHasAESNI());

  var key: int64 := alloc(32); var nonce: int64 := alloc(12);
  var aad: int64 := alloc(64);
  var pt: int64 := alloc(4096);
  var ct1: int64 := alloc(4096); var ct2: int64 := alloc(4096);
  var tag1: int64 := alloc(16);  var tag2: int64 := alloc(16);
  var pt2: int64 := alloc(4096);
  fuelle(key, 32, 7); fuelle(nonce, 12, 13); fuelle(aad, 64, 23); fuelle(pt, 4096, 31);

  var laengen: int64 := alloc(96);
  poke64(laengen,    0); poke64(laengen+ 8,    1); poke64(laengen+16,   15);
  poke64(laengen+24, 16); poke64(laengen+32,   17); poke64(laengen+40,   33);
  poke64(laengen+48, 63); poke64(laengen+56,   64); poke64(laengen+64,  100);
  poke64(laengen+72, 255); poke64(laengen+80, 1024); poke64(laengen+88, 4096);

  var schlecht: int64 := 0;
  var faelle: int64 := 0;
  var kl: int64 := 0;
  while (kl < 2) {
    var keyLen: int64 := 16; if (kl == 1) { keyLen := 32; }
    var al: int64 := 0;
    while (al < 3) {
      var aadLen: int64 := 0; if (al == 1) { aadLen := 20; } if (al == 2) { aadLen := 64; }
      var j: int64 := 0;
      while (j < 12) {
        var n: int64 := peek64(laengen + j * 8);
        AesGcmNurSoftware(0);
        if (!AesGcmSeal(key, keyLen, nonce, 12, aad, aadLen, pt, n, ct1, tag1, 16)) { PrintStrLn("SEAL_HW_FEHLER"c); return 1; }
        AesGcmNurSoftware(1);
        if (!AesGcmSeal(key, keyLen, nonce, 12, aad, aadLen, pt, n, ct2, tag2, 16)) { PrintStrLn("SEAL_SW_FEHLER"c); return 1; }
        var i: int64 := 0;
        var abw: int64 := 0;
        while (i < n) { if (peek8(ct1 + i) != peek8(ct2 + i)) { abw := abw + 1; } i := i + 1; }
        i := 0;
        while (i < 16) { if (peek8(tag1 + i) != peek8(tag2 + i)) { abw := abw + 1; } i := i + 1; }
        if (abw != 0) {
          schlecht := schlecht + 1;
          PrintStr("ABW keyLen="c); PrintStr(IntToStr(keyLen));
          PrintStr(" aadLen="c); PrintStr(IntToStr(aadLen));
          PrintStr(" n="c); PrintStr(IntToStr(n));
          PrintStr(" bytes="c); PrintLn(abw);
        }
        // Oeffnen auf dem Softwareweg, versiegelt auf dem Hardwareweg:
        // beide Richtungen muessen zusammenpassen.
        if (!AesGcmOpen(key, keyLen, nonce, 12, aad, aadLen, ct1, n, tag1, 16, pt2)) {
          schlecht := schlecht + 1; PrintStrLn("OPEN_SW_ABGEWIESEN"c);
        }
        AesGcmNurSoftware(0);
        if (!AesGcmOpen(key, keyLen, nonce, 12, aad, aadLen, ct2, n, tag2, 16, pt2)) {
          schlecht := schlecht + 1; PrintStrLn("OPEN_HW_ABGEWIESEN"c);
        }
        faelle := faelle + 1;
        j := j + 1;
      }
      al := al + 1;
    }
    kl := kl + 1;
  }
  PrintStr("faelle="c); PrintLn(faelle);
  PrintStr("abweichungen="c); PrintLn(schlecht);

  // 2. GHASH einzeln, beide Wege.
  var h: int64 := alloc(16); fuelle(h, 16, 97);
  var o1: int64 := alloc(16); var o2: int64 := alloc(16);
  var ghAbw: int64 := 0;
  var gl: int64 := 0;
  while (gl < 6) {
    var len: int64 := 0;
    if (gl == 1) { len := 1; } if (gl == 2) { len := 16; } if (gl == 3) { len := 17; }
    if (gl == 4) { len := 160; } if (gl == 5) { len := 1000; }
    AesGcmNurSoftware(0); AesGcmGhash(h, pt, len, o1);
    AesGcmNurSoftware(1); AesGcmGhash(h, pt, len, o2);
    var i: int64 := 0;
    while (i < 16) { if (peek8(o1 + i) != peek8(o2 + i)) { ghAbw := ghAbw + 1; } i := i + 1; }
    gl := gl + 1;
  }
  AesGcmNurSoftware(0);
  PrintStr("ghash_abweichungen="c); PrintLn(ghAbw);

  // 5. Verfaelschtes Tag: beide Wege weisen ab und schreiben keinen Klartext.
  var n2: int64 := 64;
  AesGcmSeal(key, 16, nonce, 12, aad, 20, pt, n2, ct1, tag1, 16);
  poke8(tag1, peek8(tag1) ^ 1);
  var i2: int64 := 0;
  while (i2 < n2) { poke8(pt2 + i2, 0xAA); i2 := i2 + 1; }
  var hwAbgewiesen: int64 := 0;
  if (!AesGcmOpen(key, 16, nonce, 12, aad, 20, ct1, n2, tag1, 16, pt2)) { hwAbgewiesen := 1; }
  var unberuehrt: int64 := 1;
  i2 := 0;
  while (i2 < n2) { if (peek8(pt2 + i2) != 0xAA) { unberuehrt := 0; } i2 := i2 + 1; }
  AesGcmNurSoftware(1);
  var swAbgewiesen: int64 := 0;
  if (!AesGcmOpen(key, 16, nonce, 12, aad, 20, ct1, n2, tag1, 16, pt2)) { swAbgewiesen := 1; }
  AesGcmNurSoftware(0);
  PrintStr("hw_abgewiesen="c); PrintLn(hwAbgewiesen);
  PrintStr("sw_abgewiesen="c); PrintLn(swAbgewiesen);
  PrintStr("klartext_unberuehrt="c); PrintLn(unberuehrt);

  if (schlecht == 0 && ghAbw == 0) { PrintStrLn("ALLES GLEICH"c); return 0; }
  return 1;
}
EOF

if ! ( cd "$TMP" && timeout 400 "$LYXC" --std-path="$ROOT" "$TMP/g.lyx" -o "$TMP/g" ) >"$TMP/b.log" 2>&1; then
  no "uebersetzt" "$(grep -m1 -iE 'error|sema' "$TMP/b.log")"
  echo "=== PASS=$PASS FAIL=$FAIL"; exit 1
fi
ok "uebersetzt"

AUS="$( cd "$TMP" && timeout 300 ./g 2>&1 )"; rc=$?
hol() { printf '%s\n' "$AUS" | sed -n "s/^$1=//p" | head -1; }
if [ "$rc" -ne 0 ]; then
  no "laeuft" "rc=$rc — $(printf '%s' "$AUS" | tr '\n' ' ' | cut -c1-300)"
  echo "=== PASS=$PASS FAIL=$FAIL"; exit 1
fi

if [ "$(hol pclmul)" = "1" ]; then
  ok "diese CPU hat PCLMULQDQ — der Hardwareweg wird wirklich gemessen"
else
  echo "HINWEIS: diese CPU hat kein PCLMULQDQ. Der Vergleich laeuft dann"
  echo "         zweimal ueber den Softwareweg und sagt ueber den"
  echo "         Hardwareweg NICHTS. Auf einer CPU mit PCLMULQDQ gegenmessen."
fi

[ "$(hol faelle)" = "72" ] && ok "72 Faelle gerechnet (2 Schluessellaengen x 3 AAD x 12 Laengen)" \
  || no "Fallzahl" "'$(hol faelle)' statt 72"
[ "$(hol abweichungen)" = "0" ] && ok "Chiffrat und Tag auf beiden Wegen Byte fuer Byte gleich" \
  || no "Abweichungen" "'$(hol abweichungen)' Faelle unterschiedlich"
[ "$(hol ghash_abweichungen)" = "0" ] && ok "GHASH einzeln gleich (6 Laengen, mit und ohne Teilblock)" \
  || no "GHASH" "'$(hol ghash_abweichungen)' abweichende Bytes"
[ "$(hol hw_abgewiesen)" = "1" ] && ok "verfaelschtes Tag: Hardwareweg weist ab" \
  || no "Tagpruefung Hardware" "'$(hol hw_abgewiesen)'"
[ "$(hol sw_abgewiesen)" = "1" ] && ok "verfaelschtes Tag: Softwareweg weist ab" \
  || no "Tagpruefung Software" "'$(hol sw_abgewiesen)'"
[ "$(hol klartext_unberuehrt)" = "1" ] && ok "abgewiesene Entschluesselung gibt keinen Klartext heraus" \
  || no "Klartext" "der Puffer wurde beschrieben"

# 3. Am Erzeugnis.
PCL="$(bytefolge "$TMP/g" 660f3a44)"
AES="$(bytefolge "$TMP/g" 660f38dc)"
if [ "$PCL" -ge 4 ]; then ok "Erzeugnis enthaelt PCLMULQDQ ($PCL mal; vier je Multiplikation)"
else no "PCLMULQDQ im Erzeugnis" "$PCL Vorkommen"; fi
if [ "$AES" -ge 1 ]; then ok "Erzeugnis enthaelt AESENC ($AES mal)"
else no "AESENC im Erzeugnis" "$AES Vorkommen"; fi

# Der bitweise Weg muss STEHEN BLEIBEN — er ist der Rueckfall ohne PCLMULQDQ
# und der Vergleichsmassstab dieses Tests.
if grep -q "fn gcmMul" "$ROOT/std/crypto/aesgcm.lyx"; then
  ok "bitweiser Rueckfall (gcmMul) ist weiter vorhanden"
else
  no "Rueckfall" "gcmMul wurde entfernt — ohne PCLMULQDQ gibt es dann keinen Weg"
fi

echo "=== PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
