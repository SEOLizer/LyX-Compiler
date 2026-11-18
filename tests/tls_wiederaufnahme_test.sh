#!/usr/bin/env bash
# tests/tls_wiederaufnahme_test.sh — #2577: Wiederaufnahme über PSK und
# NewSessionTicket (RFC 8446 §4.2.11, §4.6.1, §7.1).
#
# Geprüft wird die WIRKUNG, nicht das Vorhandensein. Die entscheidende
# Messung ist die letzte Zeile der Tabelle unten: im Wiederaufnahmeflug darf
# **kein Certificate und kein CertificateVerify** stehen (§4.1.1 — der PSK
# IST die Authentifizierung). Ohne diese Messung wäre der Beleg nur „es lief
# durch", und ein schneller voller Handschlag sähe genauso aus.
#
#   res_master beidseitig           die Wurzel jeder Wiederaufnahme muss auf
#                                   beiden Seiten bitgleich sein
#   Ticket siegeln/öffnen           78 Byte, AES-256-GCM
#   NewSessionTicket               geht hinaus, kommt an, PSK abgeleitet
#   PSK beidseitig + unabhängig     nicht nur „gleich", sondern gleich dem,
#                                   was eine eigene Rechnung ergibt
#   Wiederaufnahme                 läuft, Nutzdaten fließen
#   KEIN CertificateVerify          das Merkmal, mit Gegenprobe im vollen Fall
#
# ── Die Gegenproben, und warum jede einzelne nötig ist ─────────────────────
#
#   gekipptes Byte im Ticket   -> VOLLER Handschlag, KEIN Abbruch.
#                                 §4.2.11 erlaubt dem Server, ein
#                                 unbrauchbares Ticket zu ignorieren; ein
#                                 abgelaufenes Ticket ist Alltag.
#   falscher PSK bei gültigem
#   Ticket                     -> ABBRUCH (§4.2.11.2 "MUST abort").
#                                 Das ist der Unterschied: wer ein gültiges
#                                 Ticket hat und den PSK nicht kennt, greift
#                                 an.
#   fremde Ticketgeneration    -> abgewiesen, obwohl das Byte im Klartext
#                                 steht: es ist AAD, also unveränderbar.
#   abgelaufen / aus der
#   Zukunft                    -> abgewiesen, nach der Uhr des SERVERS; die
#                                 Altersangabe des Clients ist seine
#                                 Behauptung.
#   fremder Ticketschlüssel    -> abgewiesen (Tag scheitert).
#
# Zwei Fehler, die beim Bauen nur der LAUF gefunden hat, und die hier
# bewacht werden:
#   1. Der Server siegelte das resumption_master_secret statt des daraus
#      abgeleiteten PSK. Der Client rechnet
#      Expand(res_master, "resumption", nonce); mit dem Rohgeheimnis stimmt
#      der Binder nie.
#   2. Namensüberschattung: der Parameter `nonce` (ticket_nonce) wurde von
#      der lokalen AES-GCM-Nonce verdeckt, und der PSK entstand aus einem
#      Zufallsbyte. Beides int64 — der Compiler sagt dazu nichts.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

if ! command -v openssl >/dev/null 2>&1; then
  echo "SKIP openssl fehlt (die Kette wird damit erzeugt)"; exit 0
fi

mkdir -p "$TMP/certs"
( cd "$TMP/certs"
  openssl ecparam -name prime256v1 -genkey -noout -out ca.key
  openssl req -x509 -new -key ca.key -sha256 -days 3650 \
    -subj "/CN=Aurum PSK Test-CA" -out ca.pem \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign"
  openssl ecparam -name prime256v1 -genkey -noout -out leaf.key
  openssl req -new -key leaf.key -subj "/CN=nexus.example" -out leaf.csr
  printf 'subjectAltName=DNS:nexus.example\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nbasicConstraints=critical,CA:FALSE\n' > ext.cnf
  openssl x509 -req -in leaf.csr -CA ca.pem -CAkey ca.key -sha256 -days 3650 \
    -extfile ext.cnf -out leaf.pem
  openssl pkcs8 -topk8 -nocrypt -in leaf.key -out leafkey.pem
) > "$TMP/openssl.log" 2>&1
for f in ca.pem leaf.pem leafkey.pem; do
  [ -s "$TMP/certs/$f" ] || { echo "SKIP openssl erzeugte $f nicht"; exit 0; }
done

cat > "$TMP/w.lyx" <<'LYXEOF'
import std.io;
import std.fs;
import std.alloc;
import std.crypto.der;
import std.crypto.hkdf;
import std.net.tls13;
import std.net.tls_config;

fn ladeDer(pfad: pchar, etikett: pchar, out: int64): int64 {
  var pem: int64 := alloc(16384);
  var n: int64 := ReadFile(pfad, pem as pchar, 16383);
  if (n <= 0) { return -1; }
  return PemDekodiere(pem, n, etikett as int64, StrLen(etikett), out, 8192);
}

fn handschlag(sv: int64, cl: int64): int64 {
  var puf: int64 := alloc(49152);
  var runden: int64 := 0;
  while (runden < 40) {
    var rcC: int64 := TlsSchritt(cl);
    if (rcC < 0) { free(puf, 49152); return rcC; }
    var n: int64 := TlsAusgabe(cl, puf, 49152);
    if (n > 0) {
      var f1: int64 := TlsFuetter(sv, puf, n);
      if (f1 < 0) { free(puf, 49152); return f1; }
    }
    var rcS: int64 := TlsSchritt(sv);
    if (rcS < 0) { free(puf, 49152); return rcS; }
    var m: int64 := TlsAusgabe(sv, puf, 49152);
    if (m > 0) {
      var f2: int64 := TlsFuetter(cl, puf, m);
      if (f2 < 0) { free(puf, 49152); return f2; }
    }
    if (TlsFertig(cl) && TlsFertig(sv)) {
      // EINE Runde weiter: der Server schickt das NewSessionTicket
      // unmittelbar nach dem Client-Finished, und der Client sieht es erst,
      // wenn ihn etwas dazu bringt. Ohne diese Runde meldet der Test 0
      // Tickets — ein Messfehler, kein Defekt (so beim Bauen passiert).
      var m2: int64 := TlsAusgabe(sv, puf, 49152);
      if (m2 > 0) { TlsFuetter(cl, puf, m2); }
      // Anstossen, damit wartende Nachhandschlagnachrichten abgearbeitet
      // werden (NewSessionTicket). TlsLese tut das auch, wenn es keine
      // Anwendungsdaten gibt — der Rueckgabewert interessiert hier nicht.
      var leer: int64 := alloc(256);
      TlsSchritt(cl);
      TlsLese(cl, leer, 256);
      free(leer, 256);
      free(puf, 49152);
      return 0;
    }
    if (n == 0 && m == 0) { free(puf, 49152); return 0 - 99; }
    runden := runden + 1;
  }
  free(puf, 49152);
  return 0 - 98;
}

fn gleich(a: int64, b: int64, n: int64): int64 {
  var acc: int64 := 0;
  var i: int64 := 0;
  while (i < n) {
    acc := acc | ((peek8(a + i) & 255) ^ (peek8(b + i) & 255));
    i := i + 1;
  }
  if (acc == 0) { return 1; }
  return 0;
}

fn main(): int64 {
  var basis: pchar := "CERTDIRMARKER"c;
  var dCa: int64 := alloc(8192);
  var dLeaf: int64 := alloc(8192);
  var dKey: int64 := alloc(8192);
  var lCa: int64 := ladeDer(StrConcat(basis, "/ca.pem"c), "CERTIFICATE"c, dCa);
  var lLeaf: int64 := ladeDer(StrConcat(basis, "/leaf.pem"c), "CERTIFICATE"c, dLeaf);
  var lKey: int64 := ladeDer(StrConcat(basis, "/leafkey.pem"c), "PRIVATE KEY"c, dKey);
  if (lCa <= 0 || lLeaf <= 0 || lKey <= 0) { PrintStrLn("LADEFEHLER"c); return 1; }

  var kette: int64 := alloc(16);
  poke64(kette, dLeaf); poke64(kette + 8, lLeaf);
  var trust: int64 := alloc(16);
  poke64(trust, dCa); poke64(trust + 8, lCa);
  var host: pchar := "nexus.example"c;
  var jetzt: int64 := 1800000000;

  var cfgS: int64 := alloc(TlsConfigGroesse());
  TlsConfigNeu(cfgS, 1);
  TlsConfigKette(cfgS, kette, 1, dKey, lKey);
  TlsConfigZeit(cfgS, jetzt);
  var tkey: int64 := alloc(32);
  var i: int64 := 0;
  while (i < 32) { poke8(tkey + i, 0x40 + i); i := i + 1; }
  if (!TlsConfigTicketSchluessel(cfgS, 1, tkey, 86400)) {
    PrintStrLn("FAIL Ticketschluessel abgelehnt"c);
    return 1;
  }

  var cfgC: int64 := alloc(TlsConfigGroesse());
  TlsConfigNeu(cfgC, 2);
  TlsConfigTrust(cfgC, trust, 1);
  TlsConfigHost(cfgC, host as int64, StrLen(host));
  TlsConfigZeit(cfgC, jetzt);

  // ── Erster Handschlag: voll, mit Ticket ─────────────────────────────────
  var sv: int64 := TlsNeu(cfgS);
  var cl: int64 := TlsNeu(cfgC);
  Print("voll-handschlag "c); PrintIntLn(handschlag(sv, cl));
  Print("voll-cert "c); PrintIntLn(TlsGesendet(sv, 11));
  Print("voll-cv "c); PrintIntLn(TlsGesendet(sv, 15));
  Print("voll-nst "c); PrintIntLn(TlsGesendet(sv, 4));

  var gs: int64 := alloc(64);
  var gc: int64 := alloc(64);
  var ls: int64 := TlsWiederaufnahmeGeheimnis(sv, gs, 64);
  var lc: int64 := TlsWiederaufnahmeGeheimnis(cl, gc, 64);
  Print("res-laenge "c); PrintIntLn(ls);
  Print("res-beidseitig-gleich "c);
  if (ls > 0 && ls == lc) { PrintIntLn(gleich(gs, gc, ls)); } else { PrintIntLn(0); }

  Print("ticket-beim-client "c); PrintIntLn(TlsTicketDa(cl));
  var psk: int64 := alloc(64);
  var pl: int64 := TlsTicketPsk(cl, psk, 64);
  Print("psk-laenge "c); PrintIntLn(pl);

  // UNABHAENGIG nachrechnen: PSK = Expand(res_master, "resumption", 0x00)
  var eigen: int64 := alloc(64);
  var nz: int64 := alloc(8);
  poke8(nz, 0);
  var okE: bool := HkdfExpandLabel(ls, gs, ls, "resumption"c as int64, 10,
                                   nz, 1, eigen, ls);
  Print("psk-gegen-eigene-rechnung "c);
  if (okE && pl == ls) { PrintIntLn(gleich(eigen, psk, ls)); } else { PrintIntLn(0); }

  // ── Zweiter Handschlag: Wiederaufnahme ──────────────────────────────────
  var tRoh: int64 := alloc(TlsTicketMax());
  var tRl: int64 := TlsTicketRoh(cl, tRoh, TlsTicketMax());
  var wsv: int64 := TlsNeu(cfgS);
  var wcl: int64 := TlsNeu(cfgC);
  Print("eingesetzt "c);
  if (TlsTicketEinsetzen(wcl, tRoh, tRl, psk, pl, TlsTicketSuite(cl),
                         TlsTicketAgeAdd(cl), TlsTicketZeit(cl))) {
    PrintIntLn(1);
  } else { PrintIntLn(0); }
  Print("wieder-handschlag "c); PrintIntLn(handschlag(wsv, wcl));
  Print("wieder-server "c); PrintIntLn(TlsWiederaufgenommen(wsv));
  Print("wieder-client "c); PrintIntLn(TlsWiederaufgenommen(wcl));
  Print("wieder-cert "c); PrintIntLn(TlsGesendet(wsv, 11));
  Print("wieder-cv "c); PrintIntLn(TlsGesendet(wsv, 15));

  var puf: int64 := alloc(49152);
  var ein: int64 := alloc(8192);
  var txt: pchar := "wieder da"c;
  TlsSchreibe(wcl, txt as int64, 9);
  var n1: int64 := TlsAusgabe(wcl, puf, 49152);
  if (n1 > 0) { TlsFuetter(wsv, puf, n1); }
  Print("wieder-nutzdaten "c); PrintIntLn(TlsLese(wsv, ein, 8192));

  // ── Gegenproben ─────────────────────────────────────────────────────────
  // Gekipptes Ticket: VOLLER Handschlag (0), kein Abbruch.
  poke8(tRoh + 30, (peek8(tRoh + 30) ^ 1) & 255);
  var gsv: int64 := TlsNeu(cfgS);
  var gcl: int64 := TlsNeu(cfgC);
  TlsTicketEinsetzen(gcl, tRoh, tRl, psk, pl, TlsTicketSuite(cl),
                     TlsTicketAgeAdd(cl), TlsTicketZeit(cl));
  Print("gegen-gekippt-rc "c); PrintIntLn(handschlag(gsv, gcl));
  Print("gegen-gekippt-psk "c); PrintIntLn(TlsWiederaufgenommen(gsv));
  Print("gegen-gekippt-cv "c); PrintIntLn(TlsGesendet(gsv, 15));
  poke8(tRoh + 30, (peek8(tRoh + 30) ^ 1) & 255);

  // Falscher PSK bei GUELTIGEM Ticket: ABBRUCH.
  poke8(psk, (peek8(psk) ^ 0xFF) & 255);
  var fsv: int64 := TlsNeu(cfgS);
  var fcl: int64 := TlsNeu(cfgC);
  TlsTicketEinsetzen(fcl, tRoh, tRl, psk, pl, TlsTicketSuite(cl),
                     TlsTicketAgeAdd(cl), TlsTicketZeit(cl));
  Print("gegen-falscher-psk "c); PrintIntLn(handschlag(fsv, fcl));
  poke8(psk, (peek8(psk) ^ 0xFF) & 255);

  // Ticketebene: fuenf Gegenproben direkt an ticketOeffnen.
  var sBuf: int64 := alloc(8);
  var hBuf: int64 := alloc(8);
  var secBuf: int64 := alloc(64);
  Print("tkt-gut "c);
  PrintIntLn(TlsTicketOeffnen(sv, tRoh, tRl, jetzt, sBuf, hBuf, secBuf));
  poke8(tRoh + 1, 2);
  Print("tkt-fremde-generation "c);
  PrintIntLn(TlsTicketOeffnen(sv, tRoh, tRl, jetzt, sBuf, hBuf, secBuf));
  poke8(tRoh + 1, 1);
  Print("tkt-abgelaufen "c);
  PrintIntLn(TlsTicketOeffnen(sv, tRoh, tRl, jetzt + 86401, sBuf, hBuf, secBuf));
  Print("tkt-zukunft "c);
  PrintIntLn(TlsTicketOeffnen(sv, tRoh, tRl, jetzt - 10, sBuf, hBuf, secBuf));
  var cfgF: int64 := alloc(TlsConfigGroesse());
  TlsConfigNeu(cfgF, 1);
  TlsConfigKette(cfgF, kette, 1, dKey, lKey);
  TlsConfigZeit(cfgF, jetzt);
  var tkey2: int64 := alloc(32);
  i := 0;
  while (i < 32) { poke8(tkey2 + i, 0x99); i := i + 1; }
  TlsConfigTicketSchluessel(cfgF, 1, tkey2, 86400);
  var fsv2: int64 := TlsNeu(cfgF);
  Print("tkt-fremder-schluessel "c);
  PrintIntLn(TlsTicketOeffnen(fsv2, tRoh, tRl, jetzt, sBuf, hBuf, secBuf));

  // Ohne Ticketschluessel gibt der Server KEIN Ticket aus — und das ist
  // kein Fehler, sondern ein Server ohne Wiederaufnahme.
  var cfgO: int64 := alloc(TlsConfigGroesse());
  TlsConfigNeu(cfgO, 1);
  TlsConfigKette(cfgO, kette, 1, dKey, lKey);
  TlsConfigZeit(cfgO, jetzt);
  var osv: int64 := TlsNeu(cfgO);
  var ocl: int64 := TlsNeu(cfgC);
  Print("ohne-schluessel-rc "c); PrintIntLn(handschlag(osv, ocl));
  Print("ohne-schluessel-nst "c); PrintIntLn(TlsGesendet(osv, 4));
  Print("ohne-schluessel-ticket "c); PrintIntLn(TlsTicketDa(ocl));
  return 0;
}
LYXEOF
sed -i "s#CERTDIRMARKER#$TMP/certs#" "$TMP/w.lyx"

cd "$ROOT"
if ! timeout 900 "$LYXC" "$TMP/w.lyx" --std-path=. -o "$TMP/w" > "$TMP/build.log" 2>&1; then
  echo "FAIL: der Prueflaeufer uebersetzt nicht"; tail -20 "$TMP/build.log"; exit 1
fi
( ulimit -v 6000000 -c 0; timeout 600 "$TMP/w" > "$TMP/out.txt" 2>&1 )
rc=$?
cat "$TMP/out.txt"
if [ "$rc" -ge 128 ]; then echo "FAIL: Lauf abgebrochen (rc=$rc)"; exit 1; fi

hol() { grep -m1 "^$1 " "$TMP/out.txt" | awk '{print $2}'; }
fehler=0
pruef() { # name sollwert beschreibung
  local ist; ist="$(hol "$1")"
  if [ "$ist" = "$2" ]; then echo "PASS $1 = $2 ($3)"
  else echo "FAIL $1: '$ist' statt $2 — $3"; fehler=$((fehler+1)); fi
}

pruef voll-handschlag 0 "voller Handschlag laeuft"
pruef voll-cert 1 "im vollen Flug steht ein Certificate"
pruef voll-cv 1 "und ein CertificateVerify"
pruef voll-nst 1 "der Server gibt genau ein Ticket aus"
pruef res-laenge 32 "resumption_master_secret ist 32 Byte (SHA-256)"
pruef res-beidseitig-gleich 1 "beide Seiten rechnen dasselbe res_master"
pruef ticket-beim-client 78 "das Ticket kommt beim Client an"
pruef psk-laenge 32 "der PSK wird daraus abgeleitet"
pruef psk-gegen-eigene-rechnung 1 "und stimmt mit einer UNABHAENGIGEN Rechnung"
pruef eingesetzt 1 "das Ticket laesst sich in eine neue Verbindung setzen"
pruef wieder-handschlag 0 "die Wiederaufnahme laeuft"
pruef wieder-server 1 "der Server hat den PSK angenommen"
pruef wieder-client 1 "der Client weiss es auch"
pruef wieder-cert 0 "KEIN Certificate im Wiederaufnahmeflug (§4.1.1)"
pruef wieder-cv 0 "KEIN CertificateVerify — das ist das Merkmal"
pruef wieder-nutzdaten 9 "Nutzdaten fliessen danach"
pruef gegen-gekippt-rc 0 "gekipptes Ticket: VOLLER Handschlag, kein Abbruch"
pruef gegen-gekippt-psk 0 "und zwar ohne PSK"
pruef gegen-gekippt-cv 1 "mit Zertifikat, also wirklich voll"
pruef gegen-falscher-psk -7 "falscher Binder bei gueltigem Ticket: ABBRUCH"
pruef tkt-gut 32 "ticketOeffnen nimmt das gute Ticket"
pruef tkt-fremde-generation 0 "fremde Generation abgewiesen (AAD)"
pruef tkt-abgelaufen 0 "abgelaufen abgewiesen"
pruef tkt-zukunft 0 "aus der Zukunft abgewiesen"
pruef tkt-fremder-schluessel 0 "fremder Ticketschluessel abgewiesen"
pruef ohne-schluessel-rc 0 "ohne Ticketschluessel laeuft der Handschlag"
pruef ohne-schluessel-nst 0 "aber es geht KEIN Ticket hinaus"
pruef ohne-schluessel-ticket 0 "und der Client merkt sich keines"

if [ "$fehler" = 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$fehler FAIL"
exit 1
