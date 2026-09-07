#!/usr/bin/env bash
# tests/std_unit_deklaration_test.sh — #1999: jede Unit nennt ihren Namen selbst.
#
# 17 Dateien unter std/ fuehrten keine `unit`-Zeile. Funktional fiel das nicht
# auf: der Uebersetzer leitet den Namen aus dem PFAD ab, `import std.bpf;`
# uebersetzte und lief. Betroffen sind Werkzeuge, die den Bestand auswerten —
# beim Erzeugen des Funktionsglossars mussten diese Dateien gesondert
# behandelt werden, weil der Unit-Name nicht aus der Datei hervorgeht, sondern
# nur aus ihrer Lage.
#
# Dieser Test haelt den Bestand zusammen. Er prueft ZWEI Dinge, denn eine
# blosse Anwesenheitspruefung waere von einer beliebigen `unit`-Zeile erfuellt:
#
#   1. jede .lyx-Datei unter std/ traegt eine `unit`-Zeile,
#   2. der DEKLARIERTE Name stimmt mit dem PFAD ueberein.
#
# Der zweite Punkt ist der wichtigere. Ein falscher Name waere schlimmer als
# ein fehlender: er behauptet etwas, das der Resolver anders sieht.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0

echo "--- std/: jede Unit nennt ihren Namen selbst (#1999) ---"

fehlend=""
falsch=""
anzahl=0
while IFS= read -r f; do
  anzahl=$((anzahl+1))
  rel="${f#$ROOT/}"
  # erwarteter Name aus dem Pfad: std/net/epoll.lyx -> std.net.epoll
  erwartet="$(printf '%s' "${rel%.lyx}" | tr '/' '.')"
  zeile="$(grep -m1 -E '^[[:space:]]*unit[[:space:]]+' "$f" || true)"
  if [ -z "$zeile" ]; then
    fehlend="$fehlend $rel"
    continue
  fi
  ist="$(printf '%s' "$zeile" | sed -E 's/^[[:space:]]*unit[[:space:]]+//; s/[[:space:]]*;.*$//')"
  if [ "$ist" != "$erwartet" ]; then
    falsch="$falsch $rel(=$ist,erwartet=$erwartet)"
  fi
done < <(find "$ROOT/std" -name '*.lyx' | sort)

if [ -z "$fehlend" ]; then
  echo "PASS alle $anzahl Dateien unter std/ tragen eine unit-Zeile"; PASS=$((PASS+1))
else
  echo "FAIL ohne unit-Zeile:$fehlend"; FAIL=$((FAIL+1))
  echo "  Der Unit-Name folgt sonst nur aus dem Pfad. Werkzeuge, die den"
  echo "  Bestand auswerten, koennen ihn dann nicht aus der Datei lesen."
fi

if [ -z "$falsch" ]; then
  echo "PASS der deklarierte Name stimmt ueberall mit dem Pfad ueberein"; PASS=$((PASS+1))
else
  echo "FAIL Name weicht vom Pfad ab:$falsch"; FAIL=$((FAIL+1))
  echo "  Ein falscher Name ist schlimmer als ein fehlender: er behauptet"
  echo "  etwas, das der Resolver anders sieht."
fi

# GEGENPROBE: der Test darf nicht deshalb gruen sein, weil er nichts findet.
if [ "$anzahl" -gt 400 ]; then
  echo "PASS es wurden $anzahl Dateien geprueft"; PASS=$((PASS+1))
else
  echo "FAIL nur $anzahl Dateien gefunden — der Suchpfad stimmt nicht"; FAIL=$((FAIL+1))
fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
