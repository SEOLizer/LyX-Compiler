#!/usr/bin/env bash
# tests/crypto_ed25519_test.sh — #2096: Ed25519 nach RFC 8032, nativ.
#
# Die Vektoren stehen unten im Test und sind maschinell aus RFC 8032 §7.1
# gezogen (rfc-editor.org), nicht aus dem Gedaechtnis und nicht aus einem
# frueheren Lauf dieses Codes: fuenf Faelle mit Nachrichten von 0, 1, 2, 64
# und 1023 Byte.
#
# Geprueft wird je Fall:
#   - der oeffentliche Schluessel aus dem Seed, byteweise
#   - die eigene Signatur, byteweise (Ed25519 ist deterministisch)
#   - die Pruefung der RFC-Signatur
#   - vier Ablehnungen: ein Bit im R-Teil, ein Bit im S-Teil, ein Bit im
#     oeffentlichen Schluessel, ein Bit in der Nachricht
#   - S >= L (alle Bits gesetzt) wird abgewiesen, nicht reduziert
#     (RFC 8032 §5.1.7)
# Dazu die Schluesselformate aus X.509: SubjectPublicKeyInfo und PKCS#8
# (RFC 8410), und dass der Seed aus PKCS#8 denselben oeffentlichen Schluessel
# ergibt wie das SPKI.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/ed_vektoren.txt" <<'VEKEOF'
1|9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60|d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a||e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b
2|4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb|3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c|72|92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00
3|c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7|fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025|af82|6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a
1024|f5e5767cf153319517630f226876b86c8160cc583bc013744c6bf255f5cc0ee5|278117fc144c72340f67d0f2316e8386ceffbf2b2428c9c51fef7c597f1d426e|08b8b2b733424243760fe426a4b54908632110a66c2f6591eabd3345e3e4eb98fa6e264bf09efe12ee50f8f54e9f77b1e355f6c50544e23fb1433ddf73be84d879de7c0046dc4996d9e773f4bc9efe5738829adb26c81b37c93a1b270b20329d658675fc6ea534e0810a4432826bf58c941efb65d57a338bbd2e26640f89ffbc1a858efcb8550ee3a5e1998bd177e93a7363c344fe6b199ee5d02e82d522c4feba15452f80288a821a579116ec6dad2b3b310da903401aa62100ab5d1a36553e06203b33890cc9b832f79ef80560ccb9a39ce767967ed628c6ad573cb116dbefefd75499da96bd68a8a97b928a8bbc103b6621fcde2beca1231d206be6cd9ec7aff6f6c94fcd7204ed3455c68c83f4a41da4af2b74ef5c53f1d8ac70bdcb7ed185ce81bd84359d44254d95629e9855a94a7c1958d1f8ada5d0532ed8a5aa3fb2d17ba70eb6248e594e1a2297acbbb39d502f1a8c6eb6f1ce22b3de1a1f40cc24554119a831a9aad6079cad88425de6bde1a9187ebb6092cf67bf2b13fd65f27088d78b7e883c8759d2c4f5c65adb7553878ad575f9fad878e80a0c9ba63bcbcc2732e69485bbc9c90bfbd62481d9089beccf80cfe2df16a2cf65bd92dd597b0707e0917af48bbb75fed413d238f5555a7a569d80c3414a8d0859dc65a46128bab27af87a71314f318c782b23ebfe808b82b0ce26401d2e22f04d83d1255dc51addd3b75a2b1ae0784504df543af8969be3ea7082ff7fc9888c144da2af58429ec96031dbcad3dad9af0dcbaaaf268cb8fcffead94f3c7ca495e056a9b47acdb751fb73e666c6c655ade8297297d07ad1ba5e43f1bca32301651339e22904cc8c42f58c30c04aafdb038dda0847dd988dcda6f3bfd15c4b4c4525004aa06eeff8ca61783aacec57fb3d1f92b0fe2fd1a85f6724517b65e614ad6808d6f6ee34dff7310fdc82aebfd904b01e1dc54b2927094b2db68d6f903b68401adebf5a7e08d78ff4ef5d63653a65040cf9bfd4aca7984a74d37145986780fc0b16ac451649de6188a7dbdf191f64b5fc5e2ab47b57f7f7276cd419c17a3ca8e1b939ae49e488acba6b965610b5480109c8b17b80e1b7b750dfc7598d5d5011fd2dcc5600a32ef5b52a1ecc820e308aa342721aac0943bf6686b64b2579376504ccc493d97e6aed3fb0f9cd71a43dd497f01f17c0e2cb3797aa2a2f256656168e6c496afc5fb93246f6b1116398a346f1a641f3b041e989f7914f90cc2c7fff357876e506b50d334ba77c225bc307ba537152f3f1610e4eafe595f6d9d90d11faa933a15ef1369546868a7f3a45a96768d40fd9d03412c091c6315cf4fde7cb68606937380db2eaaa707b4c4185c32eddcdd306705e4dc1ffc872eeee475a64dfac86aba41c0618983f8741c5ef68d3a101e8a3b8cac60c905c15fc910840b94c00a0b9d0|0aab4c900501b3e24d7cdf4663326a3a87df5e4843b2cbdb67cbf6e460fec350aa5371b1508f9f4528ecea23c436d94b5e8fcd4f681e30a6ac00a9704a188a03
SHA(abc)|833fe62409237b9d62ec77587520911e9a759cec1d19755b7da901b96dca3d42|ec172b93ad5e563bf4932c70e1245034c35467ef2efd4d64ebf819683467e2bf|ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f|dc2a4459e7369633a52b1bf277839a00201009a3efbf3ecb69bea2186c26b58909351fc9ac90b3ecfdfbc7c66431e0303dca179c138ac17ad9bef1177331a704
VEKEOF
cat > "$TMP/ed_spki.pem" <<'PEMEOF'
-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEA11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=
-----END PUBLIC KEY-----
PEMEOF
cat > "$TMP/ed_pkcs8.pem" <<'PEMEOF'
-----BEGIN PRIVATE KEY-----
MC4CAQAwBQYDK2VwBCIEIJ1hsZ3v/VpguoRK9JLsLMREScVpezJpGXA7rAMcrn9g
-----END PRIVATE KEY-----
PEMEOF

cat > "$TMP/s.lyx" <<'LYXEOF'
unit main;
import std.io;
import std.string;
import std.alloc;
import std.fs;
import std.crypto.ed25519;
import std.crypto.der;
import std.crypto.ct;

fn hexZiffer(c: int64): int64 {
  if (c >= 97) { return c - 87; }
  if (c >= 65) { return c - 55; }
  return c - 48;
}
// Hex-Ausschnitt (Adresse, Zeichenzahl) in Bytes wandeln; liefert die Bytes.
fn hexNachBytes(hex: int64, zeichen: int64, out: int64): int64 {
  var i: int64 := 0;
  while (i < zeichen / 2) {
    poke8(out + i, (hexZiffer(peek8(hex + i * 2)) << 4) | hexZiffer(peek8(hex + i * 2 + 1)));
    i := i + 1;
  }
  return zeichen / 2;
}
fn druckHex(b: int64, n: int64): void {
  var d: pchar := "0123456789abcdef"c;
  var i: int64 := 0;
  while (i < n) {
    var v: int64 := peek8(b + i) & 255;
    PrintChar(StrCharAt(d, (v >> 4) & 15)); PrintChar(StrCharAt(d, v & 15));
    i := i + 1;
  }
  PrintLn("");
}
fn jaNein(b: bool): void { if (b) { PrintLn("ja"); } else { PrintLn("nein"); } }

fn main(): int64 {
  var datei: int64 := alloc(65536);
  var n: int64 := ReadFile("VEKMARKER"c, datei as pchar, 65535);
  if (n <= 0) { PrintLn("VEKTOREN-FEHLEN"); return 1; }

  var sk: int64 := alloc(64);
  var pk: int64 := alloc(64);
  var msg: int64 := alloc(2048);
  var sig: int64 := alloc(128);
  var eigenPk: int64 := alloc(64);
  var eigenSig: int64 := alloc(128);

  var pos: int64 := 0;
  var fall: int64 := 0;
  while (pos < n) {
    // Zeile zerlegen: name|sk|pk|msg|sig
    var felder: int64 := alloc(5 * 8);
    var feld: int64 := 0;
    var start: int64 := pos;
    poke64(felder, pos);
    var i: int64 := pos;
    while (i < n && peek8(datei + i) != 10) {
      if (peek8(datei + i) == 124) {       // '|'
        feld := feld + 1;
        poke64(felder + feld * 8, i + 1);
      }
      i := i + 1;
    }
    var zeilenEnde: int64 := i;
    if (feld != 4) { pos := zeilenEnde + 1; continue; }

    var skH: int64 := peek64(felder + 8);
    var pkH: int64 := peek64(felder + 16);
    var msgH: int64 := peek64(felder + 24);
    var sigH: int64 := peek64(felder + 32);
    var skLen: int64 := pkH - skH - 1;
    var pkLen: int64 := msgH - pkH - 1;
    var msgLen: int64 := sigH - msgH - 1;
    var sigLen: int64 := zeilenEnde - sigH;

    hexNachBytes(datei + skH, skLen, sk);
    hexNachBytes(datei + pkH, pkLen, pk);
    var mBytes: int64 := hexNachBytes(datei + msgH, msgLen, msg);
    hexNachBytes(datei + sigH, sigLen, sig);

    fall := fall + 1;
    Print("fall "); PrintInt(fall); Print(" nachricht "); PrintInt(mBytes); PrintLn("");

    // oeffentlicher Schluessel aus dem Seed
    Ed25519PubAusSeed(sk, eigenPk);
    Print("pk "); druckHex(eigenPk, 32);
    // Signatur
    Ed25519Sign(sk, msg, mBytes, eigenSig);
    Print("sig "); druckHex(eigenSig, 64);
    // Pruefung der RFC-Signatur
    Print("rfc-sig-gueltig "); jaNein(Ed25519Verify(sig, msg, mBytes, pk));
    // Negativfaelle
    poke8(sig + 5, peek8(sig + 5) ^ 1);
    Print("sig-bit-gekippt-abgewiesen "); jaNein(!Ed25519Verify(sig, msg, mBytes, pk));
    poke8(sig + 5, peek8(sig + 5) ^ 1);
    poke8(sig + 40, peek8(sig + 40) ^ 2);
    Print("s-teil-gekippt-abgewiesen "); jaNein(!Ed25519Verify(sig, msg, mBytes, pk));
    poke8(sig + 40, peek8(sig + 40) ^ 2);
    poke8(pk + 1, peek8(pk + 1) ^ 4);
    Print("pk-gekippt-abgewiesen "); jaNein(!Ed25519Verify(sig, msg, mBytes, pk));
    poke8(pk + 1, peek8(pk + 1) ^ 4);
    if (mBytes > 0) {
      poke8(msg, peek8(msg) ^ 8);
      Print("nachricht-gekippt-abgewiesen "); jaNein(!Ed25519Verify(sig, msg, mBytes, pk));
      poke8(msg, peek8(msg) ^ 8);
    }
    // S >= L muss abgewiesen werden (alle Bits gesetzt)
    var sigBoese: int64 := alloc(128);
    var k: int64 := 0;
    while (k < 64) { poke8(sigBoese + k, peek8(sig + k)); k := k + 1; }
    k := 32;
    while (k < 64) { poke8(sigBoese + k, 0xFF); k := k + 1; }
    Print("s-ueber-L-abgewiesen "); jaNein(!Ed25519Verify(sigBoese, msg, mBytes, pk));

    pos := zeilenEnde + 1;
  }
  Print("faelle "); PrintInt(fall); PrintLn("");

  // Schluesselformate aus X.509
  var dPub: int64 := alloc(4096);
  var pem: int64 := alloc(8192);
  var pn: int64 := ReadFile("SPKIMARKER"c, pem as pchar, 8191);
  var dl: int64 := PemDekodiere(pem, pn, "PUBLIC KEY"c as int64, 10, dPub, 4096);
  var pkOut: int64 := alloc(32);
  Print("spki-gelesen "); jaNein(Ed25519PubAusSpki(dPub, dl, pkOut));
  Print("spki-pk "); druckHex(pkOut, 32);
  var dPriv: int64 := alloc(4096);
  pn := ReadFile("PKCS8MARKER"c, pem as pchar, 8191);
  dl := PemDekodiere(pem, pn, "PRIVATE KEY"c as int64, 11, dPriv, 4096);
  var seedOut: int64 := alloc(32);
  Print("pkcs8-gelesen "); jaNein(Ed25519PrivAusPkcs8(dPriv, dl, seedOut));
  var abgeleitet: int64 := alloc(32);
  Ed25519PubAusSeed(seedOut, abgeleitet);
  Print("pkcs8-passt-zu-spki "); jaNein(CTMemEqual(abgeleitet, pkOut, 32) == -1);
  return 0;
}
LYXEOF
sed -i "s|VEKMARKER|$TMP/ed_vektoren.txt|; s|SPKIMARKER|$TMP/ed_spki.pem|; s|PKCS8MARKER|$TMP/ed_pkcs8.pem|" "$TMP/s.lyx"

if ! ( cd "$ROOT" && timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/s.lyx" -o "$TMP/s" ) >"$TMP/log" 2>&1; then
  echo "FAIL uebersetzt nicht: $(grep -m1 -i error "$TMP/log")"; exit 1
fi
[ -x "$TMP/s" ] || { echo "FAIL kein Erzeugnis (#1682)"; exit 1; }

cat > "$TMP/soll.txt" <<'SOLLEOF'
fall 1 nachricht 0
pk d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a
sig e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b
rfc-sig-gueltig ja
sig-bit-gekippt-abgewiesen ja
s-teil-gekippt-abgewiesen ja
pk-gekippt-abgewiesen ja
s-ueber-L-abgewiesen ja
fall 2 nachricht 1
pk 3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c
sig 92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00
rfc-sig-gueltig ja
sig-bit-gekippt-abgewiesen ja
s-teil-gekippt-abgewiesen ja
pk-gekippt-abgewiesen ja
nachricht-gekippt-abgewiesen ja
s-ueber-L-abgewiesen ja
fall 3 nachricht 2
pk fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025
sig 6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a
rfc-sig-gueltig ja
sig-bit-gekippt-abgewiesen ja
s-teil-gekippt-abgewiesen ja
pk-gekippt-abgewiesen ja
nachricht-gekippt-abgewiesen ja
s-ueber-L-abgewiesen ja
fall 4 nachricht 1023
pk 278117fc144c72340f67d0f2316e8386ceffbf2b2428c9c51fef7c597f1d426e
sig 0aab4c900501b3e24d7cdf4663326a3a87df5e4843b2cbdb67cbf6e460fec350aa5371b1508f9f4528ecea23c436d94b5e8fcd4f681e30a6ac00a9704a188a03
rfc-sig-gueltig ja
sig-bit-gekippt-abgewiesen ja
s-teil-gekippt-abgewiesen ja
pk-gekippt-abgewiesen ja
nachricht-gekippt-abgewiesen ja
s-ueber-L-abgewiesen ja
fall 5 nachricht 64
pk ec172b93ad5e563bf4932c70e1245034c35467ef2efd4d64ebf819683467e2bf
sig dc2a4459e7369633a52b1bf277839a00201009a3efbf3ecb69bea2186c26b58909351fc9ac90b3ecfdfbc7c66431e0303dca179c138ac17ad9bef1177331a704
rfc-sig-gueltig ja
sig-bit-gekippt-abgewiesen ja
s-teil-gekippt-abgewiesen ja
pk-gekippt-abgewiesen ja
nachricht-gekippt-abgewiesen ja
s-ueber-L-abgewiesen ja
faelle 5
spki-gelesen ja
spki-pk d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a
pkcs8-gelesen ja
pkcs8-passt-zu-spki ja
SOLLEOF

if ! ( ulimit -v 4000000; timeout 300 "$TMP/s" > "$TMP/ist.txt" 2>"$TMP/err.txt" ); then
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

# Die Signaturzeilen muessen mit den RFC-Werten uebereinstimmen — getrennt
# geprueft, damit eine Abweichung als solche gemeldet wird und nicht nur als
# Zeilenunterschied.
VEKSIG=$(awk -F'|' '{print $5}' "$TMP/ed_vektoren.txt")
ISTSIG=$(awk '/^sig /{print $2}' "$TMP/ist.txt")
if [ "$VEKSIG" = "$ISTSIG" ]; then
  echo "PASS alle Signaturen bitgleich mit RFC 8032 §7.1"; PASS=$((PASS+1))
else
  echo "FAIL Signaturen weichen von RFC 8032 ab"; FAIL=$((FAIL+1))
  diff <(echo "$VEKSIG") <(echo "$ISTSIG") | head -6
fi

echo "PASS $PASS / FAIL $FAIL (Ed25519)"
[ "$FAIL" = 0 ] || exit 1
echo "ALL PASS"
exit 0
