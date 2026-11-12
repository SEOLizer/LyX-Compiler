#!/usr/bin/env bash
# Prueft die TextMate-Grammatik der Editor-Unterstuetzung: gueltiges JSON, und
# jedes Schluesselwort und jeder Basistyp der Sprache kommt darin vor.
#
# Der Test lief nie (#1112, Unterverzeichnis unsichtbar) und konnte in seiner
# alten Fassung auch gar nicht rot werden: der JSON-Teil las die Variable
# $GRAMMAR in einem quotierten Here-Dokument, wo die Shell sie nicht ersetzt
# ("name 'GRAMMAR' is not defined"), und die Schluesselwortpruefung gab bei
# Fehlern nur WARNING aus und endete trotzdem mit 0. Beides ist der stille
# Default aus CLAUDE.md: etwas Plausibles tun statt zu melden.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GRAMMAR="$ROOT/syntaxes/lyx.tmLanguage.json"
EXAMPLES_DIR="$ROOT/examples/syntax_highlight_examples"

fail=0

echo "Grammatik: $GRAMMAR"
if [ ! -f "$GRAMMAR" ]; then
  echo "FAIL Grammatikdatei fehlt"
  exit 1
fi

if ! python3 -c 'import json,sys; json.load(open(sys.argv[1])); print("OK: JSON gueltig")' "$GRAMMAR"; then
  echo "FAIL Grammatik ist kein gueltiges JSON"
  fail=$((fail+1))
fi

keywords_expected=(fn var let co con if else while return true false extern case switch break default)
types_expected=(int8 int16 int32 int64 int bool void pchar string)

for kw in "${keywords_expected[@]}"; do
  grep -q "\\b${kw}\\b" "$GRAMMAR" || { echo "FAIL Schluesselwort fehlt in der Grammatik: ${kw}"; fail=$((fail+1)); }
done

for t in "${types_expected[@]}"; do
  grep -q "\\b${t}\\b" "$GRAMMAR" || { echo "FAIL Typ fehlt in der Grammatik: ${t}"; fail=$((fail+1)); }
done

# Die Beispieldateien sind das Material, an dem die Grammatik von Hand geprueft
# wird. Fehlen sie, prueft niemand mehr etwas.
shopt -s nullglob
examples=("$EXAMPLES_DIR"/*.lyx)
if [ ${#examples[@]} -eq 0 ]; then
  echo "FAIL keine Beispieldateien in $EXAMPLES_DIR"
  fail=$((fail+1))
fi
for f in "${examples[@]}"; do
  echo "Beispiel: ${f#"$ROOT/"}"
done

if [ "$fail" -gt 0 ]; then
  echo "FAIL $fail Befund(e)"
  exit 1
fi
echo "PASS Grammatik vollstaendig, ${#examples[@]} Beispieldatei(en)"
