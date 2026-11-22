#!/usr/bin/env bash
# tests/tls12_interop_openssl_test.sh — #2096 Stufe 2: Interop-Nachweis fuer
# TLS 1.2 gegen OpenSSL. Das ist der Nachweis, der die Drahtform wirklich
# prueft: Record-Layer mit explizitem Nonce, PRF, ChangeCipherSpec,
# Extended Master Secret und die Ablehnung der Renegotiation.
#
# Geprueft wird, mit beiden Richtungen des Urteils:
#   1. unser Server gegen `s_client -tls1_2` mit allen drei AEAD-Familien
#      (AES-128-GCM, AES-256-GCM, ChaCha20-Poly1305). openssl muss TLSv1.2,
#      die Suite, "Verify return code: 0" und unsere Antwortdaten melden.
#   2. unser Server gegen `s_client -no_ems`: der Handschlag MUSS scheitern,
#      und unsere Seite muss -17 melden. Ohne diesen Fall waere die
#      EMS-Pflicht nur behauptet.
#   3. unser Server gegen `s_client -cipher ECDHE-ECDSA-AES128-SHA` (CBC):
#      MUSS scheitern, unsere Seite meldet -3. CBC ist ausgeschlossen.
#   4. unser Client gegen `s_server -tls1_2`, ohne und mit
#      Client-Zertifikat (mTLS).
#   5. dasselbe mit RSA-Zertifikat, damit der RSA-Signaturpfad
#      (rsa_pss_rsae_sha256 beim Signieren, PKCS#1 beim Pruefen) belegt ist.
#
# Ohne openssl im Pfad wird uebersprungen (SKIP) — ein roter Test aus
# Umgebungsgruenden sagt nichts ueber den Code.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"

if ! command -v openssl >/dev/null 2>&1; then
  echo "SKIP openssl nicht im Pfad"; exit 0
fi
OSSLV="$(openssl version 2>/dev/null)"
if ! openssl s_client -help 2>&1 | grep -q tls1_2; then
  echo "SKIP openssl ohne TLS-1.2-Unterstuetzung ($OSSLV)"; exit 0
fi
echo "openssl: $OSSLV"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"; pkill -f "s_server -accept 189" 2>/dev/null' EXIT
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
import std.net.tls_config;
import std.net.tls12;

fn ladeDer(pfad: pchar, label: pchar, derOut: int64): int64 {
  var pem: int64 := alloc(8192);
  var n: int64 := ReadFile(pfad, pem as pchar, 8191);
  if (n <= 0) { return -1; }
  return PemDekodiere(pem, n, label as int64, StrLen(label), derOut, 4096);
}

fn main(): int64 {
  var basis: pchar := "CERTDIRMARKER"c;
  var port: int64 := StrToInt(GetArg(1) as pchar);
  var satzBlatt: pchar := "/tlssrv.pem"c;
  var satzKey: pchar := "/tlssrvkey.pem"c;
  var satzCa: pchar := "/tlsca.pem"c;
  var mtls: int64 := 0;
  if (GetArgC() > 2) {
    var w: pchar := GetArg(2) as pchar;
    if (StrCharAt(w, 0) == 114) {                // "rsa"
      satzBlatt := "/rsaleaf.pem"c; satzKey := "/rsaleafkey.pem"c; satzCa := "/rsaca.pem"c;
    }
  }
  if (GetArgC() > 3) { mtls := 1; }

  var dSrv: int64 := alloc(8192); var lSrv: int64 := ladeDer(StrConcat(basis, satzBlatt), "CERTIFICATE"c, dSrv);
  var dCa: int64 := alloc(8192);  var lCa: int64 := ladeDer(StrConcat(basis, satzCa), "CERTIFICATE"c, dCa);
  var dSk: int64 := alloc(8192);  var lSk: int64 := ladeDer(StrConcat(basis, satzKey), "PRIVATE KEY"c, dSk);
  if (lSrv <= 0 || lSk <= 0) { PrintLn("LADEFEHLER"); return 1; }
  var kette: int64 := alloc(32);
  poke64(kette, dSrv); poke64(kette + 8, lSrv);
  poke64(kette + 16, dCa); poke64(kette + 24, lCa);

  var cfg: int64 := alloc(TlsConfigGroesse());
  var alpn: pchar := "h2,http/1.1"c;
  TlsConfigNeu(cfg, 1);
  TlsConfigKette(cfg, kette, 2, dSk, lSk);
  TlsConfigAlpn(cfg, alpn as int64, StrLen(alpn));
  TlsConfigZeit(cfg, 1800000000);
  TlsConfigMinVersion(cfg, TlsVersion12());
  if (mtls > 0) {
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
  var c: int64 := Tls12Neu(cfg);
  var puf: int64 := alloc(32768);
  var runden: int64 := 0;
  while (!Tls12Fertig(c) && runden < 200) {
    var rc: int64 := Tls12Schritt(c);
    if (rc < 0) {
      Print("FEHLER "); PrintInt(rc); Print(" "); PrintLn(Tls12FehlerText(rc));
      var mf: int64 := Tls12Ausgabe(c, puf, 32768);
      if (mf > 0) { TCPConnWrite(conn, puf as pchar, mf); }
      TCPConnClose(conn); TCPListenerClose(l);
      return 1;
    }
    var m: int64 := Tls12Ausgabe(c, puf, 32768);
    if (m > 0) { TCPConnWrite(conn, puf as pchar, m); }
    if (!Tls12Fertig(c)) {
      var n: int64 := TCPConnRead(conn, puf as pchar, 32768);
      if (n <= 0) { PrintLn("VERBINDUNG-WEG"); return 1; }
      Tls12Fuetter(c, puf, n);
    }
    runden := runden + 1;
  }
  if (!Tls12Fertig(c)) { PrintLn("HANDSCHLAG-UNFERTIG"); return 1; }
  Print("ems "); PrintInt(Tls12EMS(c)); PrintLn("");
  var pz: int64 := Tls12PeerZertifikat(c);
  if (pz != 0) { Print("client-zertifikat-geprueft "); PrintInt(X509SubjectLen(pz) > 0); PrintLn(""); }
  Print("handschlag-fertig suite "); PrintInt(Tls12Suite(c));
  Print(" gruppe "); PrintInt(Tls12Gruppe(c));
  Print(" alpn ");
  var i: int64 := 0;
  while (i < Tls12AlpnLen(c)) { PrintChar(peek8(Tls12AlpnPos(c) + i)); i := i + 1; }
  PrintLn("");

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
    gelesen := Tls12Lese(c, ein, 4096);
    if (gelesen <= 0) {
      var n2: int64 := TCPConnRead(conn, puf as pchar, 32768);
      if (n2 > 0) { Tls12Fuetter(c, puf, n2); }
      gelesen := Tls12Lese(c, ein, 4096);
      if (n2 <= 0 && gelesen <= 0) { runden := 100; }
    }
    runden := runden + 1;
  }
  Print("empfangen "); PrintInt(gelesen); Print(" ");
  i := 0;
  while (i < gelesen) { if (peek8(ein + i) >= 32) { PrintChar(peek8(ein + i)); } i := i + 1; }
  PrintLn("");
  var antwort: pchar := "HTTP/1.0 200 OK\r\nContent-Length: 12\r\n\r\nLyx TLS 1.2\n"c;
  Tls12Schreibe(c, antwort as int64, StrLen(antwort));
  var m2: int64 := Tls12Ausgabe(c, puf, 32768);
  TCPConnWrite(conn, puf as pchar, m2);
  Tls12Schliessen(c);
  m2 := Tls12Ausgabe(c, puf, 32768);
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
import std.net.tls_config;
import std.net.tls12;

fn ladeDer(pfad: pchar, label: pchar, derOut: int64): int64 {
  var pem: int64 := alloc(8192);
  var n: int64 := ReadFile(pfad, pem as pchar, 8191);
  if (n <= 0) { return -1; }
  return PemDekodiere(pem, n, label as int64, StrLen(label), derOut, 4096);
}

fn main(): int64 {
  var basis: pchar := "CERTDIRMARKER"c;
  var port: int64 := StrToInt(GetArg(1) as pchar);
  var caPfad: pchar := "/tlsca.pem"c;
  var erwartet: pchar := "nexus.example"c;
  var mtls: int64 := 0;
  if (GetArgC() > 2) {
    var w: pchar := GetArg(2) as pchar;
    if (StrCharAt(w, 0) == 114) { caPfad := "/rsaca.pem"c; erwartet := "rsa.example"c; }
  }
  if (GetArgC() > 3) { mtls := 1; }

  var dCa: int64 := alloc(8192);  var lCa: int64 := ladeDer(StrConcat(basis, caPfad), "CERTIFICATE"c, dCa);
  var dCli: int64 := alloc(4096); var lCli: int64 := ladeDer(StrConcat(basis, "/tlscli.pem"c), "CERTIFICATE"c, dCli);
  var dCk: int64 := alloc(4096);  var lCk: int64 := ladeDer(StrConcat(basis, "/tlsclikey.pem"c), "PRIVATE KEY"c, dCk);
  var trust: int64 := alloc(16); poke64(trust, dCa); poke64(trust + 8, lCa);
  var kette: int64 := alloc(16); poke64(kette, dCli); poke64(kette + 8, lCli);

  var cfg: int64 := alloc(TlsConfigGroesse());
  var alpn: pchar := "http/1.1"c;
  TlsConfigNeu(cfg, 2);
  TlsConfigTrust(cfg, trust, 1);
  TlsConfigHost(cfg, erwartet as int64, StrLen(erwartet));
  TlsConfigAlpn(cfg, alpn as int64, StrLen(alpn));
  TlsConfigZeit(cfg, 1800000000);
  TlsConfigMinVersion(cfg, TlsVersion12());
  if (mtls > 0) { TlsConfigKette(cfg, kette, 1, dCk, lCk); }

  var conn: TCPConn := TCPConnect(0x7F000001, port);
  var c: int64 := Tls12Neu(cfg);
  var puf: int64 := alloc(32768);
  var runden: int64 := 0;
  while (!Tls12Fertig(c) && runden < 200) {
    var rc: int64 := Tls12Schritt(c);
    if (rc < 0) { Print("FEHLER "); PrintInt(rc); Print(" "); PrintLn(Tls12FehlerText(rc)); return 1; }
    var m: int64 := Tls12Ausgabe(c, puf, 32768);
    if (m > 0) { TCPConnWrite(conn, puf as pchar, m); }
    if (!Tls12Fertig(c)) {
      var n: int64 := TCPConnRead(conn, puf as pchar, 32768);
      if (n <= 0) { PrintLn("VERBINDUNG-WEG"); return 1; }
      Tls12Fuetter(c, puf, n);
    }
    runden := runden + 1;
  }
  if (!Tls12Fertig(c)) { PrintLn("HANDSCHLAG-UNFERTIG"); return 1; }
  Print("ems "); PrintInt(Tls12EMS(c)); PrintLn("");
  Print("handschlag-fertig suite "); PrintInt(Tls12Suite(c)); PrintLn("");
  Print("serverzertifikat-geprueft ");
  if (Tls12PeerZertifikat(c) != 0) { PrintInt(1); } else { PrintInt(0); }
  PrintLn("");

  var frage: pchar := "ping aus Lyx\n"c;
  Tls12Schreibe(c, frage as int64, StrLen(frage));
  var m2: int64 := Tls12Ausgabe(c, puf, 32768);
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
    gelesen := Tls12Lese(c, ein, 4096);
    if (gelesen <= 0) {
      var n2: int64 := TCPConnRead(conn, puf as pchar, 32768);
      if (n2 > 0) { Tls12Fuetter(c, puf, n2); }
      gelesen := Tls12Lese(c, ein, 4096);
      if (n2 <= 0) { runden := 50; }
    }
    runden := runden + 1;
  }
  Print("antwort "); PrintInt(gelesen); Print(" ");
  var i: int64 := 0;
  while (i < gelesen) { if (peek8(ein + i) >= 32) { PrintChar(peek8(ein + i)); } i := i + 1; }
  PrintLn("");
  Tls12Schliessen(c);
  m2 := Tls12Ausgabe(c, puf, 32768);
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
  [ -x "$TMP/$prog" ] || { echo "FAIL $prog: kein Erzeugnis"; exit 1; }
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


PORT=18900
freierPort() {
  while ss -ltn 2>/dev/null | grep -q ":$PORT "; do PORT=$((PORT+1)); done
  echo "$PORT"
}

# --- 1. unser Server gegen s_client, drei AEAD-Familien ---
for suite in ECDHE-ECDSA-AES128-GCM-SHA256 ECDHE-ECDSA-AES256-GCM-SHA384 ECDHE-ECDSA-CHACHA20-POLY1305; do
  p="$(freierPort)"; PORT=$((PORT+1))
  ( ulimit -v 4000000 -c 0; "$TMP/srv" "$p" > "$TMP/srv_$suite.txt" 2>&1 ) &
  srvpid=$!
  warteAufPort "$p" 20 || echo "  HINWEIS: Server lauscht nach 20 s nicht auf $p"
  rm -f "$TMP/fifo_$suite"; mkfifo "$TMP/fifo_$suite"
  ( printf 'GET / HTTP/1.0\r\n\r\n'; sleep 30 ) > "$TMP/fifo_$suite" &
  feedpid=$!
  timeout 40 openssl s_client -connect "127.0.0.1:$p" -ign_eof -tls1_2 \
     -servername nexus.example -CAfile "$TMP/certs/tlsca.pem" \
     -cipher "$suite" < "$TMP/fifo_$suite" > "$TMP/os_$suite.txt" 2>&1 &
  ospid=$!
  # #2418: jede Bedingung, auf die unten geurteilt wird.
  warteAufAlle 30 \
    "$TMP/os_$suite.txt" "Protocol *: TLSv1.2" \
    "$TMP/os_$suite.txt" "Cipher *: $suite" \
    "$TMP/os_$suite.txt" "Verify return code: 0 (ok)" \
    "$TMP/os_$suite.txt" "Extended master secret: yes" \
    "$TMP/os_$suite.txt" "Lyx TLS 1.2" \
    "$TMP/srv_$suite.txt" "empfangen 18 GET / HTTP/1.0"
  kill "$ospid" "$feedpid" "$srvpid" 2>/dev/null
  wait "$ospid" "$feedpid" "$srvpid" 2>/dev/null
  rm -f "$TMP/fifo_$suite"
  fehlend=""
  grep -q "Protocol *: TLSv1.2" "$TMP/os_$suite.txt" || fehlend="$fehlend protokoll"
  grep -q "Cipher *: $suite" "$TMP/os_$suite.txt" || fehlend="$fehlend cipher"
  grep -q "Verify return code: 0 (ok)" "$TMP/os_$suite.txt" || fehlend="$fehlend verify"
  grep -q "Extended master secret: yes" "$TMP/os_$suite.txt" || fehlend="$fehlend ems"
  grep -q "Lyx TLS 1.2" "$TMP/os_$suite.txt" || fehlend="$fehlend nutzdaten-bei-openssl"
  grep -q "empfangen 18 GET / HTTP/1.0" "$TMP/srv_$suite.txt" || fehlend="$fehlend anfrage-im-server"
  ok=1; [ -n "$fehlend" ] && ok=0
  pruefe "Server gegen s_client, $suite" "$ok"
  if [ "$ok" != 1 ]; then
    echo "  gefallene Bedingungen:$fehlend"
    echo "  openssl: $(grep -E 'Protocol|Cipher *:|Verify return code|Extended master' "$TMP/os_$suite.txt" | tr '\n' ' ')"
    echo "  lyx:     $(tr '\n' ' ' < "$TMP/srv_$suite.txt")"
  fi
done

# --- 2. Gegenprobe: ohne Extended Master Secret MUSS es scheitern ---
p="$(freierPort)"; PORT=$((PORT+1))
( ulimit -v 4000000 -c 0; "$TMP/srv" "$p" > "$TMP/srv_noems.txt" 2>&1 ) &
srvpid=$!
warteAufPort "$p" 20 || echo "  HINWEIS: Server lauscht nach 20 s nicht auf $p"
printf 'GET / HTTP/1.0\r\n\r\n' | timeout 25 openssl s_client -connect "127.0.0.1:$p" \
   -tls1_2 -no_ems -servername nexus.example -CAfile "$TMP/certs/tlsca.pem" \
   > "$TMP/os_noems.txt" 2>&1
wait "$srvpid" 2>/dev/null
ok=1
grep -q "FEHLER -17" "$TMP/srv_noems.txt" || ok=0
grep -q "Lyx TLS 1.2" "$TMP/os_noems.txt" && ok=0
pruefe "ohne Extended Master Secret abgewiesen (-17)" "$ok"
[ "$ok" != 1 ] && echo "  lyx: $(tr '\n' ' ' < "$TMP/srv_noems.txt")"

# --- 3. Gegenprobe: eine CBC-Suite MUSS scheitern ---
p="$(freierPort)"; PORT=$((PORT+1))
( ulimit -v 4000000 -c 0; "$TMP/srv" "$p" > "$TMP/srv_cbc.txt" 2>&1 ) &
srvpid=$!
warteAufPort "$p" 20 || echo "  HINWEIS: Server lauscht nach 20 s nicht auf $p"
printf 'GET / HTTP/1.0\r\n\r\n' | timeout 25 openssl s_client -connect "127.0.0.1:$p" \
   -tls1_2 -cipher ECDHE-ECDSA-AES128-SHA -servername nexus.example \
   -CAfile "$TMP/certs/tlsca.pem" > "$TMP/os_cbc.txt" 2>&1
wait "$srvpid" 2>/dev/null
ok=1
grep -q "FEHLER -3" "$TMP/srv_cbc.txt" || ok=0
grep -q "Lyx TLS 1.2" "$TMP/os_cbc.txt" && ok=0
pruefe "CBC-Suite abgewiesen (-3)" "$ok"
[ "$ok" != 1 ] && echo "  lyx: $(tr '\n' ' ' < "$TMP/srv_cbc.txt")"

# --- 3b. #2582: der Server MUSS die signature_algorithms des Clients lesen ---
#
# Bis 1.2.44G signierte diese Unit mit einem FESTEN Verfahren je Schluesselart,
# ohne die Liste anzusehen: art 1 immer ecdsa_secp256r1_sha256. Ein Client, der
# dieses Verfahren nicht anbietet, bekam es trotzdem -- ein Protokollfehler
# (RFC 5246 Paragraph 7.4.1.4.1).
#
# ZWEISEITIG, denn eine Pruefung, die nur zeigt "mit passendem Verfahren geht
# es", waere auch von der alten, blinden Fassung erfuellt gewesen:
#   a) Client bietet NUR ecdsa_secp384r1_sha384, unser Schluessel ist P-256
#      -> Handschlag MUSS scheitern, und zwar mit E_UNTERSTUETZT (-12).
#   b) Client bietet ecdsa_secp256r1_sha256 -> Handschlag MUSS gelingen.
# Der Server ist in beiden Faellen derselbe; nur die Liste des Clients wechselt.
#
# WARUM NICHT "nur RSA-PSS anbieten": dann bietet OpenSSL auch nur RSA-SUITES
# an, und unser Server weist schon dort ab (FEHLER -3, keine gemeinsame Suite).
# Die Signaturwahl kaeme nie dran, und die Probe haette etwas anderes gemessen
# als sie behauptet. Mit ECDSA+SHA384 bleiben die EC-Suiten im Angebot, und
# allein das VERFAHREN passt nicht zu unserem P-256-Schluessel.
#
# GEURTEILT WIRD UEBER DEN HANDSCHLAG, nicht ueber die Nutzdaten: diese
# Aufrufform (`printf | s_client`) beendet den Client, sobald seine Eingabe
# endet, und unsere Antwort kann dann noch unterwegs sein. Darum Cipher und
# Verify-Code, nicht die Nutzdatenmarke.
for fall in nur-p384 mit-p256; do
  if [ "$fall" = nur-p384 ]; then sa="ECDSA+SHA384"; else sa="ECDSA+SHA256"; fi
  p="$(freierPort)"; PORT=$((PORT+1))
  ( ulimit -v 4000000 -c 0; "$TMP/srv" "$p" > "$TMP/srv_sa_$fall.txt" 2>&1 ) &
  srvpid=$!
  warteAufPort "$p" 20 || echo "  HINWEIS: Server lauscht nach 20 s nicht auf $p"
  printf 'GET / HTTP/1.0\r\n\r\n' | timeout 25 openssl s_client -connect "127.0.0.1:$p" \
     -tls1_2 -sigalgs "$sa" -servername nexus.example \
     -CAfile "$TMP/certs/tlsca.pem" > "$TMP/os_sa_$fall.txt" 2>&1
  wait "$srvpid" 2>/dev/null
  if [ "$fall" = nur-p384 ]; then
    ok=1
    grep -q "FEHLER -12" "$TMP/srv_sa_$fall.txt" || ok=0
    # Die Gegenseite darf den Handschlag NICHT abgeschlossen haben. Geprueft
    # wird an der Suite-Zeile, nicht am Verify-Code: OpenSSL prueft die
    # Zertifikatskette, BEVOR unser Abbruch bei ihm ankommt, und meldet dann
    # voellig zu Recht "Verify return code: 0 (ok)". Mit dieser Bedingung war
    # die Probe rot, obwohl der Server richtig abgewiesen hatte.
    grep -qE "Cipher *: *ECDHE" "$TMP/os_sa_$fall.txt" && ok=0
    pruefe "nur ecdsa_secp384r1_sha384 angeboten, P-256-Schluessel: abgewiesen (-12)" "$ok"
    [ "$ok" != 1 ] && echo "  lyx: $(tr '\n' ' ' < "$TMP/srv_sa_$fall.txt")"
  else
    ok=1
    grep -q "Cipher *: ECDHE-ECDSA" "$TMP/os_sa_$fall.txt" || ok=0
    grep -q "Verify return code: 0 (ok)" "$TMP/os_sa_$fall.txt" || ok=0
    pruefe "ecdsa_secp256r1_sha256 angeboten: Handschlag gelingt" "$ok"
    [ "$ok" != 1 ] && echo "  openssl: $(grep -E 'Cipher *:|Verify return' "$TMP/os_sa_$fall.txt" | tr '\n' ' ')"
  fi
done

# --- 4. unser Server mit verlangtem Client-Zertifikat ---
p="$(freierPort)"; PORT=$((PORT+1))
( ulimit -v 4000000 -c 0; "$TMP/srv" "$p" ec mtls > "$TMP/srv_mtls.txt" 2>&1 ) &
srvpid=$!
warteAufPort "$p" 20 || echo "  HINWEIS: Server lauscht nach 20 s nicht auf $p"
rm -f "$TMP/fifo_m"; mkfifo "$TMP/fifo_m"
( printf 'GET / HTTP/1.0\r\n\r\n'; sleep 30 ) > "$TMP/fifo_m" &
feedpid=$!
timeout 40 openssl s_client -connect "127.0.0.1:$p" -ign_eof -tls1_2 \
   -servername nexus.example -CAfile "$TMP/certs/tlsca.pem" \
   -cert "$TMP/certs/tlscli.pem" -key "$TMP/certs/tlsclikey.pem" \
   < "$TMP/fifo_m" > "$TMP/os_mtls.txt" 2>&1 &
ospid=$!
# #2418: beide Bedingungen, und eine davon steht in der Serverdatei.
warteAufAlle 30 \
  "$TMP/os_mtls.txt" "Lyx TLS 1.2" \
  "$TMP/os_mtls.txt" "Verify return code: 0 (ok)" \
  "$TMP/srv_mtls.txt" "client-zertifikat-geprueft 1"
kill "$ospid" "$feedpid" "$srvpid" 2>/dev/null
wait "$ospid" "$feedpid" "$srvpid" 2>/dev/null
rm -f "$TMP/fifo_m"
ok=1
grep -q "client-zertifikat-geprueft 1" "$TMP/srv_mtls.txt" || ok=0
grep -q "Verify return code: 0 (ok)" "$TMP/os_mtls.txt" || ok=0
pruefe "Server verlangt Client-Zertifikat: mit Zertifikat Erfolg" "$ok"
[ "$ok" != 1 ] && echo "  lyx: $(tr '\n' ' ' < "$TMP/srv_mtls.txt")"

p="$(freierPort)"; PORT=$((PORT+1))
( ulimit -v 4000000 -c 0; "$TMP/srv" "$p" ec mtls > "$TMP/srv_mtls2.txt" 2>&1 ) &
srvpid=$!
warteAufPort "$p" 20 || echo "  HINWEIS: Server lauscht nach 20 s nicht auf $p"
printf 'GET / HTTP/1.0\r\n\r\n' | timeout 25 openssl s_client -connect "127.0.0.1:$p" \
   -tls1_2 -servername nexus.example -CAfile "$TMP/certs/tlsca.pem" \
   > "$TMP/os_mtls2.txt" 2>&1
wait "$srvpid" 2>/dev/null
ok=1
grep -q "FEHLER -6" "$TMP/srv_mtls2.txt" || ok=0
pruefe "Server verlangt Client-Zertifikat: ohne eines abgewiesen (-6)" "$ok"
[ "$ok" != 1 ] && echo "  lyx: $(tr '\n' ' ' < "$TMP/srv_mtls2.txt")"

# --- 5. unser Client gegen s_server, EC und RSA, ohne und mit mTLS ---
for art in ec rsa; do
  blatt="tlssrv"; key="tlssrvkey"
  if [ "$art" = rsa ]; then blatt="rsaleaf"; key="rsaleafkey"; fi
  p="$(freierPort)"; PORT=$((PORT+1))
  rm -f "$TMP/fifo_c$art"; mkfifo "$TMP/fifo_c$art"
  openssl s_server -accept "$p" -cert "$TMP/certs/$blatt.pem" -key "$TMP/certs/$key.pem" \
    -tls1_2 -quiet < "$TMP/fifo_c$art" > "$TMP/os_srv_$art.txt" 2>&1 &
  ( printf 'pong aus openssl\n'; sleep 8 ) > "$TMP/fifo_c$art" &
  warteAufPort "$p" 20 || echo "  HINWEIS: s_server lauscht nach 20 s nicht auf $p"
  ( ulimit -v 4000000 -c 0; timeout 25 "$TMP/cli" "$p" "$art" ) > "$TMP/cli_$art.txt" 2>&1
  pkill -f "s_server -accept $p" 2>/dev/null
  rm -f "$TMP/fifo_c$art"
  ok=1; fehlend=""
  grep -q "^ems 1" "$TMP/cli_$art.txt" || fehlend="$fehlend ems"
  grep -q "handschlag-fertig suite" "$TMP/cli_$art.txt" || fehlend="$fehlend handschlag"
  grep -q "serverzertifikat-geprueft 1" "$TMP/cli_$art.txt" || fehlend="$fehlend zertifikat"
  grep -q "antwort 17 pong aus openssl" "$TMP/cli_$art.txt" || fehlend="$fehlend nutzdaten"
  [ -n "$fehlend" ] && ok=0
  pruefe "Client gegen s_server mit $art-Zertifikat" "$ok"
  if [ "$ok" != 1 ]; then
    echo "  gefallene Bedingungen:$fehlend"
    echo "  lyx: $(tr '\n' ' ' < "$TMP/cli_$art.txt")"
  fi
done

p="$(freierPort)"; PORT=$((PORT+1))
rm -f "$TMP/fifo_cm"; mkfifo "$TMP/fifo_cm"
openssl s_server -accept "$p" -cert "$TMP/certs/tlssrv.pem" -key "$TMP/certs/tlssrvkey.pem" \
  -CAfile "$TMP/certs/tlsca.pem" -Verify 2 -tls1_2 -quiet < "$TMP/fifo_cm" \
  > "$TMP/os_srv_mtls.txt" 2>&1 &
( printf 'pong aus openssl\n'; sleep 8 ) > "$TMP/fifo_cm" &
warteAufPort "$p" 20 || echo "  HINWEIS: s_server lauscht nach 20 s nicht auf $p"
( ulimit -v 4000000 -c 0; timeout 25 "$TMP/cli" "$p" ec mtls ) > "$TMP/cli_mtls.txt" 2>&1
pkill -f "s_server -accept $p" 2>/dev/null
rm -f "$TMP/fifo_cm"
ok=1
grep -q "antwort 17 pong aus openssl" "$TMP/cli_mtls.txt" || ok=0
pruefe "Client gegen s_server mit Client-Zertifikat (mTLS)" "$ok"
[ "$ok" != 1 ] && echo "  lyx: $(tr '\n' ' ' < "$TMP/cli_mtls.txt")"

echo "--- $PASS PASS, $FAIL FAIL"
if [ "$FAIL" != 0 ]; then exit 1; fi
echo "ALL PASS"
exit 0
