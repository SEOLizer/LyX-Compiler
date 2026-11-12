#!/usr/bin/env bash
# tests/profile_rekursion_2249_test.sh — --profile misst Rekursion inklusive,
# der Bericht laesst ungerufene Funktionen weg (#2249).
#
# Je Funktion gab es EINEN Startwert. Ein rekursiver Eintritt ueberschrieb den
# des aeusseren Aufrufs, und dessen Austritt rechnete ab dem innersten
# Eintritt: `rek` meldete mehr Takte als `main`, das es vollstaendig enthaelt
# — eine bedeutungslose Zahl. Jetzt misst nur der aeusserste Aufruf
# (Tiefenzaehler), die Zeit ist inklusive und ohne Doppelzaehlung. Dazu
# listete der Bericht jede Funktion samt importierter std mit „0 calls“.
#
# Geprueft wird die ORDNUNG, die eine inklusive Messung erfuellen muss:
# arbeit (von rek gerufen) <= rek <= main — Takte schwanken, die Ordnung
# nicht. Dazu die Aufrufzahlen und: keine Zeile mit 0 Aufrufen.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ulimit -c 0
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

cat > "$TMP/r.lyx" <<'LYX'
import std.io;
fn arbeit(n: int64): int64 { var s: int64 := 0; var i: int64 := 0; while (i < 200000) { s := s + i * n; i := i + 1; if (s < 0) { PrintLn(s); } } return s; }
fn rek(n: int64): int64 {
  var w: int64 := arbeit(n);
  if (n <= 0) { return w & 1; }
  return rek(n - 1) + (w & 1);
}
fn main(): int64 { PrintLn(rek(5)); return 0; }
LYX
if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" --profile "$TMP/r.lyx" -o "$TMP/r" >"$TMP/b.log" 2>&1); then
  no "uebersetzt" "$(grep -m1 -i error "$TMP/b.log")"
else
  AUS=$( cd "$TMP" && timeout 60 "$TMP/r" 2>&1 )
  zahl() { echo "$AUS" | grep "\[PROFILE\] $1:" | sed "s/.*\] [^:]*: \([0-9]*\) calls, \([0-9]*\) cycles total.*/\1 \2/"; }
  read -r ca ta <<<"$(zahl arbeit)"; read -r cr tr <<<"$(zahl rek)"; read -r cm tm <<<"$(zahl main)"
  if [ "$ca" = 6 ] && [ "$cr" = 6 ] && [ "$cm" = 1 ]; then ok "Aufrufe: arbeit 6, rek 6, main 1"
  else no "Aufrufe" "arbeit=$ca rek=$cr main=$cm"; fi
  if [ -n "$tr" ] && [ -n "$tm" ] && [ -n "$ta" ] && [ "$ta" -le "$tr" ] && [ "$tr" -le "$tm" ]; then
    ok "inklusiv geordnet: arbeit $ta <= rek $tr <= main $tm"
  else no "Ordnung" "arbeit=$ta rek=$tr main=$tm (rek muss zwischen arbeit und main liegen)"; fi
  if echo "$AUS" | grep -q " 0 calls"; then no "0-calls" "$(echo "$AUS" | grep -c ' 0 calls') Zeilen mit 0 Aufrufen"
  else ok "keine Zeile mit 0 Aufrufen"; fi
fi

echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
