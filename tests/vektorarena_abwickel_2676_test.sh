#!/usr/bin/env bash
# #2676: Das Zuruecksetzen der Vektorarena (#2206) stand EINMAL vor der
# abgewickelten Schleife, der Rumpf aber U-mal darin. Es wirkte damit nur bei
# jedem U-ten Durchlauf, und die Arena wuchs auf das U-fache des Bedarfs.
#
# Gemessen wird das VERHAELTNIS der Seitenfehler zwischen einem Durchlauf und
# vielen, nicht die absolute Zahl: die haengt an Seitengroesse und Maschine.
# Vor dem Fix war es 3,33 (U = 4), danach 1,33.
#
# Belegt wird zusaetzlich die KONSTANZ zwischen 21 und 41 Durchlaeufen. Ein
# Test, der nur ein Verhaeltnis prueft, waere auch von linearem Wachstum
# erfuellt, das erst spaeter einsetzt.
set -u
cd "$(dirname "$0")/.." || exit 1
LYXC="${LYXC:-./lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
P=0; F=0
ok() { P=$((P+1)); echo "PASS $1"; }
no() { F=$((F+1)); echo "FAIL $1"; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

if [ ! -f bench/arr_add_f32.lyx ]; then echo "SKIP: bench/arr_add_f32.lyx fehlt"; exit 0; fi
if ! "$LYXC" --std-path=. bench/arr_add_f32.lyx -o "$T/b" >"$T/log" 2>&1; then
  no "Pruefstand uebersetzt nicht"; head -3 "$T/log"; echo "PASS: $P  FAIL: $F"; exit 1
fi

N=4194304
fehler() { ( ulimit -v 4000000; /usr/bin/time -f '%R' "$T/b" "$N" "$1" 2>&1 >/dev/null | tail -1 ); }
summe()  { ( ulimit -v 4000000; "$T/b" "$N" "$1" 2>/dev/null | tail -1 ); }

F1=$(fehler 1); F21=$(fehler 21); F41=$(fehler 41)
case "$F1$F21$F41" in *[^0-9]*) no "Seitenfehler nicht messbar ('$F1' '$F21' '$F41')";; esac

# Die WIRKUNG zuerst: ein Erzeugnis, das falsch rechnet, darf nicht wegen
# guter Speicherzahlen durchgehen.
S=$(summe 11)
[ "$S" = "checksum=440" ] && ok "Pruefsumme unveraendert ($S)" || no "Pruefsumme: '$S' statt checksum=440"

if [ "${F1:-0}" -gt 1000 ]; then
  ok "Grundlinie plausibel ($F1 Fehler bei einem Durchlauf)"
  # Die Zielmarke ist ERREICHT: 12310 Fehler bei 1 wie bei 41 Durchlaeufen,
  # Verhaeltnis also 1,0. Die Schwelle liegt bei 1,2 und laesst nur Rauschen zu.
  #
  # Sie faengt damit BEIDE Stufen der Ursache: 3,33 (Marke nur je U-ter
  # Durchlauf, vor 1.2.51B) und 1,33 (aufgegebener Block, vor 1.2.51C). Die
  # erste Fassung dieses Tests hatte 2,0 und haette den zweiten Teil
  # durchgelassen -- gegengeprobt: mit 1.2.51B war sie gruen.
  GRENZE=$(( F1 + (F1 / 5) ))
  if [ "${F21:-0}" -le "$GRENZE" ]; then
    ok "21 Durchlaeufe auf der Zielmarke ($F21 <= $GRENZE, Grundlinie $F1)"
  else
    no "21 Durchlaeufe: $F21 Fehler gegen $F1 bei einem -- Arena haelt mehr als den Bedarf (Marke je U-ter Durchlauf, oder ein Block wird aufgegeben)"
  fi
  # Konstanz: 41 Durchlaeufe duerfen nicht mehr kosten als 21 (plus Rauschen).
  if [ "${F41:-0}" -le $(( F21 + (F21 / 10) + 100 )) ]; then
    ok "41 Durchlaeufe kosten nicht mehr als 21 ($F41 gegen $F21)"
  else
    no "41 Durchlaeufe: $F41 gegen $F21 -- waechst weiter"
  fi
else
  no "Grundlinie unplausibel ($F1) -- misst der Lauf ueberhaupt etwas?"
fi

# --- Die Reihe ueber den Abwickelfaktor muss FLACH sein ---------------------
#
# Das ist die Absicherung gegen eine Rueckkehr: der Fehler war PROPORTIONAL zu
# U und bei U = 1 unsichtbar. Ein Test, der nur bei der Vorgabestufe messt,
# haette ihn nie gezeigt.
if "$LYXC" --std-path=. --target-energy=1 bench/arr_add_f32.lyx -o "$T/u1" >/dev/null 2>&1 \
   && "$LYXC" --std-path=. --target-energy=5 bench/arr_add_f32.lyx -o "$T/u8" >/dev/null 2>&1; then
  A=$( ulimit -v 4000000; /usr/bin/time -f '%R' "$T/u1" "$N" 21 2>&1 >/dev/null | tail -1 )
  B=$( ulimit -v 4000000; /usr/bin/time -f '%R' "$T/u8" "$N" 21 2>&1 >/dev/null | tail -1 )
  case "$A$B" in
    *[^0-9]*) no "Reihe nicht messbar ('$A' '$B')" ;;
    *) if [ "$B" -le $(( A + (A / 5) )) ]; then
         ok "Reihe flach: U=1 $A Fehler, U=8 $B (<= $(( A + (A / 5) )))"
       else
         no "Reihe steigt mit dem Abwickelfaktor: U=1 $A, U=8 $B"
       fi ;;
  esac
else
  no "Reihe ueber --target-energy nicht uebersetzbar"
fi

echo "PASS: $P  FAIL: $F"
[ "$F" -eq 0 ] || exit 1
