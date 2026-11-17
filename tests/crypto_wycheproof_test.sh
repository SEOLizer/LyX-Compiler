#!/usr/bin/env bash
# tests/crypto_wycheproof_test.sh — #2096 Abnahmekriterium 5: die
# Wycheproof-Vektoren von Google/C2SP gegen unsere Krypto.
#
# Die Vektoren liegen als tests/data/wycheproof_2096.txt im Repo (aus
# testvectors_v1 gezogen und auf die Faelle eingegrenzt, die unsere API
# pruefen kann). Der Test braucht kein Netz.
#
#   ecdsa   484  ECDSA P-256/SHA-256, Signaturpruefung aus DER
#   gcm     133  AES-GCM, 96-Bit-IV und 128-Bit-Tag (der TLS-Zuschnitt)
#   chacha  316  ChaCha20-Poly1305
#   x25519  518  X25519
#   pss     108  RSASSA-PSS 2048/SHA-256
#   pkcs1   259  RSASSA-PKCS1-v1_5 2048/SHA-256
#
# Beide Richtungen sind darin enthalten: von den 1818 Faellen muessen 845
# ANGENOMMEN und 973 ABGEWIESEN werden. Ein Test, der nur die gueltigen
# Signaturen prueft, waere auch von einer Umsetzung erfuellt, die alles
# annimmt — und genau so eine Luecke hat dieser Lauf gefunden:
#
#   Vier ECDSA-Faelle (tcId 6, 107, 145, 158) liefen durch, weil
#   EcdsaSigFromDer negative INTEGER und Werte ueber 2^256 annahm und den
#   Wert rechtsbuendig abschnitt. Aus vier verschiedenen Kodierungen wurde
#   dieselbe gueltige Signatur — Signaturverformbarkeit. Seit #2096 ist die
#   DER-Lesung streng (Vorzeichen, kuerzeste Form, 33 Byte nur mit
#   fuehrender Null).
#
# Fuer X25519 ist die Erwartung immer "rechne den angegebenen Wert aus": die
# Funktion hat nach RFC 7748 keinen Ablehnungsweg. Dass ein Punkt kleiner
# Ordnung im PROTOKOLL abgewiesen werden muss, prueft
# tests/tls_nullgeheimnis_test.sh.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
DATEN="$ROOT/tests/data/wycheproof_2096.txt"
if [ ! -s "$DATEN" ]; then
  echo "FAIL: $DATEN fehlt"; exit 1
fi

cat > "$TMP/s.lyx" <<'LYXEOF'
unit main;
import std.io;
import std.string;
import std.alloc;
import std.fs;
import std.crypto.sha256;
import std.crypto.aesgcm;
import std.crypto.chacha20poly1305;
import std.crypto.x25519;
import std.crypto.ec;
import std.crypto.rsa_native;

con MAXDATEI: int64 := 1200000;

fn hv(c: int64): int64 {
  if (c >= 48 && c <= 57) { return c - 48; }
  if (c >= 97 && c <= 102) { return c - 97 + 10; }
  if (c >= 65 && c <= 70) { return c - 65 + 10; }
  return -1;
}

// Hex aus dem Puffer (pos..pos+len) nach `out`; liefert die Bytezahl.
fn hexLesen(buf: int64, pos: int64, len: int64, out: int64): int64 {
  if (len == 1 && peek8(buf + pos) == 45) { return 0; }      // "-" = leer
  var i: int64 := 0;
  var n: int64 := 0;
  while (i + 1 < len + 1 && i + 1 <= len - 1) {
    poke8(out + n, (hv(peek8(buf + pos + i)) << 4) | hv(peek8(buf + pos + i + 1)));
    n := n + 1;
    i := i + 2;
  }
  return n;
}

// Sucht in der Zeile [z, zEnde) das Feld "name:" und gibt Position und Laenge
// des Wertes zurueck (ueber posPtr/lenPtr). 1 = gefunden.
fn feld(buf: int64, z: int64, zEnde: int64, name: pchar,
        posPtr: int64, lenPtr: int64): int64 {
  var nl: int64 := StrLen(name);
  var p: int64 := z;
  while (p < zEnde) {
    // Feldanfang: hinter einem Leerzeichen
    var passt: int64 := 1;
    var i: int64 := 0;
    while (i < nl) {
      if (p + i >= zEnde) { passt := 0; i := nl; }
      else { if (peek8(buf + p + i) != StrCharAt(name, i)) { passt := 0; i := nl; } }
      i := i + 1;
    }
    if (passt == 1 && p + nl < zEnde && peek8(buf + p + nl) == 58) {
      var start: int64 := p + nl + 1;
      var e: int64 := start;
      while (e < zEnde && peek8(buf + e) != 32) { e := e + 1; }
      poke64(posPtr, start);
      poke64(lenPtr, e - start);
      return 1;
    }
    // zum naechsten Leerzeichen
    while (p < zEnde && peek8(buf + p) != 32) { p := p + 1; }
    p := p + 1;
  }
  return 0;
}

fn istArt(buf: int64, z: int64, name: pchar): int64 {
  var nl: int64 := StrLen(name);
  var i: int64 := 0;
  while (i < nl) {
    if (peek8(buf + z + i) != StrCharAt(name, i)) { return 0; }
    i := i + 1;
  }
  if (peek8(buf + z + nl) != 32) { return 0; }
  return 1;
}

// DER eines RSAPublicKey (SEQUENCE { INTEGER n, INTEGER e }) bauen.
fn derLaenge(out: int64, p: int64, len: int64): int64 {
  if (len < 128) { poke8(out + p, len); return p + 1; }
  if (len < 256) { poke8(out + p, 0x81); poke8(out + p + 1, len); return p + 2; }
  poke8(out + p, 0x82);
  poke8(out + p + 1, (len >> 8) & 255);
  poke8(out + p + 2, len & 255);
  return p + 3;
}

fn derInt(out: int64, p: int64, wert: int64, len: int64): int64 {
  var fuehrend: int64 := 0;
  if ((peek8(wert) & 128) != 0) { fuehrend := 1; }
  poke8(out + p, 2);
  var q: int64 := derLaenge(out, p + 1, len + fuehrend);
  if (fuehrend == 1) { poke8(out + q, 0); q := q + 1; }
  var i: int64 := 0;
  while (i < len) { poke8(out + q + i, peek8(wert + i)); i := i + 1; }
  return q + len;
}

fn rsaDerBauen(out: int64, n: int64, nLen: int64, e: int64, eLen: int64): int64 {
  var inner: int64 := alloc(1024);
  var p: int64 := derInt(inner, 0, n, nLen);
  p := derInt(inner, p, e, eLen);
  poke8(out, 0x30);
  var q: int64 := derLaenge(out, 1, p);
  var i: int64 := 0;
  while (i < p) { poke8(out + q + i, peek8(inner + i)); i := i + 1; }
  free(inner, 1024);
  return q + p;
}

fn gleichBytes(a: int64, b: int64, n: int64): int64 {
  var i: int64 := 0;
  while (i < n) {
    if (peek8(a + i) != peek8(b + i)) { return 0; }
    i := i + 1;
  }
  return 1;
}

fn main(): int64 {
  var pfad: pchar := GetArg(1) as pchar;
  var buf: int64 := alloc(MAXDATEI);
  var n: int64 := ReadFile(pfad, buf as pchar, MAXDATEI - 1);
  if (n <= 0) { PrintLn("LESEFEHLER"); return 1; }

  // Zaehler je Art: gut, schlecht
  var artGut: int64 := alloc(64);
  var artSchlecht: int64 := alloc(64);
  var i: int64 := 0;
  while (i < 8) { poke64(artGut + i * 8, 0); poke64(artSchlecht + i * 8, 0); i := i + 1; }
  var nullGeheim: int64 := 0;      // x25519-Faelle mit Null-Geheimnis

  // RSA-Schluesseltabelle
  var rsaN: int64 := alloc(8 * 512);
  var rsaNLen: int64 := alloc(8 * 8);
  var rsaE: int64 := alloc(8 * 16);
  var rsaELen: int64 := alloc(8 * 8);
  var rsaAnz: int64 := 0;

  var posP: int64 := alloc(8);
  var lenP: int64 := alloc(8);
  var b1: int64 := alloc(4096);
  var b2: int64 := alloc(4096);
  var b3: int64 := alloc(4096);
  var b4: int64 := alloc(4096);
  var b5: int64 := alloc(4096);
  var hash: int64 := alloc(64);
  var key: int64 := alloc(RsaSchluesselGroesse());
  var der: int64 := alloc(2048);

  var z: int64 := 0;
  while (z < n) {
    var zEnde: int64 := z;
    while (zEnde < n && peek8(buf + zEnde) != 10) { zEnde := zEnde + 1; }
    if (zEnde > z) {
      if (istArt(buf, z, "rsakey"c) == 1) {
        // rsakey <idx>:<n>:<e>
        var p: int64 := z + 7;
        var doppel1: int64 := p;
        while (peek8(buf + doppel1) != 58) { doppel1 := doppel1 + 1; }
        var doppel2: int64 := doppel1 + 1;
        while (peek8(buf + doppel2) != 58) { doppel2 := doppel2 + 1; }
        var nl: int64 := hexLesen(buf, doppel1 + 1, doppel2 - doppel1 - 1, b1);
        var el: int64 := hexLesen(buf, doppel2 + 1, zEnde - doppel2 - 1, b2);
        var k: int64 := 0;
        while (k < nl) { poke8(rsaN + rsaAnz * 512 + k, peek8(b1 + k)); k := k + 1; }
        poke64(rsaNLen + rsaAnz * 8, nl);
        k := 0;
        while (k < el) { poke8(rsaE + rsaAnz * 16 + k, peek8(b2 + k)); k := k + 1; }
        poke64(rsaELen + rsaAnz * 8, el);
        rsaAnz := rsaAnz + 1;
      } else {
        // <art> <erwartet> feld:hex ...
        var erw: int64 := 0;
        var sp: int64 := z;
        while (peek8(buf + sp) != 32) { sp := sp + 1; }
        if (peek8(buf + sp + 1) == 49) { erw := 1; }
        var art: int64 := 0;
        if (istArt(buf, z, "ecdsa"c) == 1) { art := 1; }
        if (istArt(buf, z, "gcm"c) == 1) { art := 2; }
        if (istArt(buf, z, "chacha"c) == 1) { art := 3; }
        if (istArt(buf, z, "x25519"c) == 1) { art := 4; }
        if (istArt(buf, z, "pss"c) == 1) { art := 5; }
        if (istArt(buf, z, "pkcs1"c) == 1) { art := 6; }

        var ok: int64 := 0;         // hat unsere Umsetzung angenommen?

        if (art == 1) {
          feld(buf, z, zEnde, "x"c, posP, lenP);
          hexLesen(buf, peek64(posP), peek64(lenP), b1);
          feld(buf, z, zEnde, "y"c, posP, lenP);
          hexLesen(buf, peek64(posP), peek64(lenP), b2);
          feld(buf, z, zEnde, "msg"c, posP, lenP);
          var ml: int64 := hexLesen(buf, peek64(posP), peek64(lenP), b3);
          feld(buf, z, zEnde, "sig"c, posP, lenP);
          var sl: int64 := hexLesen(buf, peek64(posP), peek64(lenP), b4);
          SHA256(b3, ml, hash);
          if (EcdsaSigFromDer(b4, sl, b5, b5 + 32)) {
            if (EcdsaVerify(EC_P256, hash, b1, b2, b5, b5 + 32)) { ok := 1; }
          }
        }
        if (art == 2 || art == 3) {
          feld(buf, z, zEnde, "key"c, posP, lenP);
          var kl: int64 := hexLesen(buf, peek64(posP), peek64(lenP), b1);
          feld(buf, z, zEnde, "iv"c, posP, lenP);
          hexLesen(buf, peek64(posP), peek64(lenP), b2);
          feld(buf, z, zEnde, "aad"c, posP, lenP);
          var al: int64 := hexLesen(buf, peek64(posP), peek64(lenP), b3);
          feld(buf, z, zEnde, "msg"c, posP, lenP);
          var pl: int64 := hexLesen(buf, peek64(posP), peek64(lenP), b4);
          feld(buf, z, zEnde, "ct"c, posP, lenP);
          var cl: int64 := hexLesen(buf, peek64(posP), peek64(lenP), b5);
          feld(buf, z, zEnde, "tag"c, posP, lenP);
          var tag: int64 := alloc(32);
          hexLesen(buf, peek64(posP), peek64(lenP), tag);
          var klar: int64 := alloc(4096);
          var auf: bool := false;
          if (art == 2) {
            auf := AesGcmOpen(b1, kl, b2, 12, b3, al, b5, cl, tag, 16, klar);
          } else {
            auf := ChaChaPolyOpen(b1, b2, b3, al, b5, cl, tag, klar);
          }
          if (auf) {
            if (cl != pl) { ok := 0; }
            else { ok := gleichBytes(klar, b4, pl); }
          }
          free(tag, 32); free(klar, 4096);
        }
        if (art == 4) {
          feld(buf, z, zEnde, "priv"c, posP, lenP);
          hexLesen(buf, peek64(posP), peek64(lenP), b1);
          feld(buf, z, zEnde, "pub"c, posP, lenP);
          hexLesen(buf, peek64(posP), peek64(lenP), b2);
          feld(buf, z, zEnde, "shared"c, posP, lenP);
          var shl: int64 := hexLesen(buf, peek64(posP), peek64(lenP), b3);
          X25519SharedSecret(b1, b2, b4);
          var allesNull: int64 := 1;
          var q: int64 := 0;
          while (q < 32) { if (peek8(b4 + q) != 0) { allesNull := 0; } q := q + 1; }
          if (allesNull == 1) { nullGeheim := nullGeheim + 1; }
          if (shl == 32) { ok := gleichBytes(b4, b3, 32); }
        }
        if (art == 5 || art == 6) {
          feld(buf, z, zEnde, "k"c, posP, lenP);
          var idx: int64 := StrToInt((buf + peek64(posP)) as pchar);
          feld(buf, z, zEnde, "msg"c, posP, lenP);
          var ml2: int64 := hexLesen(buf, peek64(posP), peek64(lenP), b3);
          feld(buf, z, zEnde, "sig"c, posP, lenP);
          var sl2: int64 := hexLesen(buf, peek64(posP), peek64(lenP), b4);
          var dl: int64 := rsaDerBauen(der, rsaN + idx * 512, peek64(rsaNLen + idx * 8),
                                       rsaE + idx * 16, peek64(rsaELen + idx * 8));
          if (RsaPubAusDer(der, dl, key)) {
            SHA256(b3, ml2, hash);
            if (art == 5) {
              if (RsaVerifyPss(key, 32, hash, b4, sl2)) { ok := 1; }
            } else {
              if (RsaVerifyPkcs1(key, 32, hash, b4, sl2)) { ok := 1; }
            }
          }
        }

        if (art > 0) {
          if (ok == erw) { poke64(artGut + art * 8, peek64(artGut + art * 8) + 1); }
          else {
            poke64(artSchlecht + art * 8, peek64(artSchlecht + art * 8) + 1);
            if (peek64(artSchlecht + art * 8) <= 6) {
              Print("ABWEICHUNG art "); PrintInt(art);
              if (feld(buf, z, zEnde, "id"c, posP, lenP) == 1) {
                Print(" tcId "); PrintInt(StrToInt((buf + peek64(posP)) as pchar));
              }
              Print(" erwartet "); PrintInt(erw);
              Print(" bekommen "); PrintInt(ok); PrintLn("");
            }
          }
        }
      }
    }
    z := zEnde + 1;
  }

  var namen: int64 := 1;
  while (namen <= 6) {
    Print("art"); PrintInt(namen); Print(" gut ");
    PrintInt(peek64(artGut + namen * 8));
    Print(" schlecht "); PrintInt(peek64(artSchlecht + namen * 8)); PrintLn("");
    namen := namen + 1;
  }
  Print("x25519-nullgeheimnisse "); PrintInt(nullGeheim); PrintLn("");
  return 0;
}
LYXEOF

cd "$ROOT"
"$LYXC" "$TMP/s.lyx" --std-path=. -o "$TMP/s" > "$TMP/build.log" 2>&1
if [ ! -x "$TMP/s" ]; then
  echo "FAIL: Laeufer laesst sich nicht uebersetzen"; tail -20 "$TMP/build.log"; exit 1
fi
( ulimit -v 4000000 -c 0; timeout 1800 "$TMP/s" "$DATEN" > "$TMP/out.txt" 2>&1 )
rc=$?
if [ "$rc" -ge 128 ]; then
  echo "FAIL: Laeufer abgebrochen (rc=$rc)"; tail -20 "$TMP/out.txt"; exit 1
fi
cat "$TMP/out.txt"

fails=0
pruefe() {
  local ist
  ist="$(grep -m1 "^$1 " "$TMP/out.txt" | cut -d' ' -f2-)"
  if [ "$ist" != "$2" ]; then
    echo "FAIL: $1 = '$ist', erwartet '$2'"; fails=$((fails + 1))
  fi
}
pruefe art1 "gut 484 schlecht 0"
pruefe art2 "gut 133 schlecht 0"
pruefe art3 "gut 316 schlecht 0"
pruefe art4 "gut 518 schlecht 0"
pruefe art5 "gut 108 schlecht 0"
pruefe art6 "gut 259 schlecht 0"

# Die Zahl der Null-Geheimnisse ist ein Merkmal der Vektoren, nicht unserer
# Umsetzung: sinkt sie, ist die Datendatei beschnitten worden.
pruefe x25519-nullgeheimnisse 31

if grep -q 'ABWEICHUNG' "$TMP/out.txt"; then
  echo "FAIL: abweichende Faelle:"; grep -m6 'ABWEICHUNG' "$TMP/out.txt"
  fails=$((fails + 1))
fi

if [ "$fails" -eq 0 ]; then echo "ALL PASS (1818 Wycheproof-Faelle)"; exit 0; fi
echo "$fails FAIL"
exit 1
