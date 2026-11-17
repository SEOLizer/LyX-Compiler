#!/usr/bin/env bash
# tests/tls13_rfc8448_test.sh — #2096 Abnahmekriterium 5: RFC 8448
# ("TLS 1.3 Traces") bytegenau.
#
# Geprueft wird Abschnitt 3 ("Simple 1-RTT Handshake") des RFC gegen unsere
# Bausteine. Die Werte sind mit einem Auszugsskript aus dem RFC-Text gezogen
# und hier eingebettet; der Test braucht kein Netz.
#
#   1. X25519: beide veroeffentlichten Privatschluessel ergeben die
#      veroeffentlichten oeffentlichen Anteile, und BEIDE Richtungen des
#      Austauschs ergeben das veroeffentlichte Geheimnis.
#   2. Der ganze Schluesselplan aus RFC 8446 Paragraph 7.1: early_secret,
#      derived, handshake_secret, c/s hs traffic, master_secret,
#      c/s ap traffic, exporter_master — jeder Wert gegen den im RFC.
#   3. Verkehrsschluessel und IV fuer Handschlag und Anwendungsdaten.
#   4. finished_key und verify_data. Das Transkript dafuer wird aus den
#      veroeffentlichten Nachrichten zusammengesetzt (ClientHello,
#      ServerHello und der Serverflug ohne die letzten 36 Byte, also ohne
#      das Finished selbst) — damit haengt die Pruefung nicht nur am
#      Schluesselplan, sondern auch an der Transkriptbildung.
#   5. Record-Schicht: der veroeffentlichte verschluesselte Serverflug wird
#      mit den veroeffentlichten Schluesseln geoeffnet und muss den
#      veroeffentlichten Klartext samt Typbyte 22 ergeben; dasselbe fuer den
#      Anwendungsrecord mit Typbyte 23.
#   6. Gegenprobe: ein gekipptes Byte im Record MUSS abgewiesen werden. Ohne
#      sie waere der Test auch von einem AEAD erfuellt, das jedes Tag
#      annimmt.
#
# Was dieser Test NICHT leistet, und das ist keine Nachlaessigkeit: ein
# bytegleiches ClientHello unserer Unit. Das ClientHello im RFC traegt
# Erweiterungen, die wir nicht senden (psk_key_exchange_modes, early_data,
# acht Gruppen) — es ist eine Mitschrift einer anderen Umsetzung. Was RFC 8448
# festnagelt, ist die KRYPTOGRAPHIE, und die ist hier Byte fuer Byte geprueft.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/s.lyx" <<'LYXEOF'
unit main;
import std.io;
import std.string;
import std.alloc;
import std.crypto.sha256;
import std.crypto.hkdf;
import std.crypto.aesgcm;
import std.crypto.x25519;

// Hexziffer -> Wert
fn hv(c: int64): int64 {
  if (c >= 48 && c <= 57) { return c - 48; }
  if (c >= 97 && c <= 102) { return c - 97 + 10; }
  if (c >= 65 && c <= 70) { return c - 65 + 10; }
  return -1;
}

// Hexkette an Position p in den Puffer schreiben; liefert die neue Position.
fn hexAn(z: int64, p: int64, s: pchar): int64 {
  var n: int64 := StrLen(s);
  var i: int64 := 0;
  var q: int64 := p;
  while (i + 1 < n) {
    poke8(z + q, (hv(StrCharAt(s, i)) << 4) | hv(StrCharAt(s, i + 1)));
    q := q + 1;
    i := i + 2;
  }
  return q;
}

// Nonce nach RFC 8446 Paragraph 5.3: festes IV, die Sequenznummer
// rechtsbuendig hineinverxort.
fn nonce(iv: int64, seq: int64, out: int64): void {
  var i: int64 := 0;
  while (i < 12) { poke8(out + i, peek8(iv + i)); i := i + 1; }
  i := 0;
  while (i < 8) {
    var b: int64 := ((seq as uint64) >> ((7 - i) * 8)) & 255;
    poke8(out + 4 + i, peek8(out + 4 + i) ^ b);
    i := i + 1;
  }
}

var gFails: int64 := 0;

fn gleich(name: pchar, a: int64, b: int64, n: int64): void {
  var i: int64 := 0;
  var ok: int64 := 1;
  while (i < n) {
    if (peek8(a + i) != peek8(b + i)) { ok := 0; }
    i := i + 1;
  }
  Print(name); Print(" ");
  if (ok == 1) { PrintLn("ok"); } else { PrintLn("ABWEICHUNG"); gFails := gFails + 1; }
}

fn vCPRIV(z: int64): int64 {
  var p: int64 := 0;
  p := hexAn(z, p, "49af42ba7f7994852d713ef2784bcbcaa7911de26adc5642cb634540e7ea5005"c);
  return p;
}

fn vCPUB(z: int64): int64 {
  var p: int64 := 0;
  p := hexAn(z, p, "99381de560e4bd43d23d8e435a7dbafeb3c06e51c13cae4d5413691e529aaf2c"c);
  return p;
}

fn vSPRIV(z: int64): int64 {
  var p: int64 := 0;
  p := hexAn(z, p, "b1580eeadf6dd589b8ef4f2d5652578cc810e9980191ec8d058308cea216a21e"c);
  return p;
}

fn vSPUB(z: int64): int64 {
  var p: int64 := 0;
  p := hexAn(z, p, "c9828876112095fe66762bdbf7c672e156d6cc253b833df1dd69b1b04e751f0f"c);
  return p;
}

fn vCH(z: int64): int64 {
  var p: int64 := 0;
  p := hexAn(z, p, "010000c00303cb34ecb1e78163ba1c38c6dacb196a6dffa21a8d9912ec18a2ef"c);
  p := hexAn(z, p, "6283024dece7000006130113031302010000910000000b000900000673657276"c);
  p := hexAn(z, p, "6572ff01000100000a00140012001d0017001800190100010101020103010400"c);
  p := hexAn(z, p, "230000003300260024001d002099381de560e4bd43d23d8e435a7dbafeb3c06e"c);
  p := hexAn(z, p, "51c13cae4d5413691e529aaf2c002b0003020304000d0020001e040305030603"c);
  p := hexAn(z, p, "020308040805080604010501060102010402050206020202002d00020101001c"c);
  p := hexAn(z, p, "00024001"c);
  return p;
}

fn vSH(z: int64): int64 {
  var p: int64 := 0;
  p := hexAn(z, p, "020000560303a6af06a4121860dc5e6e60249cd34c95930c8ac5cb1434dac155"c);
  p := hexAn(z, p, "772ed3e2692800130100002e00330024001d0020c9828876112095fe66762bdb"c);
  p := hexAn(z, p, "f7c672e156d6cc253b833df1dd69b1b04e751f0f002b00020304"c);
  return p;
}

fn vEARLY(z: int64): int64 {
  var p: int64 := 0;
  p := hexAn(z, p, "33ad0a1c607ec03b09e6cd9893680ce210adf300aa1f2660e1b22e10f170f92a"c);
  return p;
}

fn vDERIVED(z: int64): int64 {
  var p: int64 := 0;
  p := hexAn(z, p, "6f2615a108c702c5678f54fc9dbab69716c076189c48250cebeac3576c3611ba"c);
  return p;
}

fn vECDHE(z: int64): int64 {
  var p: int64 := 0;
  p := hexAn(z, p, "8bd4054fb55b9d63fdfbacf9f04b9f0d35e6d63f537563efd46272900f89492d"c);
  return p;
}

fn vHS(z: int64): int64 {
  var p: int64 := 0;
  p := hexAn(z, p, "1dc826e93606aa6fdc0aadc12f741b01046aa6b99f691ed221a9f0ca043fbeac"c);
  return p;
}

fn vTHHS(z: int64): int64 {
  var p: int64 := 0;
  p := hexAn(z, p, "860c06edc07858ee8e78f0e7428c58edd6b43f2ca3e6e95f02ed063cf0e1cad8"c);
  return p;
}

fn vCHS(z: int64): int64 {
  var p: int64 := 0;
  p := hexAn(z, p, "b3eddb126e067f35a780b3abf45e2d8f3b1a950738f52e9600746a0e27a55a21"c);
  return p;
}

fn vSHS(z: int64): int64 {
  var p: int64 := 0;
  p := hexAn(z, p, "b67b7d690cc16c4e75e54213cb2d37b4e9c912bcded9105d42befd59d391ad38"c);
  return p;
}

fn vDERIVED2(z: int64): int64 {
  var p: int64 := 0;
  p := hexAn(z, p, "43de77e0c77713859a944db9db2590b53190a65b3ee2e4f12dd7a0bb7ce254b4"c);
  return p;
}

fn vMASTER(z: int64): int64 {
  var p: int64 := 0;
  p := hexAn(z, p, "18df06843d13a08bf2a449844c5f8a478001bc4d4c627984d5a41da8d0402919"c);
  return p;
}

fn vSKEYHS(z: int64): int64 {
  var p: int64 := 0;
  p := hexAn(z, p, "3fce516009c21727d0f2e4e86ee403bc"c);
  return p;
}

fn vSIVHS(z: int64): int64 {
  var p: int64 := 0;
  p := hexAn(z, p, "5d313eb2671276ee13000b30"c);
  return p;
}

fn vFINKEY(z: int64): int64 {
  var p: int64 := 0;
  p := hexAn(z, p, "008d3b66f816ea559f96b537e885c31fc068bf492c652f01f288a1d8cdc19fc8"c);
  return p;
}

fn vVERIFY(z: int64): int64 {
  var p: int64 := 0;
  p := hexAn(z, p, "9b9b141d906337fbd2cbdce71df4deda4ab42c309572cb7fffee5454b78f0718"c);
  return p;
}

fn vTHAP(z: int64): int64 {
  var p: int64 := 0;
  p := hexAn(z, p, "9608102a0f1ccc6db6250b7b7e417b1a000eaada3daae4777a7686c9ff83df13"c);
  return p;
}

fn vCAP(z: int64): int64 {
  var p: int64 := 0;
  p := hexAn(z, p, "9e40646ce79a7f9dc05af8889bce6552875afa0b06df0087f792ebb7c17504a5"c);
  return p;
}

fn vSAP(z: int64): int64 {
  var p: int64 := 0;
  p := hexAn(z, p, "a11af9f05531f856ad47116b45a950328204b4f44bfb6b3a4b4f1f3fcb631643"c);
  return p;
}

fn vEXPMAST(z: int64): int64 {
  var p: int64 := 0;
  p := hexAn(z, p, "fe22f881176eda18eb8f44529e6792c50c9a3f89452f68d8ae311b4309d3cf50"c);
  return p;
}

fn vSKEYAP(z: int64): int64 {
  var p: int64 := 0;
  p := hexAn(z, p, "9f02283b6c9c07efc26bb9f2ac92e356"c);
  return p;
}

fn vSIVAP(z: int64): int64 {
  var p: int64 := 0;
  p := hexAn(z, p, "cf782b88dd83549aadf1e984"c);
  return p;
}

fn vFLUGPT(z: int64): int64 {
  var p: int64 := 0;
  p := hexAn(z, p, "080000240022000a00140012001d00170018001901000101010201030104001c"c);
  p := hexAn(z, p, "00024001000000000b0001b9000001b50001b0308201ac30820115a003020102"c);
  p := hexAn(z, p, "020102300d06092a864886f70d01010b0500300e310c300a0603550403130372"c);
  p := hexAn(z, p, "7361301e170d3136303733303031323335395a170d3236303733303031323335"c);
  p := hexAn(z, p, "395a300e310c300a0603550403130372736130819f300d06092a864886f70d01"c);
  p := hexAn(z, p, "0101050003818d0030818902818100b4bb498f8279303d980836399b36c6988c"c);
  p := hexAn(z, p, "0c68de55e1bdb826d3901a2461eafd2de49a91d015abbc9a95137ace6c1af19e"c);
  p := hexAn(z, p, "aa6af98c7ced43120998e187a80ee0ccb0524b1b018c3e0b63264d449a6d38e2"c);
  p := hexAn(z, p, "2a5fda430846748030530ef0461c8ca9d9efbfae8ea6d1d03e2bd193eff0ab9a"c);
  p := hexAn(z, p, "8002c47428a6d35a8d88d79f7f1e3f0203010001a31a301830090603551d1304"c);
  p := hexAn(z, p, "023000300b0603551d0f0404030205a0300d06092a864886f70d01010b050003"c);
  p := hexAn(z, p, "81810085aad2a0e5b9276b908c65f73a7267170618a54c5f8a7b337d2df7a594"c);
  p := hexAn(z, p, "365417f2eae8f8a58c8f8172f9319cf36b7fd6c55b80f21a03015156726096fd"c);
  p := hexAn(z, p, "335e5e67f2dbf102702e608ccae6bec1fc63a42a99be5c3eb7107c3c54e9b9eb"c);
  p := hexAn(z, p, "2bd5203b1c3b84e0a8b2f759409ba3eac9d91d402dcc0cc8f8961229ac9187b4"c);
  p := hexAn(z, p, "2b4de100000f000084080400805a747c5d88fa9bd2e55ab085a61015b7211f82"c);
  p := hexAn(z, p, "4cd484145ab3ff52f1fda8477b0b7abc90db78e2d33a5c141a078653fa6bef78"c);
  p := hexAn(z, p, "0c5ea248eeaaa785c4f394cab6d30bbe8d4859ee511f602957b15411ac027671"c);
  p := hexAn(z, p, "459e46445c9ea58c181e818e95b8c3fb0bf3278409d3be152a3da5043e063dda"c);
  p := hexAn(z, p, "65cdf5aea20d53dfacd42f74f3140000209b9b141d906337fbd2cbdce71df4de"c);
  p := hexAn(z, p, "da4ab42c309572cb7fffee5454b78f0718"c);
  return p;
}

fn vFLUGREC(z: int64): int64 {
  var p: int64 := 0;
  p := hexAn(z, p, "17030302a2d1ff334a56f5bff6594a07cc87b580233f500f45e489e7f33af35e"c);
  p := hexAn(z, p, "df7869fcf40aa40aa2b8ea73f848a7ca07612ef9f945cb960b4068905123ea78"c);
  p := hexAn(z, p, "b111b429ba9191cd05d2a389280f526134aadc7fc78c4b729df828b5ecf7b13b"c);
  p := hexAn(z, p, "d9aefb0e57f271585b8ea9bb355c7c79020716cfb9b1183ef3ab20e37d57a6b9"c);
  p := hexAn(z, p, "d7477609aee6e122a4cf51427325250c7d0e509289444c9b3a648f1d71035d2e"c);
  p := hexAn(z, p, "d65b0e3cdd0cbae8bf2d0b227812cbb360987255cc744110c453baa4fcd61092"c);
  p := hexAn(z, p, "8d809810e4b7ed1a8fd991f06aa6248204797e36a6a73b70a2559c09ead68694"c);
  p := hexAn(z, p, "5ba246ab66e5edd8044b4c6de3fcf2a89441ac66272fd8fb330ef8190579b368"c);
  p := hexAn(z, p, "4596c960bd596eea520a56a8d650f563aad27409960dca63d3e688611ea5e22f"c);
  p := hexAn(z, p, "4415cf9538d51a200c27034272968a264ed6540c84838d89f72c24461aad6d26"c);
  p := hexAn(z, p, "f59ecaba9acbbb317b66d902f4f292a36ac1b639c637ce343117b65962224531"c);
  p := hexAn(z, p, "7b49eeda0c6258f100d7d961ffb138647e92ea330faeea6dfa31c7a84dc3bd7e"c);
  p := hexAn(z, p, "1b7a6c7178af36879018e3f252107f243d243dc7339d5684c8b0378bf30244da"c);
  p := hexAn(z, p, "8c87c843f5e56eb4c5e8280a2b48052cf93b16499a66db7cca71e4599426f7d4"c);
  p := hexAn(z, p, "61e66f99882bd89fc50800becca62d6c74116dbd2972fda1fa80f85df881edbe"c);
  p := hexAn(z, p, "5a37668936b335583b599186dc5c6918a396fa48a181d6b6fa4f9d62d513afbb"c);
  p := hexAn(z, p, "992f2b992f67f8afe67f76913fa388cb5630c8ca01e0c65d11c66a1e2ac4c859"c);
  p := hexAn(z, p, "77b7c7a6999bbf10dc35ae69f5515614636c0b9b68c19ed2e31c0b3b66763038"c);
  p := hexAn(z, p, "ebba42f3b38edc0399f3a9f23faa63978c317fc9fa66a73f60f0504de93b5b84"c);
  p := hexAn(z, p, "5e275592c12335ee340bbc4fddd502784016e4b3be7ef04dda49f4b440a30cb5"c);
  p := hexAn(z, p, "d2af939828fd4ae3794e44f94df5a631ede42c1719bfdabf0253fe5175be898e"c);
  p := hexAn(z, p, "750edc53370d2b"c);
  return p;
}

fn vAPPPT(z: int64): int64 {
  var p: int64 := 0;
  p := hexAn(z, p, "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"c);
  p := hexAn(z, p, "202122232425262728292a2b2c2d2e2f3031"c);
  return p;
}

fn vAPPREC(z: int64): int64 {
  var p: int64 := 0;
  p := hexAn(z, p, "17030300432e937e11ef4ac740e538ad36005fc4a46932fc3225d05f82aa1b36"c);
  p := hexAn(z, p, "e30efaf97d90e6dffc602dcb501a59a8fcc49c4bf2e5f0a21c0047c2abf33254"c);
  p := hexAn(z, p, "0dd032e167c2955d"c);
  return p;
}

fn main(): int64 {
  var leer: int64 := alloc(32);
  var zeros: int64 := alloc(32);
  var i: int64 := 0;
  while (i < 32) { poke8(zeros + i, 0); i := i + 1; }
  SHA256(0, 0, leer);                      // Hash der leeren Nachricht

  var cpriv: int64 := alloc(32);  vCPRIV(cpriv);
  var cpub: int64 := alloc(32);   vCPUB(cpub);
  var spriv: int64 := alloc(32);  vSPRIV(spriv);
  var spub: int64 := alloc(32);   vSPUB(spub);
  var ecdhe: int64 := alloc(32);  vECDHE(ecdhe);

  // ── 1. X25519 ────────────────────────────────────────────────────────────
  var pk: int64 := alloc(32);
  var sk: int64 := alloc(32);
  X25519KeyGen(cpriv, pk, sk);
  gleich("x25519-client-pub"c, pk, cpub, 32);
  X25519KeyGen(spriv, pk, sk);
  gleich("x25519-server-pub"c, pk, spub, 32);
  var gem: int64 := alloc(32);
  X25519SharedSecret(cpriv, spub, gem);
  gleich("x25519-geheimnis-client"c, gem, ecdhe, 32);
  X25519SharedSecret(spriv, cpub, gem);
  gleich("x25519-geheimnis-server"c, gem, ecdhe, 32);

  // ── 2. Schluesselplan (RFC 8446 §7.1) ────────────────────────────────────
  var early: int64 := alloc(32);   vEARLY(early);
  var derived: int64 := alloc(32); vDERIVED(derived);
  var hs: int64 := alloc(32);      vHS(hs);
  var thHs: int64 := alloc(32);    vTHHS(thHs);
  var chs: int64 := alloc(32);     vCHS(chs);
  var shs: int64 := alloc(32);     vSHS(shs);
  var derived2: int64 := alloc(32); vDERIVED2(derived2);
  var master: int64 := alloc(32);  vMASTER(master);
  var thAp: int64 := alloc(32);    vTHAP(thAp);
  var cap: int64 := alloc(32);     vCAP(cap);
  var sap: int64 := alloc(32);     vSAP(sap);
  var expm: int64 := alloc(32);    vEXPMAST(expm);

  var aus: int64 := alloc(64);
  HkdfExtract(32, 0, 0, zeros, 32, aus);
  gleich("early-secret"c, aus, early, 32);

  var lab: pchar := "derived"c;
  HkdfExpandLabel(32, early, 32, lab as int64, 7, leer, 32, aus, 32);
  gleich("derived"c, aus, derived, 32);

  HkdfExtract(32, derived, 32, ecdhe, 32, aus);
  gleich("handshake-secret"c, aus, hs, 32);

  var l2: pchar := "c hs traffic"c;
  HkdfExpandLabel(32, hs, 32, l2 as int64, 12, thHs, 32, aus, 32);
  gleich("c-hs-traffic"c, aus, chs, 32);
  var l3: pchar := "s hs traffic"c;
  HkdfExpandLabel(32, hs, 32, l3 as int64, 12, thHs, 32, aus, 32);
  gleich("s-hs-traffic"c, aus, shs, 32);

  HkdfExpandLabel(32, hs, 32, lab as int64, 7, leer, 32, aus, 32);
  gleich("derived-fuer-master"c, aus, derived2, 32);
  HkdfExtract(32, derived2, 32, zeros, 32, aus);
  gleich("master-secret"c, aus, master, 32);

  var l4: pchar := "c ap traffic"c;
  HkdfExpandLabel(32, master, 32, l4 as int64, 12, thAp, 32, aus, 32);
  gleich("c-ap-traffic"c, aus, cap, 32);
  var l5: pchar := "s ap traffic"c;
  HkdfExpandLabel(32, master, 32, l5 as int64, 12, thAp, 32, aus, 32);
  gleich("s-ap-traffic"c, aus, sap, 32);
  var l6: pchar := "exp master"c;
  HkdfExpandLabel(32, master, 32, l6 as int64, 10, thAp, 32, aus, 32);
  gleich("exporter-master"c, aus, expm, 32);

  // ── 3. Verkehrsschluessel ────────────────────────────────────────────────
  var skeyHs: int64 := alloc(16); vSKEYHS(skeyHs);
  var sivHs: int64 := alloc(12);  vSIVHS(sivHs);
  var skeyAp: int64 := alloc(16); vSKEYAP(skeyAp);
  var sivAp: int64 := alloc(12);  vSIVAP(sivAp);
  var lk: pchar := "key"c;
  var li: pchar := "iv"c;
  HkdfExpandLabel(32, shs, 32, lk as int64, 3, 0, 0, aus, 16);
  gleich("server-hs-key"c, aus, skeyHs, 16);
  HkdfExpandLabel(32, shs, 32, li as int64, 2, 0, 0, aus, 12);
  gleich("server-hs-iv"c, aus, sivHs, 12);
  HkdfExpandLabel(32, sap, 32, lk as int64, 3, 0, 0, aus, 16);
  gleich("server-ap-key"c, aus, skeyAp, 16);
  HkdfExpandLabel(32, sap, 32, li as int64, 2, 0, 0, aus, 12);
  gleich("server-ap-iv"c, aus, sivAp, 12);

  // ── 4. finished_key und verify_data ──────────────────────────────────────
  // Das Transkript fuer das Finished des Servers ist ClientHello ||
  // ServerHello || EncryptedExtensions || Certificate || CertificateVerify —
  // also der veroeffentlichte Flug OHNE die letzten 36 Byte (das Finished
  // selbst).
  var finkey: int64 := alloc(32); vFINKEY(finkey);
  var verify: int64 := alloc(32); vVERIFY(verify);
  var lf: pchar := "finished"c;
  HkdfExpandLabel(32, shs, 32, lf as int64, 8, 0, 0, aus, 32);
  gleich("finished-key"c, aus, finkey, 32);

  var ch: int64 := alloc(256);   var chLen: int64 := vCH(ch);
  var sh: int64 := alloc(128);   var shLen: int64 := vSH(sh);
  var flug: int64 := alloc(1024); var flugLen: int64 := vFLUGPT(flug);
  var trans: int64 := alloc(2048);
  var p: int64 := 0;
  var k: int64 := 0;
  while (k < chLen) { poke8(trans + p, peek8(ch + k)); p := p + 1; k := k + 1; }
  k := 0;
  while (k < shLen) { poke8(trans + p, peek8(sh + k)); p := p + 1; k := k + 1; }
  k := 0;
  while (k < flugLen - 36) { poke8(trans + p, peek8(flug + k)); p := p + 1; k := k + 1; }
  var th: int64 := alloc(32);
  SHA256(trans, p, th);
  HmacHash(32, finkey, 32, th, 32, aus);
  gleich("verify-data"c, aus, verify, 32);

  // ── 5. Record-Schicht: der verschluesselte Serverflug ───────────────────
  var rec: int64 := alloc(1024);  var recLen: int64 := vFLUGREC(rec);
  var klar: int64 := alloc(1024);
  var ctLen: int64 := recLen - 5 - 16;
  var nce: int64 := alloc(12);
  nonce(sivHs, 0, nce);                    // erster Record unter diesen Schluesseln
  var ok: bool := AesGcmOpen(skeyHs, 16, nce, 12, rec, 5,
                             rec + 5, ctLen, rec + 5 + ctLen, 16, klar);
  Print("flug-entschluesselt "); PrintInt(ok); PrintLn("");
  if (!ok) { gFails := gFails + 1; }
  gleich("flug-klartext"c, klar, flug, flugLen);
  Print("flug-typbyte "); PrintInt(peek8(klar + flugLen)); PrintLn("");

  // ── 6. Record-Schicht: Anwendungsdaten ──────────────────────────────────
  var arec: int64 := alloc(256); var arecLen: int64 := vAPPREC(arec);
  var apt: int64 := alloc(256);  var aptLen: int64 := vAPPPT(apt);
  var actLen: int64 := arecLen - 5 - 16;
  // Sequenz 1, NICHT 0: unter denselben Anwendungsschluesseln hat der Server
  // vorher das NewSessionTicket gesendet (RFC 8448, Abschnitt 3). Mit 0
  // scheitert die Entschluesselung — und genau so ist der Fehler hier
  // aufgefallen.
  nonce(sivAp, 1, nce);
  var ok2: bool := AesGcmOpen(skeyAp, 16, nce, 12, arec, 5,
                              arec + 5, actLen, arec + 5 + actLen, 16, klar);
  Print("app-entschluesselt "); PrintInt(ok2); PrintLn("");
  if (!ok2) { gFails := gFails + 1; }
  gleich("app-klartext"c, klar, apt, aptLen);
  Print("app-typbyte "); PrintInt(peek8(klar + aptLen)); PrintLn("");

  // ── 7. Gegenprobe: ein gekipptes Byte im Record muss auffallen ──────────
  poke8(rec + 7, peek8(rec + 7) ^ 1);
  nonce(sivHs, 0, nce);
  var ok3: bool := AesGcmOpen(skeyHs, 16, nce, 12, rec, 5,
                              rec + 5, ctLen, rec + 5 + ctLen, 16, klar);
  Print("gekippter-record-abgewiesen "); PrintInt(!ok3); PrintLn("");
  if (ok3) { gFails := gFails + 1; }

  Print("fails "); PrintInt(gFails); PrintLn("");
  return 0;
}
LYXEOF

cd "$ROOT"
"$LYXC" "$TMP/s.lyx" --std-path=. -o "$TMP/s" > "$TMP/build.log" 2>&1
if [ ! -x "$TMP/s" ]; then
  echo "FAIL: Testprogramm laesst sich nicht uebersetzen"; tail -20 "$TMP/build.log"; exit 1
fi
( ulimit -v 4000000 -c 0; "$TMP/s" > "$TMP/out.txt" 2>&1 )
rc=$?
if [ "$rc" -ge 128 ]; then
  echo "FAIL: Testprogramm abgebrochen (rc=$rc)"; cat "$TMP/out.txt"; exit 1
fi
cat "$TMP/out.txt"

fails=0
# Jede Zeile "name ok" ist eine erfuellte Pruefung; "ABWEICHUNG" ist eine
# gefallene. Zusaetzlich die drei Zahlenzeilen einzeln.
if grep -q 'ABWEICHUNG' "$TMP/out.txt"; then
  echo "FAIL: abweichende Werte:"; grep 'ABWEICHUNG' "$TMP/out.txt"; fails=$((fails+1))
fi
pruefe() {
  local ist
  ist="$(grep -m1 "^$1 " "$TMP/out.txt" | cut -d' ' -f2-)"
  if [ "$ist" != "$2" ]; then
    echo "FAIL: $1 = '$ist', erwartet '$2'"; fails=$((fails + 1))
  fi
}
pruefe flug-entschluesselt 1
pruefe flug-typbyte 22
pruefe app-entschluesselt 1
pruefe app-typbyte 23
pruefe gekippter-record-abgewiesen 1
pruefe fails 0

# Mindestzahl erfuellter Pruefungen, damit ein verstuemmeltes Programm nicht
# still als gruen durchgeht.
n="$(grep -c ' ok$' "$TMP/out.txt")"
if [ "$n" -lt 20 ]; then
  echo "FAIL: nur $n erfuellte Pruefungen, erwartet mindestens 20"; fails=$((fails + 1))
fi

if [ "$fails" -eq 0 ]; then echo "ALL PASS ($n Werte gegen RFC 8448)"; exit 0; fi
echo "$fails FAIL"
exit 1
