#!/usr/bin/env bash
# tests/tls_p384_test.sh — #2096 Abnahmekriterium 2, zweiter Teil:
# secp384r1 im Handschlag, in TLS 1.3 und TLS 1.2.
#
# Geprueft wird die WIRKUNG, nicht das Vorhandensein:
#
#   1. Mit einer echten P-384-Kette und BEIDSEITIG nur secp384r1 erlaubt
#      laeuft der Handschlag durch — und TlsGruppe meldet 0x0018. Waere die
#      Gruppe still auf x25519 zurueckgefallen, stuende hier eine andere
#      Zahl; dass der Handschlag klappt, genuegt also nicht.
#   2. Anwendungsdaten laufen in beide Richtungen.
#   3. Das Blattzertifikat ist mit ecdsa-with-SHA384 von einer P-384-CA
#      signiert; der Client prueft die Kette gegen den Trust-Store. Vor
#      #2096 gab x509 dafuer Code 10 ("nicht unterstuetzt").
#   4. **Gegenprobe Gruppe:** ein Client, der nur x25519 anbietet, gegen
#      einen Server, der nur secp384r1 erlaubt, MUSS scheitern. Ohne diesen
#      Fall waere der Test auch von einer Umsetzung erfuellt, die jede
#      Gruppe annimmt und heimlich x25519 rechnet.
#   5. **Gegenprobe Signatur:** ein gekipptes Byte im Serverflug MUSS die
#      Entschluesselung oder die Signaturpruefung scheitern lassen.
#   6. Dasselbe fuer TLS 1.2, wo die Signatur im ServerKeyExchange steckt
#      und ueber ecdsa_secp384r1_sha384 (0x0503) geprueft wird — das wurde
#      bis #2096 ANGEBOTEN, aber nicht geprueft: der Zweig verlangte
#      kLen == 65 und rechnete P-256.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/certs"

if ! command -v openssl >/dev/null 2>&1; then
  echo "SKIP openssl fehlt (die P-384-Kette wird damit erzeugt)"; exit 0
fi

# Eine echte Kette, mit openssl erzeugt: CA und Blatt auf secp384r1, beide
# Signaturen ecdsa-with-SHA384. Ein von Hand gebasteltes DER waere hier
# wertlos — es soll ja gerade geprueft werden, was ein fremdes Werkzeug
# ausstellt.
( cd "$TMP/certs"
  openssl ecparam -name secp384r1 -genkey -noout -out ca.key
  openssl req -x509 -new -key ca.key -sha384 -days 3650 \
    -subj "/CN=Aurum P-384 CA" -out ca.pem \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign"
  openssl ecparam -name secp384r1 -genkey -noout -out leaf.key
  openssl req -new -key leaf.key -subj "/CN=nexus.example" -out leaf.csr
  printf 'subjectAltName=DNS:nexus.example\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\n' > ext.cnf
  openssl x509 -req -in leaf.csr -CA ca.pem -CAkey ca.key -sha384 \
    -days 3650 -extfile ext.cnf -out leaf.pem
  openssl pkcs8 -topk8 -nocrypt -in leaf.key -out leafkey.pem
) > "$TMP/openssl.log" 2>&1

for f in ca.pem leaf.pem leafkey.pem; do
  if [ ! -s "$TMP/certs/$f" ]; then
    echo "SKIP openssl erzeugte $f nicht"; tail -5 "$TMP/openssl.log"; exit 0
  fi
done

if ! openssl x509 -in "$TMP/certs/leaf.pem" -noout -text \
     | grep -q 'ecdsa-with-SHA384'; then
  echo "FAIL: das erzeugte Blatt ist nicht mit ecdsa-with-SHA384 signiert"
  exit 1
fi

schreib_laeufer() {
  local ziel="$1" unit="$2" praefix="$3" kippoff="$4"
  cat > "$ziel" <<LYXEOF
import std.io;
import std.fs;
import std.alloc;
import std.crypto.der;
import std.crypto.x509;
import std.crypto.pkey;
import $unit;
import std.net.tls_config;

// PEM -> DER ueber std.crypto.der; ein eigener Base64-Leser im Test waere
// eine zweite Rechnung derselben Art.
fn ladeDer(pfad: pchar, etikett: pchar, out: int64): int64 {
  var pem: int64 := alloc(16384);
  var n: int64 := ReadFile(pfad, pem as pchar, 16383);
  if (n <= 0) { return -1; }
  return PemDekodiere(pem, n, etikett as int64, StrLen(etikett), out, 8192);
}

// Handschlag in zwei Puffern, ohne Netz. kipp = 1 kippt ein Byte im
// Serverflug.
fn handschlag(sv: int64, cl: int64, kipp: int64): int64 {
  var puf: int64 := alloc(49152);
  var runden: int64 := 0;
  var gekippt: int64 := 0;
  while (runden < 40) {
    var rcC: int64 := TLSPRESchritt(cl);
    if (rcC < 0) { free(puf, 49152); return rcC; }
    var n: int64 := TLSPREAusgabe(cl, puf, 49152);
    if (n > 0) { TLSPREFuetter(sv, puf, n); }
    var rcS: int64 := TLSPRESchritt(sv);
    if (rcS < 0) { free(puf, 49152); return rcS; }
    var m: int64 := TLSPREAusgabe(sv, puf, 49152);
    if (m > 0) {
      // Das LETZTE Byte des ersten nichtleeren Serverflugs: dort steht das
      // AEAD-Tag des letzten Records, und ein gekipptes Bit darin MUSS die
      // Entschluesselung scheitern lassen. Eine Kippstelle "in der Mitte"
      // traf beim Bauen nichts Wirksames und lieferte rc 0 — die Sonde
      // haette also nichts gemessen und waere trotzdem gruen gewesen.
      if (kipp == 1 && gekippt == 0 && m > KIPPOFF) {
        // KIPPOFF ist je Fassung verschieden:
        //   TLS 1.3: das letzte Byte ist das AEAD-Tag des letzten Records,
        //            ein gekipptes Bit darin MUSS die Entschluesselung
        //            scheitern lassen.
        //   TLS 1.2: der Handschlag laeuft bis zum CCS im KLARTEXT. Das
        //            letzte Byte gehoert zu ServerHelloDone; ein Kippen
        //            dort verstuemmelt nur einen Nachrichtenkopf, der
        //            Handschlag bleibt stehen und die Sonde misst nichts.
        //            40 Byte davor liegt die Signatur im
        //            ServerKeyExchange — dort MUSS die Pruefung anschlagen.
        poke8(puf + m - KIPPOFF, (peek8(puf + m - KIPPOFF) ^ 1) & 255);
        gekippt := 1;
      }
      TLSPREFuetter(cl, puf, m);
    }
    if (TLSPREFertig(cl) && TLSPREFertig(sv)) { free(puf, 49152); return 0; }
    if (n == 0 && m == 0) { free(puf, 49152); return -99; }
    runden := runden + 1;
  }
  free(puf, 49152);
  return -98;
}

fn main(): int64 {
  var basis: pchar := "CERTDIRMARKER"c;
  var dCa: int64 := alloc(8192);
  var dLeaf: int64 := alloc(8192);
  var dKey: int64 := alloc(8192);
  var lCa: int64 := ladeDer(StrConcat(basis, "/ca.pem"c), "CERTIFICATE"c, dCa);
  var lLeaf: int64 := ladeDer(StrConcat(basis, "/leaf.pem"c), "CERTIFICATE"c, dLeaf);
  var lKey: int64 := ladeDer(StrConcat(basis, "/leafkey.pem"c), "PRIVATE KEY"c, dKey);
  if (lCa <= 0 || lLeaf <= 0 || lKey <= 0) {
    PrintStrLn("LADEFEHLER"c);
    return 1;
  }

  // Der Schluessel muss als secp384r1 erkannt werden (Kennung 2) — sonst
  // waere der Rest dieses Tests eine Aussage ueber P-256.
  var skalar: int64 := alloc(48);
  var kurve: int64 := PkeyLiesEcPrivat(dKey, lKey, skalar);
  Print("schluessel-kurve "c); PrintIntLn(kurve);

  var kette: int64 := alloc(16);
  poke64(kette, dLeaf); poke64(kette + 8, lLeaf);
  var trust: int64 := alloc(16);
  poke64(trust, dCa); poke64(trust + 8, lCa);

  var cfgS: int64 := alloc(TlsConfigGroesse());
  var cfgC: int64 := alloc(TlsConfigGroesse());
  var host: pchar := "nexus.example"c;

  TlsConfigNeu(cfgS, 1);
  TlsConfigKette(cfgS, kette, 1, dKey, lKey);
  TlsConfigZeit(cfgS, 1800000000);
  // NUR secp384r1 (Bit 2). Damit ist ein stiller Rueckfall auf x25519
  // ausgeschlossen: er wuerde den Handschlag scheitern lassen, nicht
  // heimlich gelingen.
  TlsConfigGruppen(cfgS, 4);

  TlsConfigNeu(cfgC, 2);
  TlsConfigTrust(cfgC, trust, 1);
  TlsConfigHost(cfgC, host as int64, StrLen(host));
  TlsConfigZeit(cfgC, 1800000000);
  TlsConfigGruppen(cfgC, 4);

  var sv: int64 := TLSPRENeu(cfgS);
  var cl: int64 := TLSPRENeu(cfgC);
  Print("handschlag "c); PrintIntLn(handschlag(sv, cl, 0));
  Print("gruppe-client "c); PrintIntLn(TLSPREGruppe(cl));
  Print("gruppe-server "c); PrintIntLn(TLSPREGruppe(sv));
  Print("fertig "c);
  if (TLSPREFertig(cl) && TLSPREFertig(sv)) { PrintIntLn(1); } else { PrintIntLn(0); }

  // Anwendungsdaten in beide Richtungen
  var ein: int64 := alloc(8192);
  var text: pchar := "GET / HTTP/1.1"c;
  TLSPRESchreibe(cl, text as int64, 14);
  var puf: int64 := alloc(49152);
  var n1: int64 := TLSPREAusgabe(cl, puf, 49152);
  if (n1 > 0) { TLSPREFuetter(sv, puf, n1); }
  Print("server-liest "c); PrintIntLn(TLSPRELese(sv, ein, 8192));
  var antwort: pchar := "HTTP/1.1 200 OK"c;
  TLSPRESchreibe(sv, antwort as int64, 15);
  var n2: int64 := TLSPREAusgabe(sv, puf, 49152);
  if (n2 > 0) { TLSPREFuetter(cl, puf, n2); }
  Print("client-liest "c); PrintIntLn(TLSPRELese(cl, ein, 8192));

  // Gegenprobe 1: Client nur x25519, Server nur secp384r1 -> muss scheitern
  var cfgC2: int64 := alloc(TlsConfigGroesse());
  TlsConfigNeu(cfgC2, 2);
  TlsConfigTrust(cfgC2, trust, 1);
  TlsConfigHost(cfgC2, host as int64, StrLen(host));
  TlsConfigZeit(cfgC2, 1800000000);
  TlsConfigGruppen(cfgC2, 1);
  var sv2: int64 := TLSPRENeu(cfgS);
  var cl2: int64 := TLSPRENeu(cfgC2);
  Print("nur-x25519-gegen-nur-p384 "c); PrintIntLn(handschlag(sv2, cl2, 0));

  // Gegenprobe 2: gekipptes Byte im Serverflug
  var sv3: int64 := TLSPRENeu(cfgS);
  var cl3: int64 := TLSPRENeu(cfgC);
  Print("gekippt "c); PrintIntLn(handschlag(sv3, cl3, 1));

  return 0;
}
LYXEOF
  sed -i "s#CERTDIRMARKER#$TMP/certs#" "$ziel"
  # std.net.tls12 fuehrt dieselbe API unter dem Praefix Tls12 — die beiden
  # Units sind getrennte Zustandsmaschinen, nicht eine mit Schalter.
  sed -i "s#TLSPRE#$praefix#g" "$ziel"
  sed -i "s#KIPPOFF#$kippoff#g" "$ziel"
}

fehler=0

pruefe_lauf() {
  local name="$1" aus="$2"
  local ok=1
  grep -q '^schluessel-kurve 2$' "$aus" || { echo "FAIL $name: Schluessel nicht als secp384r1 erkannt"; ok=0; }
  grep -q '^handschlag 0$' "$aus" || { echo "FAIL $name: Handschlag mit P-384 scheitert"; ok=0; }
  grep -q '^gruppe-client 24$' "$aus" || { echo "FAIL $name: Client rechnete nicht secp384r1 (0x0018 = 24)"; ok=0; }
  grep -q '^gruppe-server 24$' "$aus" || { echo "FAIL $name: Server rechnete nicht secp384r1"; ok=0; }
  grep -q '^fertig 1$' "$aus" || { echo "FAIL $name: nicht beide fertig"; ok=0; }
  grep -q '^server-liest 14$' "$aus" || { echo "FAIL $name: Server las die Anfrage nicht"; ok=0; }
  grep -q '^client-liest 15$' "$aus" || { echo "FAIL $name: Client las die Antwort nicht"; ok=0; }
  # Gegenproben: beide MUESSEN scheitern, und zwar mit negativem Code.
  local g1 g2
  g1="$(grep -m1 '^nur-x25519-gegen-nur-p384 ' "$aus" | awk '{print $2}')"
  g2="$(grep -m1 '^gekippt ' "$aus" | awk '{print $2}')"
  if [ -z "$g1" ] || [ "$g1" -ge 0 ] 2>/dev/null; then
    echo "FAIL $name: ein Client ohne secp384r1 kam durch (rc=$g1)"; ok=0
  fi
  # Der Kippfall muss ein URTEIL der Unit sein. -99 ist der Stillstandscode
  # des Laeufers ("keine Seite hat mehr etwas zu sagen") und zaehlt NICHT:
  # damit waere der Test auch von einer Umsetzung erfuellt, die bei
  # verfaelschten Byte einfach haengen bleibt.
  if [ -z "$g2" ] || [ "$g2" -ge 0 ] 2>/dev/null; then
    echo "FAIL $name: gekippter Serverflug wurde angenommen (rc=$g2)"; ok=0
  elif [ "$g2" = "-98" ] || [ "$g2" = "-99" ]; then
    echo "FAIL $name: gekippter Serverflug fuehrte zum Stillstand (rc=$g2), nicht zu einer Ablehnung"; ok=0
  fi
  if [ "$ok" = 1 ]; then
    echo "PASS $name: Handschlag auf secp384r1, beide Gegenproben greifen"
  else
    fehler=$((fehler + 1))
    sed -n '1,20p' "$aus" | sed 's/^/    /'
  fi
}

cd "$ROOT"
for paar in "tls13:std.net.tls13:Tls:1" "tls12:std.net.tls12:Tls12:40"; do
  name="$(echo "$paar" | cut -d: -f1)"
  unit="$(echo "$paar" | cut -d: -f2)"
  praefix="$(echo "$paar" | cut -d: -f3)"
  kippoff="$(echo "$paar" | cut -d: -f4)"
  schreib_laeufer "$TMP/$name.lyx" "$unit" "$praefix" "$kippoff"
  if ! timeout 900 "$LYXC" "$TMP/$name.lyx" --std-path=. -o "$TMP/$name" \
       > "$TMP/$name.build.log" 2>&1; then
    echo "FAIL $name: Laeufer uebersetzt nicht"
    tail -15 "$TMP/$name.build.log"
    fehler=$((fehler + 1))
    continue
  fi
  ( ulimit -v 6000000 -c 0; timeout 900 "$TMP/$name" > "$TMP/$name.out" 2>&1 )
  rc=$?
  if [ "$rc" -ge 128 ]; then
    echo "FAIL $name: Lauf abgebrochen (rc=$rc)"
    tail -5 "$TMP/$name.out"
    fehler=$((fehler + 1))
    continue
  fi
  pruefe_lauf "$name" "$TMP/$name.out"
done

if [ "$fehler" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$fehler FAIL"
exit 1
