#!/bin/bash
# Runde 11 — Kryptopfade (#1571, #1532)
#
# Geprueft wird der WEG, nicht nur das Ergebnis:
#   * #1532: derselbe Hash und derselbe Schluessel muessen ZWEIMAL dieselbe
#     Signatur ergeben. Vorher zog der Nonce aus dem RNG — der Test waere rot
#     gewesen. Ein reiner "Signatur verifiziert"-Test waere auch vorher gruen
#     gewesen und haette nichts gemessen.
#   * #1532: der Signaturpfad darf die verzweigende Skalarmultiplikation
#     (jacMul) nicht mehr anfassen; sie bleibt nur in der Verifikation, wo
#     kein Wert geheim ist.
#   * #1571: lpm darf keine Signaturpruefung mehr haben, die konstant 1 liefert.
set -u
cd "$(dirname "$0")/.."
LYXC=${LYXC:-./lyxc}
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
pruefe() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (erwartet '$3', erhalten '$2')"; fi; }

cat > "$TMP/k.lyx" <<'EOF'
import std.io;
import std.alloc;
import std.crypto.ecc;

fn main(): int64 {
  var hash: int64 := alloc(32);
  var i: int64 := 0;
  while (i < 32) { poke8(hash + i, 7 + i); i := i + 1; }

  var priv: int64 := alloc(32);
  var px: int64 := alloc(32);
  var py: int64 := alloc(32);
  ECCGenKey(priv, px, py);

  var r: int64 := alloc(32);
  var s: int64 := alloc(32);
  PrintStr("sign="); PrintLn(IntToStr(ECDSASign(hash, priv, r, s)));
  PrintStr("gueltig="); PrintLn(IntToStr(ECDSAVerify(hash, px, py, r, s)));

  // Derselbe Hash, derselbe Schluessel: RFC 6979 liefert denselben Nonce und
  // damit dieselbe Signatur. Mit einem Zufallsnonce waere das ausgeschlossen.
  var r2: int64 := alloc(32);
  var s2: int64 := alloc(32);
  ECDSASign(hash, priv, r2, s2);
  var det: int64 := 1;
  i := 0;
  while (i < 32) {
    if (peek8(r + i) != peek8(r2 + i)) { det := 0; }
    if (peek8(s + i) != peek8(s2 + i)) { det := 0; }
    i := i + 1;
  }
  PrintStr("deterministisch="); PrintLn(IntToStr(det));

  // Anderer Hash -> andere Signatur (sonst waere "deterministisch" nur
  // ein konstanter Rueckgabewert).
  var h2: int64 := alloc(32);
  i := 0;
  while (i < 32) { poke8(h2 + i, 200 - i); i := i + 1; }
  var r3: int64 := alloc(32);
  var s3: int64 := alloc(32);
  ECDSASign(h2, priv, r3, s3);
  var anders: int64 := 0;
  i := 0;
  while (i < 32) { if (peek8(r + i) != peek8(r3 + i)) { anders := 1; } i := i + 1; }
  PrintStr("hashabhaengig="); PrintLn(IntToStr(anders));
  PrintStr("zweite gueltig="); PrintLn(IntToStr(ECDSAVerify(h2, px, py, r3, s3)));

  // Der oeffentliche Schluessel aus dem privaten muss der aus der Erzeugung sein.
  var qx: int64 := alloc(32);
  var qy: int64 := alloc(32);
  ECCPubFromPriv(priv, qx, qy);
  var gleich: int64 := 1;
  i := 0;
  while (i < 32) {
    if (peek8(px + i) != peek8(qx + i)) { gleich := 0; }
    if (peek8(py + i) != peek8(qy + i)) { gleich := 0; }
    i := i + 1;
  }
  PrintStr("pubkey konsistent="); PrintLn(IntToStr(gleich));

  // Verfaelschte Signatur muss durchfallen.
  poke8(r + 3, peek8(r + 3) + 1);
  PrintStr("verfaelscht="); PrintLn(IntToStr(ECDSAVerify(hash, px, py, r, s)));
  return 0;
}
EOF

if ! "$LYXC" --std-path=. "$TMP/k.lyx" -o "$TMP/k" > "$TMP/build.log" 2>&1; then
  bad "std.crypto.ecc uebersetzt"; sed -n '1,15p' "$TMP/build.log"
else
  ok "std.crypto.ecc uebersetzt"
  if ! timeout 600 "$TMP/k" > "$TMP/out.txt" 2>&1; then
    bad "Testprogramm laeuft durch"; sed -n '1,15p' "$TMP/out.txt"
  else
    ok "Testprogramm laeuft durch"
    hole() { grep "^$1=" "$TMP/out.txt" | head -1 | cut -d= -f2; }
    pruefe "ECDSASign meldet Erfolg"          "$(hole sign)"              "1"
    pruefe "Signatur verifiziert"             "$(hole gueltig)"           "1"
    pruefe "Nonce deterministisch (RFC 6979)" "$(hole deterministisch)"   "1"
    pruefe "Signatur haengt am Hash"          "$(hole hashabhaengig)"     "1"
    pruefe "zweite Signatur verifiziert"      "$(hole 'zweite gueltig')"  "1"
    pruefe "Pubkey aus Privkey konsistent"    "$(hole 'pubkey konsistent')" "1"
    pruefe "verfaelschte Signatur abgelehnt"  "$(hole verfaelscht)"       "0"
  fi
fi

# --- Wegpruefung an der Quelle -------------------------------------------
sig=$(sed -n '/^pub fn ECDSASign/,/^}/p' std/crypto/ecc.lyx)
if echo "$sig" | grep -q "EcdsaSign"; then
  ok "Signaturpfad geht ueber die konstantzeitige Einheit"
else
  bad "Signaturpfad geht ueber die konstantzeitige Einheit"
fi
if echo "$sig" | grep -q "jacMul"; then
  bad "Signaturpfad frei von verzweigender Skalarmultiplikation"
else
  ok "Signaturpfad frei von verzweigender Skalarmultiplikation"
fi
if grep -q "RandBytesExact" std/crypto/ecc.lyx; then
  bad "kein Zufallsnonce mehr in std.crypto.ecc"
else
  ok "kein Zufallsnonce mehr in std.crypto.ecc"
fi
if sed -n '/^pub fn ECCGenKey/,/^}/p' std/crypto/ecc.lyx | grep -q "0x7F"; then
  bad "Schluesselerzeugung verschenkt kein Bit"
else
  ok "Schluesselerzeugung verschenkt kein Bit"
fi

# --- #1571: lpm prueft wieder echte Signaturen ---------------------------
if grep -q "immer OK" lpm/core/verify.lyx; then
  bad "lpm ohne Stub-Signaturpruefung"
else
  ok "lpm ohne Stub-Signaturpruefung"
fi
if grep -q "^import std.crypto.ecc" lpm/core/verify.lyx; then
  ok "lpm bindet std.crypto.ecc ein"
else
  bad "lpm bindet std.crypto.ecc ein"
fi

echo "----"
echo "$PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
