#!/usr/bin/env bash
# tests/hmac_generisch_2638_test.sh — HMAC ueber eine Hash-Kennung (#2638).
#
# std/crypto/hmac.lyx war auf SHA-256 festverdrahtet; MD5, SHA-1 und SHA-512
# lagen als Hashes im Baum, waren ueber HMAC aber nicht erreichbar.
#
# Gemessen wird in fuenf Richtungen:
#
#   1. DIE PRUEFVEKTOREN, ausgefuehrt: RFC 2202 (HMAC-MD5, HMAC-SHA-1,
#      Faelle 1, 4, 6) und RFC 4231 (HMAC-SHA-224/256/384/512, Faelle 1, 4, 6).
#      Fall 6 hat einen Schluessel LAENGER als die Blockgroesse und prueft damit
#      den Zweig, der den Schluessel vorher hasht — bei SHA-384/512 mit
#      Blockgroesse 128 statt 64.
#   2. DIE ALTE SIGNATUR bleibt: HMAC_SHA256(...) liefert bitgleich dasselbe
#      wie HMAC(HMAC_HASH_SHA256, ...), und HMAC_SHA256_Hex die Hexfassung.
#      Ohne diese Pruefung waere ein Bestandsaufrufer still gebrochen.
#   3. BEIDE SEITEN: ein um ein Bit geaenderter Schluessel und eine um ein Bit
#      geaenderte Nachricht ergeben einen ANDEREN MAC. Ein Test, der nur die
#      richtigen Eingaben prueft, waere auch von einer Fassung erfuellt, die
#      den Schluessel ignoriert (#1823).
#   4. DIE TABELLEN stimmen zusammen: HMACDigestSize und HMACBlockSize nennen
#      fuer jede Kennung die Werte aus den RFCs, und die Laenge des wirklich
#      geschriebenen MAC ist die genannte (gemessen ueber ein Fuellmuster
#      hinter dem Ausgabepuffer).
#   5. EINE UNBEKANNTE KENNUNG BRICHT AB. Sie darf nicht still etwas
#      Plausibles rechnen; nachgewiesen an der WIRKUNG (Rueckgabecode des
#      abgebrochenen Laufs), nicht an einem Meldungstext.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ulimit -c 0
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1${2:+: $2}"; FAIL=$((FAIL+1)); }

cat > "$TMP/h.lyx" <<'EOF'
unit main;
import std.io;
import std.alloc;
import std.crypto.hmac;

fn hexAus(p: int64, n: int64): int64 {
  var hx: pchar := "0123456789abcdef";
  var b: int64 := alloc(300);
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

// MAC rechnen und ausgeben; prueft gleichzeitig, dass GENAU
// HMACDigestSize(id) Byte geschrieben wurden.
fn lauf(name: pchar, id: int64, key: int64, kl: int64, data: int64, dl: int64): int64 {
  var out: int64 := alloc(96);
  fuell(out, 96, 0x5A);
  HMAC(id, key, kl, data, dl, out);
  var ds: int64 := HMACDigestSize(id);
  var ueber: int64 := 0;
  var i: int64 := ds;
  while (i < 96) { if (peek8(out + i) != 0x5A) { ueber := 1; } i := i + 1; }
  PrintStr(name); PrintStr(" "c); hexAus(out, ds);
  PrintStr(" ueberschrieben="c); PrintInt(ueber); PrintStr("\n"c);
  return 0;
}

fn main(): int64 {
  var k20: int64 := alloc(20);  fuell(k20, 20, 0x0b);
  var k16: int64 := alloc(16);  fuell(k16, 16, 0x0b);
  var k80: int64 := alloc(80);  fuell(k80, 80, 0xaa);
  var k131: int64 := alloc(131); fuell(k131, 131, 0xaa);
  var k25: int64 := alloc(25);
  var i: int64 := 0; while (i < 25) { poke8(k25 + i, i + 1); i := i + 1; }
  var d50: int64 := alloc(50); fuell(d50, 50, 0xcd);
  var d1: pchar := "Hi There";
  var d6: pchar := "Test Using Larger Than Block-Size Key - Hash Key First";

  // Fall 1 (RFC 2202 nutzt bei MD5 einen 16-Byte-Schluessel, RFC 4231 20 Byte)
  lauf("md5-1"c,    HMAC_HASH_MD5,    k16, 16, d1 as int64, 8);
  lauf("sha1-1"c,   HMAC_HASH_SHA1,   k20, 20, d1 as int64, 8);
  lauf("sha256-1"c, HMAC_HASH_SHA256, k20, 20, d1 as int64, 8);
  lauf("sha384-1"c, HMAC_HASH_SHA384, k20, 20, d1 as int64, 8);
  lauf("sha512-1"c, HMAC_HASH_SHA512, k20, 20, d1 as int64, 8);

  // Fall 4: Schluessel 0x01..0x19, Nachricht 50 x 0xcd
  lauf("md5-4"c,    HMAC_HASH_MD5,    k25, 25, d50, 50);
  lauf("sha1-4"c,   HMAC_HASH_SHA1,   k25, 25, d50, 50);
  lauf("sha256-4"c, HMAC_HASH_SHA256, k25, 25, d50, 50);
  lauf("sha384-4"c, HMAC_HASH_SHA384, k25, 25, d50, 50);
  lauf("sha512-4"c, HMAC_HASH_SHA512, k25, 25, d50, 50);

  // Fall 6: Schluessel laenger als die Blockgroesse
  lauf("md5-6"c,    HMAC_HASH_MD5,    k80,  80,  d6 as int64, 54);
  lauf("sha1-6"c,   HMAC_HASH_SHA1,   k80,  80,  d6 as int64, 54);
  lauf("sha256-6"c, HMAC_HASH_SHA256, k131, 131, d6 as int64, 54);
  lauf("sha384-6"c, HMAC_HASH_SHA384, k131, 131, d6 as int64, 54);
  lauf("sha512-6"c, HMAC_HASH_SHA512, k131, 131, d6 as int64, 54);

  // MD4 ueber HMAC (keine RFC-Vektoren; gegen sich selbst stabil)
  lauf("md4-1"c, HMAC_HASH_MD4, k16, 16, d1 as int64, 8);

  // Alte Signatur
  var a: int64 := alloc(32); var b: int64 := alloc(32);
  HMAC_SHA256(k20, 20, d1 as int64, 8, a);
  HMAC(HMAC_HASH_SHA256, k20, 20, d1 as int64, 8, b);
  var gl: int64 := 1;
  i := 0; while (i < 32) { if (peek8(a + i) != peek8(b + i)) { gl := 0; } i := i + 1; }
  PrintStr("huelle-gleich="c); PrintLn(gl);
  var hx: int64 := alloc(70);
  HMAC_SHA256_Hex(k20, 20, d1 as int64, 8, hx);
  PrintStr("hex="c); PrintStr(hx as pchar); PrintStr("\n"c);

  // Beide Seiten: geaenderter Schluessel / geaenderte Nachricht
  var c: int64 := alloc(32);
  poke8(k20, peek8(k20) ^ 1);
  HMAC(HMAC_HASH_SHA256, k20, 20, d1 as int64, 8, c);
  var anders1: int64 := 0;
  i := 0; while (i < 32) { if (peek8(a + i) != peek8(c + i)) { anders1 := 1; } i := i + 1; }
  PrintStr("schluessel-anders="c); PrintLn(anders1);
  poke8(k20, peek8(k20) ^ 1);
  var d2: int64 := alloc(8);
  i := 0; while (i < 8) { poke8(d2 + i, peek8(d1 as int64 + i)); i := i + 1; }
  poke8(d2, peek8(d2) ^ 1);
  HMAC(HMAC_HASH_SHA256, k20, 20, d2, 8, c);
  var anders2: int64 := 0;
  i := 0; while (i < 32) { if (peek8(a + i) != peek8(c + i)) { anders2 := 1; } i := i + 1; }
  PrintStr("nachricht-anders="c); PrintLn(anders2);

  // Tabellen
  PrintStr("groessen="c);
  PrintInt(HMACDigestSize(HMAC_HASH_MD4)); PrintStr(","c);
  PrintInt(HMACDigestSize(HMAC_HASH_MD5)); PrintStr(","c);
  PrintInt(HMACDigestSize(HMAC_HASH_SHA1)); PrintStr(","c);
  PrintInt(HMACDigestSize(HMAC_HASH_SHA256)); PrintStr(","c);
  PrintInt(HMACDigestSize(HMAC_HASH_SHA384)); PrintStr(","c);
  PrintInt(HMACDigestSize(HMAC_HASH_SHA512)); PrintStr("/"c);
  PrintInt(HMACBlockSize(HMAC_HASH_MD4)); PrintStr(","c);
  PrintInt(HMACBlockSize(HMAC_HASH_MD5)); PrintStr(","c);
  PrintInt(HMACBlockSize(HMAC_HASH_SHA1)); PrintStr(","c);
  PrintInt(HMACBlockSize(HMAC_HASH_SHA256)); PrintStr(","c);
  PrintInt(HMACBlockSize(HMAC_HASH_SHA384)); PrintStr(","c);
  PrintInt(HMACBlockSize(HMAC_HASH_SHA512)); PrintStr("\n"c);
  PrintStr("unbekannt="c);
  PrintInt(HMACDigestSize(0)); PrintStr(","c);
  PrintInt(HMACDigestSize(7)); PrintStr(","c);
  PrintInt(HMACBlockSize(0)); PrintStr(","c);
  PrintInt(HMACBlockSize(7)); PrintStr("\n"c);
  return 0;
}
EOF
cat > "$TMP/panik.lyx" <<'EOF'
unit main;
import std.io;
import std.alloc;
import std.crypto.hmac;

fn main(): int64 {
  var k: int64 := alloc(16);
  var o: int64 := alloc(64);
  var i: int64 := 0;
  while (i < 16) { poke8(k + i, 0x0b); i := i + 1; }
  PrintStr("vor dem Abbruch\n"c);
  HMAC(99, k, 16, k, 16, o);
  PrintStr("NACH dem Abbruch — die Kennung wurde still akzeptiert\n"c);
  return 0;
}
EOF

if ! "$LYXC" --std-path="$ROOT" "$TMP/h.lyx" -o "$TMP/h" > "$TMP/build.log" 2>&1; then
    no "uebersetzt" "$(tail -5 "$TMP/build.log")"
    echo "=== PASS=$PASS FAIL=$FAIL"; exit 1
fi
ok "uebersetzt"
"$TMP/h" > "$TMP/out.txt" 2>&1 || { no "laeuft"; echo "=== PASS=$PASS FAIL=$FAIL"; exit 1; }
ok "laeuft"

pruefe() { # name erwartet
    local got
    got="$(grep -m1 "^$1 " "$TMP/out.txt" | awk '{print $2}')"
    if [ "$got" = "$2" ]; then ok "$1"; else no "$1" "$got != $2"; fi
}

# RFC 2202 (MD5, SHA-1) und RFC 4231 (SHA-2)
pruefe md5-1    9294727a3638bb1c13f48ef8158bfc9d
pruefe sha1-1   b617318655057264e28bc0b6fb378c8ef146be00
pruefe sha256-1 b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7
pruefe sha384-1 afd03944d84895626b0825f4ab46907f15f9dadbe4101ec682aa034c7cebc59cfaea9ea9076ede7f4af152e8b2fa9cb6
pruefe sha512-1 87aa7cdea5ef619d4ff0b4241a1d6cb02379f4e2ce4ec2787ad0b30545e17cdedaa833b7d6b8a702038b274eaea3f4e4be9d914eeb61f1702e696c203a126854
pruefe md5-4    697eaf0aca3a3aea3a75164746ffaa79
pruefe sha1-4   4c9007f4026250c6bc8414f9bf50c86c2d7235da
pruefe sha256-4 82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b
pruefe sha384-4 3e8a69b7783c25851933ab6290af6ca77a9981480850009cc5577c6e1f573b4e6801dd23c4a7d679ccf8a386c674cffb
pruefe sha512-4 b0ba465637458c6990e5a8c5f61d4af7e576d97ff94b872de76f8050361ee3dba91ca5c11aa25eb4d679275cc5788063a5f19741120c4f2de2adebeb10a298dd
pruefe md5-6    6b1ab7fe4bd7bf8f0b62e6ce61b9d0cd
pruefe sha1-6   aa4ae5e15272d00e95705637ce8a3b55ed402112
pruefe sha256-6 60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54
pruefe sha384-6 4ece084485813e9088d2c63a041bc5b44f9ef1012a2b588f3cd11f05033ac4c60c2ef6ab4030fe8296248df163f44952
pruefe sha512-6 80b24263c7c1a3ebb71493c1dd7be8b49b46d1f41b4aeec1121b013783f8f3526b56d037e05f2598bd0fd2215d6a1e5295e64f73f63f0aec8b915a985d786598

if ! grep -q "ueberschrieben=1" "$TMP/out.txt"; then
    ok "jeder MAC schreibt genau HMACDigestSize Byte"
else
    no "MAC-Laenge" "ein Lauf schrieb ueber den Digest hinaus"
fi

grep -q "^huelle-gleich=1" "$TMP/out.txt" \
  && ok "HMAC_SHA256 (alte Signatur) == HMAC(HMAC_HASH_SHA256, ...)" \
  || no "alte Signatur" "$(grep huelle-gleich "$TMP/out.txt")"

HEX="$(grep '^hex=' "$TMP/out.txt" | cut -d= -f2)"
if [ "$HEX" = "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7" ]; then
    ok "HMAC_SHA256_Hex unveraendert"
else
    no "HMAC_SHA256_Hex" "$HEX"
fi

grep -q "^schluessel-anders=1" "$TMP/out.txt" \
  && ok "Gegenprobe: anderer Schluessel -> anderer MAC" \
  || no "Gegenprobe Schluessel" "der MAC haengt nicht am Schluessel"
grep -q "^nachricht-anders=1" "$TMP/out.txt" \
  && ok "Gegenprobe: andere Nachricht -> anderer MAC" \
  || no "Gegenprobe Nachricht" "der MAC haengt nicht an der Nachricht"

GR="$(grep '^groessen=' "$TMP/out.txt" | cut -d= -f2)"
if [ "$GR" = "16,16,20,32,48,64/64,64,64,64,128,128" ]; then
    ok "Digest- und Blockgroessen nach RFC ($GR)"
else
    no "Groessentabellen" "$GR"
fi
UB="$(grep '^unbekannt=' "$TMP/out.txt" | cut -d= -f2)"
if [ "$UB" = "0,0,0,0" ]; then
    ok "unbekannte Kennung: Groessen melden 0 statt eines plausiblen Wertes"
else
    no "unbekannte Kennung" "$UB"
fi

# Wirkung, nicht Meldungstext: der Lauf muss abbrechen.
if "$LYXC" --std-path="$ROOT" "$TMP/panik.lyx" -o "$TMP/panik" > "$TMP/pb.log" 2>&1; then
    "$TMP/panik" > "$TMP/pout.txt" 2>&1; RC=$?
    if [ $RC -ne 0 ] && ! grep -q "NACH dem Abbruch" "$TMP/pout.txt"; then
        ok "unbekannte Hash-Kennung bricht ab (rc=$RC), rechnet nicht still weiter"
    else
        no "unbekannte Hash-Kennung" "rc=$RC, Ausgabe: $(cat "$TMP/pout.txt")"
    fi
else
    no "Panik-Programm uebersetzt" "$(tail -3 "$TMP/pb.log")"
fi

echo "=== PASS=$PASS FAIL=$FAIL"
[ $FAIL -eq 0 ]
