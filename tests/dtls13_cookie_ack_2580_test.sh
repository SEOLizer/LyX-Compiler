#!/usr/bin/env bash
# tests/dtls13_cookie_ack_2580_test.sh — #2580 Stufe 3 und 4: Cookie (§5.1),
# ACK (§7) und Wiederholung mit Rueckfall (§5.8).
#
# Drei Dinge werden geprueft, und jedes Mal die WIRKUNG:
#
#   Cookie   Es MUSS an die Adresse gebunden sein, sonst ist es ein
#            Freifahrtschein: ein Angreifer holt eines und benutzt es mit
#            gefaelschter Absenderadresse. Darum wird nicht nur geprueft,
#            dass das eigene Cookie gilt, sondern auch, dass dasselbe
#            Cookie mit ANDERER Adresse, anderem Transkript, veraendertem
#            Byte und nach Ablauf der Frist NICHT gilt. Ein Test nur des
#            guten Falls waere auch von einer Umsetzung erfuellt, die
#            jedes Cookie annimmt -- und die hebt den
#            Verstaerkungsschutz auf.
#
#   ACK      Es darf nur Nummern nennen, die wirklich geoeffnet wurden.
#            Geprueft am Rumpf: Laengenfeld, Zahl der Eintraege und die
#            Nummern selbst.
#
#   Fristen  Verdoppelung und Obergrenze, und die Aufgabe nach der
#            Versuchsgrenze. Die Uhr wird GESTELLT und nicht gelesen --
#            ein Test, der auf echte Fristen wartet, dauert Minuten und
#            wird bei Last falsch.
#
# Gegenprobe gefahren: nimmt man die Adresse aus dem MAC heraus, meldet
# `cookie-andere-adresse` 1 statt 0 und der Test ist rot. Genau dieser eine
# Wert trennt einen Verstaerkungsschutz von einem Freifahrtschein.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/c.lyx" <<'LYXEOF'
unit main;
import std.io;
import std.alloc;
import std.net.dtls13;

fn main(): int64 {
  var z: int64 := DtlsNeu(0);
  var ckkey: int64 := alloc(32);
  var i: int64 := 0;
  while (i < 32) { poke8(ckkey + i, (i * 13 + 5) & 255); i := i + 1; }
  // Frist 60 Sekunden
  Print("schluessel "); PrintInt(DtlsCookieSchluessel(z, ckkey, 60)); PrintLn("");

  // Adresse: 4 Byte IPv4 + 2 Byte Port
  var adr: int64 := alloc(8);
  poke8(adr, 192); poke8(adr + 1, 168); poke8(adr + 2, 2); poke8(adr + 3, 7);
  poke8(adr + 4, 0xC3); poke8(adr + 5, 0x50);
  var adr2: int64 := alloc(8);
  poke8(adr2, 192); poke8(adr2 + 1, 168); poke8(adr2 + 2, 2); poke8(adr2 + 3, 8);
  poke8(adr2 + 4, 0xC3); poke8(adr2 + 5, 0x50);

  var th: int64 := alloc(32);
  i := 0;
  while (i < 32) { poke8(th + i, (i * 7 + 1) & 255); i := i + 1; }
  var th2: int64 := alloc(32);
  i := 0;
  while (i < 32) { poke8(th2 + i, (i * 7 + 2) & 255); i := i + 1; }

  var ck: int64 := alloc(64);
  var jetzt: int64 := 1800000000;
  var cl: int64 := DtlsCookieBauen(z, jetzt, adr, 6, th, 32, ck, 64);
  Print("cookie-laenge "); PrintInt(cl); PrintLn("");
  Print("cookie-gueltig "); PrintInt(DtlsCookiePruefen(z, jetzt, adr, 6, th, 32, ck, cl)); PrintLn("");
  Print("cookie-spaeter-noch-gueltig "); PrintInt(DtlsCookiePruefen(z, jetzt + 30, adr, 6, th, 32, ck, cl)); PrintLn("");
  Print("cookie-andere-adresse "); PrintInt(DtlsCookiePruefen(z, jetzt, adr2, 6, th, 32, ck, cl)); PrintLn("");
  Print("cookie-anderes-transkript "); PrintInt(DtlsCookiePruefen(z, jetzt, adr, 6, th2, 32, ck, cl)); PrintLn("");
  Print("cookie-abgelaufen "); PrintInt(DtlsCookiePruefen(z, jetzt + 61, adr, 6, th, 32, ck, cl)); PrintLn("");
  Print("cookie-aus-der-zukunft "); PrintInt(DtlsCookiePruefen(z, jetzt - 1, adr, 6, th, 32, ck, cl)); PrintLn("");
  // Ein Byte im MAC kippen
  poke8(ck + 20, peek8(ck + 20) ^ 1);
  Print("cookie-gekippt "); PrintInt(DtlsCookiePruefen(z, jetzt, adr, 6, th, 32, ck, cl)); PrintLn("");
  // Ein Byte in der ZEIT kippen: dann stimmt der MAC ueber die andere Zeit
  // nicht -- der Zeitstempel ist mitsigniert und nicht bloss angehaengt.
  poke8(ck + 20, peek8(ck + 20) ^ 1);
  poke8(ck + 7, peek8(ck + 7) ^ 1);
  Print("cookie-zeit-gekippt "); PrintInt(DtlsCookiePruefen(z, jetzt, adr, 6, th, 32, ck, cl)); PrintLn("");

  // ── ACK ───────────────────────────────────────────────────────────
  var secret: int64 := alloc(48);
  i := 0;
  while (i < 48) { poke8(secret + i, (i * 31 + 7) & 255); i := i + 1; }
  var w: int64 := DtlsNeu(0);
  var r: int64 := DtlsNeu(0);
  DtlsSchluesselSetzen(w, DtlsSchreiben(), 2, secret, 32, 16, 1);
  DtlsSchluesselSetzen(r, DtlsLesen(), 2, secret, 32, 16, 1);
  var paket: int64 := alloc(4096);
  var typOut: int64 := alloc(8);
  var verbr: int64 := alloc(8);
  var rumpf: int64 := alloc(4096);
  var e: int64 := 0;
  while (e < 3) {
    var nn: int64 := DtlsRecordSchreiben(w, 23, secret, 16, paket, 4096);
    DtlsRecordLesen(r, paket, nn, typOut, rumpf, 4096, verbr);
    e := e + 1;
  }
  Print("ack-anzahl "); PrintInt(DtlsAckAnzahl(r)); PrintLn("");
  var ack: int64 := alloc(1024);
  var al: int64 := DtlsAckBauen(r, ack, 1024);
  Print("ack-laenge "); PrintInt(al); PrintLn("");
  var feld: int64 := ((peek8(ack) & 0xFF) << 8) | (peek8(ack + 1) & 0xFF);
  Print("ack-laengenfeld "); PrintInt(feld); PrintLn("");
  // Die drei Nummern sind 0, 1, 2 -- jede als uint64 hinter ihrer Epoche.
  var n0: int64 := peek8(ack + 2 + 15) & 0xFF;
  var n1: int64 := peek8(ack + 2 + 16 + 15) & 0xFF;
  var n2: int64 := peek8(ack + 2 + 32 + 15) & 0xFF;
  Print("ack-nummern "); PrintInt(n0); Print(" "); PrintInt(n1); Print(" "); PrintInt(n2); PrintLn("");
  var ep0: int64 := peek8(ack + 2 + 7) & 0xFF;
  Print("ack-epoche "); PrintInt(ep0); PrintLn("");

  // Eine Wiederholung darf die Liste NICHT verlaengern: sie wird vom
  // Fenster abgewiesen und nie geoeffnet.
  var nn2: int64 := DtlsRecordSchreiben(w, 23, secret, 16, paket, 4096);
  DtlsRecordLesen(r, paket, nn2, typOut, rumpf, 4096, verbr);
  DtlsRecordLesen(r, paket, nn2, typOut, rumpf, 4096, verbr);
  Print("ack-nach-wiederholung "); PrintInt(DtlsAckAnzahl(r)); PrintLn("");

  // ── Fristen ───────────────────────────────────────────────────────
  var f: int64 := DtlsNeu(0);
  Print("fristen "); PrintInt(DtlsFristen(f, 100, 800, 4)); PrintLn("");
  var flug: int64 := alloc(256);
  i := 0;
  while (i < 256) { poke8(flug + i, i & 255); i := i + 1; }
  DtlsFlugMerken(f, flug, 200, 1000);
  Print("sofort-faellig "); PrintInt(DtlsFristFaellig(f, 1000)); PrintLn("");
  Print("vor-der-frist "); PrintInt(DtlsFristFaellig(f, 1099)); PrintLn("");
  Print("nach-der-frist "); PrintInt(DtlsFristFaellig(f, 1100)); PrintLn("");
  var aus: int64 := alloc(512);
  var w1: int64 := DtlsFlugWiederholen(f, 1100, aus, 512);
  Print("wiederholt-laenge "); PrintInt(w1); Print(" frist "); PrintInt(DtlsFlugFrist(f)); PrintLn("");
  var w2: int64 := DtlsFlugWiederholen(f, 1300, aus, 512);
  Print("zweite-frist "); PrintInt(DtlsFlugFrist(f)); PrintLn("");
  var w3: int64 := DtlsFlugWiederholen(f, 1700, aus, 512);
  var w4: int64 := DtlsFlugWiederholen(f, 2500, aus, 512);
  Print("deckel-erreicht "); PrintInt(DtlsFlugFrist(f)); PrintLn("");
  Print("versuche "); PrintInt(DtlsFlugVersuche(f)); PrintLn("");
  Print("aufgegeben "); PrintInt(DtlsFristFaellig(f, 99999)); PrintLn("");
  Print("zaehler-wiederholungen "); PrintInt(DtlsZaehlerWiederholungen(f)); PrintLn("");
  // Inhalt der Wiederholung muss der des Flugs sein.
  var gleich: int64 := 1;
  i := 0;
  while (i < 200) { if (peek8(aus + i) != peek8(flug + i)) { gleich := 0; } i := i + 1; }
  Print("wiederholung-inhalt-gleich "); PrintInt(gleich); PrintLn("");
  // Bestaetigt: nichts mehr zu wiederholen.
  DtlsFlugBestaetigt(f);
  Print("nach-bestaetigung "); PrintInt(DtlsFristFaellig(f, 99999)); PrintLn("");
  Print("nach-bestaetigung-laenge "); PrintInt(DtlsFlugWiederholen(f, 99999, aus, 512)); PrintLn("");
  return 0;
}
LYXEOF

if ! ( cd "$ROOT" && timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" ) >"$TMP/log" 2>&1; then
  echo "FAIL uebersetzt nicht:"; grep -m5 -iE 'error|parse' "$TMP/log"; exit 1
fi
( ulimit -v 4000000 -c 0; "$TMP/c" ) > "$TMP/aus.txt" 2>&1
RC=$?
sed 's/^/    /' "$TMP/aus.txt"

P=0; F=0
ok()  { echo "PASS $1"; P=$((P+1)); }
bad() { echo "FAIL $1${2:+ -- $2}"; F=$((F+1)); }
[ "$RC" = 0 ] || bad "Lauf" "Exitcode $RC"
zeile() {
  ist="$(grep -m1 "^$1 " "$TMP/aus.txt" | cut -d' ' -f2-)"
  if [ "${ist:-fehlt}" = "$2" ]; then ok "$1: $2"; else bad "$1" "ist '${ist:-fehlt}', soll '$2'"; fi
}

zeile schluessel 1
zeile cookie-laenge 40
zeile cookie-gueltig 1
zeile cookie-spaeter-noch-gueltig 1
# Die fuenf Ablehnungen sind der eigentliche Nachweis.
zeile cookie-andere-adresse 0
zeile cookie-anderes-transkript 0
zeile cookie-abgelaufen 0
zeile cookie-aus-der-zukunft 0
zeile cookie-gekippt 0
zeile cookie-zeit-gekippt 0

zeile ack-anzahl 3
# 2 Byte Laengenfeld + 3 * 16 Byte RecordNumber
zeile ack-laenge 50
zeile ack-laengenfeld 48
zeile ack-nummern "0 1 2"
zeile ack-epoche 2
zeile ack-nach-wiederholung 4

zeile fristen 1
zeile sofort-faellig 0
zeile vor-der-frist 0
zeile nach-der-frist 1
zeile wiederholt-laenge "200 frist 200"
zeile zweite-frist 400
zeile deckel-erreicht 800
zeile versuche 4
# Nach vier Versuchen bei Grenze 4 ist der Weg aufgegeben: -1.
zeile aufgegeben -1
zeile zaehler-wiederholungen 4
zeile wiederholung-inhalt-gleich 1
zeile nach-bestaetigung 0
zeile nach-bestaetigung-laenge 0

echo "--- $P PASS, $F FAIL"
[ "$F" -eq 0 ] || exit 1
echo "ALL PASS"
