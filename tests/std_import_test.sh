#!/usr/bin/env bash
# tests/std_import_test.sh — #1272: jede Unit der Standardbibliothek muss
# importierbar sein.
#
# Warum es diese Pruefung gibt: zwischen "die Bibliothek baut" und "die Unit
# ist benutzbar" klafft eine Luecke. Die Units werden beim Bauen nie einzeln
# uebersetzt, ein Fehler IN einer Unit faellt daher erst dem ersten Anwender
# auf — und der haelt ihn fuer seinen eigenen. So blieben 19 Units unbemerkt
# unbenutzbar, darunter die komplette std.svg-Familie mit 114 oeffentlichen
# Funktionen; die Ursachen waren durchweg ein fehlender Cast oder ein
# fehlender Import.
#
# Dieselbe Bauart wie test_coverage_test.sh (#1112) und
# lyxc_guard_coverage_test.sh (#1294): eine Eigenschaft, die niemand prueft,
# verrottet.
#
# Der Lauf dauert einige Minuten — je Unit eine Uebersetzung. Das ist der
# Preis dafuer, dass er genau das misst, was der Anwender tut.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
rot=""

for f in $(find "$ROOT/std" -name '*.lyx' | sort); do
  rel="${f#$ROOT/}"
  unit="$(echo "${rel%.lyx}" | tr '/' '.')"
  printf 'import %s;\nfn main(): int64 { return 0; }\n' "$unit" > "$TMP/u.lyx"
  rm -f "$TMP/u"
  if "$LYXC" --std-path="$ROOT" "$TMP/u.lyx" -o "$TMP/u" >"$TMP/e.txt" 2>&1; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    rot="$rot
  $unit :: $(grep -iE 'error' "$TMP/e.txt" | head -1)"
  fi
done

if [ "$FAIL" -eq 0 ]; then
  echo "PASS alle $PASS Units der Standardbibliothek sind importierbar"
else
  echo "FAIL $FAIL von $((PASS+FAIL)) Units lassen sich nicht importieren:$rot"
fi

echo
echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
