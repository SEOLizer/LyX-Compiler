#!/usr/bin/env bash
# tests/version_consistency_test.sh — alle lebenden Versionsangaben nennen
# dieselbe Version.
#
# Die Version steht an vier Stellen, und keine davon leitet sich aus einer
# anderen ab: Makefile (traegt auch den .deb-Namen), README-Badge, vier Strings
# in src/lyxc.lyx (--version, --help, Bootstrap-Zeile, Copyright-Banner) und der
# Kopf von ebnf.md. Von Hand gepflegt laufen die auseinander — ebnf.md stand
# beim Bump auf 1.0.12A noch auf 1.0.11C, zwei Versionen hinter dem Compiler.
#
# Der Compiler selbst kann das nicht melden: er kennt nur die Strings, die in
# ihm stecken. Ein Badge, der eine andere Version zeigt als das Binary, faellt
# sonst erst jemandem auf, der beides nebeneinander haelt.
#
# HISTORISCHE Angaben sind ausdruecklich nicht gemeint. Saetze wie „bis 1.0.11D
# war das so" beschreiben einen Zeitpunkt; sie bleiben stehen und werden hier
# nicht geprueft. Deshalb wird an den vier BEKANNTEN Stellen nachgesehen und
# nicht nach jedem Vorkommen der Zeichenkette gesucht.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

want=$(sed -n 's/^VERSION  *:= *\([0-9A-Za-z.]*\).*/\1/p' "$ROOT/Makefile" | head -1)
if [ -z "$want" ]; then
  echo "FAIL Makefile: VERSION nicht gefunden"
  exit 1
fi
echo "Sollversion (Makefile): $want"

# Schema pruefen: MAJOR.MINOR.TAG + Suffix aus einem oder zwei Grossbuchstaben,
# wobei ein zweibuchstabiger Suffix nicht mit A beginnt (nach Z folgt BA).
if ! printf '%s' "$want" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+([A-Z]|[B-Z][A-Z])$'; then
  echo "FAIL Version '$want' passt nicht zum Schema MAJOR.MINOR.TAG+Suffix (A..Z, BA..BZ, CA..)"
  fail=$((fail+1))
fi

check() { # datei, beschreibung, gefundene version
  if [ "$3" = "$want" ]; then
    echo "PASS $1 ($2)"
  else
    echo "FAIL $1 ($2): '$3' erwartet '$want'"
    fail=$((fail+1))
  fi
}

check README.md "Badge" \
  "$(sed -n 's/.*version-v\([0-9A-Za-z.]*\)-blue.*/\1/p' "$ROOT/README.md" | head -1)"

check src/lyxc.lyx "--version" \
  "$(sed -n 's/.*PrintStrLn("\([0-9]\+\.[0-9]\+\.[0-9A-Z]\+\)"c);.*/\1/p' "$ROOT/src/lyxc.lyx" | head -1)"

# --version und --help teilen sich denselben String-Typ; beide Vorkommen muessen
# stimmen, nicht nur das erste.
n_short=$(grep -c "PrintStrLn(\"$want\"c);" "$ROOT/src/lyxc.lyx")
if [ "$n_short" -eq 2 ]; then
  echo "PASS src/lyxc.lyx (--version und --help, beide Vorkommen)"
else
  echo "FAIL src/lyxc.lyx: $n_short von 2 kurzen Versionsstrings auf $want"
  fail=$((fail+1))
fi

check src/lyxc.lyx "Bootstrap-Zeile" \
  "$(sed -n 's/.*PrintStrLn("lyxc \([0-9A-Za-z.]*\) (bootstrap)");.*/\1/p' "$ROOT/src/lyxc.lyx" | head -1)"

check src/lyxc.lyx "Copyright-Banner" \
  "$(sed -n 's/.*PrintStr("lyxc \([0-9A-Za-z.]*\) — Copyright.*/\1/p' "$ROOT/src/lyxc.lyx" | head -1)"

check ebnf.md "Titel" \
  "$(sed -n '1s/^# Lyx \([0-9A-Za-z.]*\) .*/\1/p' "$ROOT/ebnf.md")"

check ebnf.md "Standvermerk" \
  "$(sed -n 's/.*gegen lyxc \([0-9A-Za-z.]*\) geprueft.*/\1/p' "$ROOT/ebnf.md" | head -1)"

# Das gebaute Binary, falls vorhanden: es ist die einzige Stelle, die zaehlt,
# wenn jemand `lyxc --version` aufruft.
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
if [ -x "$LYXC" ]; then
  got=$("$LYXC" --version 2>/dev/null | head -1 | sed 's/^lyxc //')
  if [ "$got" = "$want" ]; then
    echo "PASS Binary --version"
  else
    echo "FAIL Binary --version: '$got' erwartet '$want' — Binary ist aelter als die Quelle"
    fail=$((fail+1))
  fi
else
  echo "SKIP Binary --version (kein Binary gebaut)"
fi

echo
if [ "$fail" -gt 0 ]; then
  echo "FAIL $fail Versionsangabe(n) weichen ab"
  exit 1
fi
echo "PASS alle Versionsangaben nennen $want"
