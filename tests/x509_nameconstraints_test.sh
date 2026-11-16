#!/usr/bin/env bash
# tests/x509_nameconstraints_test.sh — #2096: nameConstraints (RFC 5280
# §4.2.1.10) in der Kettenpruefung.
#
# Die Zertifikate sind einmalig mit OpenSSL 3.5.5 erzeugt und hier
# eingebettet; der Test braucht kein openssl. Erzeugt wurden sie als
# prime256v1-Selbstaussteller mit
#   nameConstraints=critical,permitted;DNS:.erlaubt.example
#   nameConstraints=critical,excluded;DNS:.gesperrt.example
#   nameConstraints=critical,excluded;IP:10.0.0.0/255.0.0.0
#   nameConstraints=critical,permitted;dirName:<O=Aurum Test>
# und je einem Blatt darunter (CN == SAN dNSName, EKU serverAuth,
# Gueltigkeit 2026-01-01 bis 2036-01-01, Seriennummern 1 und 2). Die Urteile stimmen mit
# `openssl verify` ueberein (Fehler 47 "permitted subtree violation" und
# 48 "excluded subtree violation" dort, Code 13 hier).
#
# Beide Seiten werden gemessen — ein Test, der nur zeigt, dass eine
# Einschraenkung greift, waere auch von einer Umsetzung erfuellt, die alles
# ablehnt:
#   permitted DNS .erlaubt.example   host.erlaubt.example   -> 0
#                                     host.fremd.example     -> 13
#   excluded  DNS .gesperrt.example  host.gesperrt.example  -> 13
#                                     host.frei.example      -> 0
#   excluded  IP  10.0.0.0/8         DNS-Blatt              -> 0
#     (eine Einschraenkung auf einen Typ, den das Blatt nicht traegt, darf
#      die Kette nicht sperren — fast jede echte CA hat so eine)
#   permitted dirName                DNS-Blatt              -> 13
#     (directoryName betrifft jedes Subjekt und wird hier nicht ausgewertet:
#      abweisen, nicht uebergehen)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/certs"
cat > "$TMP/certs/caperm.pem" <<'PEMEOF'
-----BEGIN CERTIFICATE-----
MIIBfDCCASOgAwIBAgIBATAKBggqhkjOPQQDAjAUMRIwEAYDVQQDDAljYXBlcm0g
Q0EwHhcNMjYwMTAxMDAwMDAwWhcNMzYwMTAxMDAwMDAwWjAUMRIwEAYDVQQDDAlj
YXBlcm0gQ0EwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAATwAy2GBfkynDV4xTKj
QMB6ikiXIK/mb9igOVVZ7IK+tg2zM5btmRRoWaXx8S2q98JJliQhUcmA0kd+9fuv
sv1Co2YwZDAPBgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB/wQEAwIBBjAiBgNVHR4B
Af8EGDAWoBQwEoIQLmVybGF1YnQuZXhhbXBsZTAdBgNVHQ4EFgQUtsSmn82wNCzb
ai0bGMzQ6HKA7y0wCgYIKoZIzj0EAwIDRwAwRAIgbtsISfPeR4WzCEwx4f5i167M
BaGOUj0JILCYyw5YLNACIAXh7RH7IGt4OhBUUFcvYhewHzzn17tZpZTtM/e28k3/
-----END CERTIFICATE-----
PEMEOF
cat > "$TMP/certs/caexcl.pem" <<'PEMEOF'
-----BEGIN CERTIFICATE-----
MIIBfjCCASSgAwIBAgIBATAKBggqhkjOPQQDAjAUMRIwEAYDVQQDDAljYWV4Y2wg
Q0EwHhcNMjYwMTAxMDAwMDAwWhcNMzYwMTAxMDAwMDAwWjAUMRIwEAYDVQQDDAlj
YWV4Y2wgQ0EwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAQudjGHQevt4o/69Jdi
UayDtRErNMMs3Uqt93TvX2+qwJm5zMco0l8eVcsgfAgcQpJNAYntA3avkSQLohtJ
iRcFo2cwZTAPBgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB/wQEAwIBBjAjBgNVHR4B
Af8EGTAXoRUwE4IRLmdlc3BlcnJ0LmV4YW1wbGUwHQYDVR0OBBYEFBRvT/m/IbYF
lokE5siyZIvoh7/NMAoGCCqGSM49BAMCA0gAMEUCIQCBoM3xkJ845WW4DlszrUzj
H8KQP5Bh5xL3geNZ14E15QIgHg7z1uCjm47mixFJN+RMYO0VjS9hI1BPy7H0gokh
EsM=
-----END CERTIFICATE-----
PEMEOF
cat > "$TMP/certs/caip.pem" <<'PEMEOF'
-----BEGIN CERTIFICATE-----
MIIBcjCCARegAwIBAgIBATAKBggqhkjOPQQDAjASMRAwDgYDVQQDDAdjYWlwIENB
MB4XDTI2MDEwMTAwMDAwMFoXDTM2MDEwMTAwMDAwMFowEjEQMA4GA1UEAwwHY2Fp
cCBDQTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABOvmGak1giSdU1haH/eGm3B7
1TDopV5FlzPwKpJOhs8SZmlcTU9Qg+A8zUgCeF7h/J81lc7jH2TQ16kL5N+sBIyj
XjBcMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMBoGA1UdHgEB/wQQ
MA6hDDAKhwgKAAAA/wAAADAdBgNVHQ4EFgQUIg0a/PRpF7KI7x6GOyiPc3rltD4w
CgYIKoZIzj0EAwIDSQAwRgIhANnchhgx0qnygyYoR4Y5VPU8fsshsPKtswNDa7SA
8i01AiEAiphqehcku1rPyeE+eAhiuMZqQVYbI24vk3sJ71gpJRU=
-----END CERTIFICATE-----
PEMEOF
cat > "$TMP/certs/cadir.pem" <<'PEMEOF'
-----BEGIN CERTIFICATE-----
MIIBgjCCASigAwIBAgIBATAKBggqhkjOPQQDAjATMREwDwYDVQQDDAhjYWRpciBD
QTAeFw0yNjAxMDEwMDAwMDBaFw0zNjAxMDEwMDAwMDBaMBMxETAPBgNVBAMMCGNh
ZGlyIENBMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEpW4aVqNCX3V7D/UknrsO
Rnw7CviyPZM7jJqPeEyAunZYrU64tk7tSIE7lKIZ+6OVttFQoNRU3fgG2Hr9GU5D
paNtMGswDwYDVR0TAQH/BAUwAwEB/zAOBgNVHQ8BAf8EBAMCAQYwKQYDVR0eAQH/
BB8wHaAbMBmkFzAVMRMwEQYDVQQKDApBdXJ1bSBUZXN0MB0GA1UdDgQWBBT/DG8V
eTETgnQd5F3FscCpWH2MsjAKBggqhkjOPQQDAgNIADBFAiEArhAdj0uh4wnIQ8IV
ODJTMvVTOMe2ZkYWpLV5YhTlazYCIHsiDSW7pEq5HAPHg3C3ZdzNheQ4jFF5KSDD
INaz84FH
-----END CERTIFICATE-----
PEMEOF
cat > "$TMP/certs/gut.pem" <<'PEMEOF'
-----BEGIN CERTIFICATE-----
MIIBzjCCAXWgAwIBAgIBAjAKBggqhkjOPQQDAjAUMRIwEAYDVQQDDAljYXBlcm0g
Q0EwHhcNMjYwMTAxMDAwMDAwWhcNMzYwMTAxMDAwMDAwWjA0MR0wGwYDVQQDDBRo
b3N0LmVybGF1YnQuZXhhbXBsZTETMBEGA1UECgwKQXVydW0gVGVzdDBZMBMGByqG
SM49AgEGCCqGSM49AwEHA0IABJAN1FLzBn5PuOiT9TFMKMy++iQJP+2CChtOyloG
8Wcv2ArfIPQEuIfKMGpM1jnP2Vdd30EeVY80JR983j1Q5HyjgZcwgZQwDAYDVR0T
AQH/BAIwADAOBgNVHQ8BAf8EBAMCB4AwEwYDVR0lBAwwCgYIKwYBBQUHAwEwHwYD
VR0RBBgwFoIUaG9zdC5lcmxhdWJ0LmV4YW1wbGUwHQYDVR0OBBYEFJfjsmB9FjJw
TXn92uZphl/tftlzMB8GA1UdIwQYMBaAFLbEpp/NsDQs22otGxjM0OhygO8tMAoG
CCqGSM49BAMCA0cAMEQCIEDp1qQDvIReyZISfFPZNMTyke/bR5ZSCdy70AIGCvJs
AiBbaeWEvJjNqveHRG65KkEM+Sx/LisqgM426uVS2NWhTg==
-----END CERTIFICATE-----
PEMEOF
cat > "$TMP/certs/fremd.pem" <<'PEMEOF'
-----BEGIN CERTIFICATE-----
MIIByzCCAXGgAwIBAgIBAjAKBggqhkjOPQQDAjAUMRIwEAYDVQQDDAljYXBlcm0g
Q0EwHhcNMjYwMTAxMDAwMDAwWhcNMzYwMTAxMDAwMDAwWjAyMRswGQYDVQQDDBJo
b3N0LmZyZW1kLmV4YW1wbGUxEzARBgNVBAoMCkF1cnVtIFRlc3QwWTATBgcqhkjO
PQIBBggqhkjOPQMBBwNCAAThvCfAtDWYngHnUlCC/bwlPCJ81zS+eq5cz35+b2ev
0avhr1WiCiuDh6dEJTSmT1DdWm7pCbBU5+u4I8iAn6bYo4GVMIGSMAwGA1UdEwEB
/wQCMAAwDgYDVR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMBMB0GA1Ud
EQQWMBSCEmhvc3QuZnJlbWQuZXhhbXBsZTAdBgNVHQ4EFgQUhqYffOz4SEjJ5Toy
RA4PGOWABoowHwYDVR0jBBgwFoAUtsSmn82wNCzbai0bGMzQ6HKA7y0wCgYIKoZI
zj0EAwIDSAAwRQIhAOjhJ7rznh63l/OV4PreRuxsGBpd/kt60A7FJXWsYaueAiBr
/0mmcfSccEE5k4m5Tu/cl/b7/NBxVg2Xx/7rpEGGgw==
-----END CERTIFICATE-----
PEMEOF
cat > "$TMP/certs/gesperr.pem" <<'PEMEOF'
-----BEGIN CERTIFICATE-----
MIIB0DCCAXegAwIBAgIBAjAKBggqhkjOPQQDAjAUMRIwEAYDVQQDDAljYWV4Y2wg
Q0EwHhcNMjYwMTAxMDAwMDAwWhcNMzYwMTAxMDAwMDAwWjA1MR4wHAYDVQQDDBVo
b3N0Lmdlc3BlcnJ0LmV4YW1wbGUxEzARBgNVBAoMCkF1cnVtIFRlc3QwWTATBgcq
hkjOPQIBBggqhkjOPQMBBwNCAASMY/Dl//Uppxt2RB61Pd+0GSwFkqAuLH9oqLlS
qdyHwd0U6d0SE0yageDa624YKAOhaVIUXiPTaI7FFegPBvgCo4GYMIGVMAwGA1Ud
EwEB/wQCMAAwDgYDVR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMBMCAG
A1UdEQQZMBeCFWhvc3QuZ2VzcGVycnQuZXhhbXBsZTAdBgNVHQ4EFgQU/Z00wEqb
4dg5KOAfh2oOtLDMSycwHwYDVR0jBBgwFoAUFG9P+b8htgWWiQTmyLJki+iHv80w
CgYIKoZIzj0EAwIDRwAwRAIgDiWjvmkuTNuX7eKM/yMJjfKRQhukI7kUH5VD2WVq
GmwCID4c+lrJQ3Ve3ALEdd9fZyhGR0cGByrHG1uFd3kCNH9D
-----END CERTIFICATE-----
PEMEOF
cat > "$TMP/certs/frei.pem" <<'PEMEOF'
-----BEGIN CERTIFICATE-----
MIIByjCCAW+gAwIBAgIBAjAKBggqhkjOPQQDAjAUMRIwEAYDVQQDDAljYWV4Y2wg
Q0EwHhcNMjYwMTAxMDAwMDAwWhcNMzYwMTAxMDAwMDAwWjAxMRowGAYDVQQDDBFo
b3N0LmZyZWkuZXhhbXBsZTETMBEGA1UECgwKQXVydW0gVGVzdDBZMBMGByqGSM49
AgEGCCqGSM49AwEHA0IABOKMjvQaUvE9n58Xp7+e7DFxq1F4hcM16xVZKbqwDptq
hSKouqQBYhzxl0dIeldEtz3MQNOtS/htDNNSxeZ+9OqjgZQwgZEwDAYDVR0TAQH/
BAIwADAOBgNVHQ8BAf8EBAMCB4AwEwYDVR0lBAwwCgYIKwYBBQUHAwEwHAYDVR0R
BBUwE4IRaG9zdC5mcmVpLmV4YW1wbGUwHQYDVR0OBBYEFDlO+/WTIIVY/u99abcu
lOUXKBlBMB8GA1UdIwQYMBaAFBRvT/m/IbYFlokE5siyZIvoh7/NMAoGCCqGSM49
BAMCA0kAMEYCIQD/e6q32SpXFVcfsm6ip+lT/ec1/UAaTO0CuPdGRdUshQIhAJfc
/Sb8qh6S5S7/7tELWmkQ6PRGisC9qeTB85n4CcGE
-----END CERTIFICATE-----
PEMEOF
cat > "$TMP/certs/ipca.pem" <<'PEMEOF'
-----BEGIN CERTIFICATE-----
MIIB0DCCAXWgAwIBAgIBAjAKBggqhkjOPQQDAjASMRAwDgYDVQQDDAdjYWlwIENB
MB4XDTI2MDEwMTAwMDAwMFoXDTM2MDEwMTAwMDAwMFowNTEeMBwGA1UEAwwVaG9z
dC5iZWxpZWJpZy5leGFtcGxlMRMwEQYDVQQKDApBdXJ1bSBUZXN0MFkwEwYHKoZI
zj0CAQYIKoZIzj0DAQcDQgAEjbhl+1GndgfBJUL4JMwQCVsQ8db4iuIs/zLHEdiw
8WHDIdmt9sW/vLsGUSxWKa/GkUXCkJXXGoHBEcatw5lwSqOBmDCBlTAMBgNVHRMB
Af8EAjAAMA4GA1UdDwEB/wQEAwIHgDATBgNVHSUEDDAKBggrBgEFBQcDATAgBgNV
HREEGTAXghVob3N0LmJlbGllYmlnLmV4YW1wbGUwHQYDVR0OBBYEFFNDKriovmQU
Eq7Kbwu5UMc7RRnFMB8GA1UdIwQYMBaAFCINGvz0aReyiO8ehjsoj3N65bQ+MAoG
CCqGSM49BAMCA0kAMEYCIQC1BoxlWt9rAWax0KQa7kif+EnpkKccfJSeQuZ24cJV
UwIhAMI7Gi7yeqpE1wbnY/WUfpUeDk3yyfLzBCHHk+LAutKF
-----END CERTIFICATE-----
PEMEOF
cat > "$TMP/certs/dirca.pem" <<'PEMEOF'
-----BEGIN CERTIFICATE-----
MIIB0TCCAXagAwIBAgIBAjAKBggqhkjOPQQDAjATMREwDwYDVQQDDAhjYWRpciBD
QTAeFw0yNjAxMDEwMDAwMDBaFw0zNjAxMDEwMDAwMDBaMDUxHjAcBgNVBAMMFWhv
c3QuYmVsaWViaWcuZXhhbXBsZTETMBEGA1UECgwKQXVydW0gVGVzdDBZMBMGByqG
SM49AgEGCCqGSM49AwEHA0IABIepo1M7x8Kr4TQmln3cmQFfa2o+d3LPfBmcJ31s
wTYHbQe55qwMnbnNuDc6YNyMIWp/hEkq6COctA/yWmZ+lB+jgZgwgZUwDAYDVR0T
AQH/BAIwADAOBgNVHQ8BAf8EBAMCB4AwEwYDVR0lBAwwCgYIKwYBBQUHAwEwIAYD
VR0RBBkwF4IVaG9zdC5iZWxpZWJpZy5leGFtcGxlMB0GA1UdDgQWBBTSxWiULiSc
5MSojEcXsvEhw60tnjAfBgNVHSMEGDAWgBT/DG8VeTETgnQd5F3FscCpWH2MsjAK
BggqhkjOPQQDAgNJADBGAiEA45IFe+MZobLGFPllZn+BOnBC0vmkyKBltXwapkm/
pxgCIQDowdzaGHj/Ztz7OWFsOcQBI7jMbh0LEd8qmACI04BF8w==
-----END CERTIFICATE-----
PEMEOF

cat > "$TMP/s.lyx" <<'LYXEOF'
unit main;
import std.io;
import std.alloc;
import std.fs;
import std.crypto.der;
import std.crypto.x509;

fn ladeDer(pfad: pchar, derOut: int64): int64 {
  var pem: int64 := alloc(8192);
  var n: int64 := ReadFile(pfad, pem as pchar, 8191);
  if (n <= 0) { return -1; }
  var lab: pchar := "CERTIFICATE"c;
  return PemDekodiere(pem, n, lab as int64, StrLen(lab), derOut, 4096);
}

var gBasis: pchar := "CERTDIRMARKER"c;

fn lade(datei: pchar): int64 {
  var d: int64 := alloc(4096);
  var l: int64 := ladeDer(StrConcat(gBasis, datei), d);
  if (l <= 0) { return 0; }
  var paar: int64 := alloc(16);
  poke64(paar, d); poke64(paar + 8, l);
  return paar;
}

// Kette aus Blatt (+ CA als Trust-Store) pruefen.
fn pruef(blatt: int64, ca: int64, host: pchar): int64 {
  return X509PruefeKette(blatt, 1, ca, 1, host as int64, StrLen(host),
                         1800000000, 1);
}

fn melde(name: pchar, wert: int64): void {
  Print(name); Print(" "); PrintInt(wert); PrintLn("");
}

fn main(): int64 {
  var caPerm: int64 := lade("/caperm.pem"c);
  var caExcl: int64 := lade("/caexcl.pem"c);
  var caIp: int64   := lade("/caip.pem"c);
  var caDir: int64  := lade("/cadir.pem"c);
  var gut: int64    := lade("/gut.pem"c);
  var fremd: int64  := lade("/fremd.pem"c);
  var gesp: int64   := lade("/gesperr.pem"c);
  var frei: int64   := lade("/frei.pem"c);
  var ipB: int64    := lade("/ipca.pem"c);
  var dirB: int64   := lade("/dirca.pem"c);
  if (caPerm == 0 || caExcl == 0 || caIp == 0 || caDir == 0 || gut == 0
      || fremd == 0 || gesp == 0 || frei == 0 || ipB == 0 || dirB == 0) {
    PrintLn("LADEFEHLER"); return 1;
  }

  // Die Erweiterung wird ueberhaupt gelesen: ohne nameConstraints ist die
  // Position 0, mit ihr nicht. Sonst koennte unten alles aus einem anderen
  // Grund scheitern.
  var satz: int64 := alloc(X509Groesse());
  X509Lies(peek64(caPerm), peek64(caPerm + 8), satz);
  melde("nc-gelesen"c, X509NcLen(satz) > 0);
  X509Lies(peek64(gut), peek64(gut + 8), satz);
  melde("nc-blatt-ohne"c, X509NcLen(satz));

  melde("perm-innerhalb"c, pruef(gut, caPerm, "host.erlaubt.example"c));
  melde("perm-ausserhalb"c, pruef(fremd, caPerm, "host.fremd.example"c));
  melde("excl-getroffen"c, pruef(gesp, caExcl, "host.gesperrt.example"c));
  melde("excl-daneben"c, pruef(frei, caExcl, "host.frei.example"c));
  melde("ip-sperre-stoert-nicht"c, pruef(ipB, caIp, "host.beliebig.example"c));
  melde("dirname-abgewiesen"c, pruef(dirB, caDir, "host.beliebig.example"c));
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
( ulimit -v 2000000; "$TMP/s" > "$TMP/out.txt" 2>&1 )
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

pruefe nc-gelesen 1
pruefe nc-blatt-ohne 0
pruefe perm-innerhalb 0
pruefe perm-ausserhalb 13
pruefe excl-getroffen 13
pruefe excl-daneben 0
pruefe ip-sperre-stoert-nicht 0
pruefe dirname-abgewiesen 13

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$fails FAIL"
exit 1
