#!/usr/bin/env bash
# tests/crypto_sha2_hkdf_test.sh — #2096 Etappe A: SHA-256/384/512 (auch
# schrittweise), HMAC-SHA-2 und HKDF gegen festgeschriebene Referenzwerte.
#
# Gemessen wird der GANZE Digest, nicht ein Praefix (#2094 lag bei jedem
# Vektor falsch und waere von einem Praefixtest erwischt worden, ein
# Invariantentest "32 Byte entstanden" haette nichts gezeigt).
#
# Herkunft der Erwartungen:
#   - SHA-2: FIPS 180-4 ueber Nachricht Byte i = (7*i+1)&255, Laengen um die
#     Blockgrenzen 55/56/64 (SHA-256) und 111/112/128 (SHA-384/512), dazu 1000
#     fuer mehrere Bloecke. Gegengerechnet mit Python hashlib.
#   - HMAC: RFC 2104/4868, Schluessel kuerzer/gleich/laenger als der Block
#     (4/64/128/200 Byte) — der laengere Schluessel geht durch den Hash.
#   - HKDF: RFC 5869 Testfall 1 (PRK 077709.. / OKM 3cb25f..) und Testfall 3
#     (leeres Salz, leeres info), beide buchstaeblich aus dem RFC.
#   - HKDF-Expand-Label: RFC 8446 §7.1 mit Label "derived".
#
# Zusaetzlich geprueft: schrittweises Hashen in drei ungleichen Stuecken
# liefert denselben Digest wie der Einzelaufruf, und HkdfExpand weist
# outLen > 255*HashLen ab statt still zu kuerzen.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/s.lyx" <<'LYXEOF'
unit main;
import std.io;
import std.alloc;
import std.crypto.sha256;
import std.crypto.sha512;
import std.crypto.hkdf;

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

fn msg(n: int64): int64 {
  var m: int64 := alloc(n + 4);
  var i: int64 := 0;
  while (i < n) { poke8(m + i, (i * 7 + 1) & 255); i := i + 1; }
  return m;
}

fn main(): int64 {
  var out: int64 := alloc(256);
  // SHA-256/384/512 ueber Laengen um die Blockgrenzen
  var laengen: int64 := alloc(8 * 9);
  poke64(laengen + 0, 0); poke64(laengen + 8, 3); poke64(laengen + 16, 55);
  poke64(laengen + 24, 56); poke64(laengen + 32, 64); poke64(laengen + 40, 111);
  poke64(laengen + 48, 112); poke64(laengen + 56, 128); poke64(laengen + 64, 1000);
  var k: int64 := 0;
  while (k < 9) {
    var n: int64 := peek64(laengen + k * 8);
    var m: int64 := msg(n);
    SHA256(m, n, out); hex(out, 32);
    Sha384(m, n, out); hex(out, 48);
    Sha512(m, n, out); hex(out, 64);
    // schrittweise in drei Stuecken: muss dasselbe ergeben
    var c: int64 := alloc(Sha256CtxSize());
    Sha256Init(c);
    var a: int64 := n / 3;
    var b: int64 := n / 2;
    Sha256Update(c, m, a);
    Sha256Update(c, m + a, b - a);
    Sha256Update(c, m + b, n - b);
    Sha256Final(c, out); hex(out, 32);
    var c2: int64 := alloc(Sha512CtxSize());
    Sha384Init(c2);
    Sha512Update(c2, m, a); Sha512Update(c2, m + a, b - a); Sha512Update(c2, m + b, n - b);
    Sha384Final(c2, out); hex(out, 48);
    k := k + 1;
  }
  // HMAC: Schluessel kuerzer / gleich / laenger als der Block
  var kl: int64 := alloc(4 * 8);
  poke64(kl + 0, 4); poke64(kl + 8, 64); poke64(kl + 16, 128); poke64(kl + 24, 200);
  var j: int64 := 0;
  while (j < 4) {
    var klen: int64 := peek64(kl + j * 8);
    var key: int64 := msg(klen);
    var dat: int64 := msg(137);
    HmacHash(32, key, klen, dat, 137, out); hex(out, 32);
    HmacHash(48, key, klen, dat, 137, out); hex(out, 48);
    HmacHash(64, key, klen, dat, 137, out); hex(out, 64);
    j := j + 1;
  }
  // HKDF RFC 5869 Testfall 1
  var ikm: int64 := alloc(22); var i: int64 := 0;
  while (i < 22) { poke8(ikm + i, 0x0b); i := i + 1; }
  var salt: int64 := alloc(13); i := 0;
  while (i < 13) { poke8(salt + i, i); i := i + 1; }
  var info: int64 := alloc(10); i := 0;
  while (i < 10) { poke8(info + i, 0xf0 + i); i := i + 1; }
  var prk: int64 := alloc(32);
  HkdfExtract(32, salt, 13, ikm, 22, prk); hex(prk, 32);
  if (HkdfExpand(32, prk, 32, info, 10, out, 42)) { hex(out, 42); } else { PrintLn("EXPANDFEHLER"); }
  // RFC 5869 Testfall 3: leeres Salz, leeres info
  HkdfExtract(32, 0, 0, ikm, 22, prk); hex(prk, 32);
  if (HkdfExpand(32, prk, 32, 0, 0, out, 42)) { hex(out, 42); } else { PrintLn("EXPANDFEHLER"); }
  // HKDF ueber SHA-384/512
  HkdfExtract(48, salt, 13, ikm, 22, out); hex(out, 48);
  HkdfExtract(64, salt, 13, ikm, 22, out); hex(out, 64);
  // Grenze 255*alg
  if (HkdfExpand(32, prk, 32, 0, 0, out, 255 * 32 + 1)) { PrintLn("GRENZE-NICHT-GEPRUEFT"); } else { PrintLn("grenze-ok"); }
  // Expand-Label (TLS 1.3)
  var lab: pchar := "derived"c;
  var leer: int64 := alloc(32); SHA256(leer, 0, leer);
  if (HkdfExpandLabel(32, prk, 32, lab as int64, 7, leer, 32, out, 32)) { hex(out, 32); } else { PrintLn("LABELFEHLER"); }
  return 0;
}
LYXEOF

if ! ( cd "$ROOT" && timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/s.lyx" -o "$TMP/s" ) >"$TMP/log" 2>&1; then
  echo "FAIL uebersetzt nicht: $(grep -m1 -i error "$TMP/log")"; exit 1
fi
if [ ! -x "$TMP/s" ]; then echo "FAIL kein Erzeugnis (#1682: lyxc meldet Schreibfehler mit Exit 0)"; exit 1; fi

cat > "$TMP/soll.txt" <<'SOLLEOF'
e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
38b060a751ac96384cd9327eb1b1e36a21fdb71114be07434c0cc7bf63f6e1da274edebfe76f65fbd51ad2f14898b95b
cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e
e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
38b060a751ac96384cd9327eb1b1e36a21fdb71114be07434c0cc7bf63f6e1da274edebfe76f65fbd51ad2f14898b95b
ce562c676ea7aba9812f54db146b0096011bf3e423edfb0a6f8fb2b02674a801
7a9b2c118a26b7b14a23882da1311cad684b5e9c65ebcfe3f7e3b5d7f035d99817c0c88c6612be576ab30e52c8fee606
e3e811b3993a662d9b9b625208626836ec682ab11e6b6691fec762b3a54aad3e08f3e7eaed4584327de1168621179af623bbe26acb907d3279c7ad14e1a4e97e
ce562c676ea7aba9812f54db146b0096011bf3e423edfb0a6f8fb2b02674a801
7a9b2c118a26b7b14a23882da1311cad684b5e9c65ebcfe3f7e3b5d7f035d99817c0c88c6612be576ab30e52c8fee606
16fa57a0a3423a715d594516339f36189d6b5f93754a9714fef202616a9fabfe
ff8841d726616b455ec2dae8d7c8e2c8cf99208168fba76f636d37316581231c5c4bad7b7c30d54db5d1a858eda65925
44f6d40f3dc121a98043a1771d55650d64a6f196078beedd9c6ca6fe7301166688bf9b5cb4c5057df7345665ef7f1a4ffddd0743615d9ececca811d304e2afd3
16fa57a0a3423a715d594516339f36189d6b5f93754a9714fef202616a9fabfe
ff8841d726616b455ec2dae8d7c8e2c8cf99208168fba76f636d37316581231c5c4bad7b7c30d54db5d1a858eda65925
c37b44e5f1b18554b36966f4f8e08bfbf3164c4b6c10374d12d89850892073c5
db60c1dfcf1e0fbf11157241d928fa48064fab5219bce456031fd0eaa62f2281ca2d2b81c53726ff9d5a683f26829223
acf4d3a552c68dc641082395cf73955b7a496e67e4b7968e3d3154367f9ca548b7b90e82d35bdc63c5abba19a5d8cd24ac3626c55219f311afea1c3c164a891b
c37b44e5f1b18554b36966f4f8e08bfbf3164c4b6c10374d12d89850892073c5
db60c1dfcf1e0fbf11157241d928fa48064fab5219bce456031fd0eaa62f2281ca2d2b81c53726ff9d5a683f26829223
66bd4633ed6f71c4ecfa4763bf7ba1c8ec7612de9aa6c0578a7b675207c71e0b
5c03431a001926e1861dcac42a1d51fcabb7f957cd1fba2b78e14288d2e903c62b86c3e7106310515fd9350df7c73579
1df51ad9960b51cd1d186dc402e9070ead3d517047225dee450a3d0a6a85c2e33759bea36f40ab8ef53360529e8a49fb83e9d9d2f03d49be1faa06c3054925f7
66bd4633ed6f71c4ecfa4763bf7ba1c8ec7612de9aa6c0578a7b675207c71e0b
5c03431a001926e1861dcac42a1d51fcabb7f957cd1fba2b78e14288d2e903c62b86c3e7106310515fd9350df7c73579
1796402e8fc028fc1d3a61e3e4cac839872632c2d7b381cbd802d0768f5cfd13
89c1d81d1cbc65ca869e61315165f6c3c2468b518cd03f641fac6cf9d1e857889807399d23113dc8ba27f5eac8b68ac2
3dfde1184fd99f233f98be4250f4edb9b535157909b668334370742204d97e047f1fd6a74bb5ba447f337286f421d9af957811f7ef62a458771457da126cb65e
1796402e8fc028fc1d3a61e3e4cac839872632c2d7b381cbd802d0768f5cfd13
89c1d81d1cbc65ca869e61315165f6c3c2468b518cd03f641fac6cf9d1e857889807399d23113dc8ba27f5eac8b68ac2
e19b57d2618b2898cb915bf2be9bf558f761faa651cd6c5f892610750714dea4
7b412ee8bc1953a28becb4f3417b3f0ceb41b4fc74d40f3054156e7cb3220b9adf7589cb9a92bc17537873b7ce1161c8
acc96c509e6d01787330a4c6a241e2cda9dcc2529dbe4288dbbcc3812133233c4698831127cf6ed0b333632b22715a5ce53a0a1002a684367b71c98aa6d1d900
e19b57d2618b2898cb915bf2be9bf558f761faa651cd6c5f892610750714dea4
7b412ee8bc1953a28becb4f3417b3f0ceb41b4fc74d40f3054156e7cb3220b9adf7589cb9a92bc17537873b7ce1161c8
e462c130fef8c97e34f7dc3ff3ad2f8b3533ab849af21c10531552a2852387a4
147ae27db2fd5e4381c21983e753d8f761190fac65a833746ff2558abc9c3244279b8c880537ca2990aacee7bf20358e
31f33a52b36dc2e70c83b604fa999a5cabf33bf70e4556fbed7bff10870c1b7b241dd3f15d1ade24599f068fc58ab51e0028b0f0c98895c23358e8dee032ce06
e462c130fef8c97e34f7dc3ff3ad2f8b3533ab849af21c10531552a2852387a4
147ae27db2fd5e4381c21983e753d8f761190fac65a833746ff2558abc9c3244279b8c880537ca2990aacee7bf20358e
095ecb62e30793ab4b954cd6a0586d0cc91f7ea5b1332694d8da780e98676d78
99c9fbd113c67535e7bf9477f22e2a23d183b767efb57bf4f239cb591d8ba50acf80764dfd9eeb2ed0f1aeb769955f74
76f1e766ac03deff8c614780dc1f26825ad762f92fbba09e2552cd70b2d6333816e7edec5d8820e8460601ea18d55b4fb154528db99a0bf17670f15f74c82cb7
095ecb62e30793ab4b954cd6a0586d0cc91f7ea5b1332694d8da780e98676d78
99c9fbd113c67535e7bf9477f22e2a23d183b767efb57bf4f239cb591d8ba50acf80764dfd9eeb2ed0f1aeb769955f74
d5c2e81b48c1cc87fe43fb694e4a7c47db2e05a8b62cb999a9ca5972e4683369
9d4ff4f3a18d2747a24c10582fbccd6b8a6e76b174ea4d52383c65438c1b3e281fac16ca6ae08e8d2bc616ca5bbfbbde
af3703e6efca6f1324ed4068f91fd334e0b3b2e40e696910b3e6b8ec291d5267c4b7ed7eabea18d8f741f1e1cc85b6df7f264cf10211206a33f706bae7bbaf84
e1e561fab1aff65e75ac9c074f8fe2d7939f6134e7cd8a4ef3ff2f8801097563
2a80846387186e3e1c9c448690113a47dda7d99c29f3d092c6134016a0613a3642f85becdcc07ee4bcd5be6fc2486947
3d249c225477e4515d9f01a955bfc0147acb146580362a3f68a0cc6d3375d2e727884c548e8e254c8343fdf70bdc4bb62c8e57b44f1886fd8b011be16cce2097
913546d646347eb0c8a392ecb1888092f27f544ce2a9c19e7450ea33297afe45
7434fdb4f840a156533d02042a5d15b043a4f89e30493b5c45765df6b0cdf96251e4e335a2e1cdd0a2811625a5c111c8
b1c1985174fb282ad4ab348c5009bdbcbda4b92bedd9dd5fe60529734ea3c41270faf80b89e0d9c0fd21d49c51f1936747072e9f722ea5707ac01da3a7e344a0
dfb6768df7612c015680b7df5ca70857f32c5c1459ec08be084c691ca12fd131
7f7de510237cf78b6db1fbceac367f31662cb707d39deb18023ef8defe777a3b8bfac830075ed3af1caf4d4f7ef71577
b2317a58802ab83d3794d62b1ac5def771e6f46e08080c23f55cee4e407057980e381858e42e29f966083542929fb573d97bbb92d29e1d2bcc41be5a465ad6c7
077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5
3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865
19ef24a32c717b167f33a91d6f648bdf96596776afdb6377ac434c1c293ccb04
8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8
704b39990779ce1dc548052c7dc39f303570dd13fb39f7acc564680bef80e8dec70ee9a7e1f3e293ef68eceb072a5ade
665799823737ded04a88e47e54a5890bb2c3d247c7a4254a8e61350723590a26c36238127d8661b88cf80ef802d57e2f7cebcf1e00e083848be19929c61b4237
grenze-ok
b4b6513dbcc58bf08d6844ea9bb623953a78bd339f495c91e124732a265fc5cc
SOLLEOF

if ! ( ulimit -v 4000000; timeout 120 "$TMP/s" > "$TMP/ist.txt" 2>"$TMP/err.txt" ); then
  echo "FAIL Lauf gescheitert (rc=$?): $(head -1 "$TMP/err.txt")"; exit 1
fi

ZEILEN_SOLL=$(wc -l < "$TMP/soll.txt")
ZEILEN_IST=$(wc -l < "$TMP/ist.txt")
if [ "$ZEILEN_IST" != "$ZEILEN_SOLL" ]; then
  echo "FAIL $ZEILEN_IST Zeilen statt $ZEILEN_SOLL"; exit 1
fi

FAIL=0; PASS=0; N=0
while IFS= read -r soll && IFS= read -r ist <&3; do
  N=$((N+1))
  if [ "$soll" = "$ist" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); echo "FAIL Zeile $N"; echo "  ist:  $ist"; echo "  soll: $soll"; fi
done < "$TMP/soll.txt" 3< "$TMP/ist.txt"

echo "PASS $PASS / FAIL $FAIL (SHA-2, HMAC, HKDF, Expand-Label)"
if [ "$FAIL" != 0 ]; then exit 1; fi
echo "ALL PASS"
exit 0
