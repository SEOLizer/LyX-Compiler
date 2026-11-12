#!/usr/bin/env bash
# tests/tls13_handschlag_test.sh — #2096 Etappe E: TLS 1.3 im eigenen
# Programm, zwei Zustaende sprechen ueber Puffer miteinander. Kein Netz, kein
# openssl — der Interop-Nachweis steht in tests/tls13_interop_openssl_test.sh.
#
# Geprueft wird die Wirkung in beide Richtungen:
#   - Handschlag laeuft durch, beide Seiten einigen sich auf TLS_AES_128_GCM
#     _SHA256 (4865) und auf das ALPN-Protokoll in der Reihenfolge des Servers
#   - Anwendungsdaten in beiden Richtungen, auch ueber mehrere Records
#   - Exporter (RFC 8446 §7.5): beide Seiten bekommen dasselbe Material, ein
#     anderes Label ein anderes
#   - mTLS: mit Client-Zertifikat Erfolg, ohne eines Fehler -6
#   - falscher Hostname, unbekannte Wurzel: -6
#   - ein gekipptes Byte im Serverflug und ein verfaelschter Anwendungsrecord:
#     -5 (Entschluesselung abgelehnt)
#   - EC-Privatschluessel in PKCS#8 und SEC1 ergeben denselben Skalar
#
# Ein Test, der nur den guten Fall kennt, waere auch von einer Umsetzung
# erfuellt, die jedes Zertifikat annimmt — darum steht jeder Ablehnungsfall
# mit seinem eigenen Code hier.
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

cat > "$TMP/s.lyx" <<'LYXEOF'
unit main;
import std.io;
import std.alloc;
import std.fs;
import std.crypto.der;
import std.crypto.x509;
import std.crypto.pkey;
import std.net.tls13;

fn ladeDer(pfad: pchar, label: pchar, derOut: int64): int64 {
  var pem: int64 := alloc(8192);
  var n: int64 := ReadFile(pfad, pem as pchar, 8191);
  if (n <= 0) { return -1; }
  return PemDekodiere(pem, n, label as int64, StrLen(label), derOut, 4096);
}

fn roh(b: int64, n: int64): void {
  var i: int64 := 0;
  while (i < n) { PrintChar(peek8(b + i)); i := i + 1; }
  PrintLn("");
}

// Ein Handschlag zwischen zwei Zustaenden im selben Programm.
// Liefert 0 bei Erfolg, sonst den Fehlercode der Seite, die scheitert.
fn handschlag(sv: int64, cl: int64, kipp: int64): int64 {
  var puf: int64 := alloc(32768);
  var runden: int64 := 0;
  while (runden < 40) {
    var rcC: int64 := TlsSchritt(cl);
    if (rcC < 0) { free(puf, 32768); return rcC; }
    var n: int64 := TlsAusgabe(cl, puf, 32768);
    if (n > 0) { TlsFuetter(sv, puf, n); }
    var rcS: int64 := TlsSchritt(sv);
    if (rcS < 0) { free(puf, 32768); return rcS; }
    var m: int64 := TlsAusgabe(sv, puf, 32768);
    if (m > 0) {
      // Ein Byte im letzten Record des Serverflugs kippen: das trifft das
      // AEAD-Tag des Finished, der Client muss die Entschluesselung ablehnen.
      if (kipp == 1) { poke8(puf + m - 1, peek8(puf + m - 1) ^ 1); }
      TlsFuetter(cl, puf, m);
    }
    if (TlsFertig(cl) && TlsFertig(sv)) { free(puf, 32768); return 0; }
    if (n == 0 && m == 0) { free(puf, 32768); return -99; }
    runden := runden + 1;
  }
  free(puf, 32768);
  return -98;
}

fn main(): int64 {
  var basis: pchar := "CERTDIRMARKER"c;
  var dCa: int64 := alloc(4096);  var lCa := ladeDer(StrConcat(basis, "/tlsca.pem"c), "CERTIFICATE"c, dCa);
  var dSrv: int64 := alloc(4096); var lSrv := ladeDer(StrConcat(basis, "/tlssrv.pem"c), "CERTIFICATE"c, dSrv);
  var dCli: int64 := alloc(4096); var lCli := ladeDer(StrConcat(basis, "/tlscli.pem"c), "CERTIFICATE"c, dCli);
  var dSk: int64 := alloc(4096);  var lSk := ladeDer(StrConcat(basis, "/tlssrvkey.pem"c), "PRIVATE KEY"c, dSk);
  var dCk: int64 := alloc(4096);  var lCk := ladeDer(StrConcat(basis, "/tlsclikey.pem"c), "PRIVATE KEY"c, dCk);
  var dSk1: int64 := alloc(4096); var lSk1 := ladeDer(StrConcat(basis, "/tlssrvkey_sec1.pem"c), "EC PRIVATE KEY"c, dSk1);
  if (lCa <= 0 || lSrv <= 0 || lSk <= 0) { PrintLn("LADEFEHLER"); return 1; }

  // Schluesselformate
  var skalar: int64 := alloc(48);
  Print("pkcs8-kurve "); PrintInt(PkeyLiesEcPrivat(dSk, lSk, skalar)); PrintLn("");
  var skalar2: int64 := alloc(48);
  Print("sec1-kurve "); PrintInt(PkeyLiesEcPrivat(dSk1, lSk1, skalar2)); PrintLn("");
  var gleich: int64 := 1;
  var i: int64 := 0;
  while (i < 32) { if (peek8(skalar + i) != peek8(skalar2 + i)) { gleich := 0; } i := i + 1; }
  Print("beide-formen-gleich "); PrintInt(gleich); PrintLn("");

  var kette: int64 := alloc(16); poke64(kette, dSrv); poke64(kette + 8, lSrv);
  var trust: int64 := alloc(16); poke64(trust, dCa);  poke64(trust + 8, lCa);
  var cKette: int64 := alloc(16); poke64(cKette, dCli); poke64(cKette + 8, lCli);

  var cfgS: int64 := alloc(TlsConfigGroesse());
  var cfgC: int64 := alloc(TlsConfigGroesse());
  var host: pchar := "nexus.example"c;
  var alpnS: pchar := "h2,http/1.1"c;
  var alpnC: pchar := "http/1.1,h2"c;

  TlsConfigNeu(cfgS, 1);
  TlsConfigKette(cfgS, kette, 1, dSk, lSk);
  TlsConfigAlpn(cfgS, alpnS as int64, StrLen(alpnS));
  TlsConfigZeit(cfgS, 1800000000);
  TlsConfigNeu(cfgC, 2);
  TlsConfigTrust(cfgC, trust, 1);
  TlsConfigHost(cfgC, host as int64, StrLen(host));
  TlsConfigAlpn(cfgC, alpnC as int64, StrLen(alpnC));
  TlsConfigZeit(cfgC, 1800000000);

  // Fall 1: Handschlag, Suite, ALPN, Anwendungsdaten in beide Richtungen
  var sv: int64 := TlsNeu(cfgS);
  var cl: int64 := TlsNeu(cfgC);
  Print("handschlag "); PrintInt(handschlag(sv, cl, 0)); PrintLn("");
  Print("suite "); PrintInt(TlsSuite(cl)); Print(" "); PrintInt(TlsSuite(sv)); PrintLn("");
  Print("alpn-server "); roh(TlsAlpnPos(sv), TlsAlpnLen(sv));
  Print("alpn-client "); roh(TlsAlpnPos(cl), TlsAlpnLen(cl));
  var pz: int64 := TlsPeerZertifikat(cl);
  Print("client-sah-zertifikat ");
  if (pz != 0) { PrintInt(X509SerienNrLen(pz)); } else { Print("0"); }
  PrintLn("");

  var puf: int64 := alloc(32768);
  var text: pchar := "GET / HTTP/1.1"c;
  Print("client-schreibt "); PrintInt(TlsSchreibe(cl, text as int64, 14)); PrintLn("");
  var n: int64 := TlsAusgabe(cl, puf, 32768);
  TlsFuetter(sv, puf, n);
  var ein: int64 := alloc(4096);
  var gelesen: int64 := TlsLese(sv, ein, 4096);
  Print("server-liest "); PrintInt(gelesen); Print(" "); roh(ein, gelesen);
  var antwort: pchar := "HTTP/1.1 204 No Content"c;
  TlsSchreibe(sv, antwort as int64, 23);
  n := TlsAusgabe(sv, puf, 32768);
  TlsFuetter(cl, puf, n);
  gelesen := TlsLese(cl, ein, 4096);
  Print("client-liest "); PrintInt(gelesen); Print(" "); roh(ein, gelesen);

  // grosse Nutzlast ueber mehrere Records
  var gross: int64 := alloc(40000);
  i := 0;
  while (i < 40000) { poke8(gross + i, (i * 13 + 7) & 255); i := i + 1; }
  var geschrieben: int64 := TlsSchreibe(cl, gross, 40000);
  Print("grosser-block-geschrieben "); PrintInt(geschrieben); PrintLn("");
  var summe: int64 := 0;
  var fehler: int64 := 0;
  while (summe < geschrieben) {
    n := TlsAusgabe(cl, puf, 32768);
    if (n <= 0) { summe := geschrieben; }
    else {
      TlsFuetter(sv, puf, n);
      var g: int64 := TlsLese(sv, ein, 4096);
      while (g > 0) {
        var k: int64 := 0;
        while (k < g) {
          if (peek8(ein + k) != ((summe + k) * 13 + 7) & 255) { fehler := fehler + 1; }
          k := k + 1;
        }
        summe := summe + g;
        g := TlsLese(sv, ein, 4096);
      }
    }
  }
  Print("grosser-block-gelesen "); PrintInt(summe); Print(" fehler "); PrintInt(fehler); PrintLn("");

  // Exporter: beide Seiten muessen dasselbe Material bekommen (RFC 8446 §7.5)
  var e1: int64 := alloc(32); var e2: int64 := alloc(32);
  var lab: pchar := "EXPORTER-test"c;
  var ok1: bool := TlsExportKeyingMaterial(cl, lab as int64, 13, 0, 0, e1, 32);
  var ok2: bool := TlsExportKeyingMaterial(sv, lab as int64, 13, 0, 0, e2, 32);
  var eg: int64 := 1;
  i := 0;
  while (i < 32) { if (peek8(e1 + i) != peek8(e2 + i)) { eg := 0; } i := i + 1; }
  Print("exporter-gleich "); PrintInt(eg); PrintLn("");
  var lab2: pchar := "EXPORTER-ander"c;
  TlsExportKeyingMaterial(cl, lab2 as int64, 14, 0, 0, e2, 32);
  eg := 0;
  i := 0;
  while (i < 32) { if (peek8(e1 + i) != peek8(e2 + i)) { eg := 1; } i := i + 1; }
  Print("exporter-anderes-label-unterschiedlich "); PrintInt(eg); PrintLn("");

  // Fall 2: mTLS
  TlsConfigClientAuth(cfgS, 2);
  TlsConfigTrust(cfgS, trust, 1);
  TlsConfigKette(cfgC, cKette, 1, dCk, lCk);
  var sv2: int64 := TlsNeu(cfgS);
  var cl2: int64 := TlsNeu(cfgC);
  Print("mtls "); PrintInt(handschlag(sv2, cl2, 0)); PrintLn("");
  var cz: int64 := TlsPeerZertifikat(sv2);
  Print("server-sah-client-zertifikat ");
  if (cz != 0) { PrintInt(X509SubjectLen(cz) > 0); } else { Print("0"); }
  PrintLn("");

  // Fall 3: mTLS verlangt, Client hat kein Zertifikat
  TlsConfigKette(cfgC, 0, 0, 0, 0);
  var sv3: int64 := TlsNeu(cfgS);
  var cl3: int64 := TlsNeu(cfgC);
  Print("mtls-ohne-client-zertifikat "); PrintInt(handschlag(sv3, cl3, 0)); PrintLn("");

  // Fall 4: falscher Hostname beim Client
  TlsConfigClientAuth(cfgS, 0);
  var falsch: pchar := "fremd.example"c;
  TlsConfigHost(cfgC, falsch as int64, 13);
  var sv4: int64 := TlsNeu(cfgS);
  var cl4: int64 := TlsNeu(cfgC);
  Print("falscher-hostname "); PrintInt(handschlag(sv4, cl4, 0)); PrintLn("");

  // Fall 5: Client vertraut der Wurzel nicht
  TlsConfigHost(cfgC, host as int64, 13);
  var leerTrust: int64 := alloc(16);
  TlsConfigTrust(cfgC, leerTrust, 0);
  var sv5: int64 := TlsNeu(cfgS);
  var cl5: int64 := TlsNeu(cfgC);
  Print("unbekannte-wurzel "); PrintInt(handschlag(sv5, cl5, 0)); PrintLn("");

  // Fall 6: ein gekipptes Byte im Datenstrom
  TlsConfigTrust(cfgC, trust, 1);
  var sv6: int64 := TlsNeu(cfgS);
  var cl6: int64 := TlsNeu(cfgC);
  Print("gekipptes-byte "); PrintInt(handschlag(sv6, cl6, 1)); PrintLn("");

  // Fall 7: verfaelschter Anwendungsrecord nach dem Handschlag
  var sv7: int64 := TlsNeu(cfgS);
  var cl7: int64 := TlsNeu(cfgC);
  var rc7: int64 := handschlag(sv7, cl7, 0);
  if (rc7 == 0) {
    TlsSchreibe(cl7, text as int64, 14);
    n := TlsAusgabe(cl7, puf, 32768);
    poke8(puf + n - 1, peek8(puf + n - 1) ^ 0x80);
    TlsFuetter(sv7, puf, n);
    Print("verfaelschter-record "); PrintInt(TlsLese(sv7, ein, 4096)); PrintLn("");
  } else { PrintLn("verfaelschter-record HANDSCHLAGFEHLER"); }

  Print("speicher-je-verbindung "); PrintInt(TlsSpeicherBedarf()); PrintLn("");
  return 0;
}
LYXEOF
sed -i "s|CERTDIRMARKER|$TMP/certs|" "$TMP/s.lyx"

if ! ( cd "$ROOT" && timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/s.lyx" -o "$TMP/s" ) >"$TMP/log" 2>&1; then
  echo "FAIL uebersetzt nicht: $(grep -m1 -i error "$TMP/log")"; exit 1
fi
if [ ! -x "$TMP/s" ]; then echo "FAIL kein Erzeugnis (#1682)"; exit 1; fi

cat > "$TMP/soll.txt" <<'SOLLEOF'
pkcs8-kurve 1
sec1-kurve 1
beide-formen-gleich 1
handschlag 0
suite 4865 4865
alpn-server h2
alpn-client h2
client-sah-zertifikat 2
client-schreibt 14
server-liest 14 GET / HTTP/1.1
client-liest 23 HTTP/1.1 204 No Content
grosser-block-geschrieben 16384
grosser-block-gelesen 16384 fehler 0
exporter-gleich 1
exporter-anderes-label-unterschiedlich 1
mtls 0
server-sah-client-zertifikat 1
mtls-ohne-client-zertifikat -6
falscher-hostname -6
unbekannte-wurzel -6
gekipptes-byte -5
verfaelschter-record -5
speicher-je-verbindung 115440
SOLLEOF

if ! ( ulimit -v 4000000; timeout 300 "$TMP/s" > "$TMP/ist.txt" 2>"$TMP/err.txt" ); then
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

echo "PASS $PASS / FAIL $FAIL (TLS 1.3 Handschlag, mTLS, Exporter, Ablehnungen)"
if [ "$FAIL" != 0 ]; then exit 1; fi
echo "ALL PASS"
exit 0
