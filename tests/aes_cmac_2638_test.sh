#!/usr/bin/env bash
# tests/aes_cmac_2638_test.sh — AES-CMAC (RFC 4493) und die Ableitung in
# Counter Mode nach SP 800-108, beides neu in std/crypto/aescmac.lyx (#2638).
#
# Gemessen wird in sechs Richtungen:
#
#   1. DIE PRUEFVEKTOREN, ausgefuehrt: RFC 4493 Anhang (AES-128) und
#      SP 800-38B Anhang D (AES-256), je vier Nachrichtenlaengen
#      (0, 16, 40, 64). 0 und 40 treffen den gepolsterten Zweig (K2),
#      16 und 64 den vollstaendigen (K1) — beide Unterschluessel sind damit
#      wirklich benutzt.
#   2. BEIDE SEITEN der Pruefung: AesCmacVerify nimmt den richtigen MAC an UND
#      weist einen um ein Bit geaenderten ab, an JEDER der 16 Bytepositionen.
#      Ein Test, der nur die Annahme prueft, waere auch von einer Fassung
#      erfuellt, die alles annimmt (#1823).
#   3. UNZULAESSIGE PARAMETER werden abgewiesen, nicht zurechtgebogen:
#      keyLen 17 und 24, macLen 0 und 17.
#   4. DIE ABLEITUNG gegen eine getrennt gerechnete Erwartung: K(1)||K(2) mit
#      Label "SMBSigningKey", 32 Byte Ausgabe. Zusaetzlich die Kette: die
#      ersten 16 Byte einer 32-Byte-Ableitung sind dieselben wie bei einer
#      16-Byte-Ableitung NUR, wenn L im Eingabeblock steht — sie duerfen sich
#      also UNTERSCHEIDEN, und genau das wird gemessen.
#   5. HARDWARE GEGEN SOFTWARE: mit AesCoreNurSoftware(1) rechnet derselbe
#      Vektor denselben MAC. Ohne diesen Schalter waere der Softwareweg auf
#      einer CPU mit AES-NI nicht messbar.
#   6. AM ERZEUGNIS: die Bytes von AESENC stehen drin (sonst waere gruen auch
#      ohne jede Hardwareinstruktion erreichbar).

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

cat > "$TMP/c.lyx" <<'EOF'
unit main;
import std.io;
import std.alloc;
import std.crypto.aescore;
import std.crypto.aescmac;

fn hexEin(p: int64, s: pchar, n: int64): int64 {
  var i: int64 := 0;
  while (i < n) {
    var c1: int64 := peek8(s as int64 + i*2) & 0xFF;
    var c2: int64 := peek8(s as int64 + i*2 + 1) & 0xFF;
    if (c1 > 57) { c1 := c1 - 87; } else { c1 := c1 - 48; }
    if (c2 > 57) { c2 := c2 - 87; } else { c2 := c2 - 48; }
    poke8(p + i, (c1 << 4) | c2);
    i := i + 1;
  }
  return 0;
}

fn hexAus(p: int64, n: int64): int64 {
  var hx: pchar := "0123456789abcdef";
  var b: int64 := alloc(200);
  var i: int64 := 0;
  while (i < n) {
    var v: int64 := peek8(p + i) & 0xFF;
    poke8(b + i*2,   peek8(hx as int64 + (v >> 4)));
    poke8(b + i*2+1, peek8(hx as int64 + (v & 15)));
    i := i + 1;
  }
  poke8(b + n*2, 0);
  PrintStr(b as pchar);
  return 0;
}

fn vektoren(marke: pchar, m: int64, k128: int64, k256: int64): int64 {
  var mac: int64 := alloc(16);
  var laengen: int64 := alloc(32);
  poke64(laengen, 0); poke64(laengen+8, 16); poke64(laengen+16, 40); poke64(laengen+24, 64);
  var i: int64 := 0;
  while (i < 4) {
    var L: int64 := peek64(laengen + i*8);
    AesCmac(k128, 16, m, L, mac);
    PrintStr(marke); PrintStr("128-"c); PrintInt(L); PrintStr(" "c); hexAus(mac, 16); PrintStr("\n"c);
    AesCmac(k256, 32, m, L, mac);
    PrintStr(marke); PrintStr("256-"c); PrintInt(L); PrintStr(" "c); hexAus(mac, 16); PrintStr("\n"c);
    i := i + 1;
  }
  return 0;
}

fn main(): int64 {
  var m: int64 := alloc(64);
  hexEin(m, "6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e5130c81c46a35ce411e5fbc1191a0a52eff69f2445df4f9b17ad2b417be66c3710"c, 64);
  var k128: int64 := alloc(16); hexEin(k128, "2b7e151628aed2a6abf7158809cf4f3c"c, 16);
  var k256: int64 := alloc(32); hexEin(k256, "603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4"c, 32);

  PrintStr("aesni="c); PrintLn(AesCoreAesniAktiv());
  vektoren("hw-"c, m, k128, k256);
  AesCoreNurSoftware(1);
  vektoren("sw-"c, m, k128, k256);
  AesCoreNurSoftware(0);

  // Pruefung: beide Seiten, jede Byteposition
  var mac: int64 := alloc(16);
  AesCmac(k128, 16, m, 40, mac);
  PrintStr("verify-gut="c); PrintLn(AesCmacVerify(k128, 16, m, 40, mac, 16));
  var abgewiesen: int64 := 0;
  var i: int64 := 0;
  while (i < 16) {
    poke8(mac + i, peek8(mac + i) ^ 0x80);
    if (AesCmacVerify(k128, 16, m, 40, mac, 16) == 0) { abgewiesen := abgewiesen + 1; }
    poke8(mac + i, peek8(mac + i) ^ 0x80);
    i := i + 1;
  }
  PrintStr("verify-abgewiesen="c); PrintLn(abgewiesen);
  // gekuerzter MAC: die ersten 8 Byte stimmen weiter
  PrintStr("verify-8="c); PrintLn(AesCmacVerify(k128, 16, m, 40, mac, 8));

  // Unzulaessige Parameter
  PrintStr("key17="c);  PrintLn(AesCmac(k128, 17, m, 16, mac));
  PrintStr("key24="c);  PrintLn(AesCmac(k256, 24, m, 16, mac));
  PrintStr("mac0="c);   PrintLn(AesCmacVerify(k128, 16, m, 40, mac, 0));
  PrintStr("mac17="c);  PrintLn(AesCmacVerify(k128, 16, m, 40, mac, 17));

  // Ableitung
  var ab32: int64 := alloc(32);
  var ab16: int64 := alloc(16);
  AesCmacKdfCtr(k128, 16, "SMBSigningKey"c as int64, 13, m, 16, ab32, 32);
  PrintStr("kdf32 "c); hexAus(ab32, 32); PrintStr("\n"c);
  AesCmacKdfCtr(k128, 16, "SMBSigningKey"c as int64, 13, m, 16, ab16, 16);
  PrintStr("kdf16 "c); hexAus(ab16, 16); PrintStr("\n"c);
  var gleichAnfang: int64 := 1;
  i := 0;
  while (i < 16) { if (peek8(ab16 + i) != peek8(ab32 + i)) { gleichAnfang := 0; } i := i + 1; }
  PrintStr("kdf-L-wirkt="c); PrintLn(1 - gleichAnfang);
  PrintStr("kdf-len0="c); PrintLn(AesCmacKdfCtr(k128, 16, "X"c as int64, 1, m, 16, ab16, 0));
  return 0;
}
EOF

if ! "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" > "$TMP/build.log" 2>&1; then
    no "uebersetzt" "$(tail -5 "$TMP/build.log")"
    echo "=== PASS=$PASS FAIL=$FAIL"; exit 1
fi
ok "uebersetzt"
"$TMP/c" > "$TMP/out.txt" 2>&1 || { no "laeuft" "$(tail -3 "$TMP/out.txt")"; echo "=== PASS=$PASS FAIL=$FAIL"; exit 1; }
ok "laeuft"

# RFC 4493 (AES-128) und SP 800-38B Anhang D (AES-256)
V128_0="bb1d6929e95937287fa37d129b756746"
V128_16="070a16b46b4d4144f79bdd9dd04a287c"
V128_40="dfa66747de9ae63030ca32611497c827"
V128_64="51f0bebf7e3b9d92fc49741779363cfe"
V256_0="028962f61b7bf89efc6b551f4667d983"
V256_16="28a7023f452e8f82bd4bf28d8c37c35c"
V256_40="aaf3d8f1de5640c232f5b169b9c911e6"
V256_64="e1992190549f6ed5696a2c056c315410"

pruefe() { # marke feld erwartet
    local got
    got="$(grep -m1 "^$1 " "$TMP/out.txt" | awk '{print $2}')"
    if [ "$got" = "$2" ]; then ok "$1 = $2"; else no "$1" "$got != $2"; fi
}
for weg in hw sw; do
    pruefe "$weg-128-0"  "$V128_0"
    pruefe "$weg-128-16" "$V128_16"
    pruefe "$weg-128-40" "$V128_40"
    pruefe "$weg-128-64" "$V128_64"
    pruefe "$weg-256-0"  "$V256_0"
    pruefe "$weg-256-16" "$V256_16"
    pruefe "$weg-256-40" "$V256_40"
    pruefe "$weg-256-64" "$V256_64"
done

if [ "$(grep -c '^aesni=1' "$TMP/out.txt")" = "1" ]; then
    ok "diese CPU hat AES-NI — der Hardwareweg wurde wirklich gemessen"
else
    ok "diese CPU hat kein AES-NI (nur der Softwareweg gemessen)"
fi

wert() { grep -m1 "^$1=" "$TMP/out.txt" | cut -d= -f2; }
[ "$(wert verify-gut)" = "1" ] && ok "Verify nimmt den richtigen MAC an" \
    || no "Verify" "verify-gut=$(wert verify-gut)"
[ "$(wert verify-abgewiesen)" = "16" ] && ok "Verify weist an allen 16 Bytepositionen ab" \
    || no "Verify-Gegenprobe" "nur $(wert verify-abgewiesen) von 16 abgewiesen"
[ "$(wert verify-8)" = "1" ] && ok "gekuerzter Vergleich (8 Byte) stimmt" \
    || no "gekuerzter Vergleich" "verify-8=$(wert verify-8)"
for p in key17 key24 mac0 mac17; do
    [ "$(wert $p)" = "0" ] && ok "unzulaessiger Parameter $p wird abgewiesen" \
        || no "Parameter $p" "liefert $(wert $p) statt 0"
done

KDF32="$(grep -m1 '^kdf32 ' "$TMP/out.txt" | awk '{print $2}')"
ERW="$(python3 -I -c "
from cryptography.hazmat.primitives.cmac import CMAC
from cryptography.hazmat.primitives.ciphers import algorithms
k=bytes.fromhex('2b7e151628aed2a6abf7158809cf4f3c')
ctx=bytes.fromhex('6bc1bee22e409f96e93d7e117393172a')
out=b''
for i in (1,2):
    c=CMAC(algorithms.AES(k))
    c.update(i.to_bytes(4,'big')+b'SMBSigningKey'+b'\x00'+ctx+(256).to_bytes(4,'big'))
    out+=c.finalize()
print(out[:32].hex())" 2>/dev/null)"
if [ -z "$ERW" ]; then
    # Ohne python-cryptography bleibt der festgeschriebene Wert, getrennt
    # gerechnet am 2026-11-24.
    ERW="3263f2000318264a763b33972fb55fd6f4a91db2d6867de147a4f78d87508473"
fi
if [ "$KDF32" = "$ERW" ]; then ok "KDF in Counter Mode == getrennte Rechnung"
else no "KDF" "$KDF32 != $ERW"; fi
[ "$(wert kdf-L-wirkt)" = "1" ] && ok "L steht im Eingabeblock (16- und 32-Byte-Ableitung unterscheiden sich)" \
    || no "KDF-L" "die Ausgabelaenge ging nicht in die Ableitung ein"
[ "$(wert kdf-len0)" = "0" ] && ok "Ableitung von 0 Byte wird abgewiesen" \
    || no "KDF-len0" "liefert $(wert kdf-len0) statt 0"

AESENC="$(bytefolge "$TMP/c" 660f38dc)"
if [ "$AESENC" -gt 0 ]; then ok "Erzeugnis enthaelt AESENC ($AESENC mal)"
else no "AESENC im Erzeugnis" "keine Hardwareinstruktion gefunden"; fi

echo "=== PASS=$PASS FAIL=$FAIL"
[ $FAIL -eq 0 ]
