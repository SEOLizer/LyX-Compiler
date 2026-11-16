#!/usr/bin/env bash
# tools/lyu_baum_pruefen.sh <arch> — ist der Vorkompilatbaum einer Architektur
# vollstaendig, und ist jede Luecke erklaert? (#2536)
#
# Warum es das gibt: `precompile-units` ist in Pass 2 streng und bricht beim
# ersten Fehlschlag ab. Fuer x86_64 ist das richtig -- dort gibt es keine
# zielbedingten Luecken. Fuer ein IR-Ziel wie lyxos gibt es sie: neun Units
# uebersetzen dort NICHT und sollen es auch nicht (Bluetooth-Sockets, rohe
# Linux-Wrapper, security_ext_x86). Ohne Liste waere das Ziel dauerhaft rot und
# niemand unterschiede gewollt von kaputt -- dieselbe Aufgabe, die
# tests/known-red.txt fuer Tests hat.
#
# BEIDE Richtungen, denn eine Liste, die nur entschuldigt, verfault:
#   * Unit fehlt und steht NICHT in der Liste      -> FEHLER (echte Luecke)
#   * Unit fehlt und steht     in der Liste        -> ausgenommen, mit Grund
#   * Unit uebersetzt, steht aber in der Liste     -> FEHLER (Eintrag ist
#     ueberholt; er wuerde den naechsten echten Fall verdecken)
set -u
ARCH="${1:?Aufruf: lyu_baum_pruefen.sh <arch>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BAUM="$ROOT/lyx-compiler/usr/include/lyx/units/$ARCH"
AUSN="$ROOT/tools/dist_units_ausnahmen_$ARCH.txt"
[ -f "$AUSN" ] || AUSN=/dev/null

fehlt=0; ausgenommen=0; ueberholt=0; da=0
while IFS= read -r q; do
  rel="${q#*/}"; pfx="${q%%/*}"
  lyu="$BAUM/$pfx/${rel%.lyx}.lyu"
  grund="$(sed -n "s|^$q[[:space:]]*#[[:space:]]*||p" "$AUSN" 2>/dev/null | head -1)"
  if [ -s "$lyu" ]; then
    da=$((da+1))
    if [ -n "$grund" ]; then
      echo "UEBERHOLT  $q — uebersetzt wieder, Eintrag in $(basename "$AUSN") streichen"
      ueberholt=$((ueberholt+1))
    fi
  elif [ -n "$grund" ]; then
    ausgenommen=$((ausgenommen+1))
  else
    echo "FEHLT      $q"
    fehlt=$((fehlt+1))
  fi
done < <( cd "$ROOT" && find std data -name '*.lyx' 2>/dev/null | sort )

echo "$ARCH: $da .lyu, $ausgenommen ausgenommen, $fehlt ohne Erklaerung, $ueberholt ueberholt"
[ "$fehlt" -eq 0 ] && [ "$ueberholt" -eq 0 ]
