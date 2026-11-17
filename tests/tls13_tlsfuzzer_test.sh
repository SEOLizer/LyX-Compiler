#!/usr/bin/env bash
# tests/tls13_tlsfuzzer_test.sh — #2096 Abnahmekriterium 4: die
# tlsfuzzer-Testsuite gegen unsere Server-Rolle.
#
# tlsfuzzer liegt nicht im Repo (es braucht tlslite-ng, python-ecdsa und
# six). Der Test faehrt es, wenn es da ist, und wird sonst uebersprungen:
#
#   git clone --depth 1 https://github.com/tlsfuzzer/tlsfuzzer.git
#   git clone --depth 1 https://github.com/tlsfuzzer/tlslite-ng.git
#   git clone --depth 1 https://github.com/tlsfuzzer/python-ecdsa.git ecdsa
#   curl -O https://raw.githubusercontent.com/benjaminp/six/main/six.py
#   TLSFUZZER=<verzeichnis mit diesen vier> bash tests/tls13_tlsfuzzer_test.sh
#
# Geprueft werden die Skripte, die auf unser Profil PASSEN, mit einer
# Mindestzahl bestandener Gespraeche je Skript. Sinkt sie, ist etwas
# kaputtgegangen.
#
# ── Was tlsfuzzer an dieser Umsetzung gefunden hat (#2096) ──────────────────
# Zwoelf Befunde, alle behoben, jeder mit seiner Regel:
#   - kein Dummy-ChangeCipherSpec (RFC 8446 Anhang D.4)
#   - signature_algorithms des Clients ignoriert (§4.4.2.2): der Server
#     signierte mit ECDSA, obwohl der Client nur RSA-PSS anbot
#   - kein Alert bei fatalen Fehlern (§6.2)
#   - B_HS/B_APP genau 2^14 gross, damit wurden ZULAESSIGE Records
#     maximaler Groesse abgewiesen (§5.2)
#   - Anwendungsdaten vor dem Handschlagende angenommen (§5.1)
#   - ChangeCipherSpec ohne Pruefung von Laenge und Wert verworfen (§5)
#   - kein close_notify als Antwort auf eines (§6.1)
#   - record_overflow statt decode_error bei zu grossen Records (§5.2)
#   - decode_error statt decrypt_error bei falscher Finished-Laenge (§4.4.4)
#   - legacy_version streng geprueft, obwohl §4.2.1 es ignorieren laesst
#   - nulllange Handschlag- und Alertfragmente mit falschem Alert (§5.1)
#   - request_update ausser 0 und 1 mit decode_error statt illegal_parameter
#     (§4.6.3)
#
# ── Was NICHT geprueft wird, und warum ─────────────────────────────────────
# Skripte, die Funktionen voraussetzen, die diese Umsetzung bewusst nicht
# hat, koennen nicht bestehen. Sie stehen hier nicht drin, und zwar mit
# Grund statt mit Schweigen:
#   test-tls13-session-resumption, -psk_ke, -psk_dhe_ke, -0rtt-garbage,
#   -count-tickets          PSK, Tickets und 0-RTT sind Stufe 3 (#2096)
#   test-tls13-version-negotiation  erwartet Fallback auf TLS 1.1/SSL 3.0 und
#                           bietet standardmaessig RSA-CBC an; wir fuehren
#                           nur ECDHE mit AEAD und verlangen Extended Master
#                           Secret
#   test-tls13-ffdhe-*      endliche Koerper (DHE) sind nicht umgesetzt
#   test-tls13-*brainpool*, -obsolete-curves, -mlkem, -mldsa, -eddsa-in-*
#                           diese Kurven und Verfahren fuehrt std.crypto
#                           nicht
# test-tls13-ecdhe-curves laeuft MIT, aber nur mit 21 von 33: die restlichen
# 12 sind secp521r1 (6) und x448 (4) samt ihren sanity-Faellen — Kurven, die
# std.crypto nicht fuehrt. Die 21 sind P-256 und secp384r1; vor der
# P-384-Arbeit waren es 14, und vor dem key_share-Befund 4.
#   test-tls13-certificate-compression  RFC 8879 ist nicht umgesetzt
#   test-tls13-post-handshake-auth      §4.6.2 ist nicht umgesetzt
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"

T="${TLSFUZZER:-}"
if [ -z "$T" ] || [ ! -d "$T/tlsfuzzer/scripts" ]; then
  echo "SKIP tlsfuzzer nicht da (TLSFUZZER=<verzeichnis> setzen, siehe Kopf)"
  exit 0
fi
for m in tlslite-ng ecdsa; do
  [ -d "$T/$m" ] || { echo "SKIP $m fehlt in $T"; exit 0; }
done
command -v ss >/dev/null 2>&1 || { echo "SKIP ss fehlt (Portpruefung)"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"; pkill -x tls_server 2>/dev/null' EXIT
mkdir -p "$TMP/certs"
# RSA-Zertifikat: die meisten tlsfuzzer-Skripte bieten nur RSA-PSS an, und
# ein Server mit EC-Schluessel MUSS dann abbrechen (§4.4.2.2). Mit einem
# EC-Zertifikat waere der Test also kein Test, sondern ein Missverstaendnis.
if ! command -v openssl >/dev/null 2>&1; then
  echo "SKIP openssl fehlt (Zertifikatserzeugung)"; exit 0
fi
openssl req -x509 -newkey rsa:2048 -keyout "$TMP/certs/key.pem" \
  -out "$TMP/certs/cert.pem" -days 3650 -nodes -subj "/CN=nexus.example" \
  -addext "subjectAltName=DNS:nexus.example" > "$TMP/openssl.log" 2>&1
[ -s "$TMP/certs/cert.pem" ] || { echo "SKIP openssl erzeugte kein Zertifikat"; exit 0; }

cd "$ROOT"
if ! timeout 600 "$LYXC" tools/tls_server.lyx --std-path=. -o "$TMP/tls_server" \
     > "$TMP/build.log" 2>&1; then
  echo "FAIL: tools/tls_server.lyx uebersetzt nicht"; tail -20 "$TMP/build.log"; exit 1
fi

export PYTHONPATH="$T:$T/tlslite-ng:$T/ecdsa/src"
PORT="${TLSFUZZER_PORT:-18880}"
PASS=0; FAIL=0

# Skript, Mindestzahl bestandener Gespraeche (Stand #2096, lokal gemessen)
faelle="
test-tls13-conversation 3
test-tls13-finished 42
test-tls13-record-layer-limits 68
test-tls13-lengths 1002
test-tls13-invalid-ciphers 52
test-tls13-zero-length-data 11
test-tls13-empty-alert 10
test-tls13-legacy-version 10
test-tls13-nociphers 3
test-tls13-keyupdate 59
test-tls13-ecdhe-curves 21
"

while read -r skript soll; do
  [ -z "$skript" ] && continue
  pfad="$T/tlsfuzzer/scripts/$skript.py"
  if [ ! -f "$pfad" ]; then
    echo "FAIL $skript: Skript fehlt in $T"; FAIL=$((FAIL+1)); continue
  fi
  pkill -x tls_server 2>/dev/null
  sleep 0.3
  ( ulimit -v 6000000 -c 0; "$TMP/tls_server" "$PORT" "$TMP/certs/cert.pem" \
      "$TMP/certs/key.pem" x N=0 still echo > "$TMP/srv_$skript.log" 2>&1 & )
  bereit=0
  for i in $(seq 1 60); do
    if ss -ltn 2>/dev/null | grep -q ":$PORT "; then bereit=1; break; fi
    sleep 0.1
  done
  if [ "$bereit" != 1 ]; then
    echo "FAIL $skript: Server lauscht nicht auf $PORT"; FAIL=$((FAIL+1)); continue
  fi
  timeout 2400 python3 "$pfad" -h 127.0.0.1 -p "$PORT" > "$TMP/$skript.txt" 2>&1
  ist="$(grep -m1 '^PASS:' "$TMP/$skript.txt" | awk '{print $2}')"
  ist="${ist:-0}"
  gesamt="$(grep -m1 '^TOTAL:' "$TMP/$skript.txt" | awk '{print $2}')"
  if [ "$ist" -ge "$soll" ]; then
    echo "PASS $skript: $ist von $gesamt Gespraechen (mindestens $soll)"
    PASS=$((PASS+1))
  else
    echo "FAIL $skript: nur $ist von $gesamt Gespraechen, erwartet mindestens $soll"
    sed -n '/^FAILED:/,$p' "$TMP/$skript.txt" | sed -n '2,6p' | sed 's/^/    /'
    FAIL=$((FAIL+1))
  fi
done <<< "$faelle"

echo "--- $PASS Skripte bestanden, $FAIL gefallen"
if [ "$FAIL" != 0 ]; then exit 1; fi
echo "ALL PASS"
exit 0
