#!/usr/bin/env bash
# tests/tls_version_weiche_test.sh — #2096 Stufe 2: die Weiche zwischen
# TLS 1.3 und TLS 1.2 im gemeinsamen Tor (std.net.tls13).
#
# Die Anwendung stellt EINE Konfiguration auf und ruft Tls*; welche Version
# laeuft, entscheiden TlsConfigMinVersion/MaxVersion und die Gegenseite.
# Geprueft wird in BEIDE Richtungen — ein Test, der nur zeigt, dass 1.2
# zustande kommt, waere auch von einer Fassung erfuellt, die 1.2 immer
# nimmt:
#
#   - Standard (nichts eingestellt): TLS 1.3, Suite 4865
#   - beide erlauben 1.2 zusaetzlich: es bleibt bei 1.3
#   - Server ohne 1.3 (MaxVersion 1.2): beide Seiten melden 771 (0x0303)
#     und Suite 49195 (0xC02B), Daten tragen, Zertifikat geprueft
#   - Client ohne 1.3: ebenso
#   - 1.2 auf dem Server NICHT freigeschaltet und der Client kann nur 1.2:
#     der Handschlag MUSS scheitern und der Server darf nicht fertig werden
#   - Client nur 1.3 gegen Server nur 1.2: MUSS scheitern
#
# Dazu die beiden ehrlichen Absagen im 1.2-Betrieb: TlsKeyUpdateSenden gibt
# -12 (TLS 1.2 kennt kein KeyUpdate) und TlsExportKeyingMaterial gibt false
# (RFC 5705 ist nicht umgesetzt) — nicht etwas Plausibles.
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
import std.net.tls13;

fn ladeDer(pfad: pchar, label: pchar, derOut: int64): int64 {
  var pem: int64 := alloc(8192);
  var n: int64 := ReadFile(pfad, pem as pchar, 8191);
  if (n <= 0) { return -1; }
  return PemDekodiere(pem, n, label as int64, StrLen(label), derOut, 4096);
}

fn melde(name: pchar, wert: int64): void {
  Print(name); Print(" "); PrintInt(wert); PrintLn("");
}

fn handschlag(sv: int64, cl: int64): int64 {
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
    if (m > 0) { TlsFuetter(cl, puf, m); }
    if (TlsFertig(cl) && TlsFertig(sv)) { free(puf, 32768); return 0; }
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
  var ok: int64 := 1;
  if (TlsSchreibe(cl, hin as int64, 4) != 4) { ok := 0; }
  var n: int64 := TlsAusgabe(cl, puf, 32768);
  TlsFuetter(sv, puf, n);
  var g: int64 := TlsLese(sv, ein, 4096);
  if (g != 4) { ok := 0; }
  free(puf, 32768); free(ein, 4096);
  return ok;
}

fn main(): int64 {
  var basis: pchar := "CERTDIRMARKER"c;
  var dCa: int64 := alloc(4096);  var lCa: int64 := ladeDer(StrConcat(basis, "/tlsca.pem"c), "CERTIFICATE"c, dCa);
  var dSrv: int64 := alloc(4096); var lSrv: int64 := ladeDer(StrConcat(basis, "/tlssrv.pem"c), "CERTIFICATE"c, dSrv);
  var dSk: int64 := alloc(4096);  var lSk: int64 := ladeDer(StrConcat(basis, "/tlssrvkey.pem"c), "PRIVATE KEY"c, dSk);
  if (lCa <= 0 || lSrv <= 0 || lSk <= 0) { PrintLn("LADEFEHLER"); return 1; }
  var kette: int64 := alloc(16); poke64(kette, dSrv); poke64(kette + 8, lSrv);
  var trust: int64 := alloc(16); poke64(trust, dCa);  poke64(trust + 8, lCa);
  var host: pchar := "nexus.example"c;

  var cfgS: int64 := alloc(TlsConfigGroesse());
  var cfgC: int64 := alloc(TlsConfigGroesse());
  TlsConfigNeu(cfgS, 1);
  TlsConfigKette(cfgS, kette, 1, dSk, lSk);
  TlsConfigZeit(cfgS, 1800000000);
  TlsConfigNeu(cfgC, 2);
  TlsConfigTrust(cfgC, trust, 1);
  TlsConfigHost(cfgC, host as int64, StrLen(host));
  TlsConfigZeit(cfgC, 1800000000);

  // Fall 1: Standard — beide nur TLS 1.3
  var sv: int64 := TlsNeu(cfgS);
  var cl: int64 := TlsNeu(cfgC);
  melde("standard-handschlag"c, handschlag(sv, cl));
  melde("standard-version"c, TlsVersion(cl));
  melde("standard-suite"c, TlsSuite(cl));
  melde("standard-daten"c, traegtDaten(sv, cl));
  TlsFrei(sv); TlsFrei(cl);

  // Fall 2: beide erlauben 1.2 zusaetzlich -> es bleibt bei 1.3
  TlsConfigMinVersion(cfgS, TlsVersion12());
  TlsConfigMinVersion(cfgC, TlsVersion12());
  sv := TlsNeu(cfgS); cl := TlsNeu(cfgC);
  melde("beide-erlauben-12-handschlag"c, handschlag(sv, cl));
  melde("beide-erlauben-12-version"c, TlsVersion(cl));
  melde("beide-erlauben-12-server-version"c, TlsVersion(sv));
  TlsFrei(sv); TlsFrei(cl);

  // Fall 3: der Server kann KEIN 1.3 (MaxVersion 1.2) -> beide auf 1.2
  TlsConfigMaxVersion(cfgS, TlsVersion12());
  sv := TlsNeu(cfgS); cl := TlsNeu(cfgC);
  melde("server-nur-12-handschlag"c, handschlag(sv, cl));
  melde("server-nur-12-version"c, TlsVersion(cl));
  melde("server-nur-12-server-version"c, TlsVersion(sv));
  melde("server-nur-12-suite"c, TlsSuite(cl));
  melde("server-nur-12-daten"c, traegtDaten(sv, cl));
  melde("server-nur-12-zertifikat"c, TlsPeerZertifikat(cl) != 0);
  // KeyUpdate gibt es in 1.2 nicht: muss -12 liefern, nicht etwas Plausibles
  melde("server-nur-12-keyupdate"c, TlsKeyUpdateSenden(cl, false));
  // Exporter ist fuer 1.2 nicht umgesetzt: false, nicht Muell
  var em: int64 := alloc(32);
  var lab: pchar := "EXPORTER-test"c;
  melde("server-nur-12-exporter"c, TlsExportKeyingMaterial(cl, lab as int64, 13, 0, 0, em, 32));
  TlsFrei(sv); TlsFrei(cl);

  // Fall 4: der Client kann kein 1.3, der Server beides -> 1.2
  TlsConfigMaxVersion(cfgS, 0);
  TlsConfigMaxVersion(cfgC, TlsVersion12());
  sv := TlsNeu(cfgS); cl := TlsNeu(cfgC);
  melde("client-nur-12-handschlag"c, handschlag(sv, cl));
  melde("client-nur-12-version"c, TlsVersion(sv));
  melde("client-nur-12-daten"c, traegtDaten(sv, cl));
  TlsFrei(sv); TlsFrei(cl);

  // Fall 5: Gegenprobe. Der Client kann nur 1.2, der Server erlaubt 1.2
  // NICHT (Standard) -> es darf KEIN Handschlag zustande kommen.
  TlsConfigMinVersion(cfgS, 0);
  sv := TlsNeu(cfgS); cl := TlsNeu(cfgC);
  var rc5: int64 := handschlag(sv, cl);
  melde("12-abgeschaltet-scheitert"c, rc5 < 0);
  melde("12-abgeschaltet-fertig"c, TlsFertig(sv));
  TlsFrei(sv); TlsFrei(cl);

  // Fall 6: umgekehrt — Server nur 1.2, Client nur 1.3
  TlsConfigMinVersion(cfgS, TlsVersion12());
  TlsConfigMaxVersion(cfgS, TlsVersion12());
  TlsConfigMinVersion(cfgC, 0);
  TlsConfigMaxVersion(cfgC, 0);
  sv := TlsNeu(cfgS); cl := TlsNeu(cfgC);
  var rc6: int64 := handschlag(sv, cl);
  melde("nur13-gegen-nur12-scheitert"c, rc6 < 0);
  TlsFrei(sv); TlsFrei(cl);
  return 0;
}
LYXEOF

sed -i "s#CERTDIRMARKER#$TMP/certs#" "$TMP/s.lyx"
cd "$ROOT"
"$LYXC" "$TMP/s.lyx" --std-path=. -o "$TMP/s" > "$TMP/build.log" 2>&1
if [ ! -x "$TMP/s" ]; then
  echo "FAIL: Testprogramm laesst sich nicht uebersetzen"; tail -20 "$TMP/build.log"; exit 1
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

pruefe standard-handschlag 0
pruefe standard-version 772
pruefe standard-suite 4865
pruefe standard-daten 1
pruefe beide-erlauben-12-handschlag 0
pruefe beide-erlauben-12-version 772
pruefe beide-erlauben-12-server-version 772
pruefe server-nur-12-handschlag 0
pruefe server-nur-12-version 771
pruefe server-nur-12-server-version 771
pruefe server-nur-12-suite 49195
pruefe server-nur-12-daten 1
pruefe server-nur-12-zertifikat 1
pruefe server-nur-12-keyupdate -12
pruefe server-nur-12-exporter 0
pruefe client-nur-12-handschlag 0
pruefe client-nur-12-version 771
pruefe client-nur-12-daten 1
pruefe 12-abgeschaltet-scheitert 1
pruefe 12-abgeschaltet-fertig 0
pruefe nur13-gegen-nur12-scheitert 1

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$fails FAIL"
exit 1
