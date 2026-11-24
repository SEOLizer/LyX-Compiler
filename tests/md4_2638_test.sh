#!/usr/bin/env bash
# tests/md4_2638_test.sh — MD4 (RFC 1320) in std/crypto/md4.lyx (#2638).
#
# MD4 ist gebrochen und steht nur fuer eine fremdbestimmte Altschnittstelle im
# Baum: der NT-Hash in NTLMv2 ist MD4(UTF-16LE(Passwort)). Geprueft wird
# darum zweierlei:
#
#   1. Die sieben Pruefvektoren aus RFC 1320 Anhang A.5 werden AUSGEFUEHRT
#      und Zeichen fuer Zeichen verglichen — nicht nur uebersetzt (#1751).
#      Ihre Laengen (0, 1, 3, 14, 26, 62, 80) treffen beide Polsterzweige:
#      bei 62 Byte braucht die Laenge einen zweiten Block, bei 80 nicht.
#   2. Der NT-Hash von "password" ist 8846f7eaee8fb117ad06bdd830b7586c —
#      der Wert, an dem der Anwendungsfall haengt.
#
# Gegenprobe (beide Seiten): ein um ein Bit geaendertes Eingabebyte muss einen
# ANDEREN Digest ergeben. Ohne diese Haelfte waere der Test auch von einer
# Fassung erfuellt, die immer denselben Wert liefert.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ulimit -c 0
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1${2:+: $2}"; FAIL=$((FAIL+1)); }

cat > "$TMP/m.lyx" <<'EOF'
unit main;
import std.io;
import std.alloc;
import std.crypto.md4;

fn zeig(s: pchar, n: int64): int64 {
  var h: int64 := alloc(40);
  MD4Hex(s as int64, n, h);
  PrintStr(h as pchar); PrintStr("\n"c);
  return 0;
}

fn main(): int64 {
  zeig(""c, 0);
  zeig("a"c, 1);
  zeig("abc"c, 3);
  zeig("message digest"c, 14);
  zeig("abcdefghijklmnopqrstuvwxyz"c, 26);
  zeig("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"c, 62);
  zeig("12345678901234567890123456789012345678901234567890123456789012345678901234567890"c, 80);

  // NT-Hash: MD4 ueber "password" in UTF-16LE
  var utf16: int64 := alloc(16);
  var p: pchar := "password";
  var i: int64 := 0;
  while (i < 8) {
    poke8(utf16 + i * 2, peek8(p as int64 + i));
    poke8(utf16 + i * 2 + 1, 0);
    i := i + 1;
  }
  var h2: int64 := alloc(40);
  MD4Hex(utf16, 16, h2);
  PrintStr(h2 as pchar); PrintStr("\n"c);

  // Gegenprobe: ein Bit gekippt -> anderer Digest
  poke8(utf16, peek8(utf16) ^ 1);
  MD4Hex(utf16, 16, h2);
  PrintStr(h2 as pchar); PrintStr("\n"c);
  return 0;
}
EOF

if ! "$LYXC" --std-path="$ROOT" "$TMP/m.lyx" -o "$TMP/m" > "$TMP/build.log" 2>&1; then
    no "uebersetzt" "$(tail -3 "$TMP/build.log")"
    echo "=== PASS=$PASS FAIL=$FAIL"; exit 1
fi
ok "uebersetzt"

"$TMP/m" > "$TMP/out.txt" 2>&1 || { no "laeuft"; echo "=== PASS=$PASS FAIL=$FAIL"; exit 1; }
ok "laeuft"

ERWARTET=(
  "31d6cfe0d16ae931b73c59d7e0c089c0"
  "bde52cb31de33e46245e05fbdbd6fb24"
  "a448017aaf21d8525fc10ae87aa6729d"
  "d9130a8164549fe818874806e1c7014b"
  "d79e1c308aa5bbcdeea8ed63df412da9"
  "043f8582f241db351ce627e153e7f0e4"
  "e33b4ddc9c38f2199c3e7b164fcc0536"
  "8846f7eaee8fb117ad06bdd830b7586c"
)
NAMEN=(
  "RFC 1320: leere Eingabe"
  "RFC 1320: \"a\""
  "RFC 1320: \"abc\""
  "RFC 1320: \"message digest\""
  "RFC 1320: a..z"
  "RFC 1320: A..Za..z0..9 (62 Byte, Laenge im zweiten Block)"
  "RFC 1320: 80 Byte"
  "NT-Hash von \"password\" (UTF-16LE)"
)
n=0
while [ $n -lt 8 ]; do
    GOT="$(sed -n "$((n+1))p" "$TMP/out.txt")"
    if [ "$GOT" = "${ERWARTET[$n]}" ]; then ok "${NAMEN[$n]}"
    else no "${NAMEN[$n]}" "$GOT != ${ERWARTET[$n]}"; fi
    n=$((n+1))
done

KIPP="$(sed -n '9p' "$TMP/out.txt")"
if [ "$KIPP" != "8846f7eaee8fb117ad06bdd830b7586c" ] && [ ${#KIPP} -eq 32 ]; then
    ok "Gegenprobe: gekipptes Bit gibt einen anderen Digest ($KIPP)"
else
    no "Gegenprobe" "gekipptes Bit ergab $KIPP"
fi

echo "=== PASS=$PASS FAIL=$FAIL"
[ $FAIL -eq 0 ]
