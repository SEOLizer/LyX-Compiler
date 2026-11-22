#!/usr/bin/env bash
# tests/tls13_0rtt_2578_test.sh — #2578: fruehe Daten (0-RTT) samt
# Wiederholungsschutz. Zwei Zustaende sprechen im selben Programm ueber
# Puffer miteinander; kein Netz, kein openssl.
#
# Geprueft wird die WIRKUNG, und zwar in BEIDE Richtungen. Ein Test, der nur
# zeigt, dass fruehe Daten ankommen, waere auch von einer Umsetzung erfuellt,
# die jeden wiederholten Flug annimmt — und das ist genau der Zustand, in dem
# 0-RTT schwaecher ist als kein 0-RTT.
#
#   Fall 1  Wiederaufnahme ohne fruehe Daten: Ticket entsteht, der Server
#           nennt max_early_data_size.
#   Fall 2  0-RTT angenommen: der Server liest die fruehen Byte VOR dem
#           Handschlagende, meldet sie als frueh, und der Handschlag laeuft
#           danach normal durch.
#   Fall 3  WIEDERHOLUNG desselben mitgeschnittenen Flugs gegen einen
#           frischen Server mit demselben Wiederholungsschutz: die fruehen
#           Daten MUESSEN abgewiesen werden.
#   Fall 4  derselbe Flug, aber der Server hat KEINEN
#           Wiederholungsschutz: 0-RTT bleibt aus. Die Vorgabe allein
#           schaltet es nicht ein.
#   Fall 5  der Server erlaubt keine fruehen Daten, der Client sendet sie
#           trotzdem: der Server verwirft die unlesbaren Records und der
#           Handschlag gelingt. Der Client erfaehrt die Ablehnung und sendet
#           normal.
#
# Die Faelle 3 und 4 sind der Kern. Ohne sie waere der Wiederholungsschutz
# behauptet und nicht belegt.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/certs"
cat > "$TMP/certs/tlsca.pem" <<'PEMEOF'
-----BEGIN CERTIFICATE-----
MIIBbzCCARSgAwIBAgICcAEwCgYIKoZIzj0EAwIwLDEVMBMGA1UEAwwMQXVydW0g
VExTIENBMRMwEQYDVQQKDApBdXJ1bSBUZXN0MB4XDTI2MDEwMTAwMDAwMFoXDTM2
MDEwMTAwMDAwMFowLDEVMBMGA1UEAwwMQXVydW0gVExTIENBMRMwEQYDVQQKDApB
dXJ1bSBUZXN0MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE3a2NfJ1/mpoyEWsT
ZrFd+TJWJE7e1cQ5xO5Zw/A9omNflfqqok62KU6XK0b8E0P915QVTMzLGBPP7499
Nia5H6MmMCQwEgYDVR0TAQH/BAgwBgEB/wIBATAOBgNVHQ8BAf8EBAMCAYYwCgYI
KoZIzj0EAwIDSQAwRgIhAJVCkdPFKLxMlKaT0gXw/hMmfQEaCgGGv6qoAKwYGMWx
AiEAo1GhCrHunvjleL0bTnKRZU+YBsxiioPZnWgeZdv31hc=
-----END CERTIFICATE-----
PEMEOF
cat > "$TMP/certs/tlssrv.pem" <<'PEMEOF'
-----BEGIN CERTIFICATE-----
MIIBmDCCAT6gAwIBAgICcAIwCgYIKoZIzj0EAwIwLDEVMBMGA1UEAwwMQXVydW0g
VExTIENBMRMwEQYDVQQKDApBdXJ1bSBUZXN0MB4XDTI2MDEwMTAwMDAwMFoXDTM2
MDEwMTAwMDAwMFowLTEWMBQGA1UEAwwNbmV4dXMuZXhhbXBsZTETMBEGA1UECgwK
QXVydW0gVGVzdDBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABHTsWypZoHC8Y+jv
DHgWXumKas5YDWOyaYhWQGjjqIRpoP8WnG5mh3+QsHMUIaIjixX63ExbD3bJW5ZK
cMWHILujTzBNMAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgeAMBMGA1UdJQQM
MAoGCCsGAQUFBwMBMBgGA1UdEQQRMA+CDW5leHVzLmV4YW1wbGUwCgYIKoZIzj0E
AwIDSAAwRQIgLbQ23G518d+0Qfc53GILrqRqLnKDStz4OoWM30aaBAwCIQDm5qne
WcrM+NpXO9SoDgQnNHBO4eVJQz0AMAWx5o9TLg==
-----END CERTIFICATE-----
PEMEOF
cat > "$TMP/certs/tlscli.pem" <<'PEMEOF'
-----BEGIN CERTIFICATE-----
MIIBmTCCAUCgAwIBAgICcAMwCgYIKoZIzj0EAwIwLDEVMBMGA1UEAwwMQXVydW0g
VExTIENBMRMwEQYDVQQKDApBdXJ1bSBUZXN0MB4XDTI2MDEwMTAwMDAwMFoXDTM2
MDEwMTAwMDAwMFowLjEXMBUGA1UEAwwOY2xpZW50LmV4YW1wbGUxEzARBgNVBAoM
CkF1cnVtIFRlc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAQQTvnNJvH7YFb8
4aPQ2rgyIrx1XKoj3KwB/BpJ6UCtPEfuA20/CH2J/gXHDuOey/atCtBmPKiyNlIv
2fZ2UYG4o1AwTjAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDATBgNVHSUE
DDAKBggrBgEFBQcDAjAZBgNVHREEEjAQgg5jbGllbnQuZXhhbXBsZTAKBggqhkjO
PQQDAgNHADBEAiAu1/fgtKNRBtZJvtZu3IqLsaMst+bRW29tX4xgXpwKOQIgMI1Z
fqdJ/rIfmP/4hc4u7jppKePTkBGF7sSwR+MlZH8=
-----END CERTIFICATE-----
PEMEOF
cat > "$TMP/certs/tlssrvkey.pem" <<'PEMEOF'
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgvPS7dPO8HJT+dnMm
V3fUzeQjctLlp5lQPFJtHAnu3OuhRANCAAR07FsqWaBwvGPo7wx4Fl7pimrOWA1j
smmIVkBo46iEaaD/FpxuZod/kLBzFCGiI4sV+txMWw92yVuWSnDFhyC7
-----END PRIVATE KEY-----
PEMEOF
cat > "$TMP/certs/tlsclikey.pem" <<'PEMEOF'
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgy5ggUJLLoLYZlsds
oU0nVjQBYMN7nm7Wtlp5f/Xb16uhRANCAAQQTvnNJvH7YFb84aPQ2rgyIrx1XKoj
3KwB/BpJ6UCtPEfuA20/CH2J/gXHDuOey/atCtBmPKiyNlIv2fZ2UYG4
-----END PRIVATE KEY-----
PEMEOF
cat > "$TMP/certs/tlssrvkey_sec1.pem" <<'PEMEOF'
-----BEGIN EC PRIVATE KEY-----
MHcCAQEEILz0u3TzvByU/nZzJld31M3kI3LS5aeZUDxSbRwJ7tzroAoGCCqGSM49
AwEHoUQDQgAEdOxbKlmgcLxj6O8MeBZe6YpqzlgNY7JpiFZAaOOohGmg/xacbmaH
f5CwcxQhoiOLFfrcTFsPdslblkpwxYcguw==
-----END EC PRIVATE KEY-----
PEMEOF

cat > "$TMP/z.lyx" <<'LYXEOF'
unit main;
import std.io;
import std.string;
import std.alloc;
import std.fs;
import std.crypto.der;
import std.crypto.x509;
import std.crypto.pkey;
import std.net.tls13;
import std.net.tls_config;

fn ladeDer(pfad: pchar, label: pchar, derOut: int64): int64 {
  var pem: int64 := alloc(8192);
  var n: int64 := ReadFile(pfad, pem as pchar, 8191);
  if (n <= 0) { return -1; }
  return PemDekodiere(pem, n, label as int64, StrLen(label), derOut, 4096);
}

// Ein Handschlag zwischen zwei Zustaenden. `mitschnitt` != 0 heisst: jedes
// Byte, das der CLIENT sendet, wird dort angehaengt (Laenge in
// mitschnittLen). Das ist die Grundlage fuer die Wiederholung in Fall 3 --
// wiederholt wird, was auf der Leitung war, nicht ein neu gebauter Flug.
fn handschlag(sv: int64, cl: int64, mitschnitt: int64, mitLen: int64): int64 {
  var puf: int64 := alloc(32768);
  var runden: int64 := 0;
  while (runden < 60) {
    var rcC: int64 := TlsSchritt(cl);
    if (rcC < 0) { free(puf, 32768); return rcC; }
    var n: int64 := TlsAusgabe(cl, puf, 32768);
    if (n > 0) {
      if (mitschnitt != 0) {
        var m0: int64 := peek64(mitLen);
        var k: int64 := 0;
        while (k < n) { poke8(mitschnitt + m0 + k, peek8(puf + k)); k := k + 1; }
        poke64(mitLen, m0 + n);
      }
      TlsFuetter(sv, puf, n);
    }
    var rcS: int64 := TlsSchritt(sv);
    if (rcS < 0) { free(puf, 32768); return rcS; }
    var m: int64 := TlsAusgabe(sv, puf, 32768);
    if (m > 0) { TlsFuetter(cl, puf, m); }
    if (TlsFertig(cl) && TlsFertig(sv)) {
      // EINE Runde weiter: das NewSessionTicket geht unmittelbar nach dem
      // Client-Finished hinaus, und der Client sieht es erst, wenn ihn etwas
      // dazu bringt. Ohne das meldet der Test 0 Tickets -- ein Messfehler,
      // kein Defekt (derselbe Fall steht in tls_wiederaufnahme_test.sh).
      var m2: int64 := TlsAusgabe(sv, puf, 32768);
      if (m2 > 0) { TlsFuetter(cl, puf, m2); }
      var leer: int64 := alloc(256);
      TlsSchritt(cl);
      TlsLese(cl, leer, 256);
      free(leer, 256);
      free(puf, 32768);
      return 0;
    }
    if (n == 0 && m == 0) { free(puf, 32768); return 0 - 99; }
    runden := runden + 1;
  }
  free(puf, 32768);
  return 0 - 98;
}

// Die Byte des Clients aus dem Mitschnitt in einen frischen Server geben und
// ihn so weit treiben, wie er kommt. Rueckgabe: der letzte Schrittwert.
fn einspielen(sv: int64, mitschnitt: int64, laenge: int64): int64 {
  var puf: int64 := alloc(32768);
  TlsFuetter(sv, mitschnitt, laenge);
  var rc: int64 := 0;
  var runden: int64 := 0;
  while (runden < 20) {
    rc := TlsSchritt(sv);
    if (rc < 0) { free(puf, 32768); return rc; }
    var m: int64 := TlsAusgabe(sv, puf, 32768);
    if (m <= 0 && rc != 0) { free(puf, 32768); return rc; }
    runden := runden + 1;
  }
  free(puf, 32768);
  return rc;
}

// Ein Ticket aus `quelle` in `ziel` uebertragen -- so nimmt eine Anwendung
// eine Sitzung in einer NEUEN Verbindung wieder auf. Die fruehe Obergrenze
// gehoert mit: ohne sie ist das Ticket brauchbar und 0-RTT trotzdem aus.
fn ticketUebertragen(ziel: int64, quelle: int64): bool {
  var tkt: int64 := alloc(256);
  var psk: int64 := alloc(64);
  var tl: int64 := TlsTicketRoh(quelle, tkt, 256);
  var hl: int64 := TlsTicketPsk(quelle, psk, 64);
  if (tl <= 0 || hl <= 0) { return false; }
  if (!TlsTicketEinsetzen(ziel, tkt, tl, psk, hl, TlsTicketSuite(quelle),
                          TlsTicketAgeAdd(quelle), TlsTicketZeit(quelle))) {
    return false;
  }
  TlsTicketFruehMaxEinsetzen(ziel, TlsTicketFruehMax(quelle));
  return true;
}

fn main(): int64 {
  var basis: pchar := "CERTDIRMARKER"c;
  var dCa: int64 := alloc(4096);  var lCa  := ladeDer(StrConcat(basis, "/tlsca.pem"c), "CERTIFICATE"c, dCa);
  var dSrv: int64 := alloc(4096); var lSrv := ladeDer(StrConcat(basis, "/tlssrv.pem"c), "CERTIFICATE"c, dSrv);
  var dSk: int64 := alloc(4096);  var lSk  := ladeDer(StrConcat(basis, "/tlssrvkey.pem"c), "PRIVATE KEY"c, dSk);
  if (lCa <= 0 || lSrv <= 0 || lSk <= 0) { PrintLn("LADEFEHLER"); return 1; }

  var kette: int64 := alloc(16); poke64(kette, dSrv); poke64(kette + 8, lSrv);
  var trust: int64 := alloc(16); poke64(trust, dCa);  poke64(trust + 8, lCa);

  var host: pchar := "nexus.example"c;
  var jetzt: int64 := 1800000000;

  // Ticketschluessel: 32 Byte, hier fest, damit der Lauf wiederholbar ist.
  var tkkey: int64 := alloc(32);
  var i: int64 := 0;
  while (i < 32) { poke8(tkkey + i, (i * 7 + 3) & 255); i := i + 1; }

  // Wiederholungsschutz: Speicher kommt von HIER, nicht aus der Unit.
  var arKap: int64 := 64;
  var ar1: int64 := alloc(arKap * TlsArSlotGroesse());
  var ar2: int64 := alloc(arKap * TlsArSlotGroesse());

  var cfgS: int64 := alloc(TlsConfigGroesse());
  var cfgC: int64 := alloc(TlsConfigGroesse());
  TlsConfigNeu(cfgS, 1);
  TlsConfigKette(cfgS, kette, 1, dSk, lSk);
  TlsConfigZeit(cfgS, jetzt);
  TlsConfigTicketSchluessel(cfgS, 1, tkkey, 7200);
  TlsConfigFrueheDaten(cfgS, 4096);
  TlsConfigWiederholungsschutz(cfgS, ar1, arKap, 600);
  TlsConfigNeu(cfgC, 2);
  TlsConfigTrust(cfgC, trust, 1);
  TlsConfigHost(cfgC, host as int64, StrLen(host));
  TlsConfigZeit(cfgC, jetzt);
  TlsConfigFrueheDaten(cfgC, 4096);

  // ── Fall 1: voller Handschlag, Ticket einsammeln ─────────────────────
  var sv1: int64 := TlsNeu(cfgS);
  var cl1: int64 := TlsNeu(cfgC);
  Print("voll "); PrintInt(handschlag(sv1, cl1, 0, 0)); PrintLn("");
  // Das NewSessionTicket kommt NACH dem Handschlag; ein Schritt holt es.
  var puf: int64 := alloc(32768);
  // TlsTicketDa liefert die LAENGE des Tickets, nicht 1/0.
  Print("ticket-da-positiv "); PrintInt(TlsTicketDa(cl1) > 0); PrintLn("");
  Print("ticket-fruehmax "); PrintInt(TlsTicketFruehMax(cl1)); PrintLn("");

  // Ticket in eine zweite Client-Vorgabe uebernehmen.
  var tbuf: int64 := alloc(256);
  var tlen: int64 := TlsTicketRoh(cl1, tbuf, 256);
  Print("ticket-laenge-positiv "); PrintInt(tlen > 0); PrintLn("");

  // ── Fall 2: 0-RTT angenommen ─────────────────────────────────────────
  var mitschnitt: int64 := alloc(16384);
  var mitLen: int64 := alloc(8);
  poke64(mitLen, 0);

  var sv2: int64 := TlsNeu(cfgS);
  var cl2: int64 := TlsNeu(cfgC);
  ticketUebertragen(cl2, cl1);
  // Erster Schritt: ClientHello hinaus, fruehe Schluessel stehen.
  TlsSchritt(cl2);
  Print("client-zustand-angeboten "); PrintInt(TlsFruehZustand(cl2)); PrintLn("");
  var frage: pchar := "GET /frueh HTTP/1.0\r\n\r\n"c;
  var gesendet: int64 := TlsSchreibeFrueh(cl2, frage as int64, StrLen(frage));
  Print("frueh-gesendet "); PrintInt(gesendet); PrintLn("");
  // Jetzt beides laufen lassen -- der Mitschnitt faengt alles vom Client,
  // einschliesslich ClientHello und der fruehen Records.
  var n2: int64 := TlsAusgabe(cl2, puf, 32768);
  if (n2 > 0) {
    var k2: int64 := 0;
    while (k2 < n2) { poke8(mitschnitt + k2, peek8(puf + k2)); k2 := k2 + 1; }
    poke64(mitLen, n2);
    TlsFuetter(sv2, puf, n2);
  }
  TlsSchritt(sv2);
  Print("server-angenommen "); PrintInt(TlsFruehAngenommen(sv2)); PrintLn("");
  var ein: int64 := alloc(4096);
  var gel: int64 := TlsLese(sv2, ein, 4096);
  Print("server-frueh-gelesen "); PrintInt(gel); Print(" ");
  var z: int64 := 0;
  while (z < gel) { if (peek8(ein + z) >= 32) { PrintChar(peek8(ein + z)); } z := z + 1; }
  PrintLn("");
  Print("server-letzte-lese-frueh "); PrintInt(TlsLetzteLeseFrueh(sv2)); PrintLn("");
  // Rest des Handschlags
  var rest: int64 := handschlag(sv2, cl2, mitschnitt, mitLen);
  Print("rest-handschlag "); PrintInt(rest); PrintLn("");
  Print("client-angenommen "); PrintInt(TlsFruehAngenommen(cl2)); PrintLn("");
  Print("mitschnitt-laenge-positiv "); PrintInt(peek64(mitLen) > 0); PrintLn("");

  // ── Fall 3: WIEDERHOLUNG gegen frischen Server, gleicher Schutz ──────
  var sv3: int64 := TlsNeu(cfgS);
  var rc3: int64 := einspielen(sv3, mitschnitt, peek64(mitLen));
  Print("wiederholung-zustand "); PrintInt(TlsFruehZustand(sv3)); PrintLn("");
  Print("wiederholung-frueh-gelesen "); PrintInt(TlsFruehGelesen(sv3)); PrintLn("");
  Print("wiederholung-verworfen-positiv "); PrintInt(TlsVerworfeneRecords(sv3) > 0); PrintLn("");

  // ── Fall 4: derselbe Flug, Server OHNE Wiederholungsschutz ───────────
  var cfgS4: int64 := alloc(TlsConfigGroesse());
  TlsConfigNeu(cfgS4, 1);
  TlsConfigKette(cfgS4, kette, 1, dSk, lSk);
  TlsConfigZeit(cfgS4, jetzt);
  TlsConfigTicketSchluessel(cfgS4, 1, tkkey, 7200);
  TlsConfigFrueheDaten(cfgS4, 4096);     // erlaubt, aber KEIN Schutz
  var sv4: int64 := TlsNeu(cfgS4);
  einspielen(sv4, mitschnitt, peek64(mitLen));
  Print("ohne-schutz-zustand "); PrintInt(TlsFruehZustand(sv4)); PrintLn("");
  Print("ohne-schutz-frueh-gelesen "); PrintInt(TlsFruehGelesen(sv4)); PrintLn("");

  // ── Fall 5: Server erlaubt keine fruehen Daten ───────────────────────
  var cfgS5: int64 := alloc(TlsConfigGroesse());
  TlsConfigNeu(cfgS5, 1);
  TlsConfigKette(cfgS5, kette, 1, dSk, lSk);
  TlsConfigZeit(cfgS5, jetzt);
  TlsConfigTicketSchluessel(cfgS5, 1, tkkey, 7200);
  var sv5: int64 := TlsNeu(cfgS5);
  var cl5: int64 := TlsNeu(cfgC);
  ticketUebertragen(cl5, cl1);
  TlsSchritt(cl5);
  TlsSchreibeFrueh(cl5, frage as int64, StrLen(frage));
  var rc5: int64 := handschlag(sv5, cl5, 0, 0);
  Print("abgelehnt-handschlag "); PrintInt(rc5); PrintLn("");
  Print("abgelehnt-client-zustand "); PrintInt(TlsFruehZustand(cl5)); PrintLn("");
  Print("abgelehnt-server-frueh-gelesen "); PrintInt(TlsFruehGelesen(sv5)); PrintLn("");
  Print("abgelehnt-verworfen-positiv "); PrintInt(TlsVerworfeneRecords(sv5) > 0); PrintLn("");
  // ── Fall 6: mehr fruehe Byte als der Server erlaubt ──────────────────
  //
  // Das Ticket nennt 4096, der Server erlaubt jetzt nur 8. Gezaehlt wird,
  // was ANKOMMT (§4.2.10) -- die Angabe im Ticket ist die von DAMALS, und
  // ein Server, der ihr folgt statt seiner heutigen Vorgabe, laesst sich
  // ueber ein altes Ticket zu beliebig vielen fruehen Byte bringen.
  var ar6: int64 := alloc(arKap * TlsArSlotGroesse());
  var cfgS6: int64 := alloc(TlsConfigGroesse());
  TlsConfigNeu(cfgS6, 1);
  TlsConfigKette(cfgS6, kette, 1, dSk, lSk);
  TlsConfigZeit(cfgS6, jetzt);
  TlsConfigTicketSchluessel(cfgS6, 1, tkkey, 7200);
  TlsConfigFrueheDaten(cfgS6, 8);
  TlsConfigWiederholungsschutz(cfgS6, ar6, arKap, 600);
  var sv6: int64 := TlsNeu(cfgS6);
  var cl6: int64 := TlsNeu(cfgC);
  ticketUebertragen(cl6, cl1);
  TlsSchritt(cl6);
  TlsSchreibeFrueh(cl6, frage as int64, StrLen(frage));
  var rc6: int64 := handschlag(sv6, cl6, 0, 0);
  Print("ueberschritten-handschlag "); PrintInt(rc6); PrintLn("");
  Print("ueberschritten-frueh-gelesen "); PrintInt(TlsFruehGelesen(sv6)); PrintLn("");

  // Nach dem Handschlag muss der normale Weg tragen.
  if (rc5 == 0) {
    TlsSchreibe(cl5, frage as int64, StrLen(frage));
    var n5: int64 := TlsAusgabe(cl5, puf, 32768);
    if (n5 > 0) { TlsFuetter(sv5, puf, n5); }
    TlsSchritt(sv5);
    var g5: int64 := TlsLese(sv5, ein, 4096);
    Print("abgelehnt-dann-normal "); PrintInt(g5); Print(" frueh "); PrintInt(TlsLetzteLeseFrueh(sv5)); PrintLn("");
  }
  return 0;
}
LYXEOF
sed -i "s|CERTDIRMARKER|$TMP/certs|" "$TMP/z.lyx"

if ! ( cd "$ROOT" && timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/z.lyx" -o "$TMP/z" ) >"$TMP/log" 2>&1; then
  echo "FAIL uebersetzt nicht:"; grep -m5 -i error "$TMP/log"; exit 1
fi
[ -x "$TMP/z" ] || { echo "FAIL kein Erzeugnis (#1682)"; exit 1; }
( ulimit -v 4000000 -c 0; "$TMP/z" ) > "$TMP/aus.txt" 2>&1
RC=$?
sed 's/^/    /' "$TMP/aus.txt"

P=0; F=0
ok()  { echo "PASS $1"; P=$((P+1)); }
bad() { echo "FAIL $1${2:+ -- $2}"; F=$((F+1)); }
[ "$RC" = 0 ] || bad "Lauf" "Exitcode $RC"
hat() {  # name, erwarteter Wert
  ist="$(grep -m1 "^$1 " "$TMP/aus.txt" | awk '{print $2}')"
  if [ "${ist:-fehlt}" = "$2" ]; then ok "$1 -> $2"; else bad "$1" "ist ${ist:-fehlt}, soll $2"; fi
}

hat voll 0
hat ticket-da-positiv 1
hat ticket-fruehmax 4096
hat ticket-laenge-positiv 1
hat client-zustand-angeboten 1
hat frueh-gesendet 23
hat server-angenommen 1
hat server-frueh-gelesen 23
hat server-letzte-lese-frueh 1
hat rest-handschlag 0
hat client-angenommen 1
# Fall 3: der wiederholte Flug darf KEINE fruehen Daten liefern.
hat wiederholung-zustand 3
hat wiederholung-frueh-gelesen 0
# Die fruehen Records des Angreifers mussten verworfen werden -- das ist der
# Weg aus §4.2.10 und zugleich der Beleg, dass der Flug wirklich ankam und
# nicht etwa vorher schon scheiterte.
hat wiederholung-verworfen-positiv 1
# Fall 4: ohne Wiederholungsschutz bleibt 0-RTT aus, obwohl erlaubt.
hat ohne-schutz-zustand 3
hat ohne-schutz-frueh-gelesen 0
# Fall 5: Ablehnung beschaedigt den Handschlag nicht.
hat abgelehnt-handschlag 0
hat abgelehnt-client-zustand 3
hat abgelehnt-server-frueh-gelesen 0
hat abgelehnt-verworfen-positiv 1
# Fall 6: zu viele fruehe Byte beenden die Verbindung mit einem
# ABLAUFfehler (-9), nicht mit einem Tagfehler und nicht still.
hat ueberschritten-handschlag -9
hat ueberschritten-frueh-gelesen 0

echo "--- $P PASS, $F FAIL"
[ "$F" -eq 0 ] || exit 1
echo "ALL PASS"
