#!/usr/bin/env bash
# tests/tls12_handschlag_test.sh — #2096 Stufe 2: TLS 1.2 im eigenen
# Programm, zwei Zustaende sprechen ueber Puffer miteinander. Kein Netz, kein
# openssl; der Interop-Nachweis steht in tests/tls12_interop_openssl_test.sh.
#
# Geprueft wird die WIRKUNG, und beide Seiten:
#   - renegotiation_info (RFC 5746) und extended_master_secret (RFC 7627)
#     stehen WIRKLICH im ClientHello und im ServerHello. Die Pruefung laeuft
#     ueber eine Bytesuche in den gesendeten Byte — eine Pruefung am eigenen
#     Zustand waere auch von einer Fassung erfuellt, die das Feld nie sendet.
#   - Handschlag mit x25519 und mit secp256r1, beide Seiten melden
#     dieselbe Suite (0xC02B = 49195, weil das Testzertifikat ECDSA ist)
#   - Anwendungsdaten in beide Richtungen
#   - mTLS: mit Client-Zertifikat Erfolg, ohne eines -6
#   - falscher Hostname, fremde Wurzel: -6
#   - ein gekipptes Byte in der ServerKeyExchange-Signatur: -7
#   - ein gekippter Anwendungsrecord: -5
#
# Jeder Ablehnungsfall hat seinen eigenen Code, damit nicht eine Umsetzung
# durchgeht, die einfach alles abweist.
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

cat > "$TMP/s.lyx" <<'LYXEOF'
unit main;
import std.io;
import std.string;
import std.alloc;
import std.fs;
import std.crypto.der;
import std.crypto.x509;
import std.net.tls_config;
import std.net.tls12;

fn ladeDer(pfad: pchar, label: pchar, derOut: int64): int64 {
  var pem: int64 := alloc(8192);
  var n: int64 := ReadFile(pfad, pem as pchar, 8191);
  if (n <= 0) { return -1; }
  return PemDekodiere(pem, n, label as int64, StrLen(label), derOut, 4096);
}

fn melde(name: pchar, wert: int64): void {
  Print(name); Print(" "); PrintInt(wert); PrintLn("");
}


// Sucht eine Bytefolge in einem Puffer. Fuer die Drahtpruefung: steht die
// Erweiterung WIRKLICH im ClientHello bzw. ServerHello? Eine Pruefung am
// eigenen Zustand (Tls12EMS) wuerde auch von einer Fassung erfuellt, die das
// Feld nie sendet.
fn findeFolge(buf: int64, len: int64, muster: int64, mLen: int64): int64 {
  var i: int64 := 0;
  while (i + mLen <= len) {
    var j: int64 := 0;
    var gleich: int64 := 1;
    while (j < mLen) {
      if (peek8(buf + i + j) != peek8(muster + j)) { gleich := 0; j := mLen; }
      else { j := j + 1; }
    }
    if (gleich == 1) { return i; }
    i := i + 1;
  }
  return -1;
}

fn handschlag(sv: int64, cl: int64): int64 {
  var puf: int64 := alloc(32768);
  var runden: int64 := 0;
  while (runden < 40) {
    var rcC: int64 := Tls12Schritt(cl);
    if (rcC < 0) { free(puf, 32768); return rcC; }
    var n: int64 := Tls12Ausgabe(cl, puf, 32768);
    if (n > 0) { Tls12Fuetter(sv, puf, n); }
    var rcS: int64 := Tls12Schritt(sv);
    if (rcS < 0) { free(puf, 32768); return rcS; }
    var m: int64 := Tls12Ausgabe(sv, puf, 32768);
    if (m > 0) { Tls12Fuetter(cl, puf, m); }
    if (Tls12Fertig(cl) && Tls12Fertig(sv)) { free(puf, 32768); return 0; }
    if (n == 0 && m == 0) { free(puf, 32768); return -99; }
    runden := runden + 1;
  }
  free(puf, 32768);
  return -98;
}

fn traegtDaten(sv: int64, cl: int64): int64 {
  var puf: int64 := alloc(32768);
  var ein: int64 := alloc(4096);
  var hin: pchar := "ping"c;
  var her: pchar := "pong"c;
  var ok: int64 := 1;
  if (Tls12Schreibe(cl, hin as int64, 4) != 4) { ok := 0; }
  var n: int64 := Tls12Ausgabe(cl, puf, 32768);
  Tls12Fuetter(sv, puf, n);
  var g: int64 := Tls12Lese(sv, ein, 4096);
  if (g != 4) { ok := 0; } else {
    if (peek8(ein) != 112 || peek8(ein + 3) != 103) { ok := 0; }
  }
  if (Tls12Schreibe(sv, her as int64, 4) != 4) { ok := 0; }
  n := Tls12Ausgabe(sv, puf, 32768);
  Tls12Fuetter(cl, puf, n);
  g := Tls12Lese(cl, ein, 4096);
  if (g != 4) { ok := 0; }
  free(puf, 32768); free(ein, 4096);
  return ok;
}

fn main(): int64 {
  var basis: pchar := "CERTDIRMARKER"c;
  var dCa: int64 := alloc(4096);  var lCa: int64 := ladeDer(StrConcat(basis, "/tlsca.pem"c), "CERTIFICATE"c, dCa);
  var dSrv: int64 := alloc(4096); var lSrv: int64 := ladeDer(StrConcat(basis, "/tlssrv.pem"c), "CERTIFICATE"c, dSrv);
  var dCli: int64 := alloc(4096); var lCli: int64 := ladeDer(StrConcat(basis, "/tlscli.pem"c), "CERTIFICATE"c, dCli);
  var dSk: int64 := alloc(4096);  var lSk: int64 := ladeDer(StrConcat(basis, "/tlssrvkey.pem"c), "PRIVATE KEY"c, dSk);
  var dCk: int64 := alloc(4096);  var lCk: int64 := ladeDer(StrConcat(basis, "/tlsclikey.pem"c), "PRIVATE KEY"c, dCk);
  if (lCa <= 0 || lSrv <= 0 || lSk <= 0) { PrintLn("LADEFEHLER"); return 1; }

  var kette: int64 := alloc(16);  poke64(kette, dSrv);  poke64(kette + 8, lSrv);
  var kKette: int64 := alloc(16); poke64(kKette, dCli); poke64(kKette + 8, lCli);
  var trust: int64 := alloc(16);  poke64(trust, dCa);   poke64(trust + 8, lCa);

  var host: pchar := "nexus.example"c;
  var alpnS: pchar := "h2,http/1.1"c;
  var alpnC: pchar := "http/1.1,h2"c;
  var cfgS: int64 := alloc(TlsConfigGroesse());
  var cfgC: int64 := alloc(TlsConfigGroesse());

  TlsConfigNeu(cfgS, 1);
  TlsConfigKette(cfgS, kette, 1, dSk, lSk);
  TlsConfigAlpn(cfgS, alpnS as int64, StrLen(alpnS));
  TlsConfigZeit(cfgS, 1800000000);
  TlsConfigMinVersion(cfgS, TlsVersion12());
  TlsConfigNeu(cfgC, 2);
  TlsConfigTrust(cfgC, trust, 1);
  TlsConfigHost(cfgC, host as int64, StrLen(host));
  TlsConfigAlpn(cfgC, alpnC as int64, StrLen(alpnC));
  TlsConfigZeit(cfgC, 1800000000);
  TlsConfigMinVersion(cfgC, TlsVersion12());


  // Fall 0: Drahtpruefung. renegotiation_info (FF 01 00 01 00) und
  // extended_master_secret (00 17 00 00) muessen in ClientHello UND
  // ServerHello stehen.
  var mReneg: int64 := alloc(8);
  poke8(mReneg, 0xFF); poke8(mReneg + 1, 0x01); poke8(mReneg + 2, 0x00);
  poke8(mReneg + 3, 0x01); poke8(mReneg + 4, 0x00);
  var mEms: int64 := alloc(8);
  poke8(mEms, 0x00); poke8(mEms + 1, 0x17); poke8(mEms + 2, 0x00); poke8(mEms + 3, 0x00);
  var draht: int64 := alloc(32768);
  var svD: int64 := Tls12Neu(cfgS);
  var clD: int64 := Tls12Neu(cfgC);
  Tls12Schritt(clD);
  var dn: int64 := Tls12Ausgabe(clD, draht, 32768);
  melde("ch-hat-reneg"c, findeFolge(draht, dn, mReneg, 5) >= 0);
  melde("ch-hat-ems"c, findeFolge(draht, dn, mEms, 4) >= 0);
  Tls12Fuetter(svD, draht, dn);
  Tls12Schritt(svD);
  var dm: int64 := Tls12Ausgabe(svD, draht, 32768);
  melde("sh-hat-reneg"c, findeFolge(draht, dm, mReneg, 5) >= 0);
  melde("sh-hat-ems"c, findeFolge(draht, dm, mEms, 4) >= 0);
  Tls12Frei(svD); Tls12Frei(clD);

  // Fall 1: x25519, AES-128-GCM (Standardvorliebe)
  var sv: int64 := Tls12Neu(cfgS);
  var cl: int64 := Tls12Neu(cfgC);
  melde("handschlag"c, handschlag(sv, cl));
  melde("suite"c, Tls12Suite(cl));
  melde("suite-server"c, Tls12Suite(sv));
  melde("gruppe"c, Tls12Gruppe(cl));
  melde("ems-client"c, Tls12EMS(cl));
  melde("ems-server"c, Tls12EMS(sv));
  melde("zertifikat-geprueft"c, Tls12PeerZertifikat(cl) != 0);
  melde("daten"c, traegtDaten(sv, cl));
  Print("alpn-server ");
  var i: int64 := 0;
  while (i < Tls12AlpnLen(sv)) { PrintChar(peek8(Tls12AlpnPos(sv) + i)); i := i + 1; }
  PrintLn("");
  melde("sni-gesehen"c, Tls12SniLen(sv));
  Tls12Frei(sv); Tls12Frei(cl);

  // Fall 2: secp256r1 als Gruppe
  TlsConfigGruppen(cfgS, TlsGruppeSecp256r1());
  TlsConfigGruppen(cfgC, TlsGruppeSecp256r1());
  sv := Tls12Neu(cfgS); cl := Tls12Neu(cfgC);
  melde("p256-handschlag"c, handschlag(sv, cl));
  melde("p256-gruppe"c, Tls12Gruppe(cl));
  melde("p256-daten"c, traegtDaten(sv, cl));
  Tls12Frei(sv); Tls12Frei(cl);
  TlsConfigGruppen(cfgS, 0); TlsConfigGruppen(cfgC, 0);

  // Fall 3: mTLS
  TlsConfigClientAuth(cfgS, 2);
  TlsConfigTrust(cfgS, trust, 1);
  TlsConfigKette(cfgC, kKette, 1, dCk, lCk);
  sv := Tls12Neu(cfgS); cl := Tls12Neu(cfgC);
  melde("mtls"c, handschlag(sv, cl));
  melde("mtls-server-sah-zertifikat"c, Tls12PeerZertifikat(sv) != 0);
  melde("mtls-daten"c, traegtDaten(sv, cl));
  Tls12Frei(sv); Tls12Frei(cl);

  // Fall 4: mTLS verlangt, Client hat keines -> Abweisung
  TlsConfigKette(cfgC, 0, 0, 0, 0);
  sv := Tls12Neu(cfgS); cl := Tls12Neu(cfgC);
  melde("mtls-ohne-zertifikat"c, handschlag(sv, cl));
  Tls12Frei(sv); Tls12Frei(cl);
  TlsConfigClientAuth(cfgS, 0);

  // Fall 5: falscher Hostname -> -6
  var falsch: pchar := "fremd.example"c;
  TlsConfigHost(cfgC, falsch as int64, StrLen(falsch));
  sv := Tls12Neu(cfgS); cl := Tls12Neu(cfgC);
  melde("falscher-host"c, handschlag(sv, cl));
  Tls12Frei(sv); Tls12Frei(cl);
  TlsConfigHost(cfgC, host as int64, StrLen(host));

  // Fall 6: unbekannte Wurzel -> -6
  var leerTrust: int64 := alloc(16); poke64(leerTrust, dCli); poke64(leerTrust + 8, lCli);
  TlsConfigTrust(cfgC, leerTrust, 1);
  sv := Tls12Neu(cfgS); cl := Tls12Neu(cfgC);
  melde("fremde-wurzel"c, handschlag(sv, cl));
  Tls12Frei(sv); Tls12Frei(cl);
  TlsConfigTrust(cfgC, trust, 1);

  // Fall 7: ein gekipptes Byte im letzten Record des Serverflugs -> -5
  var puf: int64 := alloc(32768);
  sv := Tls12Neu(cfgS); cl := Tls12Neu(cfgC);
  var rcA: int64 := Tls12Schritt(cl);
  var n1: int64 := Tls12Ausgabe(cl, puf, 32768);
  Tls12Fuetter(sv, puf, n1);
  Tls12Schritt(sv);
  var m1: int64 := Tls12Ausgabe(sv, puf, 32768);
  // In die SIGNATUR des ServerKeyExchange kippen, nicht ins letzte Byte:
  // das letzte Byte ist der leere Rumpf von ServerHelloDone, ein Kipp dort
  // verstuemmelt nur den Nachrichtenkopf und laesst den Handschlag haengen
  // (gemessen: Rueckgabe 1, want-read). Vierzig Byte davor liegt die
  // Signatur, und die MUSS mit -7 scheitern.
  poke8(puf + m1 - 40, peek8(puf + m1 - 40) ^ 1);
  Tls12Fuetter(cl, puf, m1);
  var rcB: int64 := Tls12Schritt(cl);
  melde("gekippte-signatur"c, rcB);
  Tls12Frei(sv); Tls12Frei(cl);

  // Fall 8: gekippter Anwendungsrecord -> -5
  sv := Tls12Neu(cfgS); cl := Tls12Neu(cfgC);
  melde("vor-kipp-handschlag"c, handschlag(sv, cl));
  Tls12Schreibe(cl, host as int64, 13);
  var n2: int64 := Tls12Ausgabe(cl, puf, 32768);
  poke8(puf + n2 - 1, peek8(puf + n2 - 1) ^ 1);
  Tls12Fuetter(sv, puf, n2);
  var ein2: int64 := alloc(4096);
  melde("gekippter-record"c, Tls12Lese(sv, ein2, 4096));
  Tls12Frei(sv); Tls12Frei(cl);

  melde("speicher-je-verbindung"c, Tls12SpeicherBedarf());
  return 0;
}
LYXEOF

sed -i "s#CERTDIRMARKER#$TMP/certs#" "$TMP/s.lyx"

cd "$ROOT"
"$LYXC" "$TMP/s.lyx" --std-path=. -o "$TMP/s" > "$TMP/build.log" 2>&1
if [ ! -x "$TMP/s" ]; then
  echo "FAIL: Testprogramm laesst sich nicht uebersetzen"
  tail -20 "$TMP/build.log"
  exit 1
fi
( ulimit -v 4000000 -c 0; "$TMP/s" > "$TMP/out.txt" 2>&1 )
rc=$?
if [ "$rc" -ge 128 ]; then
  echo "FAIL: Testprogramm abgebrochen (rc=$rc)"; cat "$TMP/out.txt"; exit 1
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

pruefe ch-hat-reneg 1
pruefe ch-hat-ems 1
pruefe sh-hat-reneg 1
pruefe sh-hat-ems 1
pruefe handschlag 0
pruefe suite 49195
pruefe suite-server 49195
pruefe gruppe 29
pruefe ems-client 1
pruefe ems-server 1
pruefe zertifikat-geprueft 1
pruefe daten 1
pruefe sni-gesehen 13
pruefe p256-handschlag 0
pruefe p256-gruppe 23
pruefe p256-daten 1
pruefe mtls 0
pruefe mtls-server-sah-zertifikat 1
pruefe mtls-daten 1
pruefe mtls-ohne-zertifikat -6
pruefe falscher-host -6
pruefe fremde-wurzel -6
pruefe gekippte-signatur -7
pruefe vor-kipp-handschlag 0
pruefe gekippter-record -5

if ! grep -q "^alpn-server h2$" "$TMP/out.txt"; then
  echo "FAIL: ALPN-Auswahl des Servers ist nicht h2"; fails=$((fails + 1))
fi

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$fails FAIL"
exit 1
