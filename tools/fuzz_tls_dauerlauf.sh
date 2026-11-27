#!/usr/bin/env bash
# tools/fuzz_tls_dauerlauf.sh — #2614, Rest aus #2096 Abnahmekriterium 6:
# „Fuzzing von Record-Layer, Handshake-Parser und X.509-Parser (mind. 24 h
# ohne Absturz)".
#
# WARUM EIN SKRIPT UND KEIN `bash -c`, und das ist eine getretene Falle und
# keine Vorliebe: `setsid nohup bash -c '<mehrzeiliger Text>'` bekam die
# Zeilenumbrueche nicht durch. `ende` wurde damit nie gesetzt, die Schleife
# lief ohne Zeitlimit weiter, und der Lauf musste von Hand abgebrochen
# werden. Ein Dauerlauf gehoert in eine DATEI und wird von dort gestartet.
#
# WARUM ABGEKOPPELT: der Lauf haelt die Maschine 24 h unter Last. Waehrend
# dessen ist sie nicht ruhig — `tests/tls13_tlsfuzzer_test.sh` fiel dabei auf
# 41 von 42 Gespraechen, und die Konstantzeitmessung aus #2096 K7 muss ihr
# Messfenster nachziehen. Der Dauerlauf gehoert deshalb NICHT neben einen
# Nachweislauf, und er haengt an keinem `make`-Ziel.
#
# Aufruf (aus dem Repo-Wurzelverzeichnis):
#   tools/fuzz_tls_dauerlauf.sh [stunden] [protokoll]
# Vorgabe: 24 Stunden, Protokoll work/tls/fuzz-dauerlauf.log
#
# Richtig gestartet wird er abgekoppelt:
#   setsid nohup tools/fuzz_tls_dauerlauf.sh 24 > /dev/null 2>&1 &
#
# Das Protokoll traegt Start- und Endzeit, jede Saat, die Zahl der Faelle,
# `rc=` je Lauf und `fertig-ohne-handschlag`. Die Saat steht in der Ausgabe;
# ein Fund laesst sich damit genau nachstellen.
set -uo pipefail

STUNDEN="${1:-24}"
# DAUER_SEKUNDEN gibt es fuer die Probefahrt: ein Dauerlaufwerkzeug, das man
# nicht in zwei Minuten einmal ganz durchlaufen lassen kann, prueft niemand
# nach, und dann faellt erst nach 24 h auf, dass das Protokoll leer bleibt.
DAUER_SEKUNDEN="${DAUER_SEKUNDEN:-$(( STUNDEN * 3600 ))}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROT="${2:-$ROOT/work/tls/fuzz-dauerlauf.log}"
LYXC="${LYXC:-$ROOT/lyxc}"
FAELLE_JE_LAUF="${FAELLE_JE_LAUF:-500000}"

mkdir -p "$(dirname "$PROT")"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Das Zertifikat, das tools/fuzz_tls.lyx als Ausgangspunkt fuer den
# X.509-Teil braucht. Dasselbe wie in tests/tls_fuzz_test.sh.
cat > "$TMP/zert.pem" <<'PEMEOF'
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

if [ -z "${FUZZ_BIN:-}" ] && [ ! -x "$LYXC" ]; then
  echo "kein Compiler unter $LYXC — make bootstrap" >&2
  exit 1
fi
# FUZZ_BIN gibt es, damit die beiden ABBRUCHZWEIGE unten pruefbar sind. Ein
# Abbruchpfad, der nie gelaufen ist, ist ein stiller Default: er sieht im
# Quelltext richtig aus und faellt erst auf, wenn man ihn braucht — also nach
# 24 h, am Fund.
if [ -n "${FUZZ_BIN:-}" ]; then
  cp "$FUZZ_BIN" "$TMP/fuzz_tls" || exit 1
elif ! "$LYXC" --std-path="$ROOT" "$ROOT/tools/fuzz_tls.lyx" -o "$TMP/fuzz_tls" \
     > "$TMP/build.log" 2>&1; then
  echo "tools/fuzz_tls.lyx uebersetzt nicht:" >&2
  tail -5 "$TMP/build.log" >&2
  exit 1
fi

# Die Grenze ist Pflicht und nicht Kosmetik: ein Fuzzer, der wegen eines
# Fehlers unbegrenzt alloziert, laeuft 24 h lang unbeaufsichtigt. Ohne Deckel
# sucht sich der OOM-Killer den groessten Verbraucher im System, und das muss
# nicht dieser Prozess sein (#1294).
ulimit -v 4000000
ulimit -c 0

START="$(date -Is)"
ENDE=$(( $(date +%s) + DAUER_SEKUNDEN ))
{
  echo "=== #2614 Dauerlauf fuzz_tls"
  echo "Start:     $START"
  echo "Dauer:     $DAUER_SEKUNDEN s (Ende geplant $(date -Is -d "@$ENDE"))"
  echo "Compiler:  $("$LYXC" --version 2>&1 | head -1)"
  echo "Faelle je Lauf: $FAELLE_JE_LAUF"
  echo "Maschine:  $(uname -srm), $(nproc) Kerne"
  echo
} >> "$PROT"

saat=0
summe=0
abbruch=0
while [ "$(date +%s)" -lt "$ENDE" ]; do
  saat=$((saat + 1))
  "$TMP/fuzz_tls" alle "$FAELLE_JE_LAUF" "$saat" "$TMP/zert.pem" > "$TMP/f.txt" 2>&1
  rc=$?
  faelle="$(grep -m1 '^faelle ' "$TMP/f.txt" | awk '{print $2}')"
  ohne="$(grep -m1 '^fertig-ohne-handschlag ' "$TMP/f.txt" | awk '{print $2}')"
  lebt="$(grep -c '^ueberlebt$' "$TMP/f.txt")"
  [ -n "${faelle:-}" ] && summe=$((summe + faelle))
  echo "$(date -Is) saat $saat rc=$rc faelle=${faelle:-?} fertig-ohne-handschlag=${ohne:-?} ueberlebt=$lebt summe=$summe" >> "$PROT"
  # Zwei Abbruchgruende, und der zweite ist der stillere: ein Lauf, der
  # zurueckkehrt, aber eine Verbindung FERTIG gemeldet hat, ohne dass ein
  # Handschlag lief. rc allein wuerde das uebersehen.
  if [ "$rc" -eq 0 ] && [ "${ohne:-0}" != "0" ]; then
    {
      echo "ABBRUCH: saat $saat meldete fertig-ohne-handschlag=$ohne bei rc=0 —"
      echo "eine Verbindung galt als fertig, ohne dass ein Handschlag lief."
      tail -20 "$TMP/f.txt" | sed 's/^/    /'
    } >> "$PROT"
    abbruch=1
    break
  fi
  if [ "$rc" -ne 0 ]; then
    {
      echo "ABBRUCH: saat $saat endete mit rc=$rc — der Fall ist mit dieser"
      echo "Saat genau nachstellbar:"
      echo "  $LYXC --std-path=$ROOT tools/fuzz_tls.lyx -o /tmp/fuzz_tls"
      echo "  /tmp/fuzz_tls alle $FAELLE_JE_LAUF $saat <zert.pem>"
      echo "letzte Ausgabe:"
      tail -20 "$TMP/f.txt" | sed 's/^/    /'
    } >> "$PROT"
    abbruch=1
    break
  fi
done

{
  echo
  echo "Ende:      $(date -Is)"
  echo "Saaten:    $saat"
  echo "Faelle:    $summe"
  if [ "$abbruch" -eq 0 ]; then
    echo "Ergebnis:  rc=0 in jedem Lauf, kein fertig-ohne-handschlag"
  else
    echo "Ergebnis:  ABGEBROCHEN bei saat $saat — siehe oben"
  fi
} >> "$PROT"

exit "$abbruch"
