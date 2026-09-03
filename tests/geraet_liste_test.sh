#!/usr/bin/env bash
# #1937: Gesundheit von tests/lyx-geraet.txt und tests/known-red.txt.
#
# Die Geraeteliste war bis 1.1.18A auf einem Rechner MIT Soundkarte und MIT
# laufendem MySQL-Server kuratiert. Sie beschrieb damit nicht "braucht ein
# Geraet", sondern "ist dem Kurator aufgefallen": von 36 auf dem CI-Runner
# scheiternden Tests stand kein einziger darin. Eine Liste, die durch Zusehen
# entsteht, misst die Maschine mit, auf der zugesehen wurde.
#
# Dagegen hilft kein statisches Merkmal am Quelltext — gemessen: 12 Tests
# nennen einen absoluten Pfad unter /home/ oder music_test.mp3 und laufen auf
# dem Runner trotzdem gruen, weil sie das Fehlen der Datei vertragen. Ein
# Zwang "Merkmal ⇒ Liste" haette also 12 Fehlalarme.
#
# Was sich maschinenunabhaengig pruefen laesst, ist die Liste selbst: dass ihre
# Eintraege existieren, dass keiner doppelt gefuehrt wird, und dass jeder unter
# einer Begruendung steht. Genau daran verfaellt so eine Liste.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GERAET="$ROOT/tests/lyx-geraet.txt"
KNOWN="$ROOT/tests/known-red.txt"
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

echo "--- Geraeteliste: Eintraege existieren, sind begruendet, nicht doppelt (#1937) ---"

if [ ! -f "$GERAET" ]; then
  nok "tests/lyx-geraet.txt fehlt"
  echo; echo "Ergebnis: $PASS PASS, $FAIL FAIL"; exit 1
fi

eintraege() { sed 's/#.*//; s/[[:space:]]*$//' "$1" | grep . ; }

# 1) Jeder Eintrag muss eine vorhandene Datei nennen. Ein Eintrag auf eine
#    geloeschte oder umbenannte Datei schuetzt nichts mehr und taeuscht
#    Abdeckung vor.
fehlend=""
while IFS= read -r e; do
  [ -f "$ROOT/$e" ] || fehlend="$fehlend $e"
done < <(eintraege "$GERAET")
if [ -n "$fehlend" ]; then
  nok "Eintraege ohne Datei:$fehlend"
else
  ok "alle $(eintraege "$GERAET" | wc -l) Eintraege nennen eine vorhandene Datei"
fi

# 2) Kein Test darf gleichzeitig als Geraetefall und als bekannter Defekt
#    gefuehrt werden — sonst ist unklar, was er misst.
if [ -f "$KNOWN" ]; then
  doppelt="$(comm -12 <(eintraege "$GERAET" | sort -u) \
                      <(sed 's/#.*//; s/!flaky//; s/[[:space:]]*$//' "$KNOWN" | grep . | sort -u) | tr '\n' ' ')"
  if [ -n "$doppelt" ]; then
    nok "in beiden Listen gefuehrt: $doppelt"
  else
    ok "keine Ueberschneidung mit known-red.txt"
  fi
else
  ok "known-red.txt nicht vorhanden — nichts zu vergleichen"
fi

# 3) Jeder Eintrag steht unter einer Gruppenueberschrift, die den Grund nennt.
#    Ohne Grund weiss niemand, wann der Eintrag wieder verschwinden darf —
#    genau so wird aus einer Ausnahmeliste eine Deponie.
ohne_grund="$(awk '
  /^#[[:space:]]*──/ { grund = 1; next }
  /^[[:space:]]*$/   { next }
  /^#/               { next }
  { if (!grund) print }
' "$GERAET" | tr '\n' ' ')"
if [ -n "$ohne_grund" ]; then
  nok "Eintraege ohne Gruppenueberschrift: $ohne_grund"
else
  ok "jeder Eintrag steht unter einer begruendeten Gruppe"
fi

# 4) Keine Dubletten innerhalb der Liste.
dubl="$(eintraege "$GERAET" | sort | uniq -d | tr '\n' ' ')"
if [ -n "$dubl" ]; then
  nok "doppelte Eintraege: $dubl"
else
  ok "keine doppelten Eintraege"
fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
