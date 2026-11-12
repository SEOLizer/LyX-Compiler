#!/usr/bin/env bash
# tests/crypto_x509_kette_test.sh — #2096 Etappe D: Signatur- und
# Kettenpruefung nach RFC 5280.
#
# Jeder Fall nennt den erwarteten Fehlercode. Gemessen wird also nicht "die
# gueltige Kette ist gueltig", sondern zu JEDEM Ablehnungsgrund der eigene
# Code — ein Prueflauf, der nur den guten Fall kennt, waere auch von einer
# Funktion erfuellt, die immer 0 liefert:
#   0  gueltige Kette (Blatt P-256 unter P-256-Wurzel, Hostname im SAN)
#   2  Zeitpunkt vor notBefore, und abgelaufenes Zertifikat
#   3  falscher Hostname
#   4  fremde Wurzel, Blatt ohne passenden Aussteller, leerer Trust-Store
#   5  ein gekipptes Byte im Zertifikat
#   6  selbstsigniertes Blatt ohne CA-Flag als eigene Wurzel
#   7  pathLenConstraint 0 an der Zwischenstelle, darunter noch eine CA
#   8  Aussteller ohne keyCertSign
#   10 RSA-Signatur — nicht unterstuetzt, also abgewiesen und nicht gueltig
#
# Die Zertifikate stehen als PEM im Test (python-cryptography erzeugt), damit
# der Lauf ohne openssl und ohne Netz auskommt.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/certs"
cat > "$TMP/certs/ca.pem" <<'PEMEOF'
-----BEGIN CERTIFICATE-----
MIIBrTCCATOgAwIBAgICRxEwCgYIKoZIzj0EAwMwLTEWMBQGA1UEAwwNQXVydW0g
VGVzdCBDQTETMBEGA1UECgwKQXVydW0gVGVzdDAeFw0yNjAxMDEwMDAwMDBaFw0z
NjAxMDEwMDAwMDBaMC0xFjAUBgNVBAMMDUF1cnVtIFRlc3QgQ0ExEzARBgNVBAoM
CkF1cnVtIFRlc3QwdjAQBgcqhkjOPQIBBgUrgQQAIgNiAAQV5/ZUWCYQii++4LQd
6Qfa/cwrBP0uqWxMgY7OZXllPd3mJ+Mm/ted1FikSkVCCShAHj7qFWroNXQ3T9LE
3f1Cs6kkBqzdYMoiK7M2Vkzahw4VvN16fm+NcOUg3PNWVDCjJjAkMBIGA1UdEwEB
/wQIMAYBAf8CAQEwDgYDVR0PAQH/BAQDAgGGMAoGCCqGSM49BAMDA2gAMGUCMH35
wp/rATBm35ZKDq2mlP2/4iDzExC8Gvw/rrnomDz1ftGYbr/LfZJ17AKE7nQOmQIx
AKHr5XIGUsAQTvCNUbY4Ir+yMyiTPWdGsmbxgcZHHc/L9Hv2fLouPFEV6TpZ+OPi
kg==
-----END CERTIFICATE-----
PEMEOF
cat > "$TMP/certs/leaf.pem" <<'PEMEOF'
-----BEGIN CERTIFICATE-----
MIIB6DCCAW6gAwIBAgIEEjSrzTAKBggqhkjOPQQDAjAtMRYwFAYDVQQDDA1BdXJ1
bSBUZXN0IENBMRMwEQYDVQQKDApBdXJ1bSBUZXN0MB4XDTI2MDEwMTAwMDAwMFoX
DTM2MDEwMTAwMDAwMFowLTEWMBQGA1UEAwwNbmV4dXMuZXhhbXBsZTETMBEGA1UE
CgwKQXVydW0gVGVzdDBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABGxLQr2ifp4N
iRalC4M2j4/aa3eruZIekttj0DLnsPirjXUEbEVejYEGskC/N77h2Yzf0RAv1b2L
BTcepAg2zcijfDB6MAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgeAMB0GA1Ud
JQQWMBQGCCsGAQUFBwMBBggrBgEFBQcDAjA7BgNVHREENDAygg1uZXh1cy5leGFt
cGxlgg8qLm5leHVzLmV4YW1wbGWBEGNhQG5leHVzLmV4YW1wbGUwCgYIKoZIzj0E
AwIDaAAwZQIwHf7IFSGOMVNdWn6YkWo3DJkuk0gDwY0rgVBccGXxlyTQNUgdzRax
LBAdUMQcHkPcAjEAj0TO6EIiBMqxd1nW84K84wHj7ppjutuDVL0DwK48Hx/LN3n0
WypNmzAXLTHHgE0d
-----END CERTIFICATE-----
PEMEOF
cat > "$TMP/certs/expired.pem" <<'PEMEOF'
-----BEGIN CERTIFICATE-----
MIIBgTCCAQegAwIBAgIBBzAKBggqhkjOPQQDAjAtMRYwFAYDVQQDDA1BdXJ1bSBU
ZXN0IENBMRMwEQYDVQQKDApBdXJ1bSBUZXN0MB4XDTIwMDEwMTAwMDAwMFoXDTIx
MDEwMTAwMDAwMFowKzEUMBIGA1UEAwwLYWx0LmV4YW1wbGUxEzARBgNVBAoMCkF1
cnVtIFRlc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAARsS0K9on6eDYkWpQuD
No+P2mt3q7mSHpLbY9Ay57D4q411BGxFXo2BBrJAvze+4dmM39EQL9W9iwU3HqQI
Ns3IoxowGDAWBgNVHREEDzANggthbHQuZXhhbXBsZTAKBggqhkjOPQQDAgNoADBl
AjAOiBw3QlBVnZByIJ7LMgyII1oNwzNZd630UT23n/50/b8Gs9kAn5K9ZBbd7XVW
HeACMQDH0FN4e/nbLxHixhxtW+6YphQ9jifuPVJ9ox+hxmW647Ioho56zJ+kX6UR
vmWmz6E=
-----END CERTIFICATE-----
PEMEOF
cat > "$TMP/certs/rsa.pem" <<'PEMEOF'
-----BEGIN CERTIFICATE-----
MIICSzCCAdKgAwIBAgIBCTAKBggqhkjOPQQDAjAtMRYwFAYDVQQDDA1BdXJ1bSBU
ZXN0IENBMRMwEQYDVQQKDApBdXJ1bSBUZXN0MB4XDTI2MDEwMTAwMDAwMFoXDTM2
MDEwMTAwMDAwMFowKzEUMBIGA1UEAwwLcnNhLmV4YW1wbGUxEzARBgNVBAoMCkF1
cnVtIFRlc3QwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCah/dHk0NS
Ncz/AALIrn0fwQvOfllSuSI6fZ4thL+uvZ8k13+Kr74EELdGVOWJz+BsQgn9FsUs
2CKMdtF8Xt4PvC2LUfsUDQP7QDBKub8kR0vt4QwBzOdPqMhsToGGBcpEw7JkfQH5
Qx9K4MHwL6LeJmfx5ym/glETOMz9nEVK/69+PLYJwPVGf3EI7tSCD+fQ6LFWTlo7
2013V7uVbMftpNDUGcjVtGn1CEmjT7ZyJ5UA5hfvXLR1LolMJQRk9GmHzNlwXcm2
QigElXgyn48Bn6Y3jHqZDnKv2+Vi2O++vw1LrQ3XvAu938c0DDc8fDftNtKwNxxf
ouNQ9wDLRzaNAgMBAAGjGjAYMBYGA1UdEQQPMA2CC3JzYS5leGFtcGxlMAoGCCqG
SM49BAMCA2cAMGQCMCwT3XUXlIxk31lDK4VjdM0jZJZTyrfrkC+2zDSyePyYGHrA
akeNbL/BX/7uj5/3WAIwYr1aDhSz+dF/MYNLHFPmS8U9BD3lHaChxYgISJkBIhXN
hDOvJN5emsg+W7lUGoAW
-----END CERTIFICATE-----
PEMEOF
cat > "$TMP/certs/ed.pem" <<'PEMEOF'
-----BEGIN CERTIFICATE-----
MIIBGzCBzqADAgECAgELMAUGAytlcDAqMRMwEQYDVQQDDAplZC5leGFtcGxlMRMw
EQYDVQQKDApBdXJ1bSBUZXN0MB4XDTI2MDEwMTAwMDAwMFoXDTM2MDEwMTAwMDAw
MFowKjETMBEGA1UEAwwKZWQuZXhhbXBsZTETMBEGA1UECgwKQXVydW0gVGVzdDAq
MAUGAytlcAMhANtC1ey5mhL+57V2VAuFjG3Ma2LO1fVF1T3WpxBrvOemoxkwFzAV
BgNVHREEDjAMggplZC5leGFtcGxlMAUGAytlcANBAA+rxaNRAnhKZIwfWcmU3a4R
1tDSuYyyNZ9+kgQuctfOsKR8y679x9kGjsq0Ku0qW18FCgoWpq7k3ji7RGYpPAE=
-----END CERTIFICATE-----
PEMEOF
cat > "$TMP/certs/ca256.pem" <<'PEMEOF'
-----BEGIN CERTIFICATE-----
MIIBcDCCARagAwIBAgICUVAwCgYIKoZIzj0EAwIwLTEWMBQGA1UEAwwNQXVydW0g
UDI1NiBDQTETMBEGA1UECgwKQXVydW0gVGVzdDAeFw0yNjAxMDEwMDAwMDBaFw0z
NjAxMDEwMDAwMDBaMC0xFjAUBgNVBAMMDUF1cnVtIFAyNTYgQ0ExEzARBgNVBAoM
CkF1cnVtIFRlc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAASRkEkxIGMxvzak
cpSFWu2PLYSHVRcawqInAddDM3wxeyZaifPA5GYYqV5g31Okecq/eIAVAQRCQVQs
LNdw1x/voyYwJDASBgNVHRMBAf8ECDAGAQH/AgEBMA4GA1UdDwEB/wQEAwIBhjAK
BggqhkjOPQQDAgNIADBFAiEAlrZY0VeWU76/8asMOyA6P8lRAurTN3V3Q453PPmq
jmUCIGCApOe+iURNS+rLG3/sXN77OFajLePN5xGfpXLjaBLg
-----END CERTIFICATE-----
PEMEOF
cat > "$TMP/certs/leaf256.pem" <<'PEMEOF'
-----BEGIN CERTIFICATE-----
MIIBmTCCAT+gAwIBAgICIiIwCgYIKoZIzj0EAwIwLTEWMBQGA1UEAwwNQXVydW0g
UDI1NiBDQTETMBEGA1UECgwKQXVydW0gVGVzdDAeFw0yNjAxMDEwMDAwMDBaFw0z
NjAxMDEwMDAwMDBaMC0xFjAUBgNVBAMMDW5leHVzLmV4YW1wbGUxEzARBgNVBAoM
CkF1cnVtIFRlc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAARLEXWia+PyefXO
qveMxjIKh6g0Rix2PA/rfm/yNONmvCOexUgzBSJ0Fh41rHpRgQqItCg+WYj2Q8FL
P4MnsyTmo08wTTAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDATBgNVHSUE
DDAKBggrBgEFBQcDATAYBgNVHREEETAPgg1uZXh1cy5leGFtcGxlMAoGCCqGSM49
BAMCA0gAMEUCIQCAUMGp2RvjRQ+q/c7B2e+a3IacplHzaNFLo5fsWW0CagIgewvs
H6EN0RZSeWAiKb8dbDML0DO3W6sqkFcr2B/DUtY=
-----END CERTIFICATE-----
PEMEOF
cat > "$TMP/certs/cab.pem" <<'PEMEOF'
-----BEGIN CERTIFICATE-----
MIIBczCCARmgAwIBAgICUVEwCgYIKoZIzj0EAwIwLTEWMBQGA1UEAwwNQXVydW0g
UDI1NiBDQTETMBEGA1UECgwKQXVydW0gVGVzdDAeFw0yNjAxMDEwMDAwMDBaFw0z
NjAxMDEwMDAwMDBaMDAxGTAXBgNVBAMMEEF1cnVtIFp3aXNjaGVuIEIxEzARBgNV
BAoMCkF1cnVtIFRlc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAARuN2sJ25z7
QKlHbpcrM2XFnnFs0HjXOIfzxzOlQaZeTDGqbc98JmthOc6eaAdiDtrAYkDStiS+
KPWLmfXI1vMsoyYwJDASBgNVHRMBAf8ECDAGAQH/AgEAMA4GA1UdDwEB/wQEAwIC
BDAKBggqhkjOPQQDAgNIADBFAiEAjNUvePCODd/tZwZhcH6nMBxOf448tvt3IoiZ
ccJOf4ECID3bd2YUa/W8eS7Ty5gV2x1VUwLGH988DhSjKQcyBJps
-----END CERTIFICATE-----
PEMEOF
cat > "$TMP/certs/cac.pem" <<'PEMEOF'
-----BEGIN CERTIFICATE-----
MIIBdjCCARygAwIBAgICUVIwCgYIKoZIzj0EAwIwMDEZMBcGA1UEAwwQQXVydW0g
Wndpc2NoZW4gQjETMBEGA1UECgwKQXVydW0gVGVzdDAeFw0yNjAxMDEwMDAwMDBa
Fw0zNjAxMDEwMDAwMDBaMDAxGTAXBgNVBAMMEEF1cnVtIFp3aXNjaGVuIEMxEzAR
BgNVBAoMCkF1cnVtIFRlc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAATBFh6H
eeppe/Xleqs88BAg9Uwi1x309o8Vck+7hvSvzZ9H+z/jv7ab3dYeiSuV2NTK/Dl8
WZlesbZHQvY44xjmoyYwJDASBgNVHRMBAf8ECDAGAQH/AgEAMA4GA1UdDwEB/wQE
AwICBDAKBggqhkjOPQQDAgNIADBFAiAxVFM0X8AC8OloOZGCHwq89LDdC/CSbEfq
pHi+CIAMaQIhAI7clskmZnBV1JjgU0OLjD36eVC5gO3S4X+OGrp52aLJ
-----END CERTIFICATE-----
PEMEOF
cat > "$TMP/certs/leaf3.pem" <<'PEMEOF'
-----BEGIN CERTIFICATE-----
MIIBhjCCASugAwIBAgICIiMwCgYIKoZIzj0EAwIwMDEZMBcGA1UEAwwQQXVydW0g
Wndpc2NoZW4gQzETMBEGA1UECgwKQXVydW0gVGVzdDAeFw0yNjAxMDEwMDAwMDBa
Fw0zNjAxMDEwMDAwMDBaMCwxFTATBgNVBAMMDHRpZWYuZXhhbXBsZTETMBEGA1UE
CgwKQXVydW0gVGVzdDBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABEsRdaJr4/J5
9c6q94zGMgqHqDRGLHY8D+t+b/I042a8I57FSDMFInQWHjWselGBCoi0KD5ZiPZD
wUs/gyezJOajOTA3MAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgeAMBcGA1Ud
EQQQMA6CDHRpZWYuZXhhbXBsZTAKBggqhkjOPQQDAgNJADBGAiEA4dUXgKnYsWrB
ot4pgmXXR9zyOxzxga86ti5qeWIfhskCIQD9OMFFQEmiZ2CvQcZkCI06qit2H44H
QUUQVY+/vhEtfA==
-----END CERTIFICATE-----
PEMEOF
cat > "$TMP/certs/leafb.pem" <<'PEMEOF'
-----BEGIN CERTIFICATE-----
MIIBjjCCATOgAwIBAgICIiUwCgYIKoZIzj0EAwIwMDEZMBcGA1UEAwwQQXVydW0g
Wndpc2NoZW4gQjETMBEGA1UECgwKQXVydW0gVGVzdDAeFw0yNjAxMDEwMDAwMDBa
Fw0zNjAxMDEwMDAwMDBaMDAxGTAXBgNVBAMMEHp3aXNjaGVuLmV4YW1wbGUxEzAR
BgNVBAoMCkF1cnVtIFRlc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAARLEXWi
a+PyefXOqveMxjIKh6g0Rix2PA/rfm/yNONmvCOexUgzBSJ0Fh41rHpRgQqItCg+
WYj2Q8FLP4MnsyTmoz0wOzAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDAb
BgNVHREEFDASghB6d2lzY2hlbi5leGFtcGxlMAoGCCqGSM49BAMCA0kAMEYCIQCm
AFHgkL/IFkmRcIEJEnC48pM/Drr2KplvPjK8rk6vAQIhAOd7CxodV/J0F2g2PJne
CJX2o9H7Fepsj2ITTFMDiz7Q
-----END CERTIFICATE-----
PEMEOF
cat > "$TMP/certs/canoku.pem" <<'PEMEOF'
-----BEGIN CERTIFICATE-----
MIIBdjCCARygAwIBAgICUVMwCgYIKoZIzj0EAwIwLTEWMBQGA1UEAwwNQXVydW0g
UDI1NiBDQTETMBEGA1UECgwKQXVydW0gVGVzdDAeFw0yNjAxMDEwMDAwMDBaFw0z
NjAxMDEwMDAwMDBaMDYxHzAdBgNVBAMMFkF1cnVtIE9obmUgS2V5Q2VydFNpZ24x
EzARBgNVBAoMCkF1cnVtIFRlc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAATw
dvDYu8zOAMS2S+3GZ9+u/pGzUmXugr/COWI5kokplk/gPuNCZm3jkrcQLizof1s0
uwL8Kn0ruJ7WWZBWNx6PoyMwITAPBgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB/wQE
AwIHgDAKBggqhkjOPQQDAgNIADBFAiEAodo+zkjG/N+2g39BklWa/mddrYXJbcqo
fjMG+Z29nqACIBArTCAFjZzl5jymDszSTUGwr4uopr+DeAsbYZSfLYKs
-----END CERTIFICATE-----
PEMEOF
cat > "$TMP/certs/leafnoku.pem" <<'PEMEOF'
-----BEGIN CERTIFICATE-----
MIIBjzCCATWgAwIBAgICIiQwCgYIKoZIzj0EAwIwNjEfMB0GA1UEAwwWQXVydW0g
T2huZSBLZXlDZXJ0U2lnbjETMBEGA1UECgwKQXVydW0gVGVzdDAeFw0yNjAxMDEw
MDAwMDBaFw0zNjAxMDEwMDAwMDBaMC4xFzAVBgNVBAMMDm9obmVrdS5leGFtcGxl
MRMwEQYDVQQKDApBdXJ1bSBUZXN0MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE
SxF1omvj8nn1zqr3jMYyCoeoNEYsdjwP635v8jTjZrwjnsVIMwUidBYeNax6UYEK
iLQoPlmI9kPBSz+DJ7Mk5qM7MDkwDAYDVR0TAQH/BAIwADAOBgNVHQ8BAf8EBAMC
B4AwGQYDVR0RBBIwEIIOb2huZWt1LmV4YW1wbGUwCgYIKoZIzj0EAwIDSAAwRQIh
AIshBZ77A0ekL8vyrCUW/m1HAcEWcwO/J79zuUi8JOm1AiAu+vtnIQ9QYAIBo935
suPnIbJlMZXicm5VqgfH5J8/kg==
-----END CERTIFICATE-----
PEMEOF

cat > "$TMP/s.lyx" <<'LYXEOF'
unit main;
import std.io;
import std.alloc;
import std.fs;
import std.crypto.der;
import std.crypto.x509;

fn lade(pfad: pchar, derOut: int64): int64 {
  var pem: int64 := alloc(8192);
  var n: int64 := ReadFile(pfad, pem as pchar, 8191);
  if (n <= 0) { return -1; }
  return PemDekodiere(pem, n, "CERTIFICATE"c as int64, 11, derOut, 4096);
}

fn main(): int64 {
  var basis: pchar := "CERTDIRMARKER"c;
  var dCa: int64 := alloc(4096);  var lCa: int64 := lade(StrConcat(basis, "/ca.pem"c), dCa);
  var dLeaf: int64 := alloc(4096); var lLeaf: int64 := lade(StrConcat(basis, "/leaf.pem"c), dLeaf);
  var dExp: int64 := alloc(4096); var lExp: int64 := lade(StrConcat(basis, "/expired.pem"c), dExp);
  var dEd: int64 := alloc(4096);  var lEd: int64 := lade(StrConcat(basis, "/ed.pem"c), dEd);
  var dRsa: int64 := alloc(4096); var lRsa: int64 := lade(StrConcat(basis, "/rsa.pem"c), dRsa);
  var dP256Ca: int64 := alloc(4096); var lP256Ca := lade(StrConcat(basis, "/ca256.pem"c), dP256Ca);
  var dLeaf256: int64 := alloc(4096); var lLeaf256 := lade(StrConcat(basis, "/leaf256.pem"c), dLeaf256);

  var kette: int64 := alloc(4 * 16);
  var trust: int64 := alloc(4 * 16);
  var host: pchar := "nexus.example"c;
  var jetzt: int64 := 1800000000;   // 2027-01-15

  // Fall 1: Blatt (P-256, von P-256-CA) gegen die richtige Wurzel
  poke64(kette + 0, dLeaf256); poke64(kette + 8, lLeaf256);
  poke64(trust + 0, dP256Ca);  poke64(trust + 8, lP256Ca);
  Print("gueltige-kette "); PrintInt(X509PruefeKette(kette, 1, trust, 1, host as int64, 13, jetzt, 1)); PrintLn("");
  // Fall 2: falscher Hostname
  Print("falscher-host "); PrintInt(X509PruefeKette(kette, 1, trust, 1, "andere.example"c as int64, 14, jetzt, 1)); PrintLn("");
  // Fall 3: Zeitpunkt vor der Gueltigkeit
  Print("zu-frueh "); PrintInt(X509PruefeKette(kette, 1, trust, 1, host as int64, 13, 1500000000, 1)); PrintLn("");
  // Fall 4: fremde Wurzel (P-384-CA passt nicht zum Aussteller)
  poke64(trust + 0, dCa); poke64(trust + 8, lCa);
  Print("fremde-wurzel "); PrintInt(X509PruefeKette(kette, 1, trust, 1, host as int64, 13, jetzt, 1)); PrintLn("");
  // Fall 5: verfaelschtes Blatt (ein Byte im Subjekt gekippt) gegen die richtige Wurzel
  poke64(trust + 0, dP256Ca); poke64(trust + 8, lP256Ca);
  poke8(dLeaf256 + lLeaf256 - 40, peek8(dLeaf256 + lLeaf256 - 40) ^ 1);
  Print("verfaelschte-signatur "); PrintInt(X509PruefeKette(kette, 1, trust, 1, host as int64, 13, jetzt, 1)); PrintLn("");
  poke8(dLeaf256 + lLeaf256 - 40, peek8(dLeaf256 + lLeaf256 - 40) ^ 1);
  // Fall 6: Blatt als eigene Wurzel vorgelegt — CA-Flag fehlt
  poke64(trust + 0, dLeaf256); poke64(trust + 8, lLeaf256);
  poke64(kette + 0, dLeaf256); poke64(kette + 8, lLeaf256);
  Print("blatt-ohne-passenden-aussteller "); PrintInt(X509PruefeKette(kette, 1, trust, 1, host as int64, 13, jetzt, 1)); PrintLn("");
  // Fall 7: Ed25519-Blatt — Verfahren nicht unterstuetzt, muss 10 liefern
  poke64(kette + 0, dEd); poke64(kette + 8, lEd);
  poke64(trust + 0, dEd); poke64(trust + 8, lEd);
  Print("selbstsigniert-ohne-ca-flag "); PrintInt(X509PruefeKette(kette, 1, trust, 1, "ed.example"c as int64, 10, jetzt, 0)); PrintLn("");
  // Fall 8: RSA-Blatt unter P-384-CA — auch 10
  poke64(kette + 0, dRsa); poke64(kette + 8, lRsa);
  poke64(trust + 0, dCa); poke64(trust + 8, lCa);
  Print("rsa "); PrintInt(X509PruefeKette(kette, 1, trust, 1, "rsa.example"c as int64, 11, jetzt, 0)); PrintLn("");
  // Fall 9: abgelaufenes Blatt
  poke64(kette + 0, dExp); poke64(kette + 8, lExp);
  Print("abgelaufen "); PrintInt(X509PruefeKette(kette, 1, trust, 1, "alt.example"c as int64, 11, jetzt, 0)); PrintLn("");
  // Fall 10: leerer Trust-Store
  poke64(kette + 0, dLeaf256); poke64(kette + 8, lLeaf256);
  Print("leerer-store "); PrintInt(X509PruefeKette(kette, 1, trust, 0, host as int64, 13, jetzt, 1)); PrintLn("");

  // Fall 11: pathLenConstraint 0 an der Zwischenstelle, darunter noch eine CA
  var dCab: int64 := alloc(4096); var lCab := lade(StrConcat(basis, "/cab.pem"c), dCab);
  var dCac: int64 := alloc(4096); var lCac := lade(StrConcat(basis, "/cac.pem"c), dCac);
  var dL3: int64 := alloc(4096);  var lL3 := lade(StrConcat(basis, "/leaf3.pem"c), dL3);
  poke64(kette + 0,  dL3);  poke64(kette + 8,  lL3);
  poke64(kette + 16, dCac); poke64(kette + 24, lCac);
  poke64(kette + 32, dCab); poke64(kette + 40, lCab);
  poke64(trust + 0, dP256Ca); poke64(trust + 8, lP256Ca);
  Print("pathlen-ueberschritten "); PrintInt(X509PruefeKette(kette, 3, trust, 1, "tief.example"c as int64, 12, jetzt, 0)); PrintLn("");
  // Fall 12: Blatt direkt unter der Zwischenstelle mit pathLen 0 ist gueltig
  var dLb: int64 := alloc(4096); var lLb := lade(StrConcat(basis, "/leafb.pem"c), dLb);
  poke64(kette + 0,  dLb);  poke64(kette + 8,  lLb);
  poke64(kette + 16, dCab); poke64(kette + 24, lCab);
  Print("zwei-glieder "); PrintInt(X509PruefeKette(kette, 2, trust, 1, "zwischen.example"c as int64, 16, jetzt, 0)); PrintLn("");
  // Fall 13: Aussteller ohne keyCertSign
  var dNoKu: int64 := alloc(4096); var lNoKu := lade(StrConcat(basis, "/canoku.pem"c), dNoKu);
  var dLNoKu: int64 := alloc(4096); var lLNoKu := lade(StrConcat(basis, "/leafnoku.pem"c), dLNoKu);
  poke64(kette + 0,  dLNoKu); poke64(kette + 8,  lLNoKu);
  poke64(kette + 16, dNoKu);  poke64(kette + 24, lNoKu);
  Print("aussteller-ohne-keycertsign "); PrintInt(X509PruefeKette(kette, 2, trust, 1, "ohneku.example"c as int64, 14, jetzt, 0)); PrintLn("");
  return 0;
}
LYXEOF
sed -i "s|CERTDIRMARKER|$TMP/certs|" "$TMP/s.lyx"

if ! ( cd "$ROOT" && timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/s.lyx" -o "$TMP/s" ) >"$TMP/log" 2>&1; then
  echo "FAIL uebersetzt nicht: $(grep -m1 -i error "$TMP/log")"; exit 1
fi
if [ ! -x "$TMP/s" ]; then echo "FAIL kein Erzeugnis (#1682)"; exit 1; fi

cat > "$TMP/soll.txt" <<'SOLLEOF'
gueltige-kette 0
falscher-host 3
zu-frueh 2
fremde-wurzel 4
verfaelschte-signatur 5
blatt-ohne-passenden-aussteller 4
selbstsigniert-ohne-ca-flag 6
rsa 10
abgelaufen 2
leerer-store 4
pathlen-ueberschritten 7
zwei-glieder 0
aussteller-ohne-keycertsign 8
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

echo "PASS $PASS / FAIL $FAIL (X.509-Kette)"
if [ "$FAIL" != 0 ]; then exit 1; fi
echo "ALL PASS"
exit 0
