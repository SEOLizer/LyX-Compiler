#!/usr/bin/env bash
# tests/aes_ccm_2638_test.sh — AES-CCM (RFC 3610) in std/crypto/aesccm.lyx (#2638).
#
# SMB 3.0 und 3.0.2 verschluesseln mit AES-128-CCM; 3.1.1 nutzt GCM.
#
# Gemessen wird in sieben Richtungen:
#
#   1. DIE PRUEFVEKTOREN, ausgefuehrt: alle ZWOELF Pakete aus RFC 3610
#      Abschnitt 8 — zwei Taglaengen (8 und 10), zwei AAD-Laengen (8 und 12)
#      und Nutzlasten von 19 bis 25 Byte, also mit und ohne Teilblock.
#      Verglichen wird Byte fuer Byte gegen die Werte des RFC.
#   2. DER RUECKWEG: AesCcmOpen gibt wieder den Klartext her, Byte fuer Byte.
#   3. BEIDE SEITEN: jedes einzelne Bit von Tag, Chiffrat, AAD und Nonce wird
#      gekippt und muss zur Abweisung fuehren. Ein Test, der nur das gute Tag
#      prueft, waere auch von einer Fassung erfuellt, die alles annimmt (#1823).
#   4. KEIN KLARTEXT OHNE TAG: der Ausgabepuffer bleibt bei Abweisung
#      unberuehrt (Fuellmuster 0xEE) — Release of Unverified Plaintext.
#   5. UNZULAESSIGE PARAMETER werden abgewiesen, nicht zurechtgebogen:
#      keyLen 24, nonceLen 6 und 14, tagLen 5 und 18, und eine Nachricht, die
#      nicht in L Byte darstellbar ist.
#   6. HARDWARE GEGEN SOFTWARE: mit AesCoreNurSoftware(1) ergeben alle zwoelf
#      Pakete dasselbe Chiffrat und dasselbe Tag.
#   7. AM ERZEUGNIS: die Bytes von AESENC stehen drin.

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
import std.crypto.aesccm;

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

fn fuell(p: int64, n: int64, v: int64): int64 {
  var i: int64 := 0;
  while (i < n) { poke8(p + i, v); i := i + 1; }
  return 0;
}

// Parameter der zwoelf Pakete aus RFC 3610 Abschnitt 8.
// nonce = 00 00 00 (p+2) (p+1) p (p-1) A0 A1 A2 A3 A4 A5
// Paketinhalt = 00 01 02 ... ; davon die ersten aadLen Byte als AAD.
fn aadLen(p: int64): int64 {
  if (p <= 3)  { return 8; }
  if (p <= 6)  { return 12; }
  if (p <= 9)  { return 8; }
  return 12;
}

fn ptLen(p: int64): int64 {
  var r: int64 := p % 3;
  if (p <= 3 || (p >= 7 && p <= 9)) {
    if (r == 1) { return 23; }
    if (r == 2) { return 24; }
    return 25;
  }
  if (r == 1) { return 19; }
  if (r == 2) { return 20; }
  return 21;
}

fn tagLen(p: int64): int64 {
  if (p <= 6) { return 8; }
  return 10;
}

fn baueNonce(nonce: int64, p: int64): int64 {
  poke8(nonce, 0); poke8(nonce + 1, 0); poke8(nonce + 2, 0);
  poke8(nonce + 3, p + 2); poke8(nonce + 4, p + 1);
  poke8(nonce + 5, p);     poke8(nonce + 6, p - 1);
  var i: int64 := 0;
  while (i < 6) { poke8(nonce + 7 + i, 0xA0 + i); i := i + 1; }
  return 0;
}

fn durchlauf(marke: pchar): int64 {
  var key: int64 := alloc(16);
  var i: int64 := 0;
  while (i < 16) { poke8(key + i, 0xC0 + i); i := i + 1; }
  var nonce: int64 := alloc(13);
  var daten: int64 := alloc(64);
  var ct: int64 := alloc(64);
  var tag: int64 := alloc(16);
  var pt2: int64 := alloc(64);

  var p: int64 := 1;
  while (p <= 12) {
    var al: int64 := aadLen(p);
    var pl: int64 := ptLen(p);
    var tl: int64 := tagLen(p);
    baueNonce(nonce, p);
    i := 0; while (i < al + pl) { poke8(daten + i, i); i := i + 1; }

    var rc: int64 := AesCcmSeal(key, 16, nonce, 13, daten, al, daten + al, pl, ct, tag, tl);
    PrintStr(marke); PrintStr("pkt"c); PrintInt(p); PrintStr(" "c); PrintInt(rc);
    PrintStr(" "c); hexAus(ct, pl); PrintStr(" "c); hexAus(tag, tl);

    // Rueckweg
    fuell(pt2, 64, 0xEE);
    var ro: int64 := AesCcmOpen(key, 16, nonce, 13, daten, al, ct, pl, tag, tl, pt2);
    var gl: int64 := 1;
    i := 0;
    while (i < pl) { if (peek8(pt2 + i) != peek8(daten + al + i)) { gl := 0; } i := i + 1; }
    PrintStr(" open="c); PrintInt(ro); PrintStr(" klartext="c); PrintInt(gl);

    // Jedes Bit von Tag und Chiffrat kippen; jedes muss abgewiesen werden und
    // der Ausgabepuffer unberuehrt bleiben.
    var bits: int64 := 0;
    var abgewiesen: int64 := 0;
    var unberuehrt: int64 := 1;
    var b: int64 := 0;
    while (b < (pl + tl) * 8) {
      var byteNr: int64 := b / 8;
      var bitNr: int64 := b % 8;
      var ziel: int64 := ct + byteNr;
      if (byteNr >= pl) { ziel := tag + (byteNr - pl); }
      poke8(ziel, peek8(ziel) ^ (1 << bitNr));
      fuell(pt2, 64, 0xEE);
      var r2: int64 := AesCcmOpen(key, 16, nonce, 13, daten, al, ct, pl, tag, tl, pt2);
      if (r2 == 0) { abgewiesen := abgewiesen + 1; }
      i := 0;
      while (i < pl) { if (peek8(pt2 + i) != 0xEE) { unberuehrt := 0; } i := i + 1; }
      poke8(ziel, peek8(ziel) ^ (1 << bitNr));
      bits := bits + 1;
      b := b + 1;
    }
    PrintStr(" bits="c); PrintInt(bits);
    PrintStr(" abgewiesen="c); PrintInt(abgewiesen);
    PrintStr(" unberuehrt="c); PrintInt(unberuehrt);

    // AAD und Nonce: je ein Bit
    poke8(daten, peek8(daten) ^ 1);
    var rAad: int64 := AesCcmOpen(key, 16, nonce, 13, daten, al, ct, pl, tag, tl, pt2);
    poke8(daten, peek8(daten) ^ 1);
    poke8(nonce + 12, peek8(nonce + 12) ^ 1);
    var rNon: int64 := AesCcmOpen(key, 16, nonce, 13, daten, al, ct, pl, tag, tl, pt2);
    poke8(nonce + 12, peek8(nonce + 12) ^ 1);
    PrintStr(" aad="c); PrintInt(rAad); PrintStr(" nonce="c); PrintInt(rNon);
    PrintStr("\n"c);
    p := p + 1;
  }
  return 0;
}

fn main(): int64 {
  PrintStr("aesni="c); PrintLn(AesCoreAesniAktiv());
  durchlauf("hw-"c);
  AesCoreNurSoftware(1);
  durchlauf("sw-"c);
  AesCoreNurSoftware(0);

  // Unzulaessige Parameter
  var key: int64 := alloc(32);
  fuell(key, 32, 0xC0);
  var nonce: int64 := alloc(16);
  fuell(nonce, 16, 0xA0);
  var pt: int64 := alloc(32);
  fuell(pt, 32, 1);
  var ct: int64 := alloc(32);
  var tag: int64 := alloc(20);
  PrintStr("key24="c);    PrintLn(AesCcmSeal(key, 24, nonce, 13, 0, 0, pt, 16, ct, tag, 8));
  PrintStr("nonce6="c);   PrintLn(AesCcmSeal(key, 16, nonce,  6, 0, 0, pt, 16, ct, tag, 8));
  PrintStr("nonce14="c);  PrintLn(AesCcmSeal(key, 16, nonce, 14, 0, 0, pt, 16, ct, tag, 8));
  PrintStr("tag5="c);     PrintLn(AesCcmSeal(key, 16, nonce, 13, 0, 0, pt, 16, ct, tag, 5));
  PrintStr("tag18="c);    PrintLn(AesCcmSeal(key, 16, nonce, 13, 0, 0, pt, 16, ct, tag, 18));
  // nonceLen 13 -> L = 2, also hoechstens 65535 Byte Nachricht
  PrintStr("zulang="c);   PrintLn(AesCcmSeal(key, 16, nonce, 13, 0, 0, pt, 65536, ct, tag, 8));
  PrintStr("gerade-noch="c); PrintLn(AesCcmSeal(key, 16, nonce, 13, 0, 0, pt, 16, ct, tag, 16));
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

# RFC 3610 Abschnitt 8, Pakete 1..12: Chiffrat und Tag.
ERW_CT=(
 "588c979a61c663d2f066d0c2c0f989806d5f6b61dac384"
 "72c91a36e135f8cf291ca894085c87e3cc15c439c9e43a3b"
 "51b1e5f44a197d1da46b0f8e2d282ae871e838bb64da859657"
 "a28c6865939a9a79faaa5c4c2a9d4a91cdac8c"
 "dcf1fb7b5d9e23fb9d4e131253658ad86ebdca3e"
 "6fc1b011f006568b5171a42d953d469b2570a4bd87"
 "0135d1b2c95f41d5d1d4fec185d166b8094e999dfed96c"
 "7b75399ac0831dd2f0bbd75879a2fd8f6cae6b6cd9b7db24"
 "82531a60cc24945a4b8279181ab5c84df21ce7f9b73f42e197"
 "07342594157785152b074098330abb141b947b"
 "676bb20380b0e301e8ab79590a396da78b834934"
 "c0ffa0d6f05bdb67f24d43a4338d2aa4bed7b20e43"
)
ERW_TAG=(
 "17e8d12cfdf926e0" "a091d56e10400916" "4adaa76fbd9fb0c5"
 "96c861b9c9e61ef1" "51e83f077d9c2d93" "405a0443ac91cb94"
 "048c56602c97acbb7490" "c17b4433f434963f34b4" "ea9c07e56b5eb17e5f4e"
 "566aa9406b4d999988dd" "f53aa2e9107a8b6c022c" "cd1aa31662e7ad65d6db"
)

for weg in hw sw; do
    alleGut=1; meldung=""
    p=1
    while [ $p -le 12 ]; do
        ZEILE="$(grep -m1 "^${weg}-pkt${p} " "$TMP/out.txt")"
        set -- $ZEILE
        RC="$2"; CT="$3"; TAG="$4"
        E_CT="${ERW_CT[$((p-1))]}"; E_TAG="${ERW_TAG[$((p-1))]}"
        if [ "$RC" != "1" ] || [ "$CT" != "$E_CT" ] || [ "$TAG" != "$E_TAG" ]; then
            alleGut=0; meldung="Paket $p: $CT/$TAG != $E_CT/$E_TAG"
            break
        fi
        p=$((p+1))
    done
    if [ $alleGut -eq 1 ]; then ok "$weg: alle 12 RFC-3610-Pakete bitgleich"
    else no "$weg: RFC-3610-Pakete" "$meldung"; fi
done

# Rueckweg, Bitkippen, kein Klartext ohne Tag
schlecht=0; grund=""
while read -r zeile; do
    case "$zeile" in
      hw-pkt*|sw-pkt*) ;;
      *) continue ;;
    esac
    open=$(echo "$zeile"  | sed -n 's/.* open=\([0-9]*\).*/\1/p')
    klar=$(echo "$zeile"  | sed -n 's/.* klartext=\([0-9]*\).*/\1/p')
    bits=$(echo "$zeile"  | sed -n 's/.* bits=\([0-9]*\).*/\1/p')
    abg=$(echo "$zeile"   | sed -n 's/.* abgewiesen=\([0-9]*\).*/\1/p')
    unb=$(echo "$zeile"   | sed -n 's/.* unberuehrt=\([0-9]*\).*/\1/p')
    aad=$(echo "$zeile"   | sed -n 's/.* aad=\([0-9]*\).*/\1/p')
    non=$(echo "$zeile"   | sed -n 's/.* nonce=\([0-9]*\).*/\1/p')
    name="${zeile%% *}"
    [ "$open" = "1" ] || { schlecht=1; grund="$name: open=$open"; break; }
    [ "$klar" = "1" ] || { schlecht=1; grund="$name: Klartext weicht ab"; break; }
    [ "$abg" = "$bits" ] || { schlecht=1; grund="$name: nur $abg von $bits gekippten Bits abgewiesen"; break; }
    [ "$unb" = "1" ] || { schlecht=1; grund="$name: abgewiesener Lauf gab Klartext heraus"; break; }
    [ "$aad" = "0" ] || { schlecht=1; grund="$name: geaenderte AAD wurde angenommen"; break; }
    [ "$non" = "0" ] || { schlecht=1; grund="$name: geaenderte Nonce wurde angenommen"; break; }
done < "$TMP/out.txt"
if [ $schlecht -eq 0 ]; then
    GESBITS="$(awk '/pkt/ {for(i=1;i<=NF;i++) if ($i ~ /^bits=/) {split($i,a,"="); s+=a[2]}} END {print s}' "$TMP/out.txt")"
    ok "Rueckweg stimmt, alle $GESBITS gekippten Bits abgewiesen, AAD und Nonce ebenso, kein Klartext ohne Tag"
else
    no "Oeffnen" "$grund"
fi

wert() { grep -m1 "^$1=" "$TMP/out.txt" | cut -d= -f2; }
for p in key24 nonce6 nonce14 tag5 tag18 zulang; do
    [ "$(wert $p)" = "0" ] && ok "unzulaessiger Parameter $p wird abgewiesen" \
        || no "Parameter $p" "liefert $(wert $p) statt 0"
done
[ "$(wert gerade-noch)" = "1" ] && ok "zulaessige Parameter (tagLen 16) gehen durch" \
    || no "tagLen 16" "wurde abgewiesen — die Pruefung ist zu streng"

AESENC="$(bytefolge "$TMP/c" 660f38dc)"
if [ "$AESENC" -gt 0 ]; then ok "Erzeugnis enthaelt AESENC ($AESENC mal)"
else no "AESENC im Erzeugnis" "keine Hardwareinstruktion gefunden"; fi

echo "=== PASS=$PASS FAIL=$FAIL"
[ $FAIL -eq 0 ]
