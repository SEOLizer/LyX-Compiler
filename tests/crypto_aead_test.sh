#!/usr/bin/env bash
# tests/crypto_aead_test.sh — #2096 Etappe B: AES-GCM (SP 800-38D) und
# ChaCha20-Poly1305 (RFC 8439) gegen festgeschriebene Referenzwerte.
#
# Geprueft wird die WIRKUNG, nicht das Vorhandensein: Ciphertext und Tag
# byteweise vollstaendig, dazu der Rundlauf (Open liefert den Klartext
# zurueck) und beide Ablehnungsfaelle — verfaelschtes Tag und verfaelschte
# AAD muessen false liefern. Ein Test, der nur "Tag entstanden" oder "16 Byte
# geschrieben" prueft, waere blind fuer ein falsches Tag.
#
# Herkunft der Erwartungen (gegengerechnet mit python-cryptography 46.0.5):
#   - AES-128/256-GCM, Nonce 12 Byte (TLS) sowie 8 und 16 Byte (dort laeuft
#     J0 ueber GHASH, ein anderer Zweig), AAD 0/13/16/20, Klartext
#     0/16/17/60/64/65 Byte — die Laengen liegen um die Blockgrenze.
#   - GHASH einzeln ueber 48 und 20 Byte (Teilblock wird rechts genullt).
#   - ChaCha20 Blockfunktion: RFC 8439 §2.4.2 (Schluessel 00..1f, Nonce
#     00..004a0000 0000, Zaehler 1) — buchstaeblich der Strom aus dem RFC.
#   - Poly1305: RFC 8439 §2.5.2 ("Cryptographic Forum Research Group",
#     Tag a8061dc1305136c6c22b8baf0c0127a9), dazu Vielfaches von 16, Teilblock
#     und leere Nachricht.
#   - AEAD_CHACHA20_POLY1305 mit AAD 0/7/12/16 und 0/64/65/114 Byte Klartext.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/s.lyx" <<'LYXEOF'
unit main;
import std.io;
import std.alloc;
import std.crypto.aesgcm;
import std.crypto.chacha20poly1305;

fn hex(b: int64, n: int64): void {
  var d: pchar := "0123456789abcdef"c;
  var i: int64 := 0;
  while (i < n) {
    var v: int64 := peek8(b + i) & 255;
    PrintChar(StrCharAt(d, (v >> 4) & 15)); PrintChar(StrCharAt(d, v & 15));
    i := i + 1;
  }
  PrintLn("");
}
fn fuell(p: int64, n: int64, seed: int64): void {
  var i: int64 := 0;
  while (i < n) { poke8(p + i, (i * 31 + seed) & 255); i := i + 1; }
}

fn gcmFall(keyLen: int64, nonceLen: int64, aadLen: int64, ptLen: int64): void {
  var key: int64 := alloc(keyLen + 1); fuell(key, keyLen, 7);
  var nonce: int64 := alloc(nonceLen + 1); fuell(nonce, nonceLen, 19);
  var aad: int64 := alloc(aadLen + 1); fuell(aad, aadLen, 3);
  var pt: int64 := alloc(ptLen + 1); fuell(pt, ptLen, 101);
  var ct: int64 := alloc(ptLen + 1);
  var tag: int64 := alloc(16);
  if (!AesGcmSeal(key, keyLen, nonce, nonceLen, aad, aadLen, pt, ptLen, ct, tag, 16)) {
    PrintLn("SEALFEHLER"); return;
  }
  hex(ct, ptLen);
  hex(tag, 16);
  // Rundlauf
  var pt2: int64 := alloc(ptLen + 1);
  if (!AesGcmOpen(key, keyLen, nonce, nonceLen, aad, aadLen, ct, ptLen, tag, 16, pt2)) {
    PrintLn("OPENFEHLER"); return;
  }
  var i: int64 := 0; var gleich: int64 := 1;
  while (i < ptLen) { if (peek8(pt2 + i) != peek8(pt + i)) { gleich := 0; } i := i + 1; }
  if (gleich == 1) { PrintLn("rundlauf-ok"); } else { PrintLn("RUNDLAUF-FALSCH"); }
  // verfaelschtes Tag muss abgewiesen werden
  poke8(tag, peek8(tag) ^ 1);
  if (AesGcmOpen(key, keyLen, nonce, nonceLen, aad, aadLen, ct, ptLen, tag, 16, pt2)) {
    PrintLn("TAGFEHLER-DURCHGELASSEN");
  } else { PrintLn("tag-abgewiesen"); }
  poke8(tag, peek8(tag) ^ 1);
  // verfaelschte AAD muss abgewiesen werden
  if (aadLen > 0) {
    poke8(aad, peek8(aad) ^ 0x80);
    if (AesGcmOpen(key, keyLen, nonce, nonceLen, aad, aadLen, ct, ptLen, tag, 16, pt2)) {
      PrintLn("AAD-FEHLER-DURCHGELASSEN");
    } else { PrintLn("aad-abgewiesen"); }
    poke8(aad, peek8(aad) ^ 0x80);
  }
}

fn chachaFall(aadLen: int64, ptLen: int64): void {
  var key: int64 := alloc(32); fuell(key, 32, 7);
  var nonce: int64 := alloc(12); fuell(nonce, 12, 19);
  var aad: int64 := alloc(aadLen + 1); fuell(aad, aadLen, 3);
  var pt: int64 := alloc(ptLen + 1); fuell(pt, ptLen, 101);
  var ct: int64 := alloc(ptLen + 1);
  var tag: int64 := alloc(16);
  if (!ChaChaPolySeal(key, nonce, aad, aadLen, pt, ptLen, ct, tag)) { PrintLn("SEALFEHLER"); return; }
  hex(ct, ptLen);
  hex(tag, 16);
  var pt2: int64 := alloc(ptLen + 1);
  if (!ChaChaPolyOpen(key, nonce, aad, aadLen, ct, ptLen, tag, pt2)) { PrintLn("OPENFEHLER"); return; }
  var i: int64 := 0; var gleich: int64 := 1;
  while (i < ptLen) { if (peek8(pt2 + i) != peek8(pt + i)) { gleich := 0; } i := i + 1; }
  if (gleich == 1) { PrintLn("rundlauf-ok"); } else { PrintLn("RUNDLAUF-FALSCH"); }
  poke8(tag, peek8(tag) ^ 1);
  if (ChaChaPolyOpen(key, nonce, aad, aadLen, ct, ptLen, tag, pt2)) { PrintLn("TAGFEHLER-DURCHGELASSEN"); }
  else { PrintLn("tag-abgewiesen"); }
}

fn main(): int64 {
  // AES-GCM: 128/256 Bit, Nonce 12 (TLS) und 8/16 (GHASH-Weg fuer J0),
  // Laengen um die Blockgrenze
  gcmFall(16, 12, 0, 0);
  gcmFall(16, 12, 0, 16);
  gcmFall(16, 12, 20, 60);
  gcmFall(16, 12, 16, 64);
  gcmFall(16, 8,  13, 17);
  gcmFall(16, 16, 13, 17);
  gcmFall(32, 12, 0, 0);
  gcmFall(32, 12, 20, 60);
  gcmFall(32, 12, 16, 65);
  gcmFall(32, 8,  13, 17);
  // GHASH einzeln
  var h: int64 := alloc(16); fuell(h, 16, 5);
  var d: int64 := alloc(48); fuell(d, 48, 9);
  var o: int64 := alloc(16);
  AesGcmGhash(h, d, 48, o); hex(o, 16);
  AesGcmGhash(h, d, 20, o); hex(o, 16);
  // ChaCha20 RFC 8439 §2.4.2: Schluessel 0..31, Nonce 00:00:00:00:00:00:00:4a:00:00:00:00, Zaehler 1
  var k2: int64 := alloc(32); var i: int64 := 0;
  while (i < 32) { poke8(k2 + i, i); i := i + 1; }
  var n2: int64 := alloc(12); i := 0;
  while (i < 12) { poke8(n2 + i, 0); i := i + 1; }
  poke8(n2 + 7, 0x4a);
  var ks: int64 := alloc(64);
  ChaCha20Block(k2, 1, n2, ks); hex(ks, 64);
  // Poly1305 RFC 8439 §2.5.2
  var pk: int64 := alloc(32);
  poke8(pk + 0, 0x85); poke8(pk + 1, 0xd6); poke8(pk + 2, 0xbe); poke8(pk + 3, 0x78);
  poke8(pk + 4, 0x57); poke8(pk + 5, 0x55); poke8(pk + 6, 0x6d); poke8(pk + 7, 0x33);
  poke8(pk + 8, 0x7f); poke8(pk + 9, 0x44); poke8(pk + 10, 0x52); poke8(pk + 11, 0xfe);
  poke8(pk + 12, 0x42); poke8(pk + 13, 0xd5); poke8(pk + 14, 0x06); poke8(pk + 15, 0xa8);
  poke8(pk + 16, 0x01); poke8(pk + 17, 0x03); poke8(pk + 18, 0x80); poke8(pk + 19, 0x8a);
  poke8(pk + 20, 0xfb); poke8(pk + 21, 0x0d); poke8(pk + 22, 0xb2); poke8(pk + 23, 0xfd);
  poke8(pk + 24, 0x4a); poke8(pk + 25, 0xbf); poke8(pk + 26, 0xf6); poke8(pk + 27, 0xaf);
  poke8(pk + 28, 0x41); poke8(pk + 29, 0x49); poke8(pk + 30, 0xf5); poke8(pk + 31, 0x1b);
  var m: pchar := "Cryptographic Forum Research Group"c;
  var t: int64 := alloc(16);
  Poly1305Mac(pk, m as int64, 34, t); hex(t, 16);
  // Poly1305 Teilblock und Vielfaches von 16
  var d2: int64 := alloc(160); fuell(d2, 160, 11);
  Poly1305Mac(pk, d2, 160, t); hex(t, 16);
  Poly1305Mac(pk, d2, 15, t); hex(t, 16);
  Poly1305Mac(pk, d2, 0, t); hex(t, 16);
  // AEAD ChaCha20-Poly1305
  chachaFall(0, 0);
  chachaFall(12, 114);
  chachaFall(16, 64);
  chachaFall(7, 65);
  return 0;
}
LYXEOF

if ! ( cd "$ROOT" && timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/s.lyx" -o "$TMP/s" ) >"$TMP/log" 2>&1; then
  echo "FAIL uebersetzt nicht: $(grep -m1 -i error "$TMP/log")"; exit 1
fi
if [ ! -x "$TMP/s" ]; then echo "FAIL kein Erzeugnis (#1682: Schreibfehler mit Exit 0)"; exit 1; fi

cat > "$TMP/soll.txt" <<'SOLLEOF'

5a6508ecbaacbb3a21a564cf8dfc75d7
rundlauf-ok
tag-abgewiesen
5a2d0650952b4446a0320002ae452a0d
3c6e8751a2b5cb9df24e6d0215aee74f
rundlauf-ok
tag-abgewiesen
5a2d0650952b4446a0320002ae452a0d273bf94256a579246035b5dfe4bd8f911872276736f814a098ec3b4e159f84184edcb77213fbb8c131488ffa
efe7ca8aa009a1f408a469c06748592d
rundlauf-ok
tag-abgewiesen
aad-abgewiesen
5a2d0650952b4446a0320002ae452a0d273bf94256a579246035b5dfe4bd8f911872276736f814a098ec3b4e159f84184edcb77213fbb8c131488ffa334b32e6
3c2ccdd7011b5b09fef602f2d344c621
rundlauf-ok
tag-abgewiesen
aad-abgewiesen
e495769745982dd25827c60d83aafe516c
1032d2b91cdc977559bf2c63a1fe9c48
rundlauf-ok
tag-abgewiesen
aad-abgewiesen
e5cef74c677f8182c84554cc0059154c66
66e217cff8ba11e46444d301cd698797
rundlauf-ok
tag-abgewiesen
aad-abgewiesen

d403ac1c1ba83e290aa02f9173be6251
rundlauf-ok
tag-abgewiesen
06df5ae166f63a01a1d1c2d9141119024ef51a7f42770da4e3d0d05e60dd647c0b1420458f3bdb3d08a0a8f31f748e45f03462bb90fb5a3231873a23
9d988d4d22521b3f9a4a1ae4e5a011f8
rundlauf-ok
tag-abgewiesen
aad-abgewiesen
06df5ae166f63a01a1d1c2d9141119024ef51a7f42770da4e3d0d05e60dd647c0b1420458f3bdb3d08a0a8f31f748e45f03462bb90fb5a3231873a23a90980475b
ed12b99d01b26b40a2ae8a2ec5bf2461
rundlauf-ok
tag-abgewiesen
aad-abgewiesen
480a019d31a1cbd584c20ce25d5dbeed67
db61b61bff64198a18afd921b82cda70
rundlauf-ok
tag-abgewiesen
aad-abgewiesen
f48bfeb38e20e96579c1f02b64064fb8
209d0db5126964b5176bccfaff4bb03c
224f51f3401bd9e12fde276fb8631ded8c131f823d2c06e27e4fcaec9ef3cf788a3b0aa372600a92b57974cded2b9334794cba40c63e34cdea212c4cf07d41b7
a8061dc1305136c6c22b8baf0c0127a9
1ecad5a63b93e6ce2d45478aa6be4dbc
a8aa5514e1349296b85264d579ec2836
0103808afb0db2fd4abff6af4149f51b

3eb29b1bbc4b290e8a24fa62752ce129
rundlauf-ok
tag-abgewiesen
a622414fe99b474f49e38ece44fbc30240e399c65e0273d4defca70673f83e94ee2590008ef2d8eb0c352a28ac1d72a6fb559183658a091a4da29710850efe5141837ff2b0b4197cdb5acc6e8da383e150fb358e938b5b24865f7321d00ba4658cc49f5c4bc9bdc27c41de0598da3241bf00
2a74dc815a056ca82848403e59c35381
rundlauf-ok
tag-abgewiesen
a622414fe99b474f49e38ece44fbc30240e399c65e0273d4defca70673f83e94ee2590008ef2d8eb0c352a28ac1d72a6fb559183658a091a4da29710850efe51
7088c06f56ef672e725aacfcd971b48c
rundlauf-ok
tag-abgewiesen
a622414fe99b474f49e38ece44fbc30240e399c65e0273d4defca70673f83e94ee2590008ef2d8eb0c352a28ac1d72a6fb559183658a091a4da29710850efe5141
443cb5181745c3588c75f21498d109ce
rundlauf-ok
tag-abgewiesen
SOLLEOF

if ! ( ulimit -v 4000000; timeout 180 "$TMP/s" > "$TMP/ist.txt" 2>"$TMP/err.txt" ); then
  echo "FAIL Lauf gescheitert: $(head -1 "$TMP/err.txt")"; exit 1
fi

ZS=$(wc -l < "$TMP/soll.txt"); ZI=$(wc -l < "$TMP/ist.txt")
if [ "$ZI" != "$ZS" ]; then echo "FAIL $ZI Zeilen statt $ZS"; diff "$TMP/soll.txt" "$TMP/ist.txt" | head -20; exit 1; fi

FAIL=0; PASS=0; N=0
while IFS= read -r soll && IFS= read -r ist <&3; do
  N=$((N+1))
  if [ "$soll" = "$ist" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); echo "FAIL Zeile $N"; echo "  ist:  $ist"; echo "  soll: $soll"; fi
done < "$TMP/soll.txt" 3< "$TMP/ist.txt"

echo "PASS $PASS / FAIL $FAIL (AES-GCM, GHASH, ChaCha20, Poly1305, AEAD)"
if [ "$FAIL" != 0 ]; then exit 1; fi
echo "ALL PASS"
exit 0
