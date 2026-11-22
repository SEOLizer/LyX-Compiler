#!/usr/bin/env bash
# tests/tls13_interop_clients_2096_test.sh — #2096 Abnahmekriterium 1,
# Server-Rolle gegen WEITERE Clients als openssl: Python `ssl`, `curl` und
# Chromium (headless). Der openssl-Teil steht in
# tests/tls13_interop_openssl_test.sh; dieser Test ergaenzt die Stacks, die
# dort fehlten.
#
# Warum drei und nicht einer: sie bringen verschiedene ClientHellos mit.
# Python `ssl` und `curl` sprechen OpenSSL, Chromium bringt BoringSSL samt
# eigener Erweiterungsreihenfolge, GREASE-Werten und zwei key_share-Anteilen
# mit. Ein Server, der nur gegen `s_client` geprueft ist, hat BoringSSL nie
# gesehen.
#
# Gemessen wird je Client die WIRKUNG: die ausgehandelte Fassung (TLS 1.3)
# und dass unsere NUTZDATEN beim Client ankommen; dazu auf der Serverseite,
# dass er die Anfrage DIESES Clients gelesen hat.
#
# ALPN steht hier auf `http/1.1` allein. Mit `h2,http/1.1` waehlen curl und
# Chromium HTTP/2 und schicken als erstes die h2-Praeambel; das Testprogramm
# spricht HTTP/1.0, und die Nutzdatenpruefung scheiterte dann an der
# ANWENDUNGSschicht, obwohl der Handschlag stand (gemessen: `curl: (16)
# Remote peer returned unexpected data while we expected SETTINGS frame`).
# Die TLS-Aussage dieses Tests haengt nicht an HTTP/2.
#
# WAS HIER NICHT STEHT, und warum — Firefox und Windows `ldp.exe` aus
# Kriterium 1:
#   * Firefox prueft Zertifikate ausschliesslich gegen seine eigene
#     NSS-Datenbank. Die Test-CA dort einzutragen braucht `certutil` aus
#     libnss3-tools, das auf dieser Maschine fehlt. Ohne das bliebe nur ein
#     Lauf mit abgeschalteter Pruefung, der weniger belegt als der
#     Chromium-Lauf unten.
#   * `ldp.exe` und `ldapsearch -H ldaps://` sprechen LDAP. Das Testprogramm
#     ist kein LDAP-Server; dieses Kriterium gehoert an den LDAPS-Dienst in
#     NEXUS, nicht an den Compiler.
# Beides bleibt eine offene Luecke in Kriterium 1 und ist keine stille
# Auslassung.
#
# Fehlt ein Client, wird genau dieser Teil uebersprungen (SKIP).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"


TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"; pkill -f "s_server -accept 1856" 2>/dev/null' EXIT
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

cat > "$TMP/certs/rsaca.pem" <<'PEMEOF'
-----BEGIN CERTIFICATE-----
MIIC+zCCAeOgAwIBAgIDAIABMA0GCSqGSIb3DQEBCwUAMCwxFTATBgNVBAMMDEF1
cnVtIFJTQSBDQTETMBEGA1UECgwKQXVydW0gVGVzdDAeFw0yNjAxMDEwMDAwMDBa
Fw0zNjAxMDEwMDAwMDBaMCwxFTATBgNVBAMMDEF1cnVtIFJTQSBDQTETMBEGA1UE
CgwKQXVydW0gVGVzdDCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAMNY
L12Zbv5N0k8v3oEeQA7bpOLta/GcVQ9Y3nGTlceZ6AElTZ2KgJ36rwHGZUuy6DR9
v76AG3vRzCIgmbgRhWsKAR4W8vj2DnU/BRpsJEMY/AzSMNBQaTzdoVLTKfDwqnOk
duaHrF9PL+9kJpZiojUDgb4uCKhS5lmrjpAo3tyZyUD/Ba362O+wa6hAnhcF28pI
SFnvbTdtQuqgBiWfyK74654zk3ZP2XMvLDTyvbxFlJJRP5+x/Ne45fnTycu4BykP
+acI6WKyrVvBu5fnQDV8TDV+XdJmtwIBktnYvSYzkKvX9IvehLaneQFo1WGBmVMJ
2bgoYWEnA8XdrwPTTe0CAwEAAaMmMCQwEgYDVR0TAQH/BAgwBgEB/wIBATAOBgNV
HQ8BAf8EBAMCAYYwDQYJKoZIhvcNAQELBQADggEBAHKOVOLii1lKGodeumMSX2Ik
qU8Lljn5lEPCEGibm1T4xP5Dr+0jCb++VYIfhht/0kseKI/wOwLXP9TuquAd3lJh
k/E1wxmnipYf60PWZkc2F6A29xJA5CGcfGH3pRlRRXMNdcKT7qmHQJNQkgamC0j6
oeT/2eMgpPdbLXhrdQ9GrPOe1vq4tDATgTJrORy/X8f8bntjn91N8Nx0h48dq5/5
6icXM2m4fq+MIJb3NveTwglM/JdN0WScgg4pTxHDr2QyPlfxZ12+eaw8tZFaRu0z
4SmyCG/Mt4p2AueVOIQQHCzP/KYpf076fOrfsxZcuLuqau+rKtDjmaDnv86wzrM=
-----END CERTIFICATE-----
PEMEOF
cat > "$TMP/certs/rsaleaf.pem" <<'PEMEOF'
-----BEGIN CERTIFICATE-----
MIIDITCCAgmgAwIBAgIDAIACMA0GCSqGSIb3DQEBCwUAMCwxFTATBgNVBAMMDEF1
cnVtIFJTQSBDQTETMBEGA1UECgwKQXVydW0gVGVzdDAeFw0yNjAxMDEwMDAwMDBa
Fw0zNjAxMDEwMDAwMDBaMCsxFDASBgNVBAMMC3JzYS5leGFtcGxlMRMwEQYDVQQK
DApBdXJ1bSBUZXN0MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAze84
br/Pbm9QIPB/lbkrfwUprsebl15/BpHArICq0iPzvgpnx9/wJi6V8AapGK70BreY
qkF3AjdVgbT9GiFv9lks+zNf7sk8g184fkB3brHPrCZaQhmsB3ZFupU3i/8tM3NO
VdEi8hfEK0LzEms4trJbGAmM2YUpVD8aJ2iI2k6FnQAgrs2YWUrmE8+TLvSRmJFP
96Q5sUeaVnbWWuqx/Nf3ZhMqPjx4rrWUGV393vn5nDG2X7hZJjpFjZF/en658uDJ
Rjbkm4a0YTAnsCnqmj7ss4i1z7DDsdNSF3/PPLN+P095bMcvG88/5PfFgXu4Dydx
b5+EZ84Mmn4mgcuIxwIDAQABo00wSzAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQE
AwIHgDATBgNVHSUEDDAKBggrBgEFBQcDATAWBgNVHREEDzANggtyc2EuZXhhbXBs
ZTANBgkqhkiG9w0BAQsFAAOCAQEATO6VZwgMCQ7K8ccc1kA42hS5teBRxFRTGN7S
a4qmxpWhxLOdz0cawRi783+l4zTqQm77C/fUdTIi7X64uCNlJzUWC5eF//H+cQY3
MqgDvfbQo31Wx01dtdGJ8l/bM2hlosV+OY02+J8nI1u3PmBSmbnLZD7TbF7FV2lA
UYx1FPy9uPMXtu8qT/WeDOfcGG/cgZ1i50DfuYajmeERov7tyXrbZ8iHI4GMUZ2W
VAdoF4mBtVkAZgQwb2fpHogopyLkUbSXltqh2ry2MMt0OF63upn1fE2l9R0P6N/Y
54lY16gjpYGHDOBHElyJ/4KUIxVezN4TcoDW/DcPcXZ1mZSk2g==
-----END CERTIFICATE-----
PEMEOF
cat > "$TMP/certs/rsaleafkey.pem" <<'PEMEOF'
-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQDN7zhuv89ub1Ag
8H+VuSt/BSmux5uXXn8GkcCsgKrSI/O+CmfH3/AmLpXwBqkYrvQGt5iqQXcCN1WB
tP0aIW/2WSz7M1/uyTyDXzh+QHdusc+sJlpCGawHdkW6lTeL/y0zc05V0SLyF8Qr
QvMSazi2slsYCYzZhSlUPxonaIjaToWdACCuzZhZSuYTz5Mu9JGYkU/3pDmxR5pW
dtZa6rH81/dmEyo+PHiutZQZXf3e+fmcMbZfuFkmOkWNkX96frny4MlGNuSbhrRh
MCewKeqaPuyziLXPsMOx01IXf888s34/T3lsxy8bzz/k98WBe7gPJ3Fvn4Rnzgya
fiaBy4jHAgMBAAECggEAAZc9vIi6RagPc6xav/O1ldETPHj4L15QJn7SP6xMB2TA
cu35r9hrkuaFf/0lVvA87JLKdbiVbQSLgarH6krMf7EKvK0B4aqCIj0I1KoYMca6
6iF2f3+hgSyz84Dt5TZFKNzNYKO+BLfA/MAYIuiK+Lq2w5YfxS3W647MwoJjXump
tgtVs2PwJJPjWGA/KcU1vWTBet0ouBfrn5ayVZ7tX+2rd2oV5jxFQDMWFkzXhOKf
67Lrz1II+HVFi3vjX5fWsNxeJ1WiQvUeaO5e5KVwhXaCR6rzucYo32bsTqe2Un/8
d1REn4mRUbqY8lTtUJ3PGRNxXWvWP3yHV5sKfdGyAQKBgQD5p+XqRVVCmYRmfjsT
UMiQdMuRXrvpYGYXYPjQzQMlNZRoG8fpDSfJCSc0PwTa7Xw9VUDnYWapwB0XDi19
nvpNSvZdLfkivUhNs9rD7n9RuquQcPWsGwVNVYpZjUMFbBJ0r3kOnixhd8+bZGPZ
g3NXvjvIQJqYARndtPaQdJKbxwKBgQDTKuYWp2J1yr7pn11OgumNgE7dsfok1EVP
7QgM1IbhEiaL6ogapdNRPprfDsGOL2DfEIHJ8YSIIh9DJ9Gm64Mmh3QY28v08xdo
RJyAPoI8qXQFBrVLUG0Bvd1M2pSKCEunsr6YZXJr/qVH9cUNQCnvT76rwEOGzi64
6E93eX2rAQKBgQD5oBiy4zp6Cjgpp0P4b0jrr+yv4RJxKpNKAwsm9CaV+Pn4EvcT
nrTOPdm2UuDO6rDUPr9T278kMlSj7egseF58FF08FDDMvIhkMVannHwvwz+ygFAV
Ezt89PAN1MJT1JirlZysshlcJ8ks7fcs0VPuQudRts8c99TeKwhyriy9lwKBgQCo
adJPxvdz0lson/0enLIANJCxpzxFGzacZALDmMxpvLwZYtdhyVcbuL5zn6Um7Qpp
XRTmJkT4/Z3JRXyjj7lthSJGoSWtGiNU+UOH1FKyZsMtLwhwJJiLhw10Oe+1lqAg
AyKXEHGNR+4x0gVyZ/YJ8qOy/wfb/5yrxDt8odxkAQKBgAEz9spSdlNqjjG+2+SH
/ySovIDYtkb4vHsp/Ef1GRuZdRQu/80mVMGBfVEbWRrV5iWnPoRyiIm8IqLrR094
q7MY993+r82G7rjPp4YfCJClfvt23PIJSxVR4TZVw2+a8z3G08f/S1sRw/rIPZCJ
lwtkmkHbrvf9ndAQeZScfjTu
-----END PRIVATE KEY-----
PEMEOF
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

cat > "$TMP/srv.lyx" <<'LYXEOF'
unit main;
import std.io;
import std.string;
import std.alloc;
import std.fs;
import std.net.socket;
import std.crypto.der;
import std.crypto.x509;
import std.net.tls13;

fn ladeDer(pfad: pchar, label: pchar, derOut: int64): int64 {
  var pem: int64 := alloc(8192);
  var n: int64 := ReadFile(pfad, pem as pchar, 8191);
  if (n <= 0) { return -1; }
  return PemDekodiere(pem, n, label as int64, StrLen(label), derOut, 4096);
}

fn main(): int64 {
  var basis: pchar := "CERTDIRMARKER"c;
  // GetArg liefert einen Zeiger auf die Zeichenkette, keine Zahl — ohne
  // StrToInt landet das Programm auf einem zufaelligen Port.
  var port: int64 := StrToInt(GetArg(1) as pchar);
  // Zertifikatssatz: ohne weiteres Argument EC P-256, mit "rsa" RSA-2048,
  // mit "ed" Ed25519.
  var satzBlatt: pchar := "/tlssrv.pem"c;
  var satzKey: pchar := "/tlssrvkey.pem"c;
  var satzCa: pchar := "/tlsca.pem"c;
  if (GetArgC() > 2) {
    var w: pchar := GetArg(2) as pchar;
    // "rsa", "ed" oder "ec" — das zweite Zeichen entscheidet, weil "ec" und
    // "ed" beide mit 'e' anfangen.
    if (StrCharAt(w, 0) == 114) {
      satzBlatt := "/rsaleaf.pem"c; satzKey := "/rsaleafkey.pem"c; satzCa := "/rsaca.pem"c;
    }
    if (StrCharAt(w, 0) == 101 && StrCharAt(w, 1) == 100) {
      satzBlatt := "/edleaf.pem"c; satzKey := "/edleafkey.pem"c; satzCa := "/edca.pem"c;
    }
  }
  // "p256": EC-Zertifikat, aber als Schluesseltausch NUR secp256r1. Gegen
  // einen Client, der x25519 anbietet, erzwingt das einen
  // HelloRetryRequest — genau der Weg, den #2096 Stufe 1 verlangt.
  var nurP256: int64 := 0;
  if (GetArgC() > 2) {
    if (StrCharAt(GetArg(2) as pchar, 0) == 112) { nurP256 := 1; }
  }
  var dSrv: int64 := alloc(8192); var lSrv := ladeDer(StrConcat(basis, satzBlatt), "CERTIFICATE"c, dSrv);
  var dCa: int64 := alloc(8192);  var lCa := ladeDer(StrConcat(basis, satzCa), "CERTIFICATE"c, dCa);
  var dSk: int64 := alloc(8192);  var lSk := ladeDer(StrConcat(basis, satzKey), "PRIVATE KEY"c, dSk);
  if (lSrv <= 0 || lSk <= 0) { PrintLn("LADEFEHLER"); return 1; }
  var kette: int64 := alloc(32);
  poke64(kette, dSrv); poke64(kette + 8, lSrv);
  poke64(kette + 16, dCa); poke64(kette + 24, lCa);

  var cfg: int64 := alloc(TlsConfigGroesse());
  var alpn: pchar := "http/1.1"c;
  TlsConfigNeu(cfg, 1);
  TlsConfigKette(cfg, kette, 2, dSk, lSk);
  TlsConfigAlpn(cfg, alpn as int64, StrLen(alpn));
  TlsConfigZeit(cfg, 1800000000);
  if (nurP256 > 0) { TlsConfigGruppen(cfg, TlsGruppeSecp256r1()); }
  // Zweites Argument: Client-Zertifikat verlangen (mTLS)
  if (GetArgC() > 3) {
    var trust: int64 := alloc(16);
    poke64(trust, dCa); poke64(trust + 8, lCa);
    TlsConfigTrust(cfg, trust, 1);
    TlsConfigClientAuth(cfg, 2);
  }

  var l: TCPListener := TCPListenerNew();
  TCPListenerSetReuseAddr(l);
  if (TCPListenerBindTo(l, 0, port) != 0) { PrintLn("BINDFEHLER"); return 1; }
  TCPListenerListen(l, 4);
  PrintLn("bereit");

  var conn: TCPConn := TCPListenerAccept(l);
  var c: int64 := TlsNeu(cfg);
  var puf: int64 := alloc(32768);
  var runden: int64 := 0;
  while (!TlsFertig(c) && runden < 200) {
    var rc: int64 := TlsSchritt(c);
    if (rc < 0) { Print("FEHLER "); PrintInt(rc); Print(" "); PrintLn(TlsFehlerText(rc)); return 1; }
    var m: int64 := TlsAusgabe(c, puf, 32768);
    if (m > 0) { TCPConnWrite(conn, puf as pchar, m); }
    if (!TlsFertig(c)) {
      var n: int64 := TCPConnRead(conn, puf as pchar, 32768);
      if (n <= 0) { PrintLn("VERBINDUNG-WEG"); return 1; }
      TlsFuetter(c, puf, n);
    }
    runden := runden + 1;
  }
  if (!TlsFertig(c)) { PrintLn("HANDSCHLAG-UNFERTIG"); return 1; }
  var pz: int64 := TlsPeerZertifikat(c);
  if (pz != 0) { Print("client-zertifikat-geprueft "); PrintInt(X509SubjectLen(pz) > 0); PrintLn(""); }
  Print("gruppe "); PrintInt(TlsGruppe(c)); PrintLn("");
  Print("handschlag-fertig suite "); PrintInt(TlsSuite(c));
  Print(" alpn ");
  var i: int64 := 0;
  while (i < TlsAlpnLen(c)) { PrintChar(peek8(TlsAlpnPos(c) + i)); i := i + 1; }
  PrintLn("");

  // Anfrage lesen, Antwort senden
  var ein: int64 := alloc(4096);
  var gelesen: int64 := 0;
  runden := 0;
  // #2418: ZUERST fragen, was schon entschluesselt bereitliegt, und nur dann
  // lesen. Unter Last koaleszieren Finished und die Anfrage in EIN
  // TCP-Segment; die Handschlagschleife liest das Segment dann ganz, und die
  // Anfrage liegt bereits im TLS-Puffer. Wer in dieser Lage mit `read`
  // anfaengt, blockiert, bis die Gegenseite die Verbindung schliesst --
  // gemessen mit `strace -T`: read(4, "", 32768) = 0 <39.948270>. Die Antwort
  // ging danach hinaus, aber s_client war schon in seinem Zeitlimit getoetet.
  // Darum war der Test unter Last rot, waehrend BEIDE Seiten den Handschlag
  // als gelungen meldeten.
  while (gelesen <= 0 && runden < 100) {
    gelesen := TlsLese(c, ein, 4096);
    if (gelesen <= 0) {
      var n2: int64 := TCPConnRead(conn, puf as pchar, 32768);
      if (n2 > 0) { TlsFuetter(c, puf, n2); }
      gelesen := TlsLese(c, ein, 4096);
      if (n2 <= 0 && gelesen <= 0) { runden := 100; }
    }
    runden := runden + 1;
  }
  Print("empfangen "); PrintInt(gelesen); Print(" ");
  i := 0;
  while (i < gelesen) { if (peek8(ein + i) >= 32) { PrintChar(peek8(ein + i)); } i := i + 1; }
  PrintLn("");
  var antwort: pchar := "HTTP/1.0 200 OK\r\nContent-Length: 12\r\n\r\nLyx TLS 1.3\n"c;
  TlsSchreibe(c, antwort as int64, StrLen(antwort));
  var m2: int64 := TlsAusgabe(c, puf, 32768);
  TCPConnWrite(conn, puf as pchar, m2);
  TlsSchliessen(c);
  m2 := TlsAusgabe(c, puf, 32768);
  if (m2 > 0) { TCPConnWrite(conn, puf as pchar, m2); }
  PrintLn("fertig");
  TCPConnClose(conn);
  TCPListenerClose(l);
  return 0;
}

LYXEOF
cat > "$TMP/cli.lyx" <<'LYXEOF'
unit main;
import std.io;
import std.string;
import std.alloc;
import std.fs;
import std.net.socket;
import std.crypto.der;
import std.crypto.x509;
import std.net.tls13;

fn ladeDer(pfad: pchar, label: pchar, derOut: int64): int64 {
  var pem: int64 := alloc(8192);
  var n: int64 := ReadFile(pfad, pem as pchar, 8191);
  if (n <= 0) { return -1; }
  return PemDekodiere(pem, n, label as int64, StrLen(label), derOut, 4096);
}

fn main(): int64 {
  var basis: pchar := "CERTDIRMARKER"c;
  var port: int64 := StrToInt(GetArg(1) as pchar);
  var mtls: int64 := 0;
  if (GetArgC() > 3) { mtls := 1; }
  // Wurzel und erwarteter Name nach dem zweiten Argument: EC, rsa oder ed.
  var caPfad: pchar := "/tlsca.pem"c;
  var erwartet: pchar := "nexus.example"c;
  if (GetArgC() > 2) {
    var w: pchar := GetArg(2) as pchar;
    // zweites Zeichen pruefen: "ec" und "ed" fangen beide mit 'e' an.
    if (StrCharAt(w, 0) == 114) { caPfad := "/rsaca.pem"c; erwartet := "rsa.example"c; }
    if (StrCharAt(w, 0) == 101 && StrCharAt(w, 1) == 100) {
      caPfad := "/edca.pem"c; erwartet := "ed.example"c;
    }
  }
  // "p256": nur secp256r1 anbieten — dann muss ein Server, der x25519 will,
  // ein HelloRetryRequest schicken, und wir muessen ihm folgen.
  var nurP256: int64 := 0;
  if (GetArgC() > 2) {
    if (StrCharAt(GetArg(2) as pchar, 0) == 112) { nurP256 := 1; }
  }
  var dCa: int64 := alloc(8192);  var lCa := ladeDer(StrConcat(basis, caPfad), "CERTIFICATE"c, dCa);
  var dCli: int64 := alloc(4096); var lCli := ladeDer(StrConcat(basis, "/tlscli.pem"c), "CERTIFICATE"c, dCli);
  var dCk: int64 := alloc(4096);  var lCk := ladeDer(StrConcat(basis, "/tlsclikey.pem"c), "PRIVATE KEY"c, dCk);
  var trust: int64 := alloc(16); poke64(trust, dCa); poke64(trust + 8, lCa);
  var kette: int64 := alloc(16); poke64(kette, dCli); poke64(kette + 8, lCli);

  var cfg: int64 := alloc(TlsConfigGroesse());
  var host: pchar := erwartet;
  var alpn: pchar := "http/1.1"c;
  TlsConfigNeu(cfg, 2);
  TlsConfigTrust(cfg, trust, 1);
  TlsConfigHost(cfg, host as int64, StrLen(host));
  TlsConfigAlpn(cfg, alpn as int64, StrLen(alpn));
  TlsConfigZeit(cfg, 1800000000);
  if (mtls > 0) { TlsConfigKette(cfg, kette, 1, dCk, lCk); }
  if (nurP256 > 0) { TlsConfigGruppen(cfg, TlsGruppeSecp256r1()); }

  var conn: TCPConn := TCPConnect(0x7F000001, port);
  var c: int64 := TlsNeu(cfg);
  var puf: int64 := alloc(32768);
  var runden: int64 := 0;
  while (!TlsFertig(c) && runden < 200) {
    var rc: int64 := TlsSchritt(c);
    if (rc < 0) { Print("FEHLER "); PrintInt(rc); Print(" "); PrintLn(TlsFehlerText(rc)); return 1; }
    var m: int64 := TlsAusgabe(c, puf, 32768);
    if (m > 0) { TCPConnWrite(conn, puf as pchar, m); }
    if (!TlsFertig(c)) {
      var n: int64 := TCPConnRead(conn, puf as pchar, 32768);
      if (n <= 0) { PrintLn("VERBINDUNG-WEG"); return 1; }
      TlsFuetter(c, puf, n);
    }
    runden := runden + 1;
  }
  if (!TlsFertig(c)) { PrintLn("HANDSCHLAG-UNFERTIG"); return 1; }
  Print("gruppe "); PrintInt(TlsGruppe(c)); PrintLn("");
  Print("handschlag-fertig suite "); PrintInt(TlsSuite(c)); PrintLn("");
  var pz: int64 := TlsPeerZertifikat(c);
  Print("serverzertifikat-geprueft ");
  if (pz != 0) { PrintInt(1); } else { PrintInt(0); }
  PrintLn("");

  var frage: pchar := "ping aus Lyx\n"c;
  TlsSchreibe(c, frage as int64, StrLen(frage));
  var m2: int64 := TlsAusgabe(c, puf, 32768);
  TCPConnWrite(conn, puf as pchar, m2);

  var ein: int64 := alloc(4096);
  var gelesen: int64 := 0;
  runden := 0;
  // #2418: ZUERST fragen, was schon entschluesselt bereitliegt, und nur dann
  // lesen. Unter Last koaleszieren Finished und die Anfrage in EIN
  // TCP-Segment; die Handschlagschleife liest das Segment dann ganz, und die
  // Anfrage liegt bereits im TLS-Puffer. Wer in dieser Lage mit `read`
  // anfaengt, blockiert, bis die Gegenseite die Verbindung schliesst --
  // gemessen mit `strace -T`: read(4, "", 32768) = 0 <39.948270>. Die Antwort
  // ging danach hinaus, aber s_client war schon in seinem Zeitlimit getoetet.
  // Darum war der Test unter Last rot, waehrend BEIDE Seiten den Handschlag
  // als gelungen meldeten.
  while (gelesen <= 0 && runden < 50) {
    gelesen := TlsLese(c, ein, 4096);
    if (gelesen <= 0) {
      var n2: int64 := TCPConnRead(conn, puf as pchar, 32768);
      if (n2 > 0) { TlsFuetter(c, puf, n2); }
      gelesen := TlsLese(c, ein, 4096);
      if (n2 <= 0) { runden := 50; }
    }
    runden := runden + 1;
  }
  Print("antwort "); PrintInt(gelesen); Print(" ");
  var i: int64 := 0;
  while (i < gelesen) { if (peek8(ein + i) >= 32) { PrintChar(peek8(ein + i)); } i := i + 1; }
  PrintLn("");
  TlsSchliessen(c);
  m2 := TlsAusgabe(c, puf, 32768);
  if (m2 > 0) { TCPConnWrite(conn, puf as pchar, m2); }
  TCPConnClose(conn);
  return 0;
}

LYXEOF
sed -i "s|CERTDIRMARKER|$TMP/certs|" "$TMP/srv.lyx" "$TMP/cli.lyx"

for prog in srv cli; do
  if ! ( cd "$ROOT" && timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/$prog.lyx" -o "$TMP/$prog" ) >"$TMP/log_$prog" 2>&1; then
    echo "FAIL $prog uebersetzt nicht: $(grep -m1 -i error "$TMP/log_$prog")"; exit 1
  fi
  [ -x "$TMP/$prog" ] || { echo "FAIL $prog: kein Erzeugnis (#1682)"; exit 1; }
done

PASS=0; FAIL=0
pruefe() {  # name, bedingung-erfuellt(0/1)
  if [ "$2" = 1 ]; then echo "PASS $1"; PASS=$((PASS+1))
  else echo "FAIL $1"; FAIL=$((FAIL+1)); fi
}

# #2418: Auf die WIRKUNG warten statt eine Zeit zu schlafen.
#
# Warum das nötig war: ein CI-Lauf meldete `FAIL Server gegen s_client,
# TLS_AES_128_GCM_SHA256`, während BEIDE Seiten Erfolg meldeten — OpenSSL mit
# `Verify return code: 0 (ok)`, unsere Seite mit `handschlag-fertig … fertig`.
# Der Durchgang brauchte 27 s gegen 4,5 s bei den beiden folgenden, also
# ungefähr `sleep 1.5` plus `timeout 25`: s_client lief in sein Zeitlimit und
# wurde getötet, womit seine Ausgabe unvollständig blieb.
#
# Lokal liess sich der Fall NICHT herstellen — weder mit `sleep 0.05` statt
# `sleep 3` noch mit `timeout 2` statt `timeout 25` wurde der Test rot; die
# Antwort steht hier nach unter zwei Sekunden vollständig in der Datei. Die
# Ursache bleibt damit unbelegt. Was aber unabhängig davon falsch war: der
# Test hing an festen Zeiten, und die hängen an der Maschine.
#
# Deshalb wird jetzt gewartet, bis das erwartete MUSTER in der Datei steht,
# und nur eine Obergrenze begrenzt die Wartezeit. Auf einem schnellen Rechner
# ist der Test damit schneller, auf einem langsamen hält er länger durch.
warteAufMuster() {   # datei, muster, max-sekunden
  local datei="$1" muster="$2" grenze="$3" i=0
  while [ "$i" -lt "$((grenze * 10))" ]; do
    [ -f "$datei" ] && grep -q "$muster" "$datei" 2>/dev/null && return 0
    sleep 0.1
    i=$((i+1))
  done
  return 1
}

# Wartet, bis der Server auf dem Port lauscht. `sleep 1.5` war eine Annahme
# über die Startzeit; unter Last ist sie falsch, und zwar in beide Richtungen.
# #2418: Auf ALLE Bedingungen warten, nicht auf eine.
#
# `warteAufMuster` wartete auf EIN Muster in EINER Datei -- danach wurden
# openssl, der Zubringer und unser Server sofort getoetet. Geurteilt wird aber
# ueber SECHS Bedingungen, verteilt auf ZWEI Dateien, darunter eine in der
# Ausgabe unseres Servers. Welche davon beim Toeten schon geschrieben war,
# entschied die Maschine: lokal alle, unter Last nicht. Genau so entsteht ein
# FAIL, bei dem beide Seiten Erfolg melden -- die fehlende Zeile war nie ein
# Fehlschlag, sie war noch nicht da.
#
# Darum: jede Bedingung, auf die geurteilt wird, ist auch eine Bedingung, auf
# die gewartet wird. Steht alles, geht es sofort weiter; fehlt etwas, laeuft
# die Obergrenze ab und der Test urteilt auf dem unvollstaendigen Stand -- dann
# ist es ein echter Fehlschlag und die gefallenen Bedingungen stehen im Bericht.
#
# Aufruf: warteAufAlle <max-sekunden> <datei> <muster> [<datei> <muster> ...]
warteAufAlle() {
  local grenze="$1"; shift
  local i=0
  while [ "$i" -lt "$((grenze * 10))" ]; do
    local fehlt=0
    local -a rest=("$@")
    local k=0
    while [ "$k" -lt "${#rest[@]}" ]; do
      local d="${rest[$k]}" m="${rest[$((k+1))]}"
      if [ ! -f "$d" ] || ! grep -q "$m" "$d" 2>/dev/null; then fehlt=1; fi
      k=$((k+2))
    done
    [ "$fehlt" = "0" ] && return 0
    sleep 0.1
    i=$((i+1))
  done
  return 1
}

warteAufPort() {     # port, max-sekunden
  local port="$1" grenze="$2" i=0
  while [ "$i" -lt "$((grenze * 10))" ]; do
    ss -ltn 2>/dev/null | grep -q ":$port " && return 0
    sleep 0.1
    i=$((i+1))
  done
  return 1
}

PORT=18560
freierPort() {
  while ss -ltn 2>/dev/null | grep -q ":$PORT "; do PORT=$((PORT+1)); done
  echo "$PORT"
}


# --- 1. Python `ssl` (OpenSSL), volle Zertifikatspruefung ---
if command -v python3 >/dev/null 2>&1 && python3 -c 'import ssl' 2>/dev/null; then
  p="$(freierPort)"; PORT=$((PORT+1))
  ( ulimit -v 4000000 -c 0; "$TMP/srv" "$p" > "$TMP/srv_py.txt" 2>&1 ) &
  warteAufPort "$p" 20 || echo "  HINWEIS: Server lauscht nach 20 s nicht auf $p"
  timeout 40 python3 - "$p" "$TMP/certs/tlsca.pem" > "$TMP/py.txt" 2>&1 <<'PYEOF'
import ssl, socket, sys
port, ca = int(sys.argv[1]), sys.argv[2]
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
ctx.load_verify_locations(ca)
ctx.minimum_version = ssl.TLSVersion.TLSv1_3
ctx.set_alpn_protocols(["http/1.1"])
with socket.create_connection(("127.0.0.1", port), timeout=20) as s:
    with ctx.wrap_socket(s, server_hostname="nexus.example") as t:
        print("fassung", t.version())
        print("suite", t.cipher()[0])
        print("alpn", t.selected_alpn_protocol())
        t.sendall(b"GET / HTTP/1.0\r\n\r\n")
        daten = b""
        while b"Lyx TLS 1.3" not in daten and len(daten) < 4096:
            h = t.recv(4096)
            if not h:
                break
            daten += h
        print("nutzdaten", b"Lyx TLS 1.3" in daten)
PYEOF
  warteAufAlle 20 "$TMP/srv_py.txt" "empfangen 18 GET / HTTP/1.0" >/dev/null
  wait 2>/dev/null
  fehlend=""
  grep -q "^fassung TLSv1.3$" "$TMP/py.txt" || fehlend="$fehlend fassung"
  grep -q "^alpn http/1.1$" "$TMP/py.txt" || fehlend="$fehlend alpn"
  grep -q "^nutzdaten True$" "$TMP/py.txt" || fehlend="$fehlend nutzdaten"
  grep -q "empfangen 18 GET / HTTP/1.0" "$TMP/srv_py.txt" || fehlend="$fehlend anfrage-im-server"
  ok=1; [ -n "$fehlend" ] && ok=0
  pruefe "Python ssl gegen unseren Server (Kette gegen CAfile geprueft)" "$ok"
  if [ "$ok" != 1 ]; then
    echo "  gefallene Bedingungen:$fehlend"
    echo "  python: $(tr '\n' ' ' < "$TMP/py.txt")"
    echo "  lyx:    $(tr '\n' ' ' < "$TMP/srv_py.txt")"
  fi
else
  echo "SKIP Python ssl nicht verfuegbar"
fi

# --- 2. curl, volle Pruefung von Kette UND Hostnamen ---
#
# `--resolve` schiebt den Namen aus dem Zertifikat (nexus.example) auf
# 127.0.0.1. Damit prueft curl auch den Hostnamen, und `ssl_verify_result`
# ist eine Zahl aus dem Lauf statt eines Wortes aus der Ausgabe.
if command -v curl >/dev/null 2>&1; then
  p="$(freierPort)"; PORT=$((PORT+1))
  ( ulimit -v 4000000 -c 0; "$TMP/srv" "$p" > "$TMP/srv_curl.txt" 2>&1 ) &
  warteAufPort "$p" 20 || echo "  HINWEIS: Server lauscht nach 20 s nicht auf $p"
  timeout 40 curl -sS --http1.1 --tlsv1.3 --tls-max 1.3 \
      --cacert "$TMP/certs/tlsca.pem" \
      --resolve "nexus.example:$p:127.0.0.1" \
      "https://nexus.example:$p/" \
      -w 'STATUS=%{http_code} VERIFY=%{ssl_verify_result}\n' \
      > "$TMP/curl.txt" 2>&1
  warteAufAlle 20 "$TMP/srv_curl.txt" "empfangen [0-9]* GET / HTTP/1.1" >/dev/null
  wait 2>/dev/null
  fehlend=""
  grep -q "Lyx TLS 1.3" "$TMP/curl.txt" || fehlend="$fehlend nutzdaten"
  grep -q "STATUS=200" "$TMP/curl.txt" || fehlend="$fehlend status"
  grep -q "VERIFY=0" "$TMP/curl.txt" || fehlend="$fehlend zertifikatspruefung"
  # curl schickt HTTP/1.1 samt Kopfzeilen -- gemessen 83 Byte, nicht die 18
  # des openssl-Teils. Darum die Laenge offen und die Zeile festgenagelt.
  grep -qE "empfangen [0-9]+ GET / HTTP/1.1" "$TMP/srv_curl.txt" || fehlend="$fehlend anfrage-im-server"
  ok=1; [ -n "$fehlend" ] && ok=0
  pruefe "curl gegen unseren Server (Kette und Hostname geprueft)" "$ok"
  if [ "$ok" != 1 ]; then
    echo "  gefallene Bedingungen:$fehlend"
    echo "  curl: $(tr '\n' ' ' < "$TMP/curl.txt")"
    echo "  lyx:  $(tr '\n' ' ' < "$TMP/srv_curl.txt")"
  fi
else
  echo "SKIP curl nicht im Pfad"
fi

# --- 3. Chromium headless (BoringSSL) ---
#
# Der Punkt dieses Teils ist der FREMDE Stack. Die Zertifikatspruefung laeuft
# hier mit `--ignore-certificate-errors`, weil die Test-CA ohne `certutil`
# nicht in die NSS-Datenbank kommt; dass unsere Kette vollstaendig geprueft
# wird, belegen die beiden Teile darueber und der openssl-Test. Geprueft wird
# hier der Handschlag mit BoringSSL und der Weg der Nutzdaten bis in das DOM.
CR="$(command -v chromium || command -v google-chrome || command -v chromium-browser || true)"
if [ -n "$CR" ]; then
  p="$(freierPort)"; PORT=$((PORT+1))
  ( ulimit -v 4000000 -c 0; "$TMP/srv" "$p" > "$TMP/srv_cr.txt" 2>&1 ) &
  warteAufPort "$p" 20 || echo "  HINWEIS: Server lauscht nach 20 s nicht auf $p"
  timeout 90 "$CR" --headless --disable-gpu --no-sandbox \
      --user-data-dir="$TMP/cr-profil" \
      --ignore-certificate-errors --virtual-time-budget=5000 \
      --dump-dom "https://127.0.0.1:$p/" > "$TMP/cr.txt" 2>"$TMP/cr_err.txt"
  warteAufAlle 20 "$TMP/srv_cr.txt" "empfangen" >/dev/null
  wait 2>/dev/null
  fehlend=""
  grep -q "Lyx TLS 1.3" "$TMP/cr.txt" || fehlend="$fehlend nutzdaten-im-dom"
  grep -q "handschlag-fertig suite 4865" "$TMP/srv_cr.txt" || fehlend="$fehlend handschlag"
  grep -q "alpn http/1.1" "$TMP/srv_cr.txt" || fehlend="$fehlend alpn"
  grep -qE "empfangen [0-9]+ GET / HTTP/1.1" "$TMP/srv_cr.txt" || fehlend="$fehlend anfrage-im-server"
  ok=1; [ -n "$fehlend" ] && ok=0
  pruefe "Chromium headless (BoringSSL) gegen unseren Server" "$ok"
  if [ "$ok" != 1 ]; then
    echo "  gefallene Bedingungen:$fehlend"
    echo "  chromium-dom: $(head -c 200 "$TMP/cr.txt" | tr '\n' ' ')"
    echo "  lyx:          $(tr '\n' ' ' < "$TMP/srv_cr.txt")"
  fi
else
  echo "SKIP Chromium/Chrome nicht im Pfad"
fi

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "ALL PASS"
