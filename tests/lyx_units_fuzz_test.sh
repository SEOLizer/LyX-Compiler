#!/usr/bin/env bash
# tests/lyx_units_fuzz_test.sh
#
# Fuzz-Abgleich der Mathematik-Units gegen UNABHAENGIGE Referenzen in Python.
#
# Warum ein eigener Runner: die Programme unter tests/lyx-units-fuzz/ pruefen
# sich nicht selbst — sie erzeugen Rohdaten (Eingaben und Ergebnisse, Zeile fuer
# Zeile), und das Urteil faellt erst das zugehoerige *_ref.py, das jede
# Operation mit Pythons beliebig langen Ganzzahlen nachrechnet. Genau darin
# liegt ihr Wert: die Referenz teilt sich keine Zeile Code und keine Annahme
# mit der Lyx-Fassung. Ein Fehler, der in beiden Umsetzungen gleich waere,
# faellt hier auf — anders als bei einer selbstgeschriebenen Gegenprobe.
#
# Wuerde man die Fuzz-Programme stattdessen einfach in suite-full.txt
# eintragen, liefen sie zwar mit, aber ohne jedes Urteil: sie drucken Daten und
# enden mit 0. Das waere eine gruene Zeile, die nichts belegt.
#
# Ohne python3 wird uebersprungen statt rot gemeldet — der Abgleich ist eine
# Zusatzpruefung, die Units selbst sind ueber tests/<unit>_test.lyx abgedeckt.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
DIR="$ROOT/tests/lyx-units-fuzz"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: python3 nicht vorhanden — Fuzz-Abgleich uebersprungen"
  exit 0
fi

if [ ! -x "$LYXC" ]; then
  echo "FAIL: $LYXC fehlt oder ist nicht ausfuehrbar"
  exit 1
fi

# Einheiten, fuer die es ein Fuzz-Programm UND eine Referenz gibt.
UNITS="bits bignum graph grid i128 money sparse"

pass=0
fail=0

for u in $UNITS; do
  src="$DIR/${u}_fuzz.lyx"
  ref="$DIR/${u}_ref.py"

  if [ ! -f "$src" ] || [ ! -f "$ref" ]; then
    echo "FAIL $u: Fuzz-Programm oder Referenz fehlt"
    fail=$((fail + 1))
    continue
  fi

  if ! timeout 120 "$LYXC" --std-path="$ROOT" "$src" -o "$TMP/$u" >"$TMP/$u.build" 2>&1; then
    echo "FAIL $u: uebersetzt nicht"
    sed -n '1,3p' "$TMP/$u.build"
    fail=$((fail + 1))
    continue
  fi

  if ! timeout 120 "$TMP/$u" >"$TMP/$u.out" 2>&1; then
    echo "FAIL $u: Fuzz-Programm bricht ab (rc=$?)"
    fail=$((fail + 1))
    continue
  fi

  # Voraussetzung der Referenz VOR dem Vergleich messen (#1933). Bis hierher
  # meldete ein fehlendes python3-Modul "Referenz meldet Abweichungen" — der
  # Absturz der Referenz sah aus wie ein Rechenfehler in der Unit. numpy fehlte
  # auf dem CI-Runner, gemeldet wurde ein Defekt in std.sparse.
  fehlt=""
  for m in $(sed -n 's/^import \([a-zA-Z_][a-zA-Z0-9_]*\).*/\1/p' "$ref"); do
    python3 -c "import $m" >/dev/null 2>&1 || fehlt="$fehlt $m"
  done
  if [ -n "$fehlt" ]; then
    echo "UEBERSPRUNGEN $u: python3-Modul fehlt —$fehlt"
    continue
  fi

  if out=$(timeout 120 python3 "$ref" "$TMP/$u.out" 2>&1); then
    lines=$(wc -l <"$TMP/$u.out")
    echo "PASS $u ($lines Zeilen abgeglichen)"
    pass=$((pass + 1))
  else
    # Auch hier trennen: bricht die Referenz selbst ab, ist das KEINE
    # Abweichung in der Unit (#1933).
    if printf '%s' "$out" | grep -q "Traceback (most recent call last)"; then
      echo "FAIL $u: die Referenz selbst bricht ab (kein Befund ueber die Unit)"
    else
      echo "FAIL $u: Referenz meldet Abweichungen"
    fi
    printf '%s\n' "$out" | sed -n '1,5p'
    fail=$((fail + 1))
  fi
done

echo "----"
echo "Fuzz-Abgleich: $pass gruen, $fail rot"
[ "$fail" -eq 0 ] || exit 1
exit 0
