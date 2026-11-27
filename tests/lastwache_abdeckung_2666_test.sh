#!/usr/bin/env bash
# tests/lastwache_abdeckung_2666_test.sh — #2666: die Lastwache und ihre Liste
# bleiben deckungsgleich, und sie TUT etwas.
#
# Warum ein Waechter: die Wache laesst einen Test aus, wenn die Maschine nicht
# ruhig ist. Genau deshalb kann sie unbemerkt verrotten — ein Test, der immer
# auslaesst, sieht im Protokoll aus wie einer, der nichts zu meckern hat. Und
# eine Liste, die neben den Tests gepflegt wird, geht beim naechsten neuen
# Zeitmesstest auseinander (#1112 in anderer Gestalt).
#
# Geprueft wird deshalb der WEG, nicht nur das Vorhandensein:
#   1/2  Liste und eingebundene Wache stimmen in BEIDE Richtungen.
#   3    die Liste haengt an einem Makefile-Ziel (sonst faehrt sie niemand).
#   4    unter Last laesst ein echter Test wirklich aus — und sagt den Grund.
#   5    mit LASTWACHE_AUS=1 urteilt derselbe Test trotzdem.
# 4 und 5 zusammen: eine Wache, die immer auslaesst, bestuende 4 und fiele
# durch 5; eine, die nichts tut, umgekehrt.
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1${2:+ -- $2}"; FAIL=$((FAIL+1)); }

LISTE="tests/messung-tests.txt"
WACHE="tests/lib/lastwache.sh"

if [ -f "$WACHE" ]; then ok "$WACHE vorhanden"; else bad "$WACHE" "fehlt"; fi

eingetragen=$(sed 's/#.*//' "$LISTE" | tr -d ' \t' | grep -v '^$' | sort)
# Gesucht wird die BENUTZUNG (`lastwache_ruhig`), nicht die Erwaehnung des
# Dateinamens: test_coverage_test.sh nennt die Bibliothek in seiner
# Ausnahmeliste und ist deshalb beim Einbinde-Muster mitgezaehlt worden.
bindend=$(grep -rl 'lastwache_ruhig' tests --include='*_test.sh' \
          | sed 's|^tests/||' | grep -v '^lastwache_abdeckung_2666_test.sh$' | sort)

fehlt_in_liste=$(comm -13 <(printf '%s\n' "$eingetragen") <(printf '%s\n' "$bindend"))
fehlt_wache=$(comm -23 <(printf '%s\n' "$eingetragen") <(printf '%s\n' "$bindend"))

if [ -z "$fehlt_in_liste" ]; then
  ok "jeder Test mit Lastwache steht in $LISTE ($(printf '%s\n' "$bindend" | grep -c . ) Tests)"
else
  bad "nicht in $LISTE" "$(printf '%s' "$fehlt_in_liste" | tr '\n' ' ')"
fi

if [ -z "$fehlt_wache" ]; then
  ok "jeder Eintrag in $LISTE bindet die Lastwache ein"
else
  bad "Eintrag ohne Lastwache" "$(printf '%s' "$fehlt_wache" | tr '\n' ' ')"
fi

if grep -q 'messung-tests\.txt' Makefile; then
  ok "$LISTE haengt an einem Makefile-Ziel"
else
  bad "$LISTE" "kein Makefile-Ziel liest sie — die Liste faehrt niemand (#1112)"
fi

# 4/5: am Verhalten, nicht am Quelltext. Genommen wird der schnellste Eintrag
# der Liste; LASTWACHE_MAX_LAUFBEREIT=0 stellt den Lastfall HER, statt auf ihn
# zu warten (eine Schranke von 0 ist von keiner Maschine zu erfuellen, die
# diesen Test gerade ausfuehrt).
PROBE="tests/rumpfausrichtung_2339_test.sh"
if [ -f "$PROBE" ]; then
  aus=$(LASTWACHE_MAX_LAUFBEREIT=0 timeout 300 bash "$PROBE" 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$aus" | grep -q '^SKIP: '; then
    ok "unter Last laesst $(basename "$PROBE") mit Grund aus (rc=0)"
  else
    bad "Auslassung unter Last" "rc=$rc, Ausgabe: $(printf '%s' "$aus" | tail -2 | tr '\n' ' ')"
  fi
else
  bad "$PROBE" "fehlt — die Probe 4/5 misst nichts"
fi

# 5: LASTWACHE_AUS=1 schlaegt die Schranke. Geprueft an der Wache selbst und
# nicht am Messtest, damit die Probe nicht die Messung bezahlt: beides
# zusammen mit 4 schliesst die zwei Entartungen aus (immer auslassen, nie
# auslassen).
erzwungen=$(LASTWACHE_AUS=1 LASTWACHE_MAX_LAUFBEREIT=0 bash -c '
  . "'"$ROOT"'/tests/lib/lastwache.sh"
  if lastwache_ruhig; then echo URTEILT; else echo AUSGELASSEN; fi
  lastwache_bericht' 2>/dev/null | head -1)
if [ "$erzwungen" = "URTEILT" ]; then
  ok "LASTWACHE_AUS=1 erzwingt das Urteil trotz unerfuellbarer Schranke"
else
  bad "LASTWACHE_AUS=1" "Ergebnis '$erzwungen' — das Urteil liesse sich nicht erzwingen"
fi

# 6: die Wache nennt im gruenen Fall ihre Zahlen. Eine Auslassung ohne Zahl
# ist nicht nachpruefbar, und ein Urteil ohne Bedingungen auch nicht.
bericht=$(bash -c '
  . "'"$ROOT"'/tests/lib/lastwache.sh"
  lastwache_ruhig >/dev/null 2>&1
  lastwache_bericht' 2>/dev/null)
if printf '%s' "$bericht" | grep -qE 'laufbereit=[0-9]+, Takt=[0-9]+/[0-9]+ MHz = -?[0-9]+ %'; then
  ok "Bericht nennt laufbereit und Takt mit Zahlen"
else
  bad "Bericht" "ohne Zahlen: '$bericht'"
fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
