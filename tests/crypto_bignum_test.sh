#!/usr/bin/env bash
# tests/crypto_bignum_test.sh — #2096: Langzahlen in Radix 2^64.
#
# Grundlage ist das Builtin-Paar `a * b` / `umulhi(a, b)`. Geprueft wird jede
# Rechnung gegen Python (beliebig genaue Ganzzahlen) auf ALLE Byte, nicht auf
# ein Praefix: Addition mit und ohne Uebertrag, Subtraktion mit Borgen,
# Schulmultiplikation (2n Glieder), Vergleich in beide Richtungen, Bitlaenge,
# Montgomery-Kennzahl n0 (m0 * n0 + 1 == 0 mod 2^64), R^2 mod m,
# Montgomery-Multiplikation und Modexp mit kleinem oeffentlichem und mit
# vollem geheimen Exponenten. Zusaetzlich: der konstantzeitige und der
# oeffentliche Modexp-Pfad muessen dasselbe liefern — sonst waere einer der
# beiden falsch und der Test der anderen Haelfte blind.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/s.lyx" <<'LYXEOF'
unit main;
import std.io;
import std.alloc;
import std.crypto.bignum;

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
// Testzahlen deterministisch fuellen: Byte i = (i*97 + seed) & 255
fn fuell(p: int64, n: int64, seed: int64): void {
  var i: int64 := 0;
  while (i < n) { poke8(p + i, (i * 97 + seed) & 255); i := i + 1; }
}

fn main(): int64 {
  var n: int64 := 4;                     // 256 Bit
  var a: int64 := alloc(n * 8);
  var b: int64 := alloc(n * 8);
  var r: int64 := alloc(2 * n * 8);
  var ba: int64 := alloc(n * 8);
  var bb: int64 := alloc(n * 8);
  fuell(ba, n * 8, 3);
  fuell(bb, n * 8, 131);
  if (!BnFromBytes(a, n, ba, n * 8)) { PrintLn("FROMBYTES-A"); return 1; }
  if (!BnFromBytes(b, n, bb, n * 8)) { PrintLn("FROMBYTES-B"); return 1; }
  var aus: int64 := alloc(2 * n * 8 + 8);
  BnToBytes(aus, a, n); Print("a "); hex(aus, n * 8);
  BnToBytes(aus, b, n); Print("b "); hex(aus, n * 8);
  Print("add-carry "); PrintInt(BnAdd(r, a, b, n)); PrintLn("");
  BnToBytes(aus, r, n); Print("add "); hex(aus, n * 8);
  Print("sub-borrow "); PrintInt(BnSub(r, a, b, n)); PrintLn("");
  BnToBytes(aus, r, n); Print("sub "); hex(aus, n * 8);
  BnMul(r, a, b, n);
  BnToBytes(aus, r, 2 * n); Print("mul "); hex(aus, 2 * n * 8);
  Print("cmp-ab "); PrintInt(BnCmp(a, b, n)); Print(" cmp-ba "); PrintInt(BnCmp(b, a, n));
  Print(" cmp-aa "); PrintInt(BnCmp(a, a, n)); PrintLn("");
  Print("bitlen-a "); PrintInt(BnBitLen(a, n)); Print(" bitlen-b "); PrintInt(BnBitLen(b, n)); PrintLn("");

  // Montgomery: ungerader Modulus
  var m: int64 := alloc(n * 8);
  var bm: int64 := alloc(n * 8);
  fuell(bm, n * 8, 211);
  poke8(bm + n * 8 - 1, peek8(bm + n * 8 - 1) | 1);     // ungerade
  poke8(bm, peek8(bm) | 0x80);                           // volle Breite
  BnFromBytes(m, n, bm, n * 8);
  BnToBytes(aus, m, n); Print("m "); hex(aus, n * 8);
  var n0: int64 := BnMontN0(peek64(m));
  Print("n0*m0+1 "); PrintInt((n0 * peek64(m)) + 1); Print(" (soll 0)"); PrintLn("");
  var r2: int64 := alloc(n * 8);
  BnMontR2(r2, m, n);
  BnToBytes(aus, r2, n); Print("r2 "); hex(aus, n * 8);
  // amod = a mod m vorbereiten: solange a >= m, subtrahieren (oeffentlich hier)
  var am: int64 := alloc(n * 8);
  var bmod: int64 := alloc(n * 8);
  BnCopy(am, a, n); BnCopy(bmod, b, n);
  while (BnCmp(am, m, n) >= 0) { BnSub(am, am, m, n); }
  while (BnCmp(bmod, m, n) >= 0) { BnSub(bmod, bmod, m, n); }
  var am2: int64 := alloc(n * 8);
  var bm2: int64 := alloc(n * 8);
  BnToMont(am2, am, m, n, n0, r2);
  BnToMont(bm2, bmod, m, n, n0, r2);
  var pm: int64 := alloc(n * 8);
  BnMontMul(pm, am2, bm2, m, n, n0);
  var prod: int64 := alloc(n * 8);
  BnFromMont(prod, pm, m, n, n0);
  BnToBytes(aus, prod, n); Print("montmul "); hex(aus, n * 8);

  // Modexp mit kleinem oeffentlichen Exponenten 65537
  var e: int64 := alloc(n * 8);
  BnZero(e, n);
  poke64(e, 65537);
  var ergebnis: int64 := alloc(n * 8);
  BnModExp(ergebnis, am, e, 17, m, n);
  BnToBytes(aus, ergebnis, n); Print("modexp-65537 "); hex(aus, n * 8);
  // Modexp mit grossem geheimen Exponenten (konstantzeitiger Pfad)
  BnModExpCT(ergebnis, am, bmod, 256, m, n);
  BnToBytes(aus, ergebnis, n); Print("modexp-ct "); hex(aus, n * 8);
  // beide Pfade muessen dasselbe liefern
  var e2: int64 := alloc(n * 8);
  BnModExp(e2, am, bmod, 256, m, n);
  Print("beide-pfade-gleich "); PrintInt(BnCmp(e2, ergebnis, n) == 0); PrintLn("");
  return 0;
}
LYXEOF

if ! ( cd "$ROOT" && timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/s.lyx" -o "$TMP/s" ) >"$TMP/log" 2>&1; then
  echo "FAIL uebersetzt nicht: $(grep -m1 -i error "$TMP/log")"; exit 1
fi
[ -x "$TMP/s" ] || { echo "FAIL kein Erzeugnis (#1682)"; exit 1; }

cat > "$TMP/soll.txt" <<'SOLLEOF'
a 0364c52687e849aa0b6ccd2e8ff051b21374d53697f859ba1b7cdd3e9f0061c2
b 83e445a60768c92a8bec4dae0f70d13293f455b61778d93a9bfc5dbe1f80e142
add-carry 0
add 87490acc8f5112d497591adc9f6122e4a7692aecaf7132f4b7793afcbe814304
sub-borrow 1
sub 7f807f80807f807f7f807f80807f807f7f807f80807f807f7f807f807f7f8080
mul 01bf978eaa7147303052759fd7a1631fdaa14fed818e7c4d02ae2879a9b6b073effa4deacd48204bc46970d99f16015815148f83ec1edd1edff9a7e7b304b604
cmp-ab -1 cmp-ba 1 cmp-aa 0
bitlen-a 250 bitlen-b 256
m d33495f657b8197adb3c9dfe5fc02182e344a50667c8298aeb4cad0e6fd03193
n0*m0+1 0 (soll 0)
r2 9bd37398c33de693886a2ad4824088c45abef1d0f59aeb93f669db66f5713394
montmul 220e5aa3bdd6b5efcfc28510d8c718932c955b32d4b97ed6cb0fba9ffb8ae832
modexp-65537 caab0028f253a70bd2d87a7b2aa8953e225a0b48186d1ce00616942a970b777c
modexp-ct 8625468f7285b7214cd73cfd4b46b3c636c8dbd498271fd1b1aac7e9d1925f38
beide-pfade-gleich 1
SOLLEOF

if ! ( ulimit -v 4000000; timeout 120 "$TMP/s" > "$TMP/ist.txt" 2>"$TMP/err.txt" ); then
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
echo "PASS $PASS / FAIL $FAIL (Bignum, Montgomery, Modexp)"
[ "$FAIL" = 0 ] || exit 1
echo "ALL PASS"
exit 0
