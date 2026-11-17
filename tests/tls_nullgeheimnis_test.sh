#!/usr/bin/env bash
# tests/tls_nullgeheimnis_test.sh — #2096: ein Punkt kleiner Ordnung im
# Schluesseltausch MUSS den Handschlag beenden (RFC 8446 Paragraph 7.4.2,
# fuer TLS 1.2 RFC 8422 Paragraph 5.11).
#
# Gefunden hat das die Arbeit an den Wycheproof-Vektoren: 31 der 518
# X25519-Faelle ergeben das NULL-Geheimnis, und ohne Pruefung lief der
# Handschlag damit durch — beide Seiten haetten ihre Schluessel aus einem
# Geheimnis abgeleitet, das der Angreifer kennt, weil es fest ist.
#
# Geprueft wird an der WIRKUNG, in beiden Fassungen, und jeweils mit
# Gegenprobe:
#   - X25519 selbst rechnet den Wert aus (so verlangt es RFC 7748); das
#     Urteil faellt im Protokoll.
#   - TLS 1.3, Client: ein ServerHello, dessen key_share den Nullpunkt, die
#     Eins oder einen Punkt kleiner Ordnung traegt -> -4, nicht fertig.
#     Fall 3 ist die GEGENPROBE mit einem gueltigen Punkt: der Handschlag
#     laeuft weiter (1 = want-read). Ohne sie wuesste niemand, ob die drei
#     Abbrueche am Geheimnis liegen oder am von Hand gebauten ServerHello —
#     beim ersten Versuch lag es genau daran (fehlende session_id-Spiegelung,
#     alle vier Faelle gaben -1).
#   - TLS 1.2, Server: im Klartextflug des Clients wird der Punkt im
#     ClientKeyExchange ersetzt -> Server -4, nicht fertig. Durchgang 1 ohne
#     Ersetzung ist die Gegenprobe: Handschlag fertig.
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
// Probe: ein Punkt kleiner Ordnung im key_share muss den Handschlag beenden
// (RFC 8446 §7.4.2). Geprueft wird an der WIRKUNG: der Client bekommt ein
// ServerHello mit einem solchen Anteil und darf nicht fertig werden.
unit main;
import std.io;
import std.string;
import std.alloc;
import std.fs;
import std.crypto.der;
import std.crypto.x509;
import std.crypto.x25519;
import std.net.tls_config;
import std.net.tls13;
import std.net.tls12;

fn hv(c: int64): int64 {
  if (c >= 48 && c <= 57) { return c - 48; }
  if (c >= 97 && c <= 102) { return c - 97 + 10; }
  return 0;
}

fn hexAn(z: int64, s: pchar): int64 {
  var n: int64 := StrLen(s);
  var i: int64 := 0;
  var q: int64 := 0;
  while (i + 1 < n + 1 && i + 1 <= n - 1) {
    poke8(z + q, (hv(StrCharAt(s, i)) << 4) | hv(StrCharAt(s, i + 1)));
    q := q + 1;
    i := i + 2;
  }
  return q;
}

fn melde(n: pchar, w: int64): void { Print(n); Print(" "); PrintInt(w); PrintLn(""); }

fn main(): int64 {
  // Drei Punkte aus den Wycheproof-Vektoren, die alle das Null-Geheimnis
  // ergeben: der Nullpunkt, die Eins und ein Punkt kleiner Ordnung.
  var p0: int64 := alloc(32);
  hexAn(p0, "0000000000000000000000000000000000000000000000000000000000000000"c);
  var p1: int64 := alloc(32);
  hexAn(p1, "0100000000000000000000000000000000000000000000000000000000000000"c);
  var p2: int64 := alloc(32);
  hexAn(p2, "e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800"c);

  // Erst die Funktion selbst: sie rechnet (und soll das auch), das Ergebnis
  // ist null.
  var sk: int64 := alloc(32);
  var pk: int64 := alloc(32);
  var seed: int64 := alloc(32);
  var i: int64 := 0;
  while (i < 32) { poke8(seed + i, i + 1); i := i + 1; }
  X25519KeyGen(seed, pk, sk);
  var ss: int64 := alloc(32);
  var alleNull: int64 := 1;
  var k: int64 := 0;
  X25519SharedSecret(sk, p2, ss);
  while (k < 32) { if (peek8(ss + k) != 0) { alleNull := 0; } k := k + 1; }
  melde("funktion-rechnet-null"c, alleNull);

  // Jetzt die Wirkung im Protokoll: ein ServerHello, dessen key_share einen
  // dieser Punkte traegt. Der Client muss abbrechen.
  var cfg: int64 := alloc(TlsConfigGroesse());
  TlsConfigNeu(cfg, 2);
  TlsConfigKettePruefen(cfg, 0);
  TlsConfigZeit(cfg, 1800000000);

  var puf: int64 := alloc(4096);
  var fall: int64 := 0;
  while (fall < 4) {
    // Fall 3 ist die GEGENPROBE: ein gueltiger Punkt. Ohne sie wuesste
    // niemand, ob die drei Abbrueche am Null-Geheimnis liegen oder an einem
    // Fehler in diesem von Hand gebauten ServerHello.
    var punkt: int64 := p0;
    if (fall == 1) { punkt := p1; }
    if (fall == 2) { punkt := p2; }
    if (fall == 3) { punkt := pk; }

    var c: int64 := TlsNeu(cfg);
    TlsSchritt(c);                          // ClientHello hinaus
    var n: int64 := TlsAusgabe(c, puf, 4096);
    // ServerHello von Hand: Kopf, Version, Zufall, leere Session-ID,
    // Suite 0x1301, Kompression 0, Erweiterungen supported_versions und
    // key_share mit dem Punkt kleiner Ordnung.
    var sh: int64 := alloc(256);
    // Die session_id MUSS die des ClientHello spiegeln (RFC 8446 §4.1.3),
    // sonst weist der Client schon vorher mit -1 ab — und dann messen wir
    // nicht das Null-Geheimnis, sondern unser eigenes kaputtes ServerHello.
    // Sie steht im aufgezeichneten ClientHello ab Versatz 44:
    // Record 5 + Handschlagkopf 4 + Version 2 + Zufall 32 + Laengenbyte 1.
    var sid: int64 := puf + 44;
    var p: int64 := 0;
    poke8(sh + p, 2); p := p + 1;                       // ServerHello
    var lenPos: int64 := p;
    p := p + 3;                                         // Laenge spaeter
    var koerper: int64 := p;
    poke8(sh + p, 3); poke8(sh + p + 1, 3); p := p + 2; // legacy_version
    var z: int64 := 0;
    while (z < 32) { poke8(sh + p + z, 7); z := z + 1; }
    p := p + 32;
    poke8(sh + p, 32); p := p + 1;                      // session_id-Laenge
    z := 0;
    while (z < 32) { poke8(sh + p + z, peek8(sid + z)); z := z + 1; }
    p := p + 32;
    poke8(sh + p, 0x13); poke8(sh + p + 1, 0x01); p := p + 2;
    poke8(sh + p, 0); p := p + 1;                       // compression
    var extLenPos: int64 := p;
    p := p + 2;
    var extStart: int64 := p;
    poke8(sh + p, 0); poke8(sh + p + 1, 0x2b); p := p + 2;  // supported_versions
    poke8(sh + p, 0); poke8(sh + p + 1, 2); p := p + 2;
    poke8(sh + p, 3); poke8(sh + p + 1, 4); p := p + 2;
    poke8(sh + p, 0); poke8(sh + p + 1, 0x33); p := p + 2;  // key_share
    poke8(sh + p, 0); poke8(sh + p + 1, 0x24); p := p + 2;
    poke8(sh + p, 0); poke8(sh + p + 1, 0x1d); p := p + 2;  // x25519
    poke8(sh + p, 0); poke8(sh + p + 1, 0x20); p := p + 2;
    z := 0;
    while (z < 32) { poke8(sh + p + z, peek8(punkt + z)); z := z + 1; }
    p := p + 32;
    // Laengen nachtragen, statt sie von Hand auszurechnen.
    var extLen: int64 := p - extStart;
    poke8(sh + extLenPos, (extLen >> 8) & 255);
    poke8(sh + extLenPos + 1, extLen & 255);
    var koerperLen: int64 := p - koerper;
    poke8(sh + lenPos, (koerperLen >> 16) & 255);
    poke8(sh + lenPos + 1, (koerperLen >> 8) & 255);
    poke8(sh + lenPos + 2, koerperLen & 255);

    var rec: int64 := alloc(300);
    poke8(rec, 22); poke8(rec + 1, 3); poke8(rec + 2, 3);
    poke8(rec + 3, (p >> 8) & 255); poke8(rec + 4, p & 255);
    z := 0;
    while (z < p) { poke8(rec + 5 + z, peek8(sh + z)); z := z + 1; }
    TlsFuetter(c, rec, 5 + p);
    var rc: int64 := TlsSchritt(c);
    Print("fall"); PrintInt(fall); Print("-rc "); PrintInt(rc);
    Print(" fertig "); PrintInt(TlsFertig(c)); PrintLn("");
    TlsFrei(c);
    free(sh, 256); free(rec, 300);
    fall := fall + 1;
  }

  // ── TLS 1.2: der Punkt kommt im ClientKeyExchange, und der liegt im
  //    KLARTEXT (vor ChangeCipherSpec). Also: echten Handschlag fahren, im
  //    Flug des Clients die CKE-Nachricht finden und ihren Punkt durch einen
  //    Punkt kleiner Ordnung ersetzen. Der Server muss abbrechen.
  var dCa: int64 := alloc(4096);
  var dSrv: int64 := alloc(4096);
  var dSk: int64 := alloc(4096);
  var basis: pchar := "CERTDIRMARKER"c;
  var pem: int64 := alloc(8192);
  var lab1: pchar := "CERTIFICATE"c;
  var lab2: pchar := "PRIVATE KEY"c;
  var nn: int64 := ReadFile(StrConcat(basis, "/tlsca.pem"c), pem as pchar, 8191);
  var lCa: int64 := PemDekodiere(pem, nn, lab1 as int64, 11, dCa, 4096);
  nn := ReadFile(StrConcat(basis, "/tlssrv.pem"c), pem as pchar, 8191);
  var lSrv: int64 := PemDekodiere(pem, nn, lab1 as int64, 11, dSrv, 4096);
  nn := ReadFile(StrConcat(basis, "/tlssrvkey.pem"c), pem as pchar, 8191);
  var lSk: int64 := PemDekodiere(pem, nn, lab2 as int64, 11, dSk, 4096);
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

  var durchgang: int64 := 0;
  while (durchgang < 2) {
    var sv: int64 := Tls12Neu(cfgS);
    var cl: int64 := Tls12Neu(cfgC);
    var b: int64 := alloc(32768);
    var runden: int64 := 0;
    var rcS: int64 := 0;
    var gepatcht: int64 := 0;
    while (runden < 20 && rcS >= 0) {
      Tls12Schritt(cl);
      var m: int64 := Tls12Ausgabe(cl, b, 32768);
      if (m > 0) {
        // Im Klartextflug die CKE-Nachricht (Typ 16) suchen und ihren Punkt
        // ersetzen. Durchgang 0 patcht, Durchgang 1 ist die Gegenprobe.
        if (durchgang == 0 && gepatcht == 0) {
          var q: int64 := 0;
          while (q + 5 < m) {
            if ((peek8(b + q) & 255) == 22) {
              var rl: int64 := ((peek8(b + q + 3) & 255) << 8) | (peek8(b + q + 4) & 255);
              if ((peek8(b + q + 5) & 255) == 16 && q + 5 + 4 + 33 <= m) {
                var zz: int64 := 0;
                while (zz < 32) { poke8(b + q + 5 + 5 + zz, peek8(p2 + zz)); zz := zz + 1; }
                gepatcht := 1;
              }
              q := q + 5 + rl;
            } else { q := m; }
          }
        }
        Tls12Fuetter(sv, b, m);
      }
      rcS := Tls12Schritt(sv);
      var k2: int64 := Tls12Ausgabe(sv, b, 32768);
      if (k2 > 0) { Tls12Fuetter(cl, b, k2); }
      if (Tls12Fertig(sv) && Tls12Fertig(cl)) { runden := 20; }
      runden := runden + 1;
    }
    Print("tls12-durchgang"); PrintInt(durchgang);
    Print(" gepatcht "); PrintInt(gepatcht);
    Print(" server-rc "); PrintInt(rcS);
    Print(" fertig "); PrintInt(Tls12Fertig(sv)); PrintLn("");
    Tls12Frei(sv); Tls12Frei(cl); free(b, 32768);
    durchgang := durchgang + 1;
  }
  return 0;
}
LYXEOF

sed -i "s#CERTDIRMARKER#$TMP/certs#" "$TMP/s.lyx"
cd "$ROOT"
"$LYXC" "$TMP/s.lyx" --std-path=. -o "$TMP/s" > "$TMP/build.log" 2>&1
if [ ! -x "$TMP/s" ]; then
  echo "FAIL: Testprogramm laesst sich nicht uebersetzen"; tail -20 "$TMP/build.log"; exit 1
fi
( ulimit -v 4000000 -c 0; timeout 300 "$TMP/s" > "$TMP/out.txt" 2>&1 )
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

pruefe funktion-rechnet-null 1
pruefe fall0-rc "-4 fertig 0"
pruefe fall1-rc "-4 fertig 0"
pruefe fall2-rc "-4 fertig 0"
pruefe fall3-rc "1 fertig 0"
pruefe tls12-durchgang0 "gepatcht 1 server-rc -4 fertig 0"
pruefe tls12-durchgang1 "gepatcht 0 server-rc 0 fertig 1"

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$fails FAIL"
exit 1
