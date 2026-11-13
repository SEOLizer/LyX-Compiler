#!/usr/bin/env bash
# tests/paket_lyu_vollstaendig_test.sh — #2444.
#
# Zu jeder Unit unter std/ und data/ gehoert ein vorkompiliertes .lyu im
# Paketbaum. Die Dateien werden nur von `make precompile-units` (und damit von
# `make package`) erzeugt; wer eine neue Unit hinzufuegt, ohne das zu fahren,
# checkt einen unvollstaendigen Paketbaum ein. Gemerkt hat das bisher nichts:
# `make test` arbeitet mit --std-path gegen std/ und sieht den Paketbaum nie.
#
# Gefunden wurde die Luecke beim Vorbereiten von #2447 (deb ohne Quellcode):
# 15 Units hatten kein .lyu — std/cpu/* (8), std/fma.lyx und std/semarti/* (6).
# Heute faellt das nicht auf, weil der Resolver .lyx vor .lyu zieht und der
# Paketbaum beide Formen traegt. Sobald nur noch .lyu ausgeliefert wird, fehlen
# diese Units beim Benutzer ERSATZLOS — ohne Meldung, denn eine Unit, die es
# nicht gibt, ist von einer Unit ohne Symbole nicht zu unterscheiden.
#
# Geprueft wird ueber die NAMEN, nicht ueber Anzahlen: eine zusaetzliche Datei
# wuerde sonst eine fehlende aufwiegen.
#
# NICHT geprueft wird hier, ob ein .lyu zur aktuellen Quelle passt. Mit
# Zeitstempeln geht das nicht — ein Branchwechsel schreibt die Arbeitskopie neu
# und macht jede mtime wertlos. Der inhaltliche Abgleich braucht erst die
# Zusicherung, dass zweimaliges Vorkompilieren dieselben Bytes ergibt (#2446);
# danach gehoert er hierher.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
_pp="$(dirname "$0")/lib/paket_pfad.sh"; [ -f "$_pp" ] || _pp="$(dirname "$0")/../lib/paket_pfad.sh"; . "$_pp"   # #2499
PKG="$PKG_UNITS"
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

cd "$ROOT" || exit 1

echo "--- #2444: jede Unit hat ein .lyu im Paketbaum ---"

fehlt=""
anz=0
while IFS= read -r f; do
  anz=$((anz + 1))
  lyu="$PKG/${f%.lyx}.lyu"
  [ -f "$lyu" ] || fehlt="$fehlt $f"
done < <(find std data -name '*.lyx' | sort)

if [ -z "$fehlt" ]; then
  ok "$anz Units, zu jeder ein .lyu"
else
  n=$(echo $fehlt | wc -w)
  nok "$n von $anz Units ohne .lyu:"
  for f in $fehlt; do echo "      $f"; done
  echo "      erzeugen mit: make precompile-units"
fi

# Gegenprobe: ein .lyu ohne Quelle ist ein Ueberrest. Er wuerde beim Benutzer
# eine Unit vorspiegeln, die es nicht mehr gibt — und nach dem Umstieg auf
# ein Paket ohne Quellen faellt das nirgends mehr auf.
verwaist=""
while IFS= read -r l; do
  rel="${l#$PKG/}"
  [ -f "$ROOT/${rel%.lyu}.lyx" ] || verwaist="$verwaist $rel"
done < <(find "$PKG" -name '*.lyu' | sort)

if [ -z "$verwaist" ]; then
  ok "kein verwaistes .lyu im Paketbaum"
else
  n=$(echo $verwaist | wc -w)
  nok "$n verwaiste .lyu (Quelle fehlt):"
  for f in $verwaist; do echo "      $f"; done
fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
