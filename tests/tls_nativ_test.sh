#!/usr/bin/env bash
# tests/tlsc_adapter_test.sh — #2096: die Konsumenten sprechen TLS nativ.
#
# std.net.tls bietet dieselbe Sechs-Funktionen-API wie bisher (TLSInit,
# TLSConnect, TLSRead, TLSWrite, TLSClose, TLSFree), rechnet aber seit #2096
# mit std.net.tls13 statt mit OpenSSL. Der NAME ist die API; getauscht wurde
# die UMSETZUNG. Die FFI-Fassung heisst jetzt std.net.tls_openssl und bleibt
# als Gegenprobe und fuer Faelle, die CBC-Suiten brauchen.
#
# Zwei Units mit denselben oeffentlichen Namen waeren fuer jeden, der beide
# importiert, MEHRDEUTIG — daran ist tests/regression/net/test_https.lyx
# zunaechst gescheitert ("mehrdeutiges Symbol 'TLSContext'"). Darum ein Name,
# eine Umsetzung.
#
# Geprueft wird die WIRKUNG, nicht das Vorhandensein:
#
#   1. **Kein Konsument haengt mehr an libssl.** Geprueft am Erzeugnis, nicht
#      an der Importzeile: ein Programm, das std.net.https benutzt, darf
#      keine libssl-Verweise mehr tragen. Das ist der Punkt des ganzen
#      Vorgangs — eine Umstellung, die nur im Quelltext steht, waere keine.
#   2. **Der Adapter laedt echte Vertrauensanker** aus dem CA-Store des
#      Systems. Eine 0 faellt durch: ein Kontext ohne Anker wuerde JEDES
#      Zertifikat ablehnen, und der Test waere trotzdem gruen, wenn man nur
#      "initialized" prueft.
#   3. **Ein Handschlag gegen einen echten Server** (loopback, eigene PKI
#      ueber TLSInitMitStore) laeuft durch, und Anwendungsdaten laufen in
#      beide Richtungen.
#   4. **Gegenproben, die greifen muessen:** hostname == 0 wird abgewiesen
#      (ohne Namenspruefung ist TLS gegen einen Angreifer in der Mitte
#      wertlos — SEC-BUG-04 im alten Wrapper), ein fauler fd wird
#      abgewiesen, und ein Server mit einer Kette, die NICHT zu den Ankern
#      passt, wird abgewiesen.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"; pkill -x tlsc_srv 2>/dev/null' EXIT

fehler=0

# ── 1. Am Erzeugnis: keine libssl-Verweise mehr ────────────────────────────
cat > "$TMP/nutzt_https.lyx" <<'LYXEOF'
import std.io;
import std.net.https;

fn main(): int64 {
  // Nur die Bindung soll entstehen; aufgerufen wird nichts.
  if (0 != 0) {
    var r: HTTPResponse := HTTPSGet("example.invalid"c, "/"c);
    PrintIntLn(r.statusCode);
  }
  PrintStrLn("gebaut"c);
  return 0;
}
LYXEOF
cd "$ROOT"
if ! timeout 900 "$LYXC" "$TMP/nutzt_https.lyx" --std-path=. -o "$TMP/nutzt_https" \
     > "$TMP/build_https.log" 2>&1; then
  echo "FAIL: ein Programm mit std.net.https uebersetzt nicht"
  tail -15 "$TMP/build_https.log"
  exit 1
fi

if command -v strings >/dev/null 2>&1; then
  treffer="$(strings "$TMP/nutzt_https" | grep -ciE 'libssl|libcrypto|SSL_CTX_new|SSL_connect' || true)"
  if [ "$treffer" != 0 ]; then
    echo "FAIL: das Erzeugnis traegt noch $treffer OpenSSL-Verweise"
    strings "$TMP/nutzt_https" | grep -iE 'libssl|libcrypto|SSL_CTX_new|SSL_connect' | head -5
    fehler=$((fehler + 1))
  else
    echo "PASS std.net.https ohne jeden OpenSSL-Verweis im Erzeugnis"
  fi
else
  echo "HINWEIS: strings fehlt — die Pruefung am Erzeugnis entfaellt"
fi

# Gegenprobe zur Pruefung selbst: der ALTE Wrapper MUSS die Verweise tragen.
# Ohne diesen Fall wuerde ein kaputtes `strings`-Kommando als Erfolg gelten.
cat > "$TMP/nutzt_tls.lyx" <<'LYXEOF'
import std.io;
import std.net.tls_openssl;

fn main(): int64 {
  if (0 != 0) {
    var ctx: TLSContext := TLSInit();
    TLSFree(ctx);
  }
  PrintStrLn("gebaut"c);
  return 0;
}
LYXEOF
if timeout 900 "$LYXC" "$TMP/nutzt_tls.lyx" --std-path=. -o "$TMP/nutzt_tls" \
     > "$TMP/build_tls.log" 2>&1; then
  if command -v strings >/dev/null 2>&1; then
    alt="$(strings "$TMP/nutzt_tls" | grep -ciE 'libssl|SSL_connect' || true)"
    if [ "$alt" = 0 ]; then
      echo "FAIL: std.net.tls_openssl traegt keine libssl-Verweise — die Pruefung oben misst nichts"
      fehler=$((fehler + 1))
    else
      echo "PASS Gegenprobe: std.net.tls_openssl traegt $alt OpenSSL-Verweise"
    fi
  fi
else
  echo "HINWEIS: std.net.tls_openssl uebersetzt hier nicht (libssl fehlt?) — Gegenprobe entfaellt"
fi

# ── 2.-4. Anker, Handschlag, Gegenproben ──────────────────────────────────
if ! command -v openssl >/dev/null 2>&1; then
  echo "HINWEIS: openssl fehlt — Handschlagteil entfaellt"
  if [ "$fehler" = 0 ]; then echo "ALL PASS (ohne Handschlagteil)"; exit 0; fi
  echo "$fehler FAIL"; exit 1
fi

mkdir -p "$TMP/certs"
# Eine richtige Kette: CA (CA:TRUE, keyCertSign) und ein davon signiertes
# Blatt. Ein selbstsigniertes Blatt als Anker geht NICHT — X509PruefeKette
# verlangt vom Aussteller basicConstraints CA:TRUE und weist es mit Code 6
# ab. Beim Bauen dieses Tests kam darueber ein E_ZERTIFIKAT (-6), und der
# Fehler lag in der Pruefanordnung, nicht im Adapter.
( cd "$TMP/certs"
  openssl req -x509 -newkey rsa:2048 -keyout ca.key -out ca.pem -days 365 \
    -nodes -subj "/CN=Aurum tlsc Test-CA" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign"
  openssl req -newkey rsa:2048 -keyout key.pem -out leaf.csr -nodes \
    -subj "/CN=localhost"
  printf 'subjectAltName=IP:127.0.0.1,DNS:localhost\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nbasicConstraints=critical,CA:FALSE\n' > ext.cnf
  openssl x509 -req -in leaf.csr -CA ca.pem -CAkey ca.key -sha256 -days 365 \
    -extfile ext.cnf -out cert.pem
  openssl req -x509 -newkey rsa:2048 -keyout fremd.key -out fremd.pem -days 365 \
    -nodes -subj "/CN=fremde CA" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign"
) > "$TMP/openssl.log" 2>&1
for f in ca.pem cert.pem key.pem fremd.pem; do
  [ -s "$TMP/certs/$f" ] || { echo "SKIP openssl erzeugte $f nicht"; exit 0; }
done

cat > "$TMP/sonde.lyx" <<'LYXEOF'
import std.io;
import std.fs;
import std.alloc;
import std.crypto.der;
import std.net.tls;
import std.net.socket;

fn ladeDer(pfad: pchar, etikett: pchar, out: int64): int64 {
  var pem: int64 := alloc(16384);
  var n: int64 := ReadFile(pfad, pem as pchar, 16383);
  if (n <= 0) { return -1; }
  return PemDekodiere(pem, n, etikett as int64, StrLen(etikett), out, 8192);
}

fn main(): int64 {
  // 2. Der Store des Systems
  var sys: TLSContext := TLSInit();
  Print("sys-initialized "c); PrintIntLn(sys.initialized);
  Print("sys-anker "c); PrintIntLn(TLSTrustAnzahl(sys));

  // 4a. Ohne Hostnamen: MUSS abgewiesen werden
  var ohne: TLSConn := TLSConnect(sys, 3, 0 as pchar);
  Print("ohne-host "c); PrintIntLn(ohne.connected);
  // 4b. Fauler fd
  var fauler: TLSConn := TLSConnect(sys, 0 - 1, "localhost"c);
  Print("fauler-fd "c); PrintIntLn(fauler.connected);
  TLSFree(sys);

  // 3. Handschlag gegen den eigenen Server, eigene PKI
  var dCert: int64 := alloc(8192);
  var lCert: int64 := ladeDer("CERTDIR/ca.pem"c, "CERTIFICATE"c, dCert);
  if (lCert <= 0) { PrintStrLn("LADEFEHLER"c); return 1; }
  var anker: int64 := alloc(16);
  poke64(anker, dCert); poke64(anker + 8, lCert);
  var eigen: TLSContext := TLSInitMitStore(anker, 1);
  Print("eigen-initialized "c); PrintIntLn(eigen.initialized);

  // 0x7F000001 ist 127.0.0.1 in Wirtsreihenfolge — kein DNS im Test.
  var tcp: TCPConn := TCPConnect(2130706433, PORTMARKER);
  if (tcp.fd < 0) { PrintStrLn("KEIN-SOCKET"c); return 1; }
  var c: TLSConn := TLSConnect(eigen, tcp.fd, "localhost"c);
  Print("handschlag "c); PrintIntLn(c.connected);
  Print("handschlag-rc "c); PrintIntLn(c.rc);
  if (c.connected == 1) {
    var anfrage: pchar := "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"c;
    Print("geschrieben "c); PrintIntLn(TLSWrite(c, anfrage as int64, StrLen(anfrage)));
    var puf: int64 := alloc(8192);
    var n: int64 := TLSRead(c, puf, 8192);
    Print("gelesen "c); PrintIntLn(n);
    var hat200: int64 := 0;
    if (n > 12) {
      if ((peek8(puf + 9) & 255) == 50 && (peek8(puf + 10) & 255) == 48
          && (peek8(puf + 11) & 255) == 48) { hat200 := 1; }
    }
    Print("status-200 "c); PrintIntLn(hat200);
    TLSClose(c);
  }
  TCPConnClose(tcp);

  // 4c. Fremde Anker: dieselbe Gegenstelle MUSS abgewiesen werden
  var dFremd: int64 := alloc(8192);
  var lFremd: int64 := ladeDer("CERTDIR/fremd.pem"c, "CERTIFICATE"c, dFremd);
  var anker2: int64 := alloc(16);
  poke64(anker2, dFremd); poke64(anker2 + 8, lFremd);
  var falsch: TLSContext := TLSInitMitStore(anker2, 1);
  var tcp2: TCPConn := TCPConnect(2130706433, PORTMARKER);
  if (tcp2.fd >= 0) {
    var c2: TLSConn := TLSConnect(falsch, tcp2.fd, "localhost"c);
    Print("fremde-anker "c); PrintIntLn(c2.connected);
    TCPConnClose(tcp2);
  } else {
    Print("fremde-anker "c); PrintIntLn(0 - 2);
  }
  return 0;
}
LYXEOF

PORT="${TLSC_PORT:-18997}"
sed -i "s#CERTDIR#$TMP/certs#g; s#PORTMARKER#$PORT#g" "$TMP/sonde.lyx"

if ! timeout 900 "$LYXC" tools/tls_server.lyx --std-path=. -o "$TMP/tlsc_srv" \
     > "$TMP/build_srv.log" 2>&1; then
  echo "FAIL: tools/tls_server.lyx uebersetzt nicht"; tail -10 "$TMP/build_srv.log"; exit 1
fi
if ! timeout 900 "$LYXC" "$TMP/sonde.lyx" --std-path=. -o "$TMP/sonde" \
     > "$TMP/build_sonde.log" 2>&1; then
  echo "FAIL: die Sonde uebersetzt nicht"; tail -15 "$TMP/build_sonde.log"; exit 1
fi

pkill -x tlsc_srv 2>/dev/null
sleep 0.3
( ulimit -v 6000000 -c 0; "$TMP/tlsc_srv" "$PORT" "$TMP/certs/cert.pem" \
    "$TMP/certs/key.pem" "$TMP/certs/ca.pem" N=0 still > "$TMP/srv.log" 2>&1 & )
bereit=0
for i in $(seq 1 60); do
  if ss -ltn 2>/dev/null | grep -q ":$PORT "; then bereit=1; break; fi
  sleep 0.1
done
if [ "$bereit" != 1 ]; then echo "FAIL: Server lauscht nicht auf $PORT"; exit 1; fi

( ulimit -v 6000000 -c 0; timeout 300 "$TMP/sonde" > "$TMP/out.txt" 2>&1 )
rc=$?
cat "$TMP/out.txt"
if [ "$rc" -ge 128 ]; then echo "FAIL: Sonde abgebrochen (rc=$rc)"; exit 1; fi

hol() { grep -m1 "^$1 " "$TMP/out.txt" | awk '{print $2}'; }

[ "$(hol sys-initialized)" = 1 ] || { echo "FAIL: der CA-Store des Systems wurde nicht geladen"; fehler=$((fehler+1)); }
anker="$(hol sys-anker)"
case "$anker" in
  ''|*[!0-9]*) echo "FAIL: Ankerzahl unlesbar"; fehler=$((fehler+1)) ;;
  *) if [ "$anker" -lt 10 ]; then
       echo "FAIL: nur $anker Vertrauensanker — ein fast leerer Store lehnt alles ab"
       fehler=$((fehler+1))
     else
       echo "PASS $anker Vertrauensanker aus dem CA-Store des Systems"
     fi ;;
esac
[ "$(hol ohne-host)" = 0 ] || { echo "FAIL: TLSConnect ohne Hostnamen kam durch"; fehler=$((fehler+1)); }
[ "$(hol fauler-fd)" = 0 ] || { echo "FAIL: TLSConnect mit faulem fd kam durch"; fehler=$((fehler+1)); }
[ "$(hol eigen-initialized)" = 1 ] || { echo "FAIL: TLSInitMitStore nahm die eigenen Anker nicht"; fehler=$((fehler+1)); }
[ "$(hol handschlag)" = 1 ] || { echo "FAIL: Handschlag gegen den eigenen Server scheitert"; fehler=$((fehler+1)); }
[ "$(hol status-200)" = 1 ] || { echo "FAIL: keine 200er-Antwort gelesen"; fehler=$((fehler+1)); }
[ "$(hol fremde-anker)" = 0 ] || { echo "FAIL: mit FREMDEN Ankern kam der Handschlag durch — die Pruefung greift nicht"; fehler=$((fehler+1)); }

if [ "$fehler" = 0 ]; then
  echo "PASS Handschlag ueber den Adapter, alle drei Gegenproben greifen"
  echo "ALL PASS"
  exit 0
fi
echo "$fehler FAIL"
exit 1
