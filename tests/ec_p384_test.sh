#!/usr/bin/env bash
# tests/ec_p384_test.sh — #2096 Abnahmekriterium 2: secp384r1 (P-384).
#
# Geprueft wird gegen die Wycheproof-Vektoren von C2SP, die als
# tests/data/wycheproof_p384_2096.txt im Repo liegen (aus
# ecdsa_secp384r1_sha384_test.json und ecdh_secp384r1_test.json gezogen).
# Kein Netz.
#
#   ecdsa384  416  Signaturpruefung aus DER, SHA-384
#   ecdh384    51  gemeinsames Geheimnis gegen den veroeffentlichten Wert
#
# **Beide Richtungen** stecken darin: von den 416 ECDSA-Faellen muessen die
# gueltigen angenommen und die ungueltigen abgewiesen werden. Ein Test, der
# nur die gueltigen prueft, waere auch von einer Umsetzung erfuellt, die
# alles annimmt — und die DER-Lesung hatte genau so eine Luecke (#2096,
# vier Kodierungen derselben Signatur).
#
# Dazu drei Pruefungen, die nicht aus den Vektoren kommen:
#   - die Kurvenparameter selbst: G muss auf der Kurve liegen, und 2*G muss
#     den erwarteten Wert ergeben. Beide Vergleichswerte (2*G auf P-384,
#     7*G auf P-256) sind UNABHAENGIG nachgerechnet — aus den
#     Kurvenparametern mit der Additionsformel, nicht aus der Ausgabe dieser
#     Umsetzung uebernommen; sonst prueefte der Test sich selbst. Dass p
#     prim und gleich 2^384-2^128-2^96+2^32-1 ist, dass G auf der Kurve
#     liegt und dass n*G der unendlich ferne Punkt ist, wurde beim Eintragen
#     der sechs Hexkonstanten ebenso nachgerechnet. Ein Tippfehler in einer
#     von ihnen faellt damit hier auf, nicht erst an einem Vektor.
#   - eine selbst erzeugte Signatur muss von der eigenen Pruefung
#     angenommen werden, und ein gekipptes Bit im Hash MUSS sie ungueltig
#     machen. Ohne die Gegenprobe waere der Test auch von einer Pruefung
#     erfuellt, die immer true liefert.
#   - P-256 muss unveraendert rechnen. Die Zahlenschicht wurde fuer P-384
#     von vier festen auf n Glieder umgestellt; 7*G auf P-256 ist die
#     Probe, dass dabei nichts verrutscht ist.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

DATEN="$ROOT/tests/data/wycheproof_p384_2096.txt"
if [ ! -s "$DATEN" ]; then
  echo "FAIL: $DATEN fehlt"; exit 1
fi

cat > "$TMP/p384.lyx" <<'LYXEOF'
import std.io;
import std.fs;
import std.alloc;
import std.crypto.ec;
import std.crypto.sha512;

fn hv(c: int64): int64 {
  if (c >= 48 && c <= 57) { return c - 48; }
  if (c >= 97 && c <= 102) { return c - 87; }
  if (c >= 65 && c <= 70) { return c - 55; }
  return -1;
}

fn hexNach(s: pchar, out: int64, nb: int64): void {
  var i: int64 := 0;
  while (i < nb) {
    poke8(out + i, hv(peek8((s as int64) + i * 2)) * 16
                   + hv(peek8((s as int64) + i * 2 + 1)));
    i := i + 1;
  }
}

fn gleich(a: int64, b: int64, n: int64): bool {
  var i: int64 := 0;
  var acc: int64 := 0;
  while (i < n) {
    acc := acc | ((peek8(a + i) & 255) ^ (peek8(b + i) & 255));
    i := i + 1;
  }
  return acc == 0;
}

// Hex aus dem Puffer ab pos bis zum naechsten Leerzeichen oder Zeilenende.
// JEDER Lesevorgang hat eine Obergrenze: die Vektoren enthalten Signaturen
// bis 4206 Byte, und ein ungedeckelter Lauf schreibt sonst ueber den Puffer
// hinaus. Rueckgabe -2 heisst "laenger als max" — ein solcher Fall MUSS
// abgewiesen werden und wird darum nicht abgeschnitten weitergegeben.
fn hexLesen(buf: int64, pos: int64, ende: int64, out: int64, max: int64): int64 {
  var n: int64 := 0;
  var p: int64 := pos;
  while (p + 1 < ende) {
    if (n >= max) { return -2; }
    var c1: int64 := peek8(buf + p) & 255;
    if (c1 == 32 || c1 == 10) { return n; }
    var h: int64 := hv(c1);
    var l: int64 := hv(peek8(buf + p + 1) & 255);
    if (h < 0 || l < 0) { return -1; }
    poke8(out + n, h * 16 + l);
    n := n + 1;
    p := p + 2;
  }
  return n;
}

fn feld(buf: int64, von: int64, bis: int64, name: pchar, nameLen: int64): int64 {
  var p: int64 := von;
  while (p + nameLen + 1 < bis) {
    var i: int64 := 0;
    var treffer: bool := true;
    while (i < nameLen) {
      if ((peek8(buf + p + i) & 255) != (peek8((name as int64) + i) & 255)) {
        treffer := false;
        i := nameLen;
      }
      i := i + 1;
    }
    if (treffer) {
      if ((peek8(buf + p + nameLen) & 255) == 58) { return p + nameLen + 1; }
    }
    p := p + 1;
  }
  return -1;
}

fn artIst(buf: int64, von: int64, name: pchar, nameLen: int64): bool {
  var i: int64 := 0;
  while (i < nameLen) {
    if ((peek8(buf + von + i) & 255) != (peek8((name as int64) + i) & 255)) {
      return false;
    }
    i := i + 1;
  }
  return (peek8(buf + von + nameLen) & 255) == 32;
}

fn main(): int64 {
  var fehler: int64 := 0;

  // ── 1. Kurvenparameter: G auf der Kurve, 2*G gegen FIPS 186-4 ───────────
  var gx: int64 := alloc(48);
  var gy: int64 := alloc(48);
  hexNach("AA87CA22BE8B05378EB1C71EF320AD746E1D3B628BA79B9859F741E082542A385502F25DBF55296C3A545E3872760AB7"c, gx, 48);
  hexNach("3617DE4A96262C6F5D9E98BF9292DC29F8F41DBD289A147CE9DA3113B5F0B8C00A60B1CE1D7E819D7A431D7C90EA0E5F"c, gy, 48);
  if (EcFieldBytes(EC_P384) != 48) {
    PrintStrLn("FAIL EcFieldBytes(P-384) ist nicht 48"c);
    fehler := fehler + 1;
  }
  if (!EcIsOnCurve(EC_P384, gx, gy)) {
    PrintStrLn("FAIL G liegt nicht auf P-384"c);
    fehler := fehler + 1;
  }
  var k: int64 := alloc(48);
  var ox: int64 := alloc(48);
  var oy: int64 := alloc(48);
  var soll2g: int64 := alloc(48);
  hexNach("08D999057BA3D2D969260045C55B97F089025959A6F434D651D207D19FB96E9E4FE0E86EBE0E64F85B96A9C75295DF61"c, soll2g, 48);
  var i: int64 := 0;
  while (i < 48) { poke8(k + i, 0); i := i + 1; }
  poke8(k + 47, 2);
  if (!EcScalarMul(EC_P384, k, gx, gy, ox, oy)) {
    PrintStrLn("FAIL 2*G rechnet nicht"c);
    fehler := fehler + 1;
  }
  else {
    if (!gleich(ox, soll2g, 48)) {
      PrintStrLn("FAIL 2*G stimmt nicht mit dem nachgerechneten Wert"c);
      fehler := fehler + 1;
    }
    else { PrintStrLn("PASS Kurvenparameter: G auf der Kurve, 2*G stimmt"c); }
  }

  // ── 2. P-256 muss unveraendert rechnen ──────────────────────────────────
  var p2x: int64 := alloc(48);
  var p2y: int64 := alloc(48);
  var soll7g: int64 := alloc(48);
  hexNach("8E533B6FA0BF7B4625BB30667C01FB607EF9F8B8A80FEF5B300628703187B2A3"c, soll7g, 32);
  i := 0;
  while (i < 48) { poke8(k + i, 0); i := i + 1; }
  poke8(k + 31, 7);
  if (!EcPublicFromPrivate(EC_P256, k, p2x, p2y)) {
    PrintStrLn("FAIL P-256 rechnet nicht mehr"c);
    fehler := fehler + 1;
  }
  else {
    if (!gleich(p2x, soll7g, 32)) {
      PrintStrLn("FAIL P-256 7*G hat sich geaendert"c);
      fehler := fehler + 1;
    }
    else { PrintStrLn("PASS P-256 unveraendert (7*G)"c); }
  }

  // ── 3. Die Vektoren ─────────────────────────────────────────────────────
  var pfad: pchar := "VEKTORDATEI"c;
  var gr: int64 := FileSize(pfad);
  if (gr <= 0) {
    PrintStrLn("FAIL Vektordatei nicht lesbar"c);
    return 1;
  }
  var buf: int64 := alloc(gr + 16);
  if (ReadFile(pfad, buf as pchar, gr) != gr) {
    PrintStrLn("FAIL Vektordatei nicht vollstaendig gelesen"c);
    return 1;
  }

  var hash: int64 := alloc(64);
  var xb: int64 := alloc(48);
  var yb: int64 := alloc(48);
  var rb: int64 := alloc(48);
  var sb: int64 := alloc(48);
  var der: int64 := alloc(8192);
  var msg: int64 := alloc(4096);
  var shared: int64 := alloc(48);
  var eigen: int64 := alloc(48);
  var priv: int64 := alloc(48);

  var pos: int64 := 0;
  var dsaOk: int64 := 0;
  var dsaFalsch: int64 := 0;
  var dsaAnnehmen: int64 := 0;
  var dsaAbweisen: int64 := 0;
  var dhOk: int64 := 0;
  var dhFalsch: int64 := 0;

  while (pos < gr) {
    var ende: int64 := pos;
    while (ende < gr && (peek8(buf + ende) & 255) != 10) { ende := ende + 1; }
    if (ende <= pos) { pos := ende + 1; }
    else {
      if (artIst(buf, pos, "ecdsa384"c, 8)) {
        var erwartet: int64 := (peek8(buf + pos + 9) & 255) - 48;
        var fx: int64 := feld(buf, pos, ende, "x"c, 1);
        var fy: int64 := feld(buf, pos, ende, "y"c, 1);
        var fm: int64 := feld(buf, pos, ende, "msg"c, 3);
        var fs: int64 := feld(buf, pos, ende, "sig"c, 3);
        if (fx > 0 && fy > 0 && fm > 0 && fs > 0) {
          hexLesen(buf, fx, ende, xb, 48);
          hexLesen(buf, fy, ende, yb, 48);
          var mlen: int64 := 0;
          if ((peek8(buf + fm) & 255) != 45) {
            mlen := hexLesen(buf, fm, ende, msg, 4096);
          }
          if (mlen < 0) { mlen := 0; }
          var dlen: int64 := hexLesen(buf, fs, ende, der, 8192);
          Sha384(msg, mlen, hash);
          var gut: bool := false;
          if (dlen > 0) {
            if (EcdsaSigFromDer(der, dlen, rb, sb, 48)) {
              gut := EcdsaVerify(EC_P384, hash, xb, yb, rb, sb);
            }
          }
          if (erwartet == 1) { dsaAnnehmen := dsaAnnehmen + 1; }
          else { dsaAbweisen := dsaAbweisen + 1; }
          var soll: bool := erwartet == 1;
          if (gut == soll) { dsaOk := dsaOk + 1; }
          else {
            dsaFalsch := dsaFalsch + 1;
            if (dsaFalsch <= 5) {
              Print("  FAIL ecdsa384 erwartet "c);
              PrintIntLn(erwartet);
            }
          }
        }
      }
      if (artIst(buf, pos, "ecdh384"c, 7)) {
        var fp: int64 := feld(buf, pos, ende, "priv"c, 4);
        var fpx: int64 := feld(buf, pos, ende, "px"c, 2);
        var fpy: int64 := feld(buf, pos, ende, "py"c, 2);
        var fsh: int64 := feld(buf, pos, ende, "shared"c, 6);
        if (fp > 0 && fpx > 0 && fpy > 0 && fsh > 0) {
          hexLesen(buf, fp, ende, priv, 48);
          hexLesen(buf, fpx, ende, xb, 48);
          hexLesen(buf, fpy, ende, yb, 48);
          hexLesen(buf, fsh, ende, shared, 48);
          var ok2: bool := EcdhSharedSecret(EC_P384, priv, xb, yb, eigen);
          if (ok2 && gleich(eigen, shared, 48)) { dhOk := dhOk + 1; }
          else { dhFalsch := dhFalsch + 1; }
        }
      }
      pos := ende + 1;
    }
  }

  Print("ecdsa384: "c); PrintIntLn(dsaOk);
  Print("  davon anzunehmen "c); PrintIntLn(dsaAnnehmen);
  Print("  davon abzuweisen "c); PrintIntLn(dsaAbweisen);
  Print("  falsch "c); PrintIntLn(dsaFalsch);
  Print("ecdh384 richtig: "c); PrintIntLn(dhOk);
  Print("  falsch "c); PrintIntLn(dhFalsch);
  if (dsaFalsch > 0 || dhFalsch > 0) { fehler := fehler + 1; }

  // Der Lauf muss ueberhaupt Faelle gesehen haben — sonst zaehlt der Test
  // etwas, das nicht passiert ist.
  if (dsaOk + dsaFalsch < 400) {
    PrintStrLn("FAIL zu wenige ECDSA-Faelle gelesen"c);
    fehler := fehler + 1;
  }
  if (dhOk + dhFalsch < 40) {
    PrintStrLn("FAIL zu wenige ECDH-Faelle gelesen"c);
    fehler := fehler + 1;
  }
  if (dsaAnnehmen < 50 || dsaAbweisen < 50) {
    PrintStrLn("FAIL die Vektoren pruefen nicht beide Richtungen"c);
    fehler := fehler + 1;
  }

  // ── 4. Eigene Signatur, mit Gegenprobe ─────────────────────────────────
  var q3x: int64 := alloc(48);
  var q3y: int64 := alloc(48);
  i := 0;
  while (i < 48) { poke8(priv + i, 0); i := i + 1; }
  poke8(priv + 47, 42);
  if (!EcPublicFromPrivate(EC_P384, priv, q3x, q3y)) {
    PrintStrLn("FAIL P-384 Schluessel aus privatem Wert"c);
    fehler := fehler + 1;
  }
  else {
    Sha384("Eine Nachricht fuer P-384."c as int64, 26, hash);
    if (!EcdsaSign(EC_P384, hash, priv, rb, sb)) {
      PrintStrLn("FAIL P-384 EcdsaSign"c);
      fehler := fehler + 1;
    }
    else {
      if (!EcdsaVerify(EC_P384, hash, q3x, q3y, rb, sb)) {
        PrintStrLn("FAIL P-384 eigene Signatur wird abgelehnt"c);
        fehler := fehler + 1;
      }
      // Gegenprobe: ein gekipptes Bit im Hash MUSS die Signatur
      // ungueltig machen.
      poke8(hash, (peek8(hash) ^ 1) & 255);
      if (EcdsaVerify(EC_P384, hash, q3x, q3y, rb, sb)) {
        PrintStrLn("FAIL P-384 gekippter Hash wird angenommen"c);
        fehler := fehler + 1;
      }
      else {
        PrintStrLn("PASS P-384 eigene Signatur, Gegenprobe greift"c);
      }
    }
  }

  if (fehler == 0) { PrintStrLn("ALL PASS"c); return 0; }
  Print("FAIL: "c); PrintIntLn(fehler);
  return 1;
}
LYXEOF

sed -i "s#VEKTORDATEI#$DATEN#" "$TMP/p384.lyx"

cd "$ROOT"
if ! timeout 900 "$LYXC" "$TMP/p384.lyx" --std-path=. -o "$TMP/p384" > "$TMP/build.log" 2>&1; then
  echo "FAIL: Prueflaeufer uebersetzt nicht"; tail -20 "$TMP/build.log"; exit 1
fi

( ulimit -v 6000000 -c 0; timeout 1800 "$TMP/p384" > "$TMP/out.txt" 2>&1 )
rc=$?
cat "$TMP/out.txt"
if [ "$rc" -ge 128 ]; then
  echo "FAIL: Lauf abgebrochen (rc=$rc)"; exit 1
fi
if [ "$rc" -ne 0 ]; then exit 1; fi
grep -q '^ALL PASS$' "$TMP/out.txt" || { echo "FAIL: keine Abschlussmeldung"; exit 1; }
exit 0
