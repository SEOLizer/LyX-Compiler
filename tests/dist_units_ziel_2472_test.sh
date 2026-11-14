#!/bin/bash
# #2472: Die Unit-Herkunft steht JE BACKEND in der Tabelle von
# tools/build_dist.sh (Spalte "Units"), und jedes zielweise Backend hat eine
# Ausnahmeliste, in der JEDE Zeile ihre Ursache als Issue nennt.
#
# Warum ein Waechter: eine .lyu traegt das Layout ihres Ziels (StringBuilder
# ist auf x86-64 32 Byte mit Typwort 1, auf arm64 24 mit Typwort 0). Stand die
# Herkunft global auf `host`, bekamen arm64, riscv64 und macos-arm64 die Units
# des Hosts -- und 47 von 87 Beispielen im arm64-Baum uebersetzten nicht.
#
# Geprueft wird die TABELLE und die LISTEN, nicht ein Auslieferbau: der dauert
# Minuten und haengt an Cross-Werkzeugen. Die Wirkung steht im Issue und im
# Skriptkopf, hier wird festgehalten, dass die Angabe nicht wieder global wird.
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
PASS=0; FAIL=0
pr() { if [ "$1" = ok ]; then PASS=$((PASS+1)); echo "PASS $2"; else FAIL=$((FAIL+1)); echo "FAIL $2"; fi; }

S="tools/build_dist.sh"
[ -f "$S" ] || { echo "SKIP: $S fehlt"; echo "Ergebnis: 0 PASS, 0 FAIL"; exit 0; }

# 1) Jede Tabellenzeile hat sechs Felder, das letzte ist host oder ziel.
ZEILEN="$(sed -n '/^BACKEND_TABELLE=(/,/^)/p' "$S" | grep -oE '"[^"]+"' | tr -d '"')"
[ -n "$ZEILEN" ] || { echo "FAIL Backend-Tabelle nicht lesbar"; echo "Ergebnis: 0 PASS, 1 FAIL"; exit 1; }
schlecht=""
while IFS= read -r z; do
  n=$(printf '%s' "$z" | awk -F'|' '{print NF}')
  u=$(printf '%s' "$z" | awk -F'|' '{print $6}')
  case "$n:$u" in
    6:host|6:ziel) ;;
    *) schlecht="$schlecht ${z%%|*}($n:$u)" ;;
  esac
done <<< "$ZEILEN"
if [ -z "$schlecht" ]; then
  pr ok "alle $(printf '%s\n' "$ZEILEN" | wc -l) Backends nennen ihre Unit-Herkunft (host|ziel)"
else
  pr no "Backends ohne gueltige Herkunft:$schlecht"
fi

# 2) Kein globales `UNITS_ZIEL=host` mehr als Vorgabe -- genau das war der
#    Defekt. Von aussen gesetzt darf weiter gewinnen.
if grep -qE '^UNITS_ZIEL="\$\{UNITS_ZIEL:-host\}"' "$S"; then
  pr no "die Vorgabe steht wieder global auf host"
else
  pr ok "keine globale host-Vorgabe mehr"
fi
if grep -q 'UNITS_ZIEL_GESETZT' "$S"; then
  pr ok "eine von aussen gesetzte Herkunft gewinnt weiter"
else
  pr no "UNITS_ZIEL von aussen wirkt nicht mehr"
fi

# 3) Jedes zielweise Backend hat eine Ausnahmeliste, und JEDE Zeile darin
#    nennt eine Issue-Nummer. Ein Eintrag ohne Ursache waere der stille
#    Default, den die Projektregeln verbieten.
ohneListe=""; ohneGrund=""
while IFS= read -r z; do
  name="${z%%|*}"
  u=$(printf '%s' "$z" | awk -F'|' '{print $6}')
  [ "$u" = "ziel" ] || continue
  L="tools/dist_units_ausnahmen_$name.txt"
  if [ ! -f "$L" ]; then ohneListe="$ohneListe $name"; continue; fi
  while IFS= read -r e; do
    case "$e" in ''|'#'*) continue ;; esac
    printf '%s' "$e" | grep -qE '#.*#[0-9]+' || ohneGrund="$ohneGrund $name:${e%% *}"
  done < "$L"
done <<< "$ZEILEN"
if [ -z "$ohneListe" ]; then
  pr ok "jedes zielweise Backend hat eine Ausnahmeliste"
else
  pr no "zielweise Backends ohne Liste:$ohneListe"
fi
if [ -z "$ohneGrund" ]; then
  pr ok "jede Ausnahme nennt ihre Ursache mit Issue-Nummer"
else
  pr no "Ausnahmen ohne Issue-Nummer:$ohneGrund"
fi

# 4) Die x86-64-Ziele bleiben auf host: dort ist der Host-Baum vollstaendig,
#    und zielweise fehlten 16 Units (win64, #2459/#2460/#1678).
for b in linux-x86_64 win64 macos-x86_64; do
  u="$(printf '%s\n' "$ZEILEN" | awk -F'|' -v b="$b" '$1==b{print $6}')"
  [ "$u" = "host" ] || { pr no "$b steht auf '$u', erwartet host"; continue; }
done
pr ok "die x86-64-Ziele stehen auf host"

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "OK: Unit-Herkunft je Backend, Ausnahmen mit Ursache (#2472)"
