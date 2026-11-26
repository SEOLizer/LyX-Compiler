#!/usr/bin/env bash
# tests/tls_hosts_probe_2613_test.sh — haelt tools/tls_hosts_probe.lyx lauffaehig,
# OHNE das Netz ins test-Ziel zu holen (#2613 Punkt 3).
#
# WARUM SO. Der Befund gegen oeffentliche Hosts gehoert nicht in das
# `test`-Ziel: ein Test an einem fremden Dienst wird rot, wenn dort jemand ein
# Zertifikat tauscht, und misst dann nichts ueber uns (so steht es in #2613,
# und so ist es entschieden). Ein Werkzeug, das nirgends gebaut wird, verrottet
# aber -- dasselbe Muster wie tests/tls_fuzz_test.sh fuer tools/fuzz_tls.lyx.
#
# Geprueft wird deshalb zweierlei, beides netzfrei:
#   1. das Werkzeug UEBERSETZT,
#   2. es LAEUFT und meldet einen unaufloesbaren Namen als BEFUND
#      ("DNS-FEHLER") statt abzustuerzen oder still 0 zu liefern.
#
# Punkt 2 ist der wichtigere: ein Werkzeug, das bei jedem Fehler schweigt,
# erzeugt einen Standvermerk, der nach Erfolg aussieht. Die Gegenrichtung
# (ein Host, der traegt) steht im Standvermerk unter work/, nicht hier.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$ROOT/tests/lib/lyxc_guard.sh"; [ -f "$_g" ] && . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ulimit -c 0 2>/dev/null
ok() { PASS=$((PASS+1)); echo "PASS $1"; }
no() { FAIL=$((FAIL+1)); echo "FAIL $1: $2"; }

if ( cd "$ROOT" && timeout 600 "$LYXC" --std-path="$ROOT" tools/tls_hosts_probe.lyx -o "$TMP/probe" ) >"$TMP/build.log" 2>&1 \
   && [ -x "$TMP/probe" ]; then
  ok "tools/tls_hosts_probe.lyx uebersetzt"
else
  no "tools/tls_hosts_probe.lyx uebersetzt nicht" "$(grep -m1 -i error "$TMP/build.log")"
  echo ""; echo "Ergebnis: $PASS PASS, $FAIL FAIL"; exit 1
fi

# `.invalid` ist nach RFC 2606 fuer genau das reserviert und wird nie
# aufgeloest -- kein fremder Dienst wird dabei angefasst.
if ( ulimit -v 4000000; timeout 120 "$TMP/probe" nicht-aufloesbar.invalid ) >"$TMP/lauf.log" 2>&1; then
  if grep -q 'DNS-FEHLER' "$TMP/lauf.log"; then
    ok "unaufloesbarer Name wird als Befund gemeldet"
  else
    no "unaufloesbarer Name wird gemeldet" "$(tail -2 "$TMP/lauf.log" | tr '\n' ' ')"
  fi
  # Die Zusammenfassung muss 0 von 1 nennen -- ein Werkzeug, das den
  # Fehlschlag mitzaehlt, erzeugt einen falschen Standvermerk.
  if grep -qE '^# 0 von 1 ' "$TMP/lauf.log"; then
    ok "Zusammenfassung zaehlt den Fehlschlag NICHT als Erfolg"
  else
    no "Zusammenfassung" "$(grep -m1 '^# ' "$TMP/lauf.log" | tail -1)"
  fi
else
  no "Werkzeug laeuft nicht" "rc != 0 -- $(tail -2 "$TMP/lauf.log" | tr '\n' ' ')"
fi

echo ""
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
