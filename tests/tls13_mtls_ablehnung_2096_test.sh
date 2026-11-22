#!/usr/bin/env bash
# tests/tls13_mtls_ablehnung_2096_test.sh — #2096 Abnahmekriterium 3:
# "mTLS: Client-Zertifikat angefordert, gueltig/abgelaufen/falsche CA/falsche
# EKU korrekt behandelt".
#
# Abgedeckt war davon nur der gute Fall und "gar kein Zertifikat"
# (tests/tls13_handschlag_test.sh). Die drei ABLEHNUNGSfaelle standen im
# Kriterium und nirgends im Lauf; auf der X.509-Ebene allein sind sie
# geprueft (tests/crypto_x509_kette_test.sh), aber nicht am TLS-Handschlag.
# Das ist ein Unterschied: der Server muss `zweck = 2` (clientAuth) und
# seine Vorgabezeit UEBERHAUPT an die Kettenpruefung reichen. Tut er das
# nicht, besteht die X.509-Pruefung weiter und der Handschlag nimmt
# trotzdem jedes Zertifikat.
#
# Vier Faelle, dieselbe Form, nur das Client-Zertifikat bzw. die Zeit
# wechselt:
#   gut          Kette von unserer CA, EKU clientAuth          -> 0
#   fremde-ca    Kette von einer ZWEITEN CA, sonst gleich      -> -6
#   falsche-eku  unsere CA, aber EKU serverAuth (kein client)  -> -6
#   abgelaufen   dasselbe gute Zertifikat, Serverzeit NACH notAfter -> -6
#
# Der Ablauf wird ueber die VORGABEZEIT des Servers hergestellt und nicht
# ueber ein rueckdatiertes Zertifikat: `TlsConfigZeit` ist die Stelle, die
# der Server der Kettenpruefung reicht, und genau sie soll geprueft werden.
# Ein rueckdatiertes Zertifikat haette ausserdem eine zweite Fehlerquelle
# (die Datumsschreibweise im Erzeuger) in den Test geholt.
#
# Beide Seiten gemessen: ohne den guten Fall waere der Test auch von einem
# Server erfuellt, der JEDES Client-Zertifikat ablehnt.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"

if ! command -v openssl >/dev/null 2>&1; then
  echo "SKIP openssl nicht im Pfad (Zertifikatserzeugung)"; exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
C="$TMP/certs"; mkdir -p "$C"

# --- Zertifikate erzeugen -------------------------------------------------
# Zwei CAs: die eine vertraut der Server, die andere ist die "fremde".
for ca in ca1 ca2; do
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$C/$ca.key" -out "$C/$ca.pem" -days 3650 -nodes \
    -subj "/CN=Aurum Test $ca" -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1
done

# Ein Blatt: $1 Name, $2 CA, $3 EKU-Zeichenkette, $4 SAN
blatt() {
  local name="$1" ca="$2" eku="$3" san="$4"
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$C/$name.key" -out "$C/$name.csr" -nodes \
    -subj "/CN=$name.example" >/dev/null 2>&1
  openssl x509 -req -in "$C/$name.csr" -CA "$C/$ca.pem" -CAkey "$C/$ca.key" \
    -days 365 -set_serial "0x$(openssl rand -hex 8)" \
    -extfile <(printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=%s\nsubjectAltName=%s\n' "$eku" "$san") \
    -out "$C/$name.pem" >/dev/null 2>&1
}

blatt srv      ca1 serverAuth              "DNS:nexus.example"
blatt cligut   ca1 clientAuth              "DNS:client.example"
blatt clifremd ca2 clientAuth              "DNS:client.example"
blatt clieku   ca1 serverAuth              "DNS:client.example"

for f in ca1.pem srv.pem srv.key cligut.pem cligut.key clifremd.pem clifremd.key clieku.pem clieku.key; do
  [ -s "$C/$f" ] || { echo "FAIL Zertifikatserzeugung: $f fehlt oder ist leer"; exit 1; }
done
# Gegenprobe am ERZEUGNIS: das EKU-Zertifikat muss wirklich serverAuth
# tragen und nicht clientAuth. Ein Test gegen ein falsch erzeugtes
# Zertifikat wuerde aus dem richtigen Grund gruen und waere wertlos.
if ! openssl x509 -in "$C/clieku.pem" -noout -text | grep -q "TLS Web Server Authentication"; then
  echo "FAIL Vorbedingung: clieku.pem traegt kein serverAuth"; exit 1
fi
if openssl x509 -in "$C/clieku.pem" -noout -text | grep -q "TLS Web Client Authentication"; then
  echo "FAIL Vorbedingung: clieku.pem traegt clientAuth, der Fall waere keiner"; exit 1
fi

cat > "$TMP/m.lyx" <<'LYXEOF'
unit main;
import std.io;
import std.string;
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

fn handschlag(sv: int64, cl: int64): int64 {
  var puf: int64 := alloc(32768);
  var runden: int64 := 0;
  while (runden < 40) {
    var rcC: int64 := TlsSchritt(cl);
    if (rcC < 0) { return rcC; }
    var n: int64 := TlsAusgabe(cl, puf, 32768);
    if (n > 0) { TlsFuetter(sv, puf, n); }
    var rcS: int64 := TlsSchritt(sv);
    if (rcS < 0) { return rcS; }
    var m: int64 := TlsAusgabe(sv, puf, 32768);
    if (m > 0) { TlsFuetter(cl, puf, m); }
    if (TlsFertig(cl) && TlsFertig(sv)) { return 0; }
    if (n == 0 && m == 0) { return 0 - 99; }
    runden := runden + 1;
  }
  return 0 - 98;
}

fn main(): int64 {
  var basis: pchar := "CERTDIRMARKER"c;
  var dCa: int64 := alloc(4096);   var lCa  := ladeDer(StrConcat(basis, "/ca1.pem"c), "CERTIFICATE"c, dCa);
  var dSrv: int64 := alloc(4096);  var lSrv := ladeDer(StrConcat(basis, "/srv.pem"c), "CERTIFICATE"c, dSrv);
  var dSk: int64 := alloc(4096);   var lSk  := ladeDer(StrConcat(basis, "/srv.key"c), "PRIVATE KEY"c, dSk);
  var dGut: int64 := alloc(4096);  var lGut := ladeDer(StrConcat(basis, "/cligut.pem"c), "CERTIFICATE"c, dGut);
  var dGk: int64 := alloc(4096);   var lGk  := ladeDer(StrConcat(basis, "/cligut.key"c), "PRIVATE KEY"c, dGk);
  var dFre: int64 := alloc(4096);  var lFre := ladeDer(StrConcat(basis, "/clifremd.pem"c), "CERTIFICATE"c, dFre);
  var dFk: int64 := alloc(4096);   var lFk  := ladeDer(StrConcat(basis, "/clifremd.key"c), "PRIVATE KEY"c, dFk);
  var dEku: int64 := alloc(4096);  var lEku := ladeDer(StrConcat(basis, "/clieku.pem"c), "CERTIFICATE"c, dEku);
  var dEk: int64 := alloc(4096);   var lEk  := ladeDer(StrConcat(basis, "/clieku.key"c), "PRIVATE KEY"c, dEk);
  if (lCa <= 0 || lSrv <= 0 || lSk <= 0 || lGut <= 0 || lFre <= 0 || lEku <= 0) {
    PrintLn("LADEFEHLER"); return 1;
  }

  var kette: int64 := alloc(16);  poke64(kette, dSrv); poke64(kette + 8, lSrv);
  var trust: int64 := alloc(16);  poke64(trust, dCa);  poke64(trust + 8, lCa);
  var kGut: int64 := alloc(16);   poke64(kGut, dGut);  poke64(kGut + 8, lGut);
  var kFre: int64 := alloc(16);   poke64(kFre, dFre);  poke64(kFre + 8, lFre);
  var kEku: int64 := alloc(16);   poke64(kEku, dEku);  poke64(kEku + 8, lEku);

  var host: pchar := "nexus.example"c;
  var jetzt: int64 := JETZTMARKER;
  var spaeter: int64 := jetzt + 63072000;   // zwei Jahre -- nach notAfter (365 Tage)

  // Vier Laeufe, je mit frischer Vorgabe: ein wiederverwendeter
  // Konfigurationsblock traegt sonst die Kette des Vorgaengers weiter.
  var fall: int64 := 0;
  while (fall < 4) {
    var cfgS: int64 := alloc(TlsConfigGroesse());
    var cfgC: int64 := alloc(TlsConfigGroesse());
    TlsConfigNeu(cfgS, 1);
    TlsConfigKette(cfgS, kette, 1, dSk, lSk);
    TlsConfigClientAuth(cfgS, 2);
    TlsConfigTrust(cfgS, trust, 1);
    TlsConfigNeu(cfgC, 2);
    TlsConfigTrust(cfgC, trust, 1);
    TlsConfigHost(cfgC, host as int64, StrLen(host));
    TlsConfigZeit(cfgC, jetzt);

    if (fall == 0) {
      TlsConfigZeit(cfgS, jetzt);
      TlsConfigKette(cfgC, kGut, 1, dGk, lGk);
      Print("gut ");
    }
    if (fall == 1) {
      TlsConfigZeit(cfgS, jetzt);
      TlsConfigKette(cfgC, kFre, 1, dFk, lFk);
      Print("fremde-ca ");
    }
    if (fall == 2) {
      TlsConfigZeit(cfgS, jetzt);
      TlsConfigKette(cfgC, kEku, 1, dEk, lEk);
      Print("falsche-eku ");
    }
    if (fall == 3) {
      TlsConfigZeit(cfgS, spaeter);
      TlsConfigKette(cfgC, kGut, 1, dGk, lGk);
      Print("abgelaufen ");
    }

    var sv: int64 := TlsNeu(cfgS);
    var cl: int64 := TlsNeu(cfgC);
    PrintInt(handschlag(sv, cl));
    PrintLn("");
    TlsFrei(sv);
    TlsFrei(cl);
    fall := fall + 1;
  }
  return 0;
}
LYXEOF
sed -i "s|CERTDIRMARKER|$C|" "$TMP/m.lyx"
# Die Vorgabezeit ist die Stunde des Laufs: die Zertifikate oben sind eben
# erzeugt worden, eine festgenagelte Zahl waere in einem Jahr falsch.
sed -i "s|JETZTMARKER|$(date +%s)|" "$TMP/m.lyx"

if ! ( cd "$ROOT" && timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/m.lyx" -o "$TMP/m" ) >"$TMP/log" 2>&1; then
  echo "FAIL uebersetzt nicht: $(grep -m1 -i error "$TMP/log")"; exit 1
fi
[ -x "$TMP/m" ] || { echo "FAIL kein Erzeugnis (#1682)"; exit 1; }
( ulimit -v 4000000 -c 0; "$TMP/m" ) > "$TMP/aus.txt" 2>&1
RC=$?
sed 's/^/    /' "$TMP/aus.txt"

P=0; F=0
ok()  { echo "PASS $1"; P=$((P+1)); }
bad() { echo "FAIL $1${2:+ -- $2}"; F=$((F+1)); }

[ "$RC" = 0 ] || bad "Lauf" "Exitcode $RC"
pruefeZeile() {  # name, erwarteter Wert
  ist="$(grep -m1 "^$1 " "$TMP/aus.txt" | awk '{print $2}')"
  if [ "${ist:-fehlt}" = "$2" ]; then ok "$1 -> $2"; else bad "$1" "ist ${ist:-fehlt}, soll $2"; fi
}
# -6 ist E_ZERTIFIKAT. Die Zahl steht hier ausdruecklich und nicht "< 0":
# ein Handschlag, der aus einem ANDEREN Grund scheitert (etwa -5,
# Entschluesselung), wuerde sonst als richtige Ablehnung durchgehen.
pruefeZeile gut 0
pruefeZeile fremde-ca -6
pruefeZeile falsche-eku -6
pruefeZeile abgelaufen -6

echo "--- $P PASS, $F FAIL"
[ "$F" -eq 0 ] || exit 1
echo "ALL PASS"
