#!/usr/bin/env bash
# tests/crypto_konstantzeit_signieren_2615_test.sh — #2096 Kriterium 7, Rest:
# Konstantzeit beim SIGNIEREN (#2615).
#
# tests/crypto_konstantzeit_2096_test.sh deckt den Tag-Vergleich ab. Dort steht
# ausdruecklich, was fehlt: das Signieren braucht ein anderes Geschirr, weil die
# Laufzeit einer Signatur schon ueber den Nonce streut. Geprueft wird deshalb
# nicht EINE Eingabe gegen eine andere, sondern eine Klasse von SKALAREN bzw.
# SCHLUESSELN gegen eine andere -- dudect im urspruenglichen Sinn.
#
# DREI MESSUNGEN, und die erste ist die wichtigste:
#
#   1. die SKALARMULTIPLIKATION selbst (EcScalarMul, secp256k1). Hier ist der
#      Skalar steuerbar, und genau er ist beim Signieren der Nonce. Klassen:
#      ein voller Skalar (etwa die Haelfte der Bits gesetzt) gegen k = 1
#      (255 fuehrende Nullbits) -- der klassische Fall, in dem eine
#      nicht-konstante Leiter kuerzer rechnet.
#   2. ECDSA ganz (EcdsaSign): ein fester Schluessel gegen je einen neuen.
#      Hier ist die Streuung ueber den RFC-6979-Nonce schon drin; die Messung
#      belegt, dass die SCHLUESSELklasse darueber hinaus nichts hinzufuegt.
#   3. RSA (RsaSignPkcs1, 2048 Bit, CRT): EIN Schluessel, zwei
#      NACHRICHTENklassen. Die Zusage steht im Kopf von rsa_native.lyx
#      (BnModExpCT, maskierter CRT-Weg) und wird hier gemessen statt geglaubt.
#
#      WARUM NICHT ZWEI SCHLUESSEL, obwohl #2615 das vorschlaegt: gemessen am
#      2026-11-24 unterscheiden sich zwei frisch erzeugte 2048-Bit-Schluessel um
#      rund 700 us je 20 Signaturen. Das ist kein Leck, sondern Struktur -- p,
#      q, dp, dq und der private Exponent haben je Schluessel andere
#      Bitlaengen, und der CRT-Weg rechnet entsprechend verschieden lange. Fuer
#      das Bedrohungsmodell ist das auch die falsche Frage: der Schluessel ist
#      beim Signieren fest, waehlen kann der Angreifer die NACHRICHT. Genau die
#      wird hier variiert -- Hash aus Nullbytes gegen Hash mit dichten Bits.
#
# GEGENPROBE IM TEST SELBST. Ohne sie waere jede dieser Messungen auch von
# einem Geschirr erfuellt, das zu grob ist, um irgendetwas zu finden. Gemessen
# wird darum zusaetzlich eine Routine, deren Arbeit ABSICHTLICH an der Zahl der
# gesetzten Bits haengt (Aufrufe proportional zum Hamming-Gewicht) -- also die
# Form eines undichten Double-and-Add, gebaut aus einer konstantzeitigen
# Grundoperation. Sie MUSS die Schwelle reissen; tut sie es nicht, ist der Test
# rot, weil er dann nichts belegt.
#
# Warum nicht std.crypto.ecc als undichte Gegenstelle: gemessen am 2026-11-24
# geht `ECCPubFromPriv` ueber `EcPublicFromPrivate` aus ec.lyx, und
# `ECDSASign` ueber `EcdsaSign` -- beide also ueber den konstantzeitigen Weg.
# Die undichte Leiter `jacMul` (`if (bit != 0)`) steht dort nur noch in
# `ECDSAVerify`, und die verarbeitet Hash, Signatur und oeffentlichen
# Schluessel, also oeffentliche Werte. Es gibt in dieser Bibliothek keinen
# ausgelieferten undichten Pfad auf ein Geheimnis -- deshalb die selbstgebaute
# Gegenprobe.
#
# Geurteilt wird wie im Tag-Test: Median (nicht Mittelwert), gegen den SELBST
# gemessenen Rauschboden (zweimal dieselbe Klasse), Messfenster wird
# nachgezogen, bis der Median zehnmal ueber dem Rauschboden liegt, `taskset`
# bindet auf einen Kern.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ulimit -c 0 2>/dev/null
pr() { if [ "$1" = ok ]; then PASS=$((PASS+1)); echo "PASS $2"; else FAIL=$((FAIL+1)); echo "FAIL $2"; fi; }

WDH="${WDH:-20}"            # Skalarmultiplikationen je Messpunkt (~2,6 ms each)
PROBEN="${PROBEN:-20}"
BIND=""
command -v taskset >/dev/null 2>&1 && BIND="taskset -c 2"

cat > "$TMP/ct.lyx" <<'LYXEOF'
unit main;
import std.io;
import std.string;
import std.alloc;
import std.fs;
import std.time;
import std.crypto.ct;
import std.crypto.der;
import std.crypto.ec;
import std.crypto.rsa_native;

// Skalar bauen: art 0 = k gleich 1 (255 fuehrende Nullbits),
// art 1 = voller Skalar, art 2 = zweiter voller Skalar (anderes Muster,
// gleiches Hamming-Gewicht in derselben Groessenordnung).
fn skalar(k: int64, art: int64): void {
  var i: int64 := 0;
  while (i < 32) { poke8(k + i, 0); i := i + 1; }
  if (art == 0) { poke8(k + 31, 1); return; }
  if (art == 1) { i := 0; while (i < 32) { poke8(k + i, (i * 37 + 11) & 255); i := i + 1; } return; }
  i := 0; while (i < 32) { poke8(k + i, (i * 53 + 29) & 255); i := i + 1; }
}

fn gewicht(k: int64): int64 {
  var i: int64 := 0; var g: int64 := 0;
  while (i < 32) {
    var b: int64 := peek8(k + i); var j: int64 := 0;
    while (j < 8) { g := g + ((b >> j) & 1); j := j + 1; }
    i := i + 1;
  }
  return g;
}

fn messeLeiter(k: int64, gx: int64, gy: int64, ox: int64, oy: int64,
               wdh: int64, senke: int64): int64 {
  var t0: int64 := NowUs(); var i: int64 := 0; var s: int64 := 0;
  while (i < wdh) {
    if (EcScalarMul(EC_SECP256K1, k, gx, gy, ox, oy)) { s := s + peek8(ox); }
    i := i + 1;
  }
  poke64(senke, peek64(senke) + s);
  return NowUs() - t0;
}

// ABSICHTLICH undicht: die Zahl der Aufrufe haengt am Hamming-Gewicht des
// Skalars -- die Form eines Double-and-Add mit `if (bit) add`, gebaut aus
// einer konstantzeitigen Grundoperation. Nur zur Pruefung des Geschirrs.
// LECK_ARBEIT ist so gewaehlt, dass diese Routine bei vollem Skalar etwa so
// lange braucht wie die echte Skalarmultiplikation (rund 2,6 ms je Aufruf).
// Erst dann belegt die Gegenprobe nicht nur, DASS die Urteilsregel feuern
// kann, sondern dass sie es in DERSELBEN Groessenordnung tut, in der die
// eigentliche Messung urteilt. Mit 97 us gegen 52 ms waere das offen
// geblieben.
fn messeLeck(k: int64, puf: int64, wdh: int64, senke: int64): int64 {
  var t0: int64 := NowUs(); var i: int64 := 0; var s: int64 := 0;
  while (i < wdh) {
    var bit: int64 := 0;
    while (bit < 256) {
      if (((peek8(k + (bit / 8)) >> (bit % 8)) & 1) != 0) {
        var w: int64 := 0;
        while (w < 45) { s := s + CTMemEqual(puf, puf, 512); w := w + 1; }
      }
      bit := bit + 1;
    }
    i := i + 1;
  }
  poke64(senke, peek64(senke) + s);
  return NowUs() - t0;
}

fn messeEcdsa(h: int64, priv: int64, r: int64, s32: int64,
              wdh: int64, senke: int64): int64 {
  var t0: int64 := NowUs(); var i: int64 := 0; var s: int64 := 0;
  while (i < wdh) {
    if (EcdsaSign(EC_SECP256K1, h, priv, r, s32)) { s := s + peek8(r); }
    i := i + 1;
  }
  poke64(senke, peek64(senke) + s);
  return NowUs() - t0;
}

fn ladeDer(pfad: pchar, label: pchar, derOut: int64): int64 {
  var pem: int64 := alloc(16384);
  var n: int64 := ReadFile(pfad, pem as pchar, 16383);
  if (n <= 0) { return -1; }
  return PemDekodiere(pem, n, label as int64, StrLen(label), derOut, 8192);
}

fn messeRsa(key: int64, h: int64, sig: int64, wdh: int64, senke: int64): int64 {
  var t0: int64 := NowUs(); var i: int64 := 0; var s: int64 := 0;
  while (i < wdh) { s := s + RsaSignPkcs1(key, 32, h, sig); i := i + 1; }
  poke64(senke, peek64(senke) + s);
  return NowUs() - t0;
}

fn main(): int64 {
  var wdh: int64 := WDHMARKER;
  var proben: int64 := PROBENMARKER;
  var senke: int64 := alloc(8); poke64(senke, 0);

  var kEins: int64 := alloc(32); var kVoll: int64 := alloc(32); var kVoll2: int64 := alloc(32);
  skalar(kEins, 0); skalar(kVoll, 1); skalar(kVoll2, 2);
  Print("gewicht eins "c);  PrintInt(gewicht(kEins));
  Print(" voll "c);          PrintInt(gewicht(kVoll));
  Print(" voll2 "c);         PrintInt(gewicht(kVoll2)); PrintLn(""c);

  var gx: int64 := alloc(32); var gy: int64 := alloc(32);
  if (!EcPublicFromPrivate(EC_SECP256K1, kEins, gx, gy)) { PrintLn("G fehlt"c); return 1; }
  var ox: int64 := alloc(32); var oy: int64 := alloc(32);
  var puf: int64 := alloc(512);

  var h: int64 := alloc(32); var r: int64 := alloc(32); var s32: int64 := alloc(32);
  var i: int64 := 0; while (i < 32) { poke8(h + i, (i * 7 + 3) & 255); i := i + 1; }
  // Zweite Nachrichtenklasse: alles Nullbytes. Der zu potenzierende Wert ist
  // damit klein und bitarm -- der Fall, in dem eine nicht-konstante
  // Fensterauswahl kuerzer rechnet.
  var h0: int64 := alloc(32);
  i := 0; while (i < 32) { poke8(h0 + i, 0); i := i + 1; }

  // RSA: zwei verschiedene private Schluessel, wenn openssl sie geliefert hat.
  var der1: int64 := alloc(8192);
  var k1: int64 := alloc(RsaSchluesselGroesse());
  var rsaDa: int64 := 0;
  var n1: int64 := ladeDer("RSA1MARKER"c, "PRIVATE KEY"c, der1);
  if (n1 > 0) {
    if (RsaPrivAusPkcs8(der1, n1, k1)) { rsaDa := 1; }
  }
  var sig: int64 := alloc(512);
  Print("rsa_da "c); PrintInt(rsaDa); PrintLn(""c);

  // Einlaufrunde: der erste Aufruf misst Seitenfehler und kalten Cache.
  messeLeiter(kVoll, gx, gy, ox, oy, wdh, senke);
  messeLeck(kVoll, puf, 1, senke);
  messeEcdsa(h, kVoll, r, s32, 1, senke);
  if (rsaDa != 0) { messeRsa(k1, h, sig, 1, senke); messeRsa(k1, h0, sig, 1, senke); }

  var p: int64 := 0;
  while (p < proben) {
    Print("probe "c);       PrintInt(p);
    // 1. Skalarmultiplikation: voll, eins, voll2 (Rauschboden)
    Print(" leiter_voll "c);  PrintInt(messeLeiter(kVoll,  gx, gy, ox, oy, wdh, senke));
    Print(" leiter_eins "c);  PrintInt(messeLeiter(kEins,  gx, gy, ox, oy, wdh, senke));
    Print(" leiter_voll2 "c); PrintInt(messeLeiter(kVoll2, gx, gy, ox, oy, wdh, senke));
    // Gegenprobe: dieselben Klassen, absichtlich undichte Routine
    Print(" leck_voll "c);    PrintInt(messeLeck(kVoll,  puf, wdh, senke));
    Print(" leck_eins "c);    PrintInt(messeLeck(kEins,  puf, wdh, senke));
    Print(" leck_voll2 "c);   PrintInt(messeLeck(kVoll2, puf, wdh, senke));
    // 2. ECDSA ganz: fester Schluessel gegen anderen Schluessel
    Print(" ecdsa_a "c);      PrintInt(messeEcdsa(h, kVoll,  r, s32, wdh, senke));
    Print(" ecdsa_b "c);      PrintInt(messeEcdsa(h, kVoll2, r, s32, wdh, senke));
    Print(" ecdsa_a2 "c);     PrintInt(messeEcdsa(h, kVoll,  r, s32, wdh, senke));
    // 3. RSA: zwei Schluessel
    if (rsaDa != 0) {
      // EIN Schluessel, zwei Nachrichtenklassen; rsa_a2 ist der Rauschboden.
      Print(" rsa_a "c);      PrintInt(messeRsa(k1, h,  sig, wdh, senke));
      Print(" rsa_b "c);      PrintInt(messeRsa(k1, h0, sig, wdh, senke));
      Print(" rsa_a2 "c);     PrintInt(messeRsa(k1, h,  sig, wdh, senke));
    }
    PrintLn(""c);
    p := p + 1;
  }
  Print("senke "c); PrintInt(peek64(senke)); PrintLn(""c);
  return 0;
}
LYXEOF

# RSA-Schluessel: zwei verschiedene. Ohne openssl bleibt der RSA-Teil aus --
# ein roter Test aus Umgebungsgruenden sagt nichts ueber den Code.
RSA1="$TMP/r1.pem"
if command -v openssl >/dev/null 2>&1; then
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$RSA1" 2>/dev/null
fi
[ -s "$RSA1" ] || echo "    (Hinweis: ohne openssl-Schluessel bleibt der RSA-Teil aus)"

median() { sort -n | awk '{v[NR]=$1} END {if (NR==0) {print 0} else if (NR%2) {print v[(NR+1)/2]} else {print int((v[NR/2]+v[NR/2+1])/2)}}'; }

# Die Schwelle ist das DREIFACHE des Rauschbodens -- aber mindestens ein
# Promille des Medians.
#
# #2615: Ohne diese Untergrenze ist der Test auf einer SEHR ruhigen Maschine
# rot. Auf dem CI-Laeufer kam der Boden als 1 us heraus (zwei Durchgaenge
# derselben Klasse lagen gleich), die Schwelle damit auf 3 us -- und ein
# Unterschied von 4 us auf einen Median von 34973 us, also 0,011 %, galt als
# Datenabhaengigkeit. Das ist Auflösung und keine Messung: ein Verhaeltnis
# unter der Untergrenze des Messmittels sagt nichts.
#
# Ein Promille ist bewusst streng. Die Gegenprobe behaelt damit reichlich
# Luft: ihr Leck liegt bei rund 28000 us auf einen Median von 28243 us, also
# fast 100 %, und reisst die Schwelle um den Faktor 40.
# Streuung EINER Klasse: p75 - p25 ueber die Proben.
#
# #2615: Der Rauschboden war zuerst allein |median(voll) - median(voll2)|,
# also eine Schaetzung aus ZWEI Zahlen. Die kann klein ausfallen, waehrend die
# echte Streuung gross ist -- dann urteilt der Test auf eine Schwelle, die die
# Maschine gar nicht hergibt. Gemessen: im vollen `make test` (Maschine
# belastet) kam der Boden als 46 us heraus und die Leiter scheiterte mit
# 258 us; auf dem CI-Laeufer (sehr ruhig) als 1 us und sie scheiterte mit
# 4 us. Beide Male war nicht der Code das Thema, sondern die Schaetzung.
#
# Der Quartilsabstand nutzt alle Proben und ist gegen einzelne Ausreisser
# robust -- dasselbe Argument wie beim Median gegen den Mittelwert.
streuung() { sort -n | awk '{v[NR]=$1} END {
  if (NR < 4) { print 0; exit }
  q1 = v[int(NR/4)+1]; q3 = v[int(3*NR/4)]
  d = q3 - q1; if (d < 0) d = -d; print d }'; }

schwelle() { # boden, median
  local s3=$(( $1 * 3 ))
  local rel=$(( $2 / 1000 ))
  if [ "$rel" -gt "$s3" ]; then echo "$rel"; else echo "$s3"; fi
}
spalte() { awk -v f="$1" '{for (i=1;i<NF;i++) if ($i==f) print $(i+1)}' "$2"; }

lauf() { # wdh -> $TMP/mess.txt
  sed -e "s/WDHMARKER/$1/" -e "s/PROBENMARKER/$PROBEN/" \
      -e "s|RSA1MARKER|$RSA1|" "$TMP/ct.lyx" > "$TMP/run.lyx"
  ( cd "$ROOT" && "$LYXC" "$TMP/run.lyx" --std-path="$ROOT" -o "$TMP/ct" ) > "$TMP/bau.log" 2>&1 || return 1
  $BIND "$TMP/ct" > "$TMP/mess.txt" 2>&1 || return 1
  return 0
}

if ! lauf "$WDH"; then
  pr fail "Messprogramm uebersetzt oder laeuft nicht: $(grep -m1 -iE 'error|fehler' "$TMP/bau.log" "$TMP/mess.txt" 2>/dev/null | head -1)"
  echo "Ergebnis: $PASS PASS, $FAIL FAIL"; exit 1
fi
pr ok "Messprogramm uebersetzt und laeuft ($(grep -c '^probe' "$TMP/mess.txt") Proben)"
echo "    $(grep -m1 '^gewicht' "$TMP/mess.txt")"

# Fenster nachziehen, bis der Median zehnmal ueber dem Rauschboden liegt.
versuch=1
while [ "$versuch" -le 3 ]; do
  MV="$(spalte leiter_voll  "$TMP/mess.txt" | median)"
  ME="$(spalte leiter_eins  "$TMP/mess.txt" | median)"
  MV2="$(spalte leiter_voll2 "$TMP/mess.txt" | median)"
  BODEN=$(( MV > MV2 ? MV - MV2 : MV2 - MV ))
  SV="$(spalte leiter_voll "$TMP/mess.txt" | streuung)"
  [ "${SV:-0}" -gt "$BODEN" ] && BODEN="$SV"
  [ "$BODEN" -eq 0 ] && BODEN=1
  if [ $(( MV / BODEN )) -ge 10 ]; then break; fi
  WDH=$(( WDH * 4 )); versuch=$(( versuch + 1 ))
  echo "    Rauschboden $BODEN us gegen Median $MV us -- Fenster auf WDH=$WDH"
  lauf "$WDH" || { pr fail "Lauf mit WDH=$WDH scheitert"; break; }
done

MV="$(spalte leiter_voll  "$TMP/mess.txt" | median)"
ME="$(spalte leiter_eins  "$TMP/mess.txt" | median)"
MV2="$(spalte leiter_voll2 "$TMP/mess.txt" | median)"
BODEN=$(( MV > MV2 ? MV - MV2 : MV2 - MV ))
SV="$(spalte leiter_voll "$TMP/mess.txt" | streuung)"
[ "${SV:-0}" -gt "$BODEN" ] && BODEN="$SV"
[ "$BODEN" -eq 0 ] && BODEN=1
SCHWELLE="$(schwelle "$BODEN" "$MV")"
UNTERSCHIED=$(( MV > ME ? MV - ME : ME - MV ))
echo "    Leiter: voll=$MV eins=$ME voll2=$MV2 -> Rauschboden $BODEN us, Schwelle $SCHWELLE us, Unterschied $UNTERSCHIED us"
if [ "$UNTERSCHIED" -le "$SCHWELLE" ]; then
  pr ok "EcScalarMul: Laufzeit unabhaengig vom Skalar ($UNTERSCHIED us <= $SCHWELLE us)"
else
  pr fail "EcScalarMul: Laufzeit haengt am Skalar ($UNTERSCHIED us > $SCHWELLE us)"
fi

# Gegenprobe: die absichtlich undichte Routine MUSS die Schwelle reissen.
LV="$(spalte leck_voll  "$TMP/mess.txt" | median)"
LE="$(spalte leck_eins  "$TMP/mess.txt" | median)"
LV2="$(spalte leck_voll2 "$TMP/mess.txt" | median)"
LBODEN=$(( LV > LV2 ? LV - LV2 : LV2 - LV ))
LSV="$(spalte leck_voll "$TMP/mess.txt" | streuung)"
[ "${LSV:-0}" -gt "$LBODEN" ] && LBODEN="$LSV"
[ "$LBODEN" -eq 0 ] && LBODEN=1
LUNTER=$(( LV > LE ? LV - LE : LE - LV ))
echo "    Gegenprobe: voll=$LV eins=$LE voll2=$LV2 -> Rauschboden $LBODEN us, Unterschied $LUNTER us"
if [ "$LUNTER" -gt "$(schwelle "$LBODEN" "$LV")" ]; then
  pr ok "Gegenprobe: das Geschirr findet eine bitabhaengige Laufzeit ($LUNTER us)"
else
  pr fail "Gegenprobe: eine ABSICHTLICH undichte Routine fiel nicht auf -- der Test belegt nichts"
fi

# ECDSA ganz: Schluesselklassen.
EA="$(spalte ecdsa_a  "$TMP/mess.txt" | median)"
EB="$(spalte ecdsa_b  "$TMP/mess.txt" | median)"
EA2="$(spalte ecdsa_a2 "$TMP/mess.txt" | median)"
EBODEN=$(( EA > EA2 ? EA - EA2 : EA2 - EA ))
ESV="$(spalte ecdsa_a "$TMP/mess.txt" | streuung)"
[ "${ESV:-0}" -gt "$EBODEN" ] && EBODEN="$ESV"
[ "$EBODEN" -eq 0 ] && EBODEN=1
EUNTER=$(( EA > EB ? EA - EB : EB - EA ))
echo "    EcdsaSign: a=$EA b=$EB a2=$EA2 -> Rauschboden $EBODEN us, Unterschied $EUNTER us"
ESCHW="$(schwelle "$EBODEN" "$EA")"
if [ "$EUNTER" -le "$ESCHW" ]; then
  pr ok "EcdsaSign: Laufzeit unabhaengig vom Schluessel ($EUNTER us <= $ESCHW us)"
else
  pr fail "EcdsaSign: Laufzeit haengt am Schluessel ($EUNTER us > $ESCHW us)"
fi

# RSA: zwei Schluessel, nur wenn openssl sie geliefert hat.
if grep -q "^rsa_da 1" "$TMP/mess.txt"; then
  RA="$(spalte rsa_a  "$TMP/mess.txt" | median)"
  RB="$(spalte rsa_b  "$TMP/mess.txt" | median)"
  RA2="$(spalte rsa_a2 "$TMP/mess.txt" | median)"
  RBODEN=$(( RA > RA2 ? RA - RA2 : RA2 - RA ))
  RSV="$(spalte rsa_a "$TMP/mess.txt" | streuung)"
  [ "${RSV:-0}" -gt "$RBODEN" ] && RBODEN="$RSV"
  [ "$RBODEN" -eq 0 ] && RBODEN=1
  RUNTER=$(( RA > RB ? RA - RB : RB - RA ))
  echo "    RsaSignPkcs1: a=$RA b=$RB a2=$RA2 -> Rauschboden $RBODEN us, Unterschied $RUNTER us"
  RSCHW="$(schwelle "$RBODEN" "$RA")"
  if [ "$RUNTER" -le "$RSCHW" ]; then
    pr ok "RsaSignPkcs1: Laufzeit unabhaengig von der Nachricht ($RUNTER us <= $RSCHW us)"
  else
    pr fail "RsaSignPkcs1: Laufzeit haengt an der Nachricht ($RUNTER us > $RSCHW us)"
  fi
else
  echo "    (SKIP RSA: kein Schluesselpaar -- openssl fehlt oder erzeugt keines)"
fi

echo ""
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
