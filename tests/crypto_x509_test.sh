#!/usr/bin/env bash
# tests/crypto_x509_test.sh — #2096 Etappe C: DER-Leser, PEM-Dekodierer und
# X.509-Parser gegen echte Zertifikate.
#
# Die fuenf Zertifikate stehen unten als PEM im Test, damit der Lauf nicht von
# openssl oder vom Netz abhaengt. Erzeugt mit python-cryptography; die
# Erwartungswerte (DER-Laenge, Seriennummer, TBS-Laenge, Signaturlaenge,
# Gueltigkeit als Unix-Zeit, Schluessellaenge) sind unabhaengig mit
# cryptography nachgerechnet, nicht aus der Lyx-Ausgabe uebernommen:
#   ca      EC P-384, selbstausgestellt, CA mit pathLen 1, KU 97
#   leaf    EC P-256, von ca, KU 1, EKU serverAuth+clientAuth, drei SAN
#   expired EC P-256, Gueltigkeit 2020..2021
#   rsa     RSA-2048
#   ed      Ed25519, selbstausgestellt
#   wild    SAN "*.example" und "w*.breit.example" — beide zu weit, beide
#           duerfen NICHT treffen
#
# Geprueft wird die WIRKUNG: jedes Feld einzeln, die SAN-Liste im Wortlaut,
# die Hostnamenspruefung nach RFC 6125 in BEIDEN Richtungen (Treffer UND
# Nichttreffer: "a.b.nexus.example" darf von "*.nexus.example" nicht getroffen
# werden, der rfc822Name-Eintrag nicht als Hostname gelten), und drei Faelle,
# in denen der Parser abweisen MUSS: abgeschnittener Puffer, verfaelschtes
# Laengenbyte, Muellbytes. Ein Test, der nur "parst durch" prueft, wuerde
# einen fail-open-Parser nicht von einem strengen unterscheiden.
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
cat > "$TMP/certs/wild.pem" <<'PEMEOF'
-----BEGIN CERTIFICATE-----
MIIBdDCCARmgAwIBAgIBDTAKBggqhkjOPQQDAjAtMRYwFAYDVQQDDA1icmVpdC5l
eGFtcGxlMRMwEQYDVQQKDApBdXJ1bSBUZXN0MB4XDTI2MDEwMTAwMDAwMFoXDTM2
MDEwMTAwMDAwMFowLTEWMBQGA1UEAwwNYnJlaXQuZXhhbXBsZTETMBEGA1UECgwK
QXVydW0gVGVzdDBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABDjt+aBxR8GnY11c
7R2NsbT6cYw79R7D01DHE6sth7kMEV8qPgs8cPJhxTlxN1mQAudzBVi/bO/QHUwJ
OlJ+1MOjKjAoMCYGA1UdEQQfMB2CCSouZXhhbXBsZYIQdyouYnJlaXQuZXhhbXBs
ZTAKBggqhkjOPQQDAgNJADBGAiEAkFCxQkJ606z7hH7TN/Tw/YJBhiZqKmhxwtn9
Zp7GA6UCIQDo76T0j6vKGUEEi3HExuCVz+hPkInl9Huc+wO3lLuB2Q==
-----END CERTIFICATE-----
PEMEOF

cat > "$TMP/s.lyx" <<'LYXEOF'
unit main;
import std.io;
import std.alloc;
import std.fs;
import std.crypto.der;
import std.crypto.x509;

fn hex(b: int64, n: int64): void {
  var d: pchar := "0123456789abcdef"c;
  var i: int64 := 0;
  while (i < n) {
    var v: int64 := peek8(b + i) & 255;
    PrintChar(StrCharAt(d, (v >> 4) & 15)); PrintChar(StrCharAt(d, v & 15));
    i := i + 1;
  }
  PrintLn("");
}
fn roh(b: int64, n: int64): void {
  var i: int64 := 0;
  while (i < n) { PrintChar(peek8(b + i)); i := i + 1; }
  PrintLn("");
}

fn pruefeHost(satz: int64, host: pchar): void {
  if (X509PasstName(satz, host as int64, StrLen(host))) { Print("ja "); } else { Print("nein "); }
  roh(host as int64, StrLen(host));
}

fn zertifikat(pfad: pchar): void {
  var pem: int64 := alloc(8192);
  var n: int64 := ReadFile(pfad, pem as pchar, 8191);
  if (n <= 0) { PrintLn("LESEFEHLER"); return; }
  var der: int64 := alloc(4096);
  var lab: pchar := "CERTIFICATE"c;
  var dLen: int64 := PemDekodiere(pem, n, lab as int64, 11, der, 4096);
  Print("der-laenge "); PrintInt(dLen); PrintLn("");
  if (dLen <= 0) { return; }

  var satz: int64 := alloc(X509Groesse());
  if (!X509Lies(der, dLen, satz)) { PrintLn("PARSEFEHLER"); return; }
  Print("version "); PrintInt(X509Version(satz)); PrintLn("");
  Print("serie "); hex(der + X509SerienNrPos(satz), X509SerienNrLen(satz));
  Print("sigalg "); PrintInt(X509SigAlg(satz)); PrintLn("");
  Print("keyalg "); PrintInt(X509KeyAlg(satz)); PrintLn("");
  Print("schluessel-laenge "); PrintInt(X509PubKeyLen(satz)); PrintLn("");
  Print("notbefore "); PrintInt(X509NotBefore(satz)); PrintLn("");
  Print("notafter "); PrintInt(X509NotAfter(satz)); PrintLn("");
  Print("tbs-laenge "); PrintInt(X509TbsLen(satz)); PrintLn("");
  Print("sig-laenge "); PrintInt(X509SigLen(satz)); PrintLn("");
  Print("ca ");
  if (X509IstCA(satz)) { PrintLn("ja"); } else { PrintLn("nein"); }
  Print("pfadlen "); PrintInt(X509PfadLen(satz)); PrintLn("");
  Print("ku "); PrintInt(X509KeyUsage(satz)); PrintLn("");
  Print("eku "); PrintInt(X509Eku(satz)); PrintLn("");
  Print("selbst ");
  if (X509IstSelbstAusgestellt(satz)) { PrintLn("ja"); } else { PrintLn("nein"); }
  Print("san-anzahl "); PrintInt(X509SanAnzahl(satz)); PrintLn("");
  var art: int64 := alloc(8); var pos: int64 := alloc(8); var len: int64 := alloc(8);
  var i: int64 := 0;
  while (i < X509SanAnzahl(satz)) {
    if (X509SanAt(satz, i, art, pos, len)) {
      Print("san "); PrintInt(peek64(art)); Print(" ");
      roh(der + peek64(pos), peek64(len));
    }
    i := i + 1;
  }
  // Zeitfenster
  Print("gueltig-2027 ");
  if (X509ZeitGueltig(satz, 1800000000)) { PrintLn("ja"); } else { PrintLn("nein"); }
}


// Einzelne TLV-Faelle direkt am DER-Leser: jede Zeile nennt, was abgewiesen
// werden MUSS. Nach #2096 ist das der Kern der Strenge — ein Parser, der
// nicht minimale Laengen annimmt, nimmt zwei Lesarten derselben Bytes an.
fn derFall(name: pchar, bytes: int64, n: int64, erwartetOk: int64): void {
  var f: int64 := alloc(DerFeldGroesse());
  var ok: int64 := 0;
  if (DerLies(bytes, n, 0, f)) { ok := 1; }
  Print(name); Print(" ");
  if (ok == erwartetOk) {
    if (ok == 1) { Print("gelesen len="); PrintInt(DerInhaltLen(f)); PrintLn(""); }
    else { PrintLn("abgewiesen"); }
  } else {
    if (ok == 1) { PrintLn("FALSCH-ANGENOMMEN"); } else { PrintLn("FALSCH-ABGEWIESEN"); }
  }
}

fn derStrenge(): void {
  var b: int64 := alloc(300);
  var i: int64 := 0;
  while (i < 300) { poke8(b + i, 0); i := i + 1; }
  // kurze Form, 3 Byte Inhalt
  poke8(b, 0x04); poke8(b + 1, 0x03);
  derFall("kurze-form"c, b, 5, 1);
  // lange Form fuer eine Laenge, die in die kurze passt (0x81 0x03)
  poke8(b, 0x04); poke8(b + 1, 0x81); poke8(b + 2, 0x03);
  derFall("lange-form-fuer-3"c, b, 6, 0);
  // lange Form mit 128: erlaubt
  poke8(b, 0x04); poke8(b + 1, 0x81); poke8(b + 2, 0x80);
  derFall("lange-form-128"c, b, 131, 1);
  // lange Form mit fuehrender Null (0x82 0x00 0x80)
  poke8(b, 0x04); poke8(b + 1, 0x82); poke8(b + 2, 0x00); poke8(b + 3, 0x80);
  derFall("fuehrende-null"c, b, 132, 0);
  // unbestimmte Laenge
  poke8(b, 0x30); poke8(b + 1, 0x80);
  derFall("unbestimmte-laenge"c, b, 10, 0);
  // reserviertes 0xFF
  poke8(b, 0x04); poke8(b + 1, 0xFF);
  derFall("reserviert-ff"c, b, 10, 0);
  // Laenge zeigt ueber das Pufferende
  poke8(b, 0x04); poke8(b + 1, 0x20);
  derFall("laenge-ueber-puffer"c, b, 10, 0);
  // mehrbyte-Tag
  poke8(b, 0x1F); poke8(b + 1, 0x01);
  derFall("mehrbyte-tag"c, b, 10, 0);
  // INTEGER: nicht minimale Kodierung 00 01 muss -1 geben
  poke8(b, 0x02); poke8(b + 1, 0x02); poke8(b + 2, 0x00); poke8(b + 3, 0x01);
  var f: int64 := alloc(DerFeldGroesse());
  if (DerLies(b, 4, 0, f)) {
    Print("integer-nicht-minimal "); PrintInt(DerGanzzahl(b, 4, f)); PrintLn("");
  } else { PrintLn("integer-nicht-minimal LESEFEHLER"); }
  // INTEGER: 00 80 ist minimal (Vorzeichenbit)
  poke8(b + 3, 0x80);
  if (DerLies(b, 4, 0, f)) {
    Print("integer-00-80 "); PrintInt(DerGanzzahl(b, 4, f)); PrintLn("");
  } else { PrintLn("integer-00-80 LESEFEHLER"); }
  // BIT STRING mit Restbits wird abgewiesen
  poke8(b, 0x03); poke8(b + 1, 0x02); poke8(b + 2, 0x03); poke8(b + 3, 0xF8);
  var pp: int64 := alloc(8); var ll: int64 := alloc(8);
  if (DerLies(b, 4, 0, f)) {
    Print("bitkette-restbits ");
    if (DerBitKette(b, f, pp, ll)) { PrintLn("FALSCH-ANGENOMMEN"); } else { PrintLn("abgewiesen"); }
  }
  // UTCTime mit Zeitzonenversatz statt Z
  var z: pchar := "260101000000+0100"c;
  poke8(b, 0x17); poke8(b + 1, 17);
  i := 0;
  while (i < 17) { poke8(b + 2 + i, StrCharAt(z, i)); i := i + 1; }
  if (DerLies(b, 19, 0, f)) {
    Print("utctime-versatz "); PrintInt(DerZeitUnix(b, f)); PrintLn("");
  }
  // UTCTime korrekt
  var z2: pchar := "260101000000Z"c;
  poke8(b, 0x17); poke8(b + 1, 13);
  i := 0;
  while (i < 13) { poke8(b + 2 + i, StrCharAt(z2, i)); i := i + 1; }
  if (DerLies(b, 15, 0, f)) {
    Print("utctime-2026 "); PrintInt(DerZeitUnix(b, f)); PrintLn("");
  }
  // UTCTime mit Jahr 49 / 50 (RFC 5280 Jahrhundertregel)
  var z3: pchar := "490101000000Z"c;
  i := 0;
  while (i < 13) { poke8(b + 2 + i, StrCharAt(z3, i)); i := i + 1; }
  if (DerLies(b, 15, 0, f)) { Print("utctime-49 "); PrintInt(DerZeitUnix(b, f)); PrintLn(""); }
  var z4: pchar := "500101000000Z"c;
  i := 0;
  while (i < 13) { poke8(b + 2 + i, StrCharAt(z4, i)); i := i + 1; }
  if (DerLies(b, 15, 0, f)) { Print("utctime-50 "); PrintInt(DerZeitUnix(b, f)); PrintLn(""); }
}

fn main(): int64 {
  var basis: pchar := "CERTDIRMARKER"c;
  var pfad: int64 := alloc(512);
  var namen: int64 := alloc(5 * 8);
  zertifikat(StrConcat(basis, "/ca.pem"c));
  zertifikat(StrConcat(basis, "/leaf.pem"c));
  zertifikat(StrConcat(basis, "/expired.pem"c));
  zertifikat(StrConcat(basis, "/rsa.pem"c));
  zertifikat(StrConcat(basis, "/ed.pem"c));
  // Hostnamenspruefung am Blattzertifikat
  var pem: int64 := alloc(8192);
  var n: int64 := ReadFile(StrConcat(basis, "/leaf.pem"c), pem as pchar, 8191);
  var der: int64 := alloc(4096);
  var dLen: int64 := PemDekodiere(pem, n, "CERTIFICATE"c as int64, 11, der, 4096);
  var satz: int64 := alloc(X509Groesse());
  if (!X509Lies(der, dLen, satz)) { PrintLn("PARSEFEHLER"); return 1; }
  pruefeHost(satz, "nexus.example"c);
  pruefeHost(satz, "NEXUS.EXAMPLE"c);
  pruefeHost(satz, "a.nexus.example"c);
  pruefeHost(satz, "a.b.nexus.example"c);
  pruefeHost(satz, "nexus.example.com"c);
  pruefeHost(satz, "xnexus.example"c);
  pruefeHost(satz, "example"c);
  pruefeHost(satz, "ca@nexus.example"c);
  // Zu weite Wildcards muessen NICHT treffen
  var pemW: int64 := alloc(8192);
  var nW: int64 := ReadFile(StrConcat(basis, "/wild.pem"c), pemW as pchar, 8191);
  var derW: int64 := alloc(4096);
  var dLenW: int64 := PemDekodiere(pemW, nW, "CERTIFICATE"c as int64, 11, derW, 4096);
  var satzW: int64 := alloc(X509Groesse());
  if (!X509Lies(derW, dLenW, satzW)) { PrintLn("PARSEFEHLER-WILD"); return 1; }
  pruefeHost(satzW, "a.example"c);
  pruefeHost(satzW, "example"c);
  pruefeHost(satzW, "wa.breit.example"c);
  pruefeHost(satzW, "w.breit.example"c);
  derStrenge();
  // DER-Strenge: verfaelschte Laenge, abgeschnittener Puffer, Muellbytes
  var satz2: int64 := alloc(X509Groesse());
  Print("abgeschnitten ");
  if (X509Lies(der, dLen - 5, satz2)) { PrintLn("ANGENOMMEN"); } else { PrintLn("abgewiesen"); }
  poke8(der + 1, 0x7F);
  Print("laenge-verfaelscht ");
  if (X509Lies(der, dLen, satz2)) { PrintLn("ANGENOMMEN"); } else { PrintLn("abgewiesen"); }
  var muell: int64 := alloc(64);
  var j: int64 := 0;
  while (j < 64) { poke8(muell + j, (j * 37 + 5) & 255); j := j + 1; }
  Print("muell ");
  if (X509Lies(muell, 64, satz2)) { PrintLn("ANGENOMMEN"); } else { PrintLn("abgewiesen"); }
  // PEM mit falschem Label
  Print("pem-falsches-label ");
  PrintInt(PemDekodiere(pem, n, "PRIVATE KEY"c as int64, 11, der, 4096)); PrintLn("");
  return 0;
}

LYXEOF
sed -i "s|CERTDIRMARKER|$TMP/certs|" "$TMP/s.lyx"

if ! ( cd "$ROOT" && timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/s.lyx" -o "$TMP/s" ) >"$TMP/log" 2>&1; then
  echo "FAIL uebersetzt nicht: $(grep -m1 -i error "$TMP/log")"; exit 1
fi
if [ ! -x "$TMP/s" ]; then echo "FAIL kein Erzeugnis (#1682: Schreibfehler mit Exit 0)"; exit 1; fi

cat > "$TMP/soll.txt" <<'SOLLEOF'
der-laenge 433
version 3
serie 4711
sigalg 2
keyalg 2
schluessel-laenge 97
notbefore 1767225600
notafter 2082758400
tbs-laenge 311
sig-laenge 103
ca ja
pfadlen 1
ku 97
eku 0
selbst ja
san-anzahl 0
gueltig-2027 ja
der-laenge 492
version 3
serie 1234abcd
sigalg 1
keyalg 1
schluessel-laenge 65
notbefore 1767225600
notafter 2082758400
tbs-laenge 370
sig-laenge 103
ca nein
pfadlen -1
ku 1
eku 3
selbst nein
san-anzahl 3
san 2 nexus.example
san 2 *.nexus.example
san 1 ca@nexus.example
gueltig-2027 ja
der-laenge 389
version 3
serie 07
sigalg 1
keyalg 1
schluessel-laenge 65
notbefore 1577836800
notafter 1609459200
tbs-laenge 267
sig-laenge 103
ca nein
pfadlen -1
ku 0
eku 0
selbst nein
san-anzahl 1
san 2 alt.example
gueltig-2027 nein
der-laenge 591
version 3
serie 09
sigalg 1
keyalg 3
schluessel-laenge 270
notbefore 1767225600
notafter 2082758400
tbs-laenge 470
sig-laenge 102
ca nein
pfadlen -1
ku 0
eku 0
selbst nein
san-anzahl 1
san 2 rsa.example
gueltig-2027 ja
der-laenge 287
version 3
serie 0b
sigalg 7
keyalg 4
schluessel-laenge 32
notbefore 1767225600
notafter 2082758400
tbs-laenge 209
sig-laenge 64
ca nein
pfadlen -1
ku 0
eku 0
selbst ja
san-anzahl 1
san 2 ed.example
gueltig-2027 ja
ja nexus.example
ja NEXUS.EXAMPLE
ja a.nexus.example
nein a.b.nexus.example
nein nexus.example.com
nein xnexus.example
nein example
nein ca@nexus.example
nein a.example
nein example
nein wa.breit.example
nein w.breit.example
kurze-form gelesen len=3
lange-form-fuer-3 abgewiesen
lange-form-128 gelesen len=128
fuehrende-null abgewiesen
unbestimmte-laenge abgewiesen
reserviert-ff abgewiesen
laenge-ueber-puffer abgewiesen
mehrbyte-tag abgewiesen
integer-nicht-minimal -1
integer-00-80 128
bitkette-restbits abgewiesen
utctime-versatz -1
utctime-2026 1767225600
utctime-49 2493072000
utctime-50 -631152000
abgeschnitten abgewiesen
laenge-verfaelscht abgewiesen
muell abgewiesen
pem-falsches-label -1
SOLLEOF

if ! ( ulimit -v 4000000; timeout 120 "$TMP/s" > "$TMP/ist.txt" 2>"$TMP/err.txt" ); then
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

echo "PASS $PASS / FAIL $FAIL (DER, PEM, X.509, RFC 6125)"
if [ "$FAIL" != 0 ]; then exit 1; fi
echo "ALL PASS"
exit 0
