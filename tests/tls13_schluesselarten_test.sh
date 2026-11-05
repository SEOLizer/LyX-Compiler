#!/usr/bin/env bash
# tests/tls13_schluesselarten_test.sh — #2096: TLS 1.3 mit EC-, RSA- und Ed25519-Serverzertifikat
#
# Derselbe Handschlag dreimal, je mit einer anderen Schluesselart des
# Servers: EC P-256 (ecdsa_secp256r1_sha256), RSA-2048
# (rsa_pss_rsae_sha256) und Ed25519. Jeder Fall muss 0 liefern und danach
# Anwendungsdaten durchlassen. Der Fall RSA war der Grund, das Zertifikat der
# Gegenseite in den Verbindungsblock zu kopieren: im Empfangspuffer wurde der
# Modulus vom naechsten Record ueberschrieben, und zwar nur bei RSA, weil
# dessen CertificateVerify lang genug ist.
#
# Die Zertifikate stehen unten im Test, der Lauf braucht kein openssl und
# kein Netz.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/certs"
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
cat > "$TMP/certs/rsaleaf384.pem" <<'PEMEOF'
-----BEGIN CERTIFICATE-----
MIIDEjCCAfqgAwIBAgIDAIADMA0GCSqGSIb3DQEBDAUAMCwxFTATBgNVBAMMDEF1
cnVtIFJTQSBDQTETMBEGA1UECgwKQXVydW0gVGVzdDAeFw0yNjAxMDEwMDAwMDBa
Fw0zNjAxMDEwMDAwMDBaMC4xFzAVBgNVBAMMDnJzYTM4NC5leGFtcGxlMRMwEQYD
VQQKDApBdXJ1bSBUZXN0MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA
ze84br/Pbm9QIPB/lbkrfwUprsebl15/BpHArICq0iPzvgpnx9/wJi6V8AapGK70
BreYqkF3AjdVgbT9GiFv9lks+zNf7sk8g184fkB3brHPrCZaQhmsB3ZFupU3i/8t
M3NOVdEi8hfEK0LzEms4trJbGAmM2YUpVD8aJ2iI2k6FnQAgrs2YWUrmE8+TLvSR
mJFP96Q5sUeaVnbWWuqx/Nf3ZhMqPjx4rrWUGV393vn5nDG2X7hZJjpFjZF/en65
8uDJRjbkm4a0YTAnsCnqmj7ss4i1z7DDsdNSF3/PPLN+P095bMcvG88/5PfFgXu4
Dydxb5+EZ84Mmn4mgcuIxwIDAQABozswOTAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB
/wQEAwIHgDAZBgNVHREEEjAQgg5yc2EzODQuZXhhbXBsZTANBgkqhkiG9w0BAQwF
AAOCAQEAWG3Zu0B4MzhrVLwEY2jZVnov/nzsmEwA1ApoK0vPtti19CSbH0inKSLj
NZMJDn7BVqR4fjyFlopcy9wJW5/z7kLWBSRtXAsiPoTaXcPZ3unqXSarD86+acu2
Aayhwm/EK/MjWlIsvvZ7VD4HG0QTgm8pZlzS8bDTYMm9GR104r7wUPtOp63aXlBV
LyjCJ6RXUvIbNp/20E0T6fV4J5ybyOtfhzEHavJoD90VyaUP6fWb+EjN/t22QSSN
sU164FhCllFuShrU5om1P9Q3D+11QXH1cWPZYn2WsK4HyMYiaUHXLbIAvO/Yswio
eAF54duqXF4lZIWulfa6CNFTv7snFg==
-----END CERTIFICATE-----
PEMEOF
cat > "$TMP/certs/rsaleafpss.pem" <<'PEMEOF'
-----BEGIN CERTIFICATE-----
MIIDajCCAh6gAwIBAgIDAIAEMEEGCSqGSIb3DQEBCjA0oA8wDQYJYIZIAWUDBAIB
BQChHDAaBgkqhkiG9w0BAQgwDQYJYIZIAWUDBAIBBQCiAwIBIDAsMRUwEwYDVQQD
DAxBdXJ1bSBSU0EgQ0ExEzARBgNVBAoMCkF1cnVtIFRlc3QwHhcNMjYwMTAxMDAw
MDAwWhcNMzYwMTAxMDAwMDAwWjAuMRcwFQYDVQQDDA5yc2Fwc3MuZXhhbXBsZTET
MBEGA1UECgwKQXVydW0gVGVzdDCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoC
ggEBAM3vOG6/z25vUCDwf5W5K38FKa7Hm5defwaRwKyAqtIj874KZ8ff8CYulfAG
qRiu9Aa3mKpBdwI3VYG0/Rohb/ZZLPszX+7JPINfOH5Ad26xz6wmWkIZrAd2RbqV
N4v/LTNzTlXRIvIXxCtC8xJrOLayWxgJjNmFKVQ/GidoiNpOhZ0AIK7NmFlK5hPP
ky70kZiRT/ekObFHmlZ21lrqsfzX92YTKj48eK61lBld/d75+Zwxtl+4WSY6RY2R
f3p+ufLgyUY25JuGtGEwJ7Ap6po+7LOItc+ww7HTUhd/zzyzfj9PeWzHLxvPP+T3
xYF7uA8ncW+fhGfODJp+JoHLiMcCAwEAAaMrMCkwDAYDVR0TAQH/BAIwADAZBgNV
HREEEjAQgg5yc2Fwc3MuZXhhbXBsZTBBBgkqhkiG9w0BAQowNKAPMA0GCWCGSAFl
AwQCAQUAoRwwGgYJKoZIhvcNAQEIMA0GCWCGSAFlAwQCAQUAogMCASADggEBACaF
vq884Wfs9XPERJaDQ+OlSeVIXNRuhzZ6ZJYdv19gnArUg/+qMA2htg/AUUpYrWHS
knM5bp6OYW0idGxjK+UAw81KTB4dcnaHKuxabRHgBwa7F/7wN+Ezi9iyRK8qn+Bi
RW125VsSk+0RdtJrLjVCBDYLxxpOi+dSbjl1Fe4F6qP8eYInn8rU5I1ikfgLUpWY
wuyeSfcawtieryCKOA2xdAmwDbMCdtYr0ozt2hvC0EVSNHl5ODlBOCslNKJX/mlv
XsGPj1fI+PW0JbgznPPxv08DFAZLUnZfhBeREtTgXJA5tS/h/WM1bdZcplk1qXWU
ycKJvfUcPVzIAUyWfdY=
-----END CERTIFICATE-----
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
cat > "$TMP/certs/edleafkey.pem" <<'PEMEOF'
-----BEGIN PRIVATE KEY-----
MC4CAQAwBQYDK2VwBCIEIFD4PnGAF9NwCKEQ50+xruut4Mv/aYarhDZ1AH/369qK
-----END PRIVATE KEY-----
PEMEOF
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
cat > "$TMP/certs/tlssrvkey.pem" <<'PEMEOF'
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgvPS7dPO8HJT+dnMm
V3fUzeQjctLlp5lQPFJtHAnu3OuhRANCAAR07FsqWaBwvGPo7wx4Fl7pimrOWA1j
smmIVkBo46iEaaD/FpxuZod/kLBzFCGiI4sV+txMWw92yVuWSnDFhyC7
-----END PRIVATE KEY-----
PEMEOF

cat > "$TMP/s.lyx" <<'LYXEOF'
unit main;
import std.io;
import std.alloc;
import std.fs;
import std.crypto.der;
import std.crypto.x509;
import std.net.tls13;

fn ladeDer(pfad: pchar, label: pchar, derOut: int64): int64 {
  var pem: int64 := alloc(16384);
  var n: int64 := ReadFile(pfad, pem as pchar, 16383);
  if (n <= 0) { return -1; }
  return PemDekodiere(pem, n, label as int64, StrLen(label), derOut, 8192);
}
fn handschlag(sv: int64, cl: int64): int64 {
  var puf: int64 := alloc(32768);
  var r: int64 := 0;
  while (r < 60) {
    var a: int64 := TlsSchritt(cl);
    if (a < 0) { free(puf, 32768); return a; }
    var n: int64 := TlsAusgabe(cl, puf, 32768);
    if (n > 0) { TlsFuetter(sv, puf, n); }
    var b: int64 := TlsSchritt(sv);
    if (b < 0) { free(puf, 32768); return b; }
    var m: int64 := TlsAusgabe(sv, puf, 32768);
    if (m > 0) { TlsFuetter(cl, puf, m); }
    if (TlsFertig(cl) && TlsFertig(sv)) { free(puf, 32768); return 0; }
    if (n == 0 && m == 0) { free(puf, 32768); return -99; }
    r := r + 1;
  }
  free(puf, 32768);
  return -98;
}
fn fall(name: pchar, basis: pchar, blatt: pchar, key: pchar, wurzel: pchar, host: pchar): void {
  var dL: int64 := alloc(8192); var lL := ladeDer(StrConcat(basis, blatt), "CERTIFICATE"c, dL);
  var dK: int64 := alloc(8192); var lK := ladeDer(StrConcat(basis, key), "PRIVATE KEY"c, dK);
  var dW: int64 := alloc(8192); var lW := ladeDer(StrConcat(basis, wurzel), "CERTIFICATE"c, dW);
  if (lL <= 0 || lK <= 0 || lW <= 0) { Print(name); PrintLn(" LADEFEHLER"); return; }
  var kette: int64 := alloc(16); poke64(kette, dL); poke64(kette + 8, lL);
  var trust: int64 := alloc(16); poke64(trust, dW); poke64(trust + 8, lW);
  var cfgS: int64 := alloc(TlsConfigGroesse());
  var cfgC: int64 := alloc(TlsConfigGroesse());
  TlsConfigNeu(cfgS, 1); TlsConfigKette(cfgS, kette, 1, dK, lK); TlsConfigZeit(cfgS, 1800000000);
  TlsConfigNeu(cfgC, 2); TlsConfigTrust(cfgC, trust, 1);
  TlsConfigHost(cfgC, host as int64, StrLen(host)); TlsConfigZeit(cfgC, 1800000000);
  var sv: int64 := TlsNeu(cfgS);
  var cl: int64 := TlsNeu(cfgC);
  var rc: int64 := handschlag(sv, cl);
  Print(name); Print(" "); PrintInt(rc);
  if (rc == 0) {
    // Anwendungsdaten pruefen
    var text: pchar := "ping"c;
    var puf: int64 := alloc(32768);
    var ein: int64 := alloc(4096);
    TlsSchreibe(cl, text as int64, 4);
    var n: int64 := TlsAusgabe(cl, puf, 32768);
    TlsFuetter(sv, puf, n);
    Print(" daten "); PrintInt(TlsLese(sv, ein, 4096));
  }
  PrintLn("");
  TlsFrei(sv); TlsFrei(cl);
}
fn main(): int64 {
  var basis: pchar := "CERTDIRMARKER"c;
  fall("ec-p256"c, basis, "/tlssrv.pem"c, "/tlssrvkey.pem"c, "/tlsca.pem"c, "nexus.example"c);
  fall("rsa-2048"c, basis, "/rsaleaf.pem"c, "/rsaleafkey.pem"c, "/rsaca.pem"c, "rsa.example"c);
  fall("ed25519"c, basis, "/edleaf.pem"c, "/edleafkey.pem"c, "/edca.pem"c, "ed.example"c);
  return 0;
}
LYXEOF
sed -i "s|CERTDIRMARKER|$TMP/certs|" "$TMP/s.lyx"

if ! ( cd "$ROOT" && timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/s.lyx" -o "$TMP/s" ) >"$TMP/log" 2>&1; then
  echo "FAIL uebersetzt nicht: $(grep -m1 -i error "$TMP/log")"; exit 1
fi
[ -x "$TMP/s" ] || { echo "FAIL kein Erzeugnis (#1682)"; exit 1; }

cat > "$TMP/soll.txt" <<'SOLLEOF'
ec-p256 0 daten 4
rsa-2048 0 daten 4
ed25519 0 daten 4
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
echo "PASS $PASS / FAIL $FAIL"
[ "$FAIL" = 0 ] || exit 1
echo "ALL PASS"
exit 0
