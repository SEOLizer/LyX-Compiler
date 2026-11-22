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
# ── Stand 2026-11-22, gegen tlsfuzzer-HEAD neu gemessen (#2096 K4) ────────
# Zwei Fehlschlaege, keiner davon ein TLS-Defekt:
#   * test-tls13-zero-length-data lief mit dem Schalter `echo` auf 8 von 11.
#     Ursache war die Betriebsart des TESTSERVERS, nicht der Record-Schicht:
#     leere Anwendungsdaten-Records nimmt sie seit je an (RFC 8446 §5.1
#     "Zero-length fragments of Application Data MAY be sent", §5.4 "may
#     contain a zero-length TLSInnerPlaintext.content"). Ohne `echo` 11 von 11.
#   * test-tls13-legacy-version erwartet seit tlsfuzzer-Fassung 5 einen
#     Abbruch, den RFC 8446 §4.2.1 nicht verlangt. Siehe die Begruendung
#     unten am Ende dieses Tests.
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

# Skript, Mindestzahl bestandener Gespraeche, Serverbetriebsart
# (Stand #2096, lokal gemessen gegen tlsfuzzer-HEAD vom 2026-11-22).
#
# Die dritte Spalte ist neu und noetig: der Serverschalter `echo` schickt
# JEDES empfangene Stueck Anwendungsdaten als eigenen Record zurueck, ohne
# ihn `echo` antwortet er EINMAL mit einer HTTP-Antwort. Beides braucht je ein
# anderes Skript, und mit einer Betriebsart fuer alle fielen zwei durch:
#
#   test-tls13-lengths        braucht echo    (ohne: 2 von 1002 — das Skript
#                             schickt Nutzdaten und erwartet sie zurueck)
#   test-tls13-zero-length-data  braucht KEIN echo (mit: 8 von 11 — das Skript
#                             erwartet EINE Antwort, echo schickt je Fragment
#                             eine; der Fehlschlag war `Unexpected message
#                             from peer: ApplicationData(len=7)` an der
#                             Stelle, an der es den Alert erwartet)
#
# Beide Zahlen sind gemessen, in beiden Betriebsarten, nicht geschaetzt.
faelle="
test-tls13-conversation 3 echo
test-tls13-finished 42 echo
test-tls13-record-layer-limits 68 echo
test-tls13-lengths 1002 echo
test-tls13-invalid-ciphers 52 echo
test-tls13-zero-length-data 11 kein_echo
test-tls13-empty-alert 10 echo
test-tls13-legacy-version 2 echo
test-tls13-nociphers 3 echo
test-tls13-keyupdate 59 echo
test-tls13-ecdhe-curves 21 echo
"

while read -r skript soll art; do
  [ -z "$skript" ] && continue
  pfad="$T/tlsfuzzer/scripts/$skript.py"
  if [ ! -f "$pfad" ]; then
    echo "FAIL $skript: Skript fehlt in $T"; FAIL=$((FAIL+1)); continue
  fi
  pkill -x tls_server 2>/dev/null
  sleep 0.3
  if [ "${art:-echo}" = echo ]; then
    ( ulimit -v 6000000 -c 0; "$TMP/tls_server" "$PORT" "$TMP/certs/cert.pem" \
        "$TMP/certs/key.pem" x N=0 still echo > "$TMP/srv_$skript.log" 2>&1 & )
  else
    ( ulimit -v 6000000 -c 0; "$TMP/tls_server" "$PORT" "$TMP/certs/cert.pem" \
        "$TMP/certs/key.pem" x N=0 still > "$TMP/srv_$skript.log" 2>&1 & )
  fi
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

# #2096 K4, zweiseitig fuer test-tls13-legacy-version: die Zahl 2 oben ist
# eine ENTSCHEIDUNG und kein Nachgeben. tlsfuzzer-HEAD erwartet dort seit
# seiner Fassung 5, dass der Server jede `legacy_version` ausser 0x0303 mit
# `protocol_version` abweist ("Check that invalid legacy versions are rejected
# with protocol version alert by the TLS 1.3 server"). RFC 8446 verlangt das
# NICHT, sobald supported_versions dabei ist:
#
#   §4.2.1: "If this extension is present in the ClientHello, servers MUST NOT
#            use the ClientHello.legacy_version value for version negotiation"
#   §4.2.1: das Abbruchrecht gilt ausdruecklich fuer den Fall OHNE Erweiterung
#            ("If this extension is not present, ... Servers MAY abort ...")
#
# Ein Abbruch waere also eine Verwendung von legacy_version zur Verhandlung.
# Diese Umsetzung ignoriert das Feld bewusst (der Weg dorthin steht oben in
# der Befundliste). Darum steht hier 2 (die sanity-Faelle) und nicht 10.
#
# Die Gegenrichtung muss aber auch festgenagelt sein: WUERDEN plotzlich mehr
# als 2 Gespraeche bestehen, haette jemand das Ignorieren abgeschafft. Dann
# ist nicht der Test nachzuziehen, sondern die Aenderung zu begruenden.
LV="$TMP/test-tls13-legacy-version.txt"
if [ -f "$LV" ]; then
  lv_ist="$(grep -m1 '^PASS:' "$LV" | awk '{print $2}')"
  if [ "${lv_ist:-0}" -gt 3 ]; then
    echo "FAIL test-tls13-legacy-version: $lv_ist Gespraeche bestanden (erwartet 2)."
    echo "  Das heisst: der Server weist legacy_version != 0x0303 jetzt ab."
    echo "  RFC 8446 §4.2.1 verlangt das nicht, sobald supported_versions dabei"
    echo "  ist -- siehe Kommentar oben. Begruenden, nicht die Zahl nachziehen."
    FAIL=$((FAIL+1))
  else
    echo "PASS test-tls13-legacy-version ignoriert legacy_version weiter (RFC 8446 §4.2.1)"
    PASS=$((PASS+1))
  fi
fi

echo "--- $PASS Skripte bestanden, $FAIL gefallen"
if [ "$FAIL" != 0 ]; then exit 1; fi
echo "ALL PASS"
exit 0
