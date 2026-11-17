#!/usr/bin/env bash
# tests/tls_fuzz_test.sh — #2096 Abnahmekriterium 6: Fuzzing von
# Record-Schicht, Handschlagleser und X.509-Leser.
#
# Geprueft wird eine EIGENSCHAFT, nicht ein Ergebnis: egal was hereinkommt,
# die Leser muessen urteilen und dabei am Leben bleiben, und keine Verbindung
# darf FERTIG melden, ohne dass ein echter Handschlag gelaufen ist. Ein
# Absturz beendet den Prozess — daran faellt er auf (rc >= 128).
#
# Hier laufen bewusst nur wenige Tausend Faelle: der Test gehoert ins
# `test`-Ziel und darf es nicht aufhalten. Der lange Lauf ist abgekoppelt
# gedacht, mit demselben Werkzeug:
#
#   ./lyxc tools/fuzz_tls.lyx --std-path=. -o /tmp/fuzz_tls
#   setsid nohup bash -c 'ulimit -v 4000000 -c 0;
#     for s in 1 2 3 4 5 6; do /tmp/fuzz_tls alle 200000 $s zert.pem; done' \
#     > fuzz.log 2>&1 &
#
# Die Saat steht in der Ausgabe; ein Fund laesst sich damit genau
# nachstellen. Stand #2096: 3,6 Mio Faelle in sechs Laeufen ohne Absturz und
# ohne falsches FERTIG.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/certs"
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

cd "$ROOT"
if ! timeout 600 "$LYXC" tools/fuzz_tls.lyx --std-path=. -o "$TMP/fuzz" > "$TMP/build.log" 2>&1; then
  echo "FAIL: tools/fuzz_tls.lyx uebersetzt nicht"; tail -20 "$TMP/build.log"; exit 1
fi
[ -x "$TMP/fuzz" ] || { echo "FAIL: kein Erzeugnis"; exit 1; }

fails=0
# Vier Saaten, je 1500 Runden ueber alle drei Ziele = 18 000 Faelle.
for saat in 1 7 1337 20260; do
  ( ulimit -v 4000000 -c 0; timeout 900 "$TMP/fuzz" alle 1500 "$saat" \
      "$TMP/certs/tlssrv.pem" > "$TMP/out_$saat.txt" 2>&1 )
  rc=$?
  if [ "$rc" -ge 128 ]; then
    echo "FAIL: Saat $saat hat den Fuzzer umgebracht (rc=$rc)"
    tail -5 "$TMP/out_$saat.txt"
    fails=$((fails + 1))
    continue
  fi
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: Saat $saat endete mit rc=$rc"; tail -5 "$TMP/out_$saat.txt"
    fails=$((fails + 1)); continue
  fi
  if ! grep -q '^ueberlebt$' "$TMP/out_$saat.txt"; then
    echo "FAIL: Saat $saat ohne Abschlussmeldung"; fails=$((fails + 1)); continue
  fi
  f="$(grep -m1 '^faelle ' "$TMP/out_$saat.txt" | awk '{print $2}')"
  u="$(grep -m1 '^urteile ' "$TMP/out_$saat.txt" | awk '{print $2}')"
  o="$(grep -m1 '^fertig-ohne-handschlag ' "$TMP/out_$saat.txt" | awk '{print $2}')"
  if [ "$f" != 4500 ]; then
    echo "FAIL: Saat $saat nur $f Faelle, erwartet 4500"; fails=$((fails + 1)); continue
  fi
  if [ "$u" != "$f" ]; then
    echo "FAIL: Saat $saat $u Urteile bei $f Faellen — einer blieb stumm"
    fails=$((fails + 1)); continue
  fi
  if [ "$o" != 0 ]; then
    echo "FAIL: Saat $saat meldete $o mal FERTIG ohne Handschlag"
    fails=$((fails + 1)); continue
  fi
  echo "PASS Saat $saat: $f Faelle, $u Urteile, kein falsches FERTIG"
done

# Gegenprobe: der Fuzzer muss ueberhaupt etwas tun. Ein Lauf mit 0 Runden
# darf keine Faelle melden — sonst zaehlt der Test etwas, das nicht passiert.
( ulimit -v 4000000 -c 0; timeout 60 "$TMP/fuzz" alle 0 1 "$TMP/certs/tlssrv.pem" \
    > "$TMP/out_null.txt" 2>&1 )
if [ "$(grep -m1 '^faelle ' "$TMP/out_null.txt" | awk '{print $2}')" != 0 ]; then
  echo "FAIL: 0 Runden ergaben Faelle — der Zaehler stimmt nicht"
  fails=$((fails + 1))
fi

if [ "$fails" -eq 0 ]; then echo "ALL PASS (18 000 Faelle)"; exit 0; fi
echo "$fails FAIL"
exit 1
