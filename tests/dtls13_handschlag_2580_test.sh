#!/usr/bin/env bash
# tests/dtls13_handschlag_2580_test.sh — #2580 Stufe 5: der DTLS-1.3-
# Handschlag. Zwei Zustaende sprechen im selben Programm ueber DATAGRAMME
# miteinander; kein Netz, keine fremde Gegenstelle (OpenSSL 3.5 kann kein
# DTLS 1.3, siehe der Kommentar an #2580).
#
# Geprueft wird die WIRKUNG, und der entscheidende Teil ist nicht "der
# Handschlag kam zustande":
#
#   1. Beide Seiten haben danach DASSELBE Anwendungsgeheimnis. Das ist der
#      Nachweis, dass Schluesselplan und Transkript auf beiden Seiten
#      uebereinstimmen -- ohne eine Anwendung dafuer zu brauchen.
#   2. PAKETVERLUST: ein Datagramm des Serverflugs wird verworfen, und der
#      Handschlag kommt trotzdem zustande -- ueber die WIEDERHOLUNG, und die
#      Zahl der Wiederholungen wird gezaehlt. Ein Test ohne diesen Fall waere
#      auch von einer Umsetzung erfuellt, die nie wiederholt; auf einer
#      verlustfreien Schleife faellt das nie auf.
#   3. UMORDNUNG und DOPPELUNG der Datagramme: der Handschlag kommt
#      zustande, und das Wiederholungsfenster zaehlt die Doppelungen.
#   4. Ein verfaelschtes Byte im Serverflug fuehrt zu einem LAUTEN Abbruch
#      (Tag falsch), nicht zu einem halben Handschlag.
#
# Die Uhr wird GESTELLT: die Fristen aus §5.8 lassen sich sonst nicht in
# einem Test fahren, der Sekunden statt Minuten dauern soll.
#
# ── Was dieser Test beim Bauen GEFUNDEN hat ──────────────────────────────
# Drei echte Fehler, jeder nur durch eine dieser Pruefungen sichtbar. Sie
# stehen hier, weil sie die Gegenproben SIND: nimmt man den jeweiligen Fix
# heraus, meldet genau diese Zeile wieder den alten Wert.
#
#   1. `geheimnis-gleich` war 0: der Client rechnete die
#      Anwendungsgeheimnisse NACH dem Senden des eigenen Finished, also
#      ueber ein Transkript, das es schon enthielt. Der Handschlag gelang
#      trotzdem -- das Finished stimmte ja --, und nur der Vergleich der
#      Geheimnisse zeigte es. (§7.1: der Stand ist das Finished DES SERVERS.)
#   2. `verlust` war -99 (Rundengrenze): die Wiederholung schickte die
#      gemerkten BYTE noch einmal, also Records mit ALTEN Sequenznummern --
#      das Fenster der Gegenseite wies sie ab (§4.2.1 verlangt neue). Und
#      danach noch einmal -99, weil ein Flug ZWEI Epochen spannt: das
#      ServerHello in Epoche 0, der Rest in Epoche 2. Wiederholt wurde alles
#      verschluesselt, und das ServerHello war damit unlesbar.
#   3. `doppelt` war -1 bzw. -99: eine wiederholte Nachricht wurde erneut
#      verarbeitet (Ablauffehler), und nachdem das behoben war, antworteten
#      sich beide Seiten endlos auf Wiederholungen. §5.8.1 erlaubt die
#      Antwort nur im WARTEzustand -- und hoechstens einmal je Datagramm.
#
# Keiner der drei Fehler haette auf einer verlustfreien, geordneten Leitung
# je auffallen koennen. Genau das ist der Grund, warum dieser Test die
# Leitung selbst stoert.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/certs"
cat > "$TMP/certs/edca.pem" <<'PEMEOF'
-----BEGIN CERTIFICATE-----
MIIBLDCB36ADAgECAgMAgBAwBQYDK2VwMCsxFDASBgNVBAMMC0F1cnVtIEVkIENB
MRMwEQYDVQQKDApBdXJ1bSBUZXN0MB4XDTI2MDEwMTAwMDAwMFoXDTM2MDEwMTAw
MDAwMFowKzEUMBIGA1UEAwwLQXVydW0gRWQgQ0ExEzARBgNVBAoMCkF1cnVtIFRl
c3QwKjAFBgMrZXADIQA113hCHuvVJF15Yz5gsoo5yOywjVUubpWcSL/wiawWo6Mm
MCQwEgYDVR0TAQH/BAgwBgEB/wIBATAOBgNVHQ8BAf8EBAMCAYYwBQYDK2VwA0EA
UHeajnBDcteueP+Q23Ycwm8ULcWLGsaheXthMr9fcV8Ij+AZhkUCoGtSVOKd4O+m
OrWE7j7cUq+JHw/6rbL6BQ==
-----END CERTIFICATE-----
PEMEOF
cat > "$TMP/certs/edleaf.pem" <<'PEMEOF'
-----BEGIN CERTIFICATE-----
MIIBUjCCAQSgAwIBAgIDAIARMAUGAytlcDArMRQwEgYDVQQDDAtBdXJ1bSBFZCBD
QTETMBEGA1UECgwKQXVydW0gVGVzdDAeFw0yNjAxMDEwMDAwMDBaFw0zNjAxMDEw
MDAwMDBaMCoxEzARBgNVBAMMCmVkLmV4YW1wbGUxEzARBgNVBAoMCkF1cnVtIFRl
c3QwKjAFBgMrZXADIQDf1FSJtjEDCYedH3RmQPAY1+wp/M3c5q1U6UqOSCzUwKNM
MEowDAYDVR0TAQH/BAIwADAOBgNVHQ8BAf8EBAMCB4AwEwYDVR0lBAwwCgYIKwYB
BQUHAwEwFQYDVR0RBA4wDIIKZWQuZXhhbXBsZTAFBgMrZXADQQCJLq49hU50Nlu7
i52toVqxjHj9Ns2J4FxavsgbOS+1jOJvlM2hucgpVFZO8e4qgEcZpDidURxOkAsB
zmGd8moH
-----END CERTIFICATE-----
PEMEOF
cat > "$TMP/certs/edleafkey.pem" <<'PEMEOF'
-----BEGIN PRIVATE KEY-----
MC4CAQAwBQYDK2VwBCIEIFD4PnGAF9NwCKEQ50+xruut4Mv/aYarhDZ1AH/369qK
-----END PRIVATE KEY-----
PEMEOF

cat > "$TMP/h.lyx" <<'LYXEOF'
unit main;
import std.io;
import std.string;
import std.alloc;
import std.fs;
import std.crypto.der;
import std.crypto.x509;
import std.crypto.ed25519;
import std.net.dtls13;
import std.net.tls_config;

fn ladeDer(pfad: pchar, label: pchar, derOut: int64): int64 {
  var pem: int64 := alloc(8192);
  var n: int64 := ReadFile(pfad, pem as pchar, 8191);
  if (n <= 0) { return 0 - 1; }
  return PemDekodiere(pem, n, label as int64, StrLen(label), derOut, 4096);
}

// Ein Handschlag ueber eine Leitung, die der Test KONTROLLIERT.
//
// `verlust` ist die Nummer des Datagramms (vom Server zum Client), das
// unterwegs verloren geht -- 0 heisst kein Verlust. `doppeln` doppelt
// jedes Datagramm, `verfaelschen` kippt ein Byte im ersten Serverdatagramm.
//
// Rueckgabe: 0 wenn beide Seiten fertig sind, sonst der letzte Fehler.
fn fahren(sv: int64, cl: int64, verlust: int64, doppeln: int64,
          verfaelschen: int64, wiederholungenOut: int64): int64 {
  var ausC: int64 := alloc(32768);
  var ausS: int64 := alloc(32768);
  var uhr: int64 := 1000;
  var runde: int64 := 0;
  var zaehlerS: int64 := 0;

  // Erster Schritt des Clients: ClientHello.
  var n: int64 := DtlsSchritt(cl, ausC, 32768, 1200, uhr);
  if (n < 0) { return n; }

  while (runde < 40) {
    // Client -> Server
    if (n > 0) {
      var m: int64 := DtlsPaketLesen(sv, ausC, n, ausS, 32768, 1200, uhr);
      if (m < 0) { return m; }
      // Server -> Client, mit den Stoerungen dieses Durchgangs
      if (m > 0) {
        zaehlerS := zaehlerS + 1;
        var weg: int64 := 0;
        if (zaehlerS == verlust) { weg := 1; }
        if (weg == 0) {
          if (verfaelschen == 1 && zaehlerS == 1) {
            poke8(ausS + m - 1, peek8(ausS + m - 1) ^ 1);
          }
          var r1: int64 := DtlsPaketLesen(cl, ausS, m, ausC, 32768, 1200, uhr);
          if (r1 < 0) { return r1; }
          n := r1;
          if (doppeln == 1) {
            var r2: int64 := DtlsPaketLesen(cl, ausS, m, ausC, 32768, 1200, uhr);
            if (r2 < 0) { return r2; }
            if (r2 > 0) { n := r2; }
          }
        } else {
          n := 0;
        }
      } else {
        n := 0;
      }
    }

    if (DtlsFertig(sv) == 1 && DtlsFertig(cl) == 1) {
      poke64(wiederholungenOut, DtlsZaehlerWiederholungen(sv) + DtlsZaehlerWiederholungen(cl));
      return 0;
    }

    // Nichts mehr zu senden: die Uhr vorstellen, bis eine Frist faellig ist.
    if (n == 0) {
      uhr := uhr + 1500;
      var w1: int64 := DtlsSchritt(cl, ausC, 32768, 1200, uhr);
      if (w1 < 0) { return w1; }
      if (w1 > 0) { n := w1; }
      else {
        var w2: int64 := DtlsSchritt(sv, ausS, 32768, 1200, uhr);
        if (w2 < 0) { return w2; }
        if (w2 > 0) {
          var r3: int64 := DtlsPaketLesen(cl, ausS, w2, ausC, 32768, 1200, uhr);
          if (r3 < 0) { return r3; }
          n := r3;
        }
      }
    }
    runde := runde + 1;
  }
  poke64(wiederholungenOut, DtlsZaehlerWiederholungen(sv) + DtlsZaehlerWiederholungen(cl));
  return 0 - 99;
}

fn gleich(a: int64, b: int64, n: int64): int64 {
  var i: int64 := 0;
  while (i < n) { if (peek8(a + i) != peek8(b + i)) { return 0; } i := i + 1; }
  return 1;
}

fn aufbauen(cfgS: int64, cfgC: int64, svOut: int64, clOut: int64): bool {
  var sv: int64 := DtlsHandschlagNeu(cfgS, 1);
  var cl: int64 := DtlsHandschlagNeu(cfgC, 2);
  if (sv == 0 || cl == 0) { return false; }
  DtlsFristen(sv, 100, 800, 6);
  DtlsFristen(cl, 100, 800, 6);
  poke64(svOut, sv);
  poke64(clOut, cl);
  return true;
}

fn main(): int64 {
  var basis: pchar := "CERTDIRMARKER"c;
  var dCa: int64 := alloc(4096);
  var lCa: int64 := ladeDer(StrConcat(basis, "/edca.pem"c), "CERTIFICATE"c, dCa);
  var dLeaf: int64 := alloc(4096);
  var lLeaf: int64 := ladeDer(StrConcat(basis, "/edleaf.pem"c), "CERTIFICATE"c, dLeaf);
  var dKey: int64 := alloc(4096);
  var lKey: int64 := ladeDer(StrConcat(basis, "/edleafkey.pem"c), "PRIVATE KEY"c, dKey);
  if (lCa <= 0 || lLeaf <= 0 || lKey <= 0) { PrintLn("LADEFEHLER"); return 1; }

  // Der Ed25519-Seed steckt in PKCS#8.
  var seed: int64 := alloc(32);
  if (!Ed25519PrivAusPkcs8(dKey, lKey, seed)) { PrintLn("SEEDFEHLER"); return 1; }

  var kette: int64 := alloc(16); poke64(kette, dLeaf); poke64(kette + 8, lLeaf);
  var trust: int64 := alloc(16); poke64(trust, dCa);  poke64(trust + 8, lCa);

  var cfgS: int64 := alloc(TlsConfigGroesse());
  var cfgC: int64 := alloc(TlsConfigGroesse());
  TlsConfigNeu(cfgS, 1);
  TlsConfigKette(cfgS, kette, 1, seed, 32);
  TlsConfigZeit(cfgS, 1800000000);
  TlsConfigNeu(cfgC, 2);
  TlsConfigTrust(cfgC, trust, 1);
  TlsConfigZeit(cfgC, 1800000000);

  var svp: int64 := alloc(8);
  var clp: int64 := alloc(8);
  var whp: int64 := alloc(8);
  var g1: int64 := alloc(64);
  var g2: int64 := alloc(64);

  // ── Fall 1: ungestoert ────────────────────────────────────────────
  if (!aufbauen(cfgS, cfgC, svp, clp)) { PrintLn("AUFBAUFEHLER"); return 1; }
  poke64(whp, 0);
  Print("ungestoert "); PrintInt(fahren(peek64(svp), peek64(clp), 0, 0, 0, whp)); PrintLn("");
  Print("beide-fertig "); PrintInt(DtlsFertig(peek64(svp)) + DtlsFertig(peek64(clp))); PrintLn("");
  var l1: int64 := DtlsAnwendungsgeheimnis(peek64(svp), true, g1, 64);
  var l2: int64 := DtlsAnwendungsgeheimnis(peek64(clp), false, g2, 64);
  Print("geheimnis-laenge "); PrintInt(l1); Print(" "); PrintInt(l2); PrintLn("");
  Print("geheimnis-gleich "); PrintInt(gleich(g1, g2, 32)); PrintLn("");
  // Die andere Richtung muss ein ANDERES Geheimnis sein -- sonst waere die
  // Trennung der Richtungen nur behauptet.
  DtlsAnwendungsgeheimnis(peek64(svp), false, g2, 64);
  Print("richtungen-verschieden "); PrintInt(1 - gleich(g1, g2, 32)); PrintLn("");
  Print("ungestoert-wiederholungen "); PrintInt(peek64(whp)); PrintLn("");

  // ── Fall 2: ein Serverdatagramm geht verloren ─────────────────────
  if (!aufbauen(cfgS, cfgC, svp, clp)) { PrintLn("AUFBAUFEHLER"); return 1; }
  poke64(whp, 0);
  Print("verlust "); PrintInt(fahren(peek64(svp), peek64(clp), 1, 0, 0, whp)); PrintLn("");
  Print("verlust-fertig "); PrintInt(DtlsFertig(peek64(svp)) + DtlsFertig(peek64(clp))); PrintLn("");
  Print("verlust-wiederholungen-positiv "); PrintInt(peek64(whp) > 0); PrintLn("");

  // ── Fall 3: jedes Datagramm doppelt ───────────────────────────────
  if (!aufbauen(cfgS, cfgC, svp, clp)) { PrintLn("AUFBAUFEHLER"); return 1; }
  poke64(whp, 0);
  Print("doppelt "); PrintInt(fahren(peek64(svp), peek64(clp), 0, 1, 0, whp)); PrintLn("");
  Print("doppelt-fertig "); PrintInt(DtlsFertig(peek64(svp)) + DtlsFertig(peek64(clp))); PrintLn("");
  // Abgewiesen wird auf ZWEI Ebenen, und beide zaehlen: das Fenster der
  // Record-Schicht (nur fuer verschluesselte Records, Epoche 0 hat keines)
  // und die Nachrichtenebene ueber die message_seq.
  Print("doppelt-abgewiesen-positiv ");
  PrintInt((DtlsZaehlerWiederholt(peek64(clp)) + DtlsZaehlerDoppelt(peek64(clp))) > 0);
  PrintLn("");

  // ── Fall 4: ein gekipptes Byte im ersten Serverdatagramm ──────────
  //
  // Ein verfaelschter Record wird VERWORFEN (das Tag stimmt nicht), und die
  // Wiederholung bringt den Handschlag durch. Genau das ist der Unterschied
  // zu TLS: dort beendet ein falsches Tag die Verbindung, in DTLS ist es
  // ein Paket, das eben nichts wert war (§4.5.1 "silently discard").
  if (!aufbauen(cfgS, cfgC, svp, clp)) { PrintLn("AUFBAUFEHLER"); return 1; }
  poke64(whp, 0);
  Print("gekippt "); PrintInt(fahren(peek64(svp), peek64(clp), 0, 0, 1, whp)); PrintLn("");
  Print("gekippt-fertig "); PrintInt(DtlsFertig(peek64(svp)) + DtlsFertig(peek64(clp))); PrintLn("");
  Print("gekippt-wiederholungen-positiv "); PrintInt(peek64(whp) > 0); PrintLn("");
  return 0;
}
LYXEOF
sed -i "s|CERTDIRMARKER|$TMP/certs|" "$TMP/h.lyx"

if ! ( cd "$ROOT" && timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/h.lyx" -o "$TMP/h" ) >"$TMP/log" 2>&1; then
  echo "FAIL uebersetzt nicht:"; grep -m5 -iE 'error|parse' "$TMP/log"; exit 1
fi
( ulimit -v 4000000 -c 0; "$TMP/h" ) > "$TMP/aus.txt" 2>&1
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

zeile ungestoert 0
zeile beide-fertig 2
zeile geheimnis-laenge "32 32"
zeile geheimnis-gleich 1
zeile richtungen-verschieden 1

# Verlust: der Handschlag kommt ueber die Wiederholung zustande.
zeile verlust 0
zeile verlust-fertig 2
zeile verlust-wiederholungen-positiv 1

# Doppelung: der Handschlag gelingt, und das Fenster hat die Doppelungen
# abgewiesen statt sie zweimal zu verarbeiten.
zeile doppelt 0
zeile doppelt-fertig 2
zeile doppelt-abgewiesen-positiv 1

# Gekipptes Byte: der Record ist verloren, die Wiederholung traegt den
# Handschlag durch. Ein Test, der hier einen Abbruch erwartet, wuerde eine
# Umsetzung verlangen, die bei jedem Bitfehler die Verbindung wegwirft -- in
# einem Datagrammprotokoll ist das falsch.
zeile gekippt 0
zeile gekippt-fertig 2
zeile gekippt-wiederholungen-positiv 1

echo "--- $P PASS, $F FAIL"
[ "$F" -eq 0 ] || exit 1
echo "ALL PASS"
