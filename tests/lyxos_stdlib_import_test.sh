#!/bin/bash
# #1720 — welche stdlib-Units gegen --target=lyxos bauen.
#
# Der Bau bricht immer beim ERSTEN fehlenden Namen ab: wer eine Luecke
# schliesst, sieht sofort die naechste. Diese Liste haelt fest, wie weit es
# gerade traegt, und sie ist in BEIDE Richtungen scharf:
#
#   * eine Unit unter BAUT, die nicht mehr baut  -> Rueckschritt, rot
#   * eine Unit unter BLOCKIERT, die inzwischen baut -> Eintrag streichen, rot
#
# Ohne die zweite Richtung veraltet die Liste still, und der naechste liest
# einen Rueckstand, den es nicht mehr gibt.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$ROOT/tests/lib/lyxc_guard.sh"; [ -f "$_g" ] && . "$_g"   # #1294
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
P=0; F=0
ok()  { echo "PASS: $1"; P=$((P+1)); }
bad() { echo "FAIL: $1${2:+ — $2}"; F=$((F+1)); }

BAUT="std.fs std.io std.alloc std.string std.env std.time std.conv std.math"
# Unit:blockierender Name — der Name gehoert dazu, sonst sagt der Eintrag
# nicht, worauf man wartet.
BLOCKIERT=""

pruefe() {   # pruefe <unit> ; setzt $rc und $msg
  printf 'import %s;\nfn main(): int64 { return 0; }\n' "$1" > "$TMP/t.lyx"
  if timeout 300 "$LYXC" --std-path="$ROOT" --target=lyxos "$TMP/t.lyx" -o "$TMP/t.out" >"$TMP/l" 2>&1
  then rc=0; msg=""
  else
    rc=1
    # Es gibt ZWEI Fehlerformen, und nur eine zu greifen hat schon einmal
    # einen fehlgeschlagenen Bau als Erfolg gemeldet:
    #   "unbekannter Builtin/Funktion: X"  (Name im Lowerer unbekannt)
    #   "Builtin-ID N wird nicht behandelt" (Backend kennt die ID nicht)
    msg="$(grep -oE 'unbekannter Builtin/Funktion: .*|Builtin-ID [0-9]+ wird nicht behandelt' "$TMP/l" | head -1)"
  fi
}

for u in $BAUT; do
  pruefe "$u"
  if [ "$rc" -eq 0 ]; then ok "$u baut"; else bad "$u baut nicht mehr" "$msg"; fi
done

for eintrag in ${BLOCKIERT:-}; do
  u="${eintrag%%:*}"; erwartet="${eintrag##*:}"
  pruefe "$u"
  if [ "$rc" -eq 0 ]; then
    bad "$u baut inzwischen" "aus der BLOCKIERT-Liste streichen"
  # Platzhalter: im Eintrag steht "Builtin-ID_9" fuer "Builtin-ID 9", weil
  # die Liste durch Leerzeichen getrennt ist. Namen wie sys_clock_nanosleep
  # tragen selbst Unterstriche — deshalb nur das Muster "Builtin-ID_" ersetzen.
  elif echo "$msg" | grep -q "$(echo "$erwartet" | sed 's/^Builtin-ID_/Builtin-ID /')"; then
    ok "$u blockiert wie vermerkt an $erwartet"
  else
    bad "$u blockiert an etwas anderem" "$msg statt $erwartet — Eintrag nachziehen"
  fi
done

echo "Ergebnis: $P PASS, $F FAIL"
[ "$F" -eq 0 ] || exit 1
