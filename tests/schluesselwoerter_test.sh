#!/bin/bash
# #1653 — reservierte Woerter: Liste in ebnf.md und Meldung im Parser
#
# Der Test haelt die Grammatik am Compiler fest. Ohne ihn verrottet die Liste
# in ebnf.md beim naechsten neuen Schluesselwort, und niemand merkt es —
# genau der Zustand, aus dem #1653 entstanden ist.
#
# Geprueft wird beides in beide Richtungen:
#   * jedes Wort der Keyword-Produktion wird als Bezeichner ABGEWIESEN
#   * jedes als weich benannte Wort wird als Bezeichner ANGENOMMEN
set -u
cd "$(dirname "$0")/.."
LYXC=${LYXC:-./lyxc}
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# Die harten Woerter aus der Keyword-Produktion in ebnf.md lesen.
hart=$(awk '/^Keyword           =/,/;$/' ebnf.md | grep -oE '"[a-z_]+"' | tr -d '"' | sort -u)
anzahl=$(echo "$hart" | wc -w)
if [ "$anzahl" -lt 50 ]; then
  bad "Keyword-Produktion in ebnf.md gefunden (nur $anzahl Woerter)"
else
  ok "Keyword-Produktion in ebnf.md gefunden ($anzahl Woerter)"
fi

# Die weichen aus dem Absatz darunter.
weich=$(awk '/WEICHE Schluesselwoerter/,/\*\)/' ebnf.md | grep -E "^     [a-z]" | tr -s ' ' '\n' | grep -E "^[a-z]+$" | sort -u)
weichN=$(echo "$weich" | wc -w)
if [ "$weichN" -lt 5 ]; then
  bad "Liste der weichen Schluesselwoerter gefunden (nur $weichN)"
else
  ok "Liste der weichen Schluesselwoerter gefunden ($weichN Woerter)"
fi

probiere() {   # probiere <wort> -> 0 = uebersetzt, 1 = abgewiesen
  printf 'fn f(%s: int64): int64 { return %s; }\nfn main(): int64 { return f(1); }\n' "$1" "$1" > "$TMP/k.lyx"
  if "$LYXC" --std-path=. "$TMP/k.lyx" -o "$TMP/k.bin" > "$TMP/k.log" 2>&1; then return 0; else return 1; fi
}

falsch=""
for w in $hart; do
  if probiere "$w"; then falsch="$falsch $w"; fi
done
if [ -z "$falsch" ]; then
  ok "alle $anzahl harten Woerter werden als Bezeichner abgewiesen"
else
  bad "diese Woerter stehen in der Liste, sind aber als Bezeichner erlaubt:$falsch"
fi

falsch2=""
for w in $weich; do
  if ! probiere "$w"; then falsch2="$falsch2 $w"; fi
done
if [ -z "$falsch2" ]; then
  ok "alle $weichN weichen Woerter sind als Bezeichner erlaubt"
else
  bad "diese gelten als weich, werden aber abgewiesen:$falsch2"
fi

# Die Meldung nennt den Anlass — vorher stand dort "got unit 'unit'".
printf 'fn f(unit: int64): int64 { return unit; }\nfn main(): int64 { return f(1); }\n' > "$TMP/m.lyx"
"$LYXC" --std-path=. "$TMP/m.lyx" -o "$TMP/m.bin" > "$TMP/m.log" 2>&1
if grep -q "reserved word 'unit'" "$TMP/m.log"; then
  ok "Meldung nennt das reservierte Wort als Anlass"
else
  bad "Meldung nennt das reservierte Wort als Anlass"; head -2 "$TMP/m.log"
fi

# Gegenprobe: andere Fehlpassungen melden weiter wie bisher.
printf 'fn f(123: int64): int64 { return 1; }\nfn main(): int64 { return 0; }\n' > "$TMP/z.lyx"
"$LYXC" --std-path=. "$TMP/z.lyx" -o "$TMP/z.bin" > "$TMP/z.log" 2>&1
if grep -q "got INT '123'" "$TMP/z.log"; then
  ok "andere Fehlpassungen melden unveraendert"
else
  bad "andere Fehlpassungen melden unveraendert"; head -2 "$TMP/z.log"
fi

echo "----"
echo "$PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
