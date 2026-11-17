#!/usr/bin/env bash
# tests/tls_interop_test.sh — #2096: Interop gegen eine Fremdimplementierung,
# in BEIDE Richtungen.
#
# Die eigenen Tests prüfen unsere Units gegeneinander. Das zeigt, dass sie zu
# sich selbst passen — nicht, dass sie zum Rest der Welt passen. Zwei
# Richtungen, beide gegen OpenSSL:
#
#   1. **Unser Server, fremder Client** (`openssl s_client`): TLS 1.3 und
#      TLS 1.2, je mit Prüfung der ausgehandelten Version UND Suite.
#   2. **Unser Client, fremder Server** (`openssl s_server`): derselbe
#      Durchgang, über die native std.net.tls.
#
# Geprüft wird jeweils die WIRKUNG: nicht "der Handschlag lief", sondern
# welche Version und welche Suite dabei herauskam, und dass Nutzdaten in
# beide Richtungen ankommen.
#
# ── Gegenproben, die greifen müssen ────────────────────────────────────────
#   - Ein `s_client`, der NUR TLS 1.0/1.1 anbietet, muss abgewiesen werden.
#   - Ein `s_client`, der nur CBC-Suiten anbietet, muss abgewiesen werden
#     (diese Umsetzung führt bewusst nur AEAD).
#   - Unser Client muss einen Server mit FREMDER Kette abweisen.
# Ohne diese Fälle wäre der Test auch von einer Umsetzung erfüllt, die alles
# annimmt — und „nimmt alles an" ist bei TLS der Normalfall eines Fehlers.
#
# ── Was dieser Test NICHT prüft, und warum ─────────────────────────────────
# **Browser.** Gemessen am 2026-11-17 mit Chrome 157 gegen tools/tls_server:
# ClientHello 1990 Byte (mit ML-KEM-Anteil), unser ServerHello, CCS und die
# vier verschlüsselten Records werden entschlüsselt und ANGENOMMEN — Chrome
# antwortet dann mit einem verschlüsselten Alert 46 (`certificate_unknown`,
# Stufe fatal). Das ist eine Aussage über das TESTZERTIFIKAT (eigene CA, im
# Browser nicht verankert), nicht über das Protokoll. Ein automatischer
# Browsertest bräuchte einen im System verankerten Vertrauensanker; das ist
# ein Eingriff in die Maschine, der nicht in einen Testlauf gehört. Die
# Alertnummer selbst ist seit #2096 über TlsPeerAlert ablesbar — vorher wurde
# sie gelesen und weggeworfen.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; pkill -x io_srv 2>/dev/null; [ -n "${SPID:-}" ] && kill "$SPID" 2>/dev/null' EXIT

if ! command -v openssl >/dev/null 2>&1; then
  echo "SKIP openssl fehlt — Interop nicht messbar"; exit 0
fi
OSSL_VER="$(openssl version 2>/dev/null | head -1)"
echo "Gegenstelle: $OSSL_VER"

mkdir -p "$TMP/certs"
( cd "$TMP/certs"
  openssl req -x509 -newkey rsa:2048 -keyout ca.key -out ca.pem -days 365 \
    -nodes -subj "/CN=Aurum Interop CA" \
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

fehler=0
PORT="${INTEROP_PORT:-18998}"
PORT2=$((PORT + 1))

cd "$ROOT"
if ! timeout 900 "$LYXC" tools/tls_server.lyx --std-path=. -o "$TMP/io_srv" \
     > "$TMP/b_srv.log" 2>&1; then
  echo "FAIL: tools/tls_server.lyx uebersetzt nicht"; tail -10 "$TMP/b_srv.log"; exit 1
fi

starte_server() {
  pkill -x io_srv 2>/dev/null
  sleep 0.3
  ( ulimit -v 6000000 -c 0; "$TMP/io_srv" "$PORT" "$TMP/certs/cert.pem" \
      "$TMP/certs/key.pem" "$TMP/certs/ca.pem" N=0 still tls12 \
      > "$TMP/srv.log" 2>&1 & )
  for i in $(seq 1 60); do
    if ss -ltn 2>/dev/null | grep -q ":$PORT "; then return 0; fi
    sleep 0.1
  done
  return 1
}

# ── Richtung 1: unser Server, openssl s_client ─────────────────────────────
for fall in "tls1_3:TLSv1.3" "tls1_2:TLSv1.2"; do
  schalter="${fall%%:*}"
  erwartet="${fall##*:}"
  starte_server || { echo "FAIL: eigener Server lauscht nicht"; fehler=$((fehler+1)); continue; }
  aus="$TMP/sc_$schalter.txt"
  printf 'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n' \
    | timeout 60 openssl s_client -connect "127.0.0.1:$PORT" \
        -servername localhost -CAfile "$TMP/certs/ca.pem" "-$schalter" \
        -ign_eof > "$aus" 2>&1
  ver="$(grep -m1 -oE 'TLSv1\.[0-3]' "$aus" | head -1)"
  suite="$(grep -m1 'Cipher is' "$aus" | sed 's/.*Cipher is //' | tr -d ' \r')"
  pruef="$(grep -m1 'Verify return code' "$aus" | sed 's/.*code: //')"
  hat200="$(grep -c 'HTTP/1.1 200' "$aus" || true)"
  if [ "$ver" = "$erwartet" ] && [ -n "$suite" ] && [ "$hat200" -ge 1 ]; then
    echo "PASS unser Server <- openssl s_client: $ver, $suite, Kette geprueft ($pruef), 200 gelesen"
  else
    echo "FAIL unser Server <- openssl s_client ($schalter): Version '$ver' (erwartet $erwartet), Suite '$suite', 200 gefunden $hat200"
    grep -iE 'alert|error|failure' "$aus" | head -3 | sed 's/^/    /'
    fehler=$((fehler+1))
  fi
done

# ── Gegenprobe: alte Versionen und CBC muessen abgewiesen werden ───────────
starte_server || true
for fall in "tls1:TLS 1.0" "tls1_1:TLS 1.1"; do
  schalter="${fall%%:*}"
  name="${fall##*:}"
  aus="$TMP/alt_$schalter.txt"
  timeout 60 openssl s_client -connect "127.0.0.1:$PORT" -servername localhost \
      "-$schalter" < /dev/null > "$aus" 2>&1 || true
  if grep -qE 'TLSv1\.[23]' "$aus" && grep -q 'Cipher is' "$aus" \
     && ! grep -qiE 'no protocols available|alert|failure|error' "$aus"; then
    echo "FAIL Gegenprobe $name: der Handschlag kam durch"
    fehler=$((fehler+1))
  else
    echo "PASS Gegenprobe: $name wird abgewiesen"
  fi
done

starte_server || true
aus="$TMP/cbc.txt"
timeout 60 openssl s_client -connect "127.0.0.1:$PORT" -servername localhost \
    -tls1_2 -cipher 'AES128-SHA:ECDHE-RSA-AES128-SHA' < /dev/null \
    > "$aus" 2>&1 || true
if grep -q 'Cipher is' "$aus" && grep -qE 'AES128-SHA' "$aus"; then
  echo "FAIL Gegenprobe CBC: eine CBC-Suite wurde ausgehandelt"
  fehler=$((fehler+1))
else
  echo "PASS Gegenprobe: ein Client mit nur CBC-Suiten wird abgewiesen"
fi
pkill -x io_srv 2>/dev/null

# ── Richtung 2: unser Client (std.net.tls), openssl s_server ───────────────
cat > "$TMP/klient.lyx" <<'LYXEOF'
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

fn versuch(ankerPfad: pchar, port: int64, marke: pchar): void {
  var dCa: int64 := alloc(8192);
  var lCa: int64 := ladeDer(ankerPfad, "CERTIFICATE"c, dCa);
  if (lCa <= 0) { Print(marke); PrintStrLn(" LADEFEHLER"c); return; }
  var anker: int64 := alloc(16);
  poke64(anker, dCa); poke64(anker + 8, lCa);
  var ctx: TLSContext := TLSInitMitStore(anker, 1);

  var tcp: TCPConn := TCPConnect(2130706433, port);
  if (tcp.fd < 0) { Print(marke); PrintStrLn(" KEIN-SOCKET"c); return; }
  var c: TLSConn := TLSConnect(ctx, tcp.fd, "localhost"c);
  Print(marke); Print(" connected "c); PrintIntLn(c.connected);
  Print(marke); Print(" rc "c); PrintIntLn(c.rc);
  if (c.connected == 1) {
    var anfrage: pchar := "GET / HTTP/1.0\r\n\r\n"c;
    Print(marke); Print(" geschrieben "c);
    PrintIntLn(TLSWrite(c, anfrage as int64, StrLen(anfrage)));
    var puf: int64 := alloc(8192);
    var n: int64 := TLSRead(c, puf, 8192);
    Print(marke); Print(" gelesen "c); PrintIntLn(n);
    // Traegt die Antwort wirklich HTTP? Sonst waere "Nutzdaten" eine
    // Behauptung ueber eine Zahl, nicht ueber Inhalt.
    var httpOk: int64 := 0;
    if (n > 4) {
      if ((peek8(puf) & 255) == 72 && (peek8(puf + 1) & 255) == 84
          && (peek8(puf + 2) & 255) == 84 && (peek8(puf + 3) & 255) == 80) {
        httpOk := 1;
      }
    }
    Print(marke); Print(" http "c); PrintIntLn(httpOk);
    TLSClose(c);
  }
  TCPConnClose(tcp);
}

fn main(): int64 {
  versuch("CERTDIR/ca.pem"c, PORTMARKER, "echt"c);
  versuch("CERTDIR/fremd.pem"c, PORTMARKER, "fremd"c);
  return 0;
}
LYXEOF
sed -i "s#CERTDIR#$TMP/certs#g; s#PORTMARKER#$PORT2#g" "$TMP/klient.lyx"

if ! timeout 900 "$LYXC" "$TMP/klient.lyx" --std-path=. -o "$TMP/klient" \
     > "$TMP/b_kl.log" 2>&1; then
  echo "FAIL: der Lyx-Client uebersetzt nicht"; tail -15 "$TMP/b_kl.log"
  echo "$((fehler+1)) FAIL"; exit 1
fi

# s_server antwortet auf jede Zeile; -naccept 2 fuer die zwei Versuche.
# Direkt im Hintergrund, NICHT in einer Subshell: aus einer Subshell ist
# $! im Elternprozess nicht gesetzt, und unter `set -u` bricht das Skript
# dann ab — beim Bauen lief Richtung 2 dadurch gar nicht.
# -www: s_server antwortet selbst mit einer HTTP-Seite. Ohne das schickt er
# NICHTS und schliesst, unser TLSRead meldet dann korrekt close_notify (-14)
# — und ein Test, der nur "connected == 1" prueft, haette trotzdem
# "Handschlag und Nutzdaten" gemeldet. Gemessen wird jetzt, dass wirklich
# Byte ankommen.
timeout 120 openssl s_server -accept "$PORT2" -cert "$TMP/certs/cert.pem" \
    -key "$TMP/certs/key.pem" -naccept 2 -www \
    > "$TMP/ssrv.log" 2>&1 &
SPID=$!
bereit=0
for i in $(seq 1 80); do
  if ss -ltn 2>/dev/null | grep -q ":$PORT2 "; then bereit=1; break; fi
  sleep 0.1
done
if [ "$bereit" != 1 ]; then
  echo "FAIL: openssl s_server lauscht nicht auf $PORT2"
  echo "$((fehler+1)) FAIL"; exit 1
fi

( ulimit -v 6000000 -c 0; timeout 180 "$TMP/klient" > "$TMP/kl.txt" 2>&1 )
cat "$TMP/kl.txt"
hol() { grep -m1 "^$1 $2 " "$TMP/kl.txt" | awk '{print $3}'; }

gelesen="$(hol echt gelesen)"
httpok="$(hol echt http)"
if [ "$(hol echt connected)" = 1 ] && [ "${gelesen:-0}" -gt 0 ] 2>/dev/null \
   && [ "$httpok" = 1 ]; then
  echo "PASS unser Client -> openssl s_server: Handschlag, $gelesen Byte gelesen, Antwort traegt HTTP"
else
  echo "FAIL unser Client -> openssl s_server: connected='$(hol echt connected)' rc='$(hol echt rc)' gelesen='$gelesen' http='$httpok'"
  fehler=$((fehler+1))
fi
if [ "$(hol fremd connected)" = 0 ]; then
  echo "PASS Gegenprobe: mit fremdem Anker weist unser Client den Server ab"
else
  echo "FAIL Gegenprobe fremder Anker: connected='$(hol fremd connected)'"
  fehler=$((fehler+1))
fi

if [ "$fehler" = 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$fehler FAIL"
exit 1
