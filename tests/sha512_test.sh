#!/usr/bin/env bash
# tests/sha512_test.sh — #2094: SHA-512 und SHA-384 gegen Referenzwerte.
#
# sha512_rotr und sigma0/sigma1 verschoben auf int64 ARITHMETISCH (SAR, seit
# #1125 die Bedeutung von `>>` auf vorzeichenbehafteten Typen). Bei gesetztem
# Bit 63 fuellten Einsen die oberen Bits — 0 von 314 Vektoren stimmten, auch
# die leere Nachricht. Gemessen wird der ganze Digest, nicht ein Praefix.
#
# Referenzwerte: Python hashlib (FIPS 180-4). Nachricht der Laenge n: Byte i
# = (7*i + 1) & 255, ausser n = 3: "abc" (FIPS-Beispiel). Die Laengen liegen
# um die Blockgrenzen: 111/112 (Laengenfeld passt noch / nicht mehr), 127,
# 128, 129, dazu 1000 (mehrere Bloecke).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
cat > "$TMP/s.lyx" <<'EOF'
unit main;
import std.io;
import std.alloc;
import std.hash;
fn hex(out: int64, n: int64): void {
  var i: int64 := 0;
  var d: pchar := "0123456789abcdef"c;
  while (i < n) {
    var b: int64 := peek8(out + i);
    PrintChar(StrCharAt(d, (b >> 4) & 15)); PrintChar(StrCharAt(d, b & 15));
    i := i + 1;
  }
  PrintLn("");
}
fn eins(n: int64, lang: int64): void {
  var m: int64 := alloc(n + 4);
  var i: int64 := 0;
  while (i < n) { poke8(m + i, (i * 7 + 1) & 255); i := i + 1; }
  if (n == 3) { poke8(m, 97); poke8(m + 1, 98); poke8(m + 2, 99); }
  var ctx: int64 := alloc(256);
  var out: int64 := alloc(64);
  if (lang == 64) { SHA512Init(ctx); } else { SHA384Init(ctx); }
  SHA512Update(ctx, m, n);
  SHA512Final(ctx, out);
  hex(out, lang);
}
fn main(): int64 {
  var w: int64 := 64;
  if (GetArgC() > 1) { w := 48; }
  eins(0, w); eins(3, w); eins(111, w); eins(112, w);
  eins(127, w); eins(128, w); eins(129, w); eins(1000, w);
  return 0;
}
EOF
if ! ( cd "$ROOT" && timeout 240 "$LYXC" --std-path="$ROOT" "$TMP/s.lyx" -o "$TMP/s" ) >"$TMP/log" 2>&1; then
  echo "FAIL uebersetzt nicht: $(grep -m1 -i error "$TMP/log")"; exit 1
fi
pruefe() {  # name, ist, soll
  if [ "$2" = "$3" ]; then echo "PASS $1"; PASS=$((PASS+1))
  else echo "FAIL $1"; echo "  ist:  $2"; echo "  soll: $3"; FAIL=$((FAIL+1)); fi
}
pruefe "SHA-512, 8 Laengen (0, abc, 111, 112, 127, 128, 129, 1000)" "$("$TMP/s" | tr '\n' '|')" \
  "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e|ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f|3dfde1184fd99f233f98be4250f4edb9b535157909b668334370742204d97e047f1fd6a74bb5ba447f337286f421d9af957811f7ef62a458771457da126cb65e|acc96c509e6d01787330a4c6a241e2cda9dcc2529dbe4288dbbcc3812133233c4698831127cf6ed0b333632b22715a5ce53a0a1002a684367b71c98aa6d1d900|a315910cb7812a8e66d87c0c49a42d93dbe97bf0240ee995792292c529256d93f40199a59b3f6266343f302651fea1589e2040a2f3756126d3fe4f421a72079d|31f33a52b36dc2e70c83b604fa999a5cabf33bf70e4556fbed7bff10870c1b7b241dd3f15d1ade24599f068fc58ab51e0028b0f0c98895c23358e8dee032ce06|748fec3280c9165199f8c260e87eea61cbbe1b23ef1567c220df65b37e3fcced15fa7f63c9a381fde38ddd4eb2b09b67f77d03c5e0a639b487e8c48343590c97|76f1e766ac03deff8c614780dc1f26825ad762f92fbba09e2552cd70b2d6333816e7edec5d8820e8460601ea18d55b4fb154528db99a0bf17670f15f74c82cb7|"
pruefe "SHA-384, dieselben Laengen" "$("$TMP/s" 384 | tr '\n' '|')" \
  "38b060a751ac96384cd9327eb1b1e36a21fdb71114be07434c0cc7bf63f6e1da274edebfe76f65fbd51ad2f14898b95b|cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7|89c1d81d1cbc65ca869e61315165f6c3c2468b518cd03f641fac6cf9d1e857889807399d23113dc8ba27f5eac8b68ac2|7b412ee8bc1953a28becb4f3417b3f0ceb41b4fc74d40f3054156e7cb3220b9adf7589cb9a92bc17537873b7ce1161c8|714fa595ed33148c59e469ef0423462749b953698aaab1491ed101eb24b9e9a6b3a4e6d55b0ef14ee1dff02cc15ea103|147ae27db2fd5e4381c21983e753d8f761190fac65a833746ff2558abc9c3244279b8c880537ca2990aacee7bf20358e|ba91c6a4a8860362942120527ff39a9a15dc821434d0d51cb25a96ed90890fd940b6ff9ea17b469551dca7d081fa2b7e|99c9fbd113c67535e7bf9477f22e2a23d183b767efb57bf4f239cb591d8ba50acf80764dfd9eeb2ed0f1aeb769955f74|"
echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
