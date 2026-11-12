#!/bin/bash
# #1696/#1699 — zwei Verfallsarten, die im gewachsenen Arbeitsbaum unsichtbar
# sind und deshalb jahrelang liegenbleiben konnten:
#
#   1. Ein Make-Ziel, das niemand faehrt. `test-lyxos` und `test-lyxos-units`
#      hingen an keinem Sammelziel und liefen in keiner CI — entsprechend waren
#      sie rot, ohne dass es auffiel: drei Dateien in tests/lyxos/ scheiterten
#      seit ihrer Einfuehrung (LX-23) am Parser. Dasselbe galt fuer `test-lyx`
#      (die Vollsuite mit 408 Tests) und `test-external`.
#      tests/test_coverage_test.sh prueft nur, ob der Runner IM MAKEFILE STEHT
#      — nicht, ob sein Ziel je aufgerufen wird. Diese Luecke schliesst hier.
#
#   2. Eine Suite-Liste, die Dateien nennt, die git nicht kennt. Lokal liegen
#      sie herum und alles ist gruen; auf einem frischen Klon ist das Ziel rot
#      und die Tests laufen dort nie. Genau so hat .gitignore per `debug_*`
#      drei Regressionstests verschluckt.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
P=0; F=0
ok()  { echo "PASS: $1"; P=$((P+1)); }
bad() { echo "FAIL: $1"; F=$((F+1)); }

CI="$ROOT/.github/workflows/ci.yml"
if [ ! -f "$CI" ]; then
  echo "SKIP: keine CI-Datei gefunden ($CI)"
  echo "----"; echo "0 PASS, 0 FAIL"; exit 0
fi

# --- 1) Jedes Testziel muss von der CI gefahren werden ---------------------
ziele=$(grep -oE "^test[a-z-]*:" "$ROOT/Makefile" | tr -d ':' | sort -u)
gefahren=$(grep -oE "make [a-z-]+" "$CI" | awk '{print $2}' | sort -u)
fehlt=""
for z in $ziele; do
  echo "$gefahren" | grep -qx "$z" || fehlt="$fehlt $z"
done
if [ -z "$fehlt" ]; then
  ok "alle Testziele des Makefiles werden von der CI gefahren"
else
  bad "Testziel(e) laufen in keiner CI:$fehlt
  Ein Ziel, das niemand aufruft, ist so unsichtbar wie ein Test, der in keinem
  Ziel steht. Entweder in .github/workflows/ci.yml aufnehmen oder das Ziel
  entfernen."
fi

# --- 2) Die CI muss fuer den Arbeitszweig ausloesen ------------------------
# Gearbeitet wird gegen `develop`; loest die CI nur auf `main` aus, laeuft sie
# fuer keinen einzigen echten PR.
if grep -qE "branches:.*develop" "$CI"; then
  ok "die CI loest auch fuer develop aus"
else
  bad "die CI loest nicht fuer develop aus — sie laeuft damit fuer keinen der
  tatsaechlichen PRs, sondern nur beim Zusammenfuehren nach main"
fi

# --- 3) Jede in einer Suite-Liste genannte Datei muss in git sein ----------
if git -C "$ROOT" rev-parse --git-dir > /dev/null 2>&1; then
  unbekannt=""; geprueft=0
  for liste in "$ROOT"/tests/suite-*.txt; do
    [ -f "$liste" ] || continue
    while IFS= read -r zeile; do
      zeile="${zeile%%#*}"
      zeile="$(printf '%s' "$zeile" | sed -e 's/[[:space:]]*$//')"
      # Wie run_lyx_suite.sh (Zeile 48): hinter dem Namen kann ein Argument stehen.
      t="${zeile%% *}"
      [ -z "$t" ] && continue
      geprueft=$((geprueft+1))
      datei="tests/$t.lyx"
      if [ ! -f "$ROOT/$datei" ]; then
        unbekannt="$unbekannt $t(fehlt)"
      elif ! git -C "$ROOT" ls-files --error-unmatch "$datei" > /dev/null 2>&1; then
        unbekannt="$unbekannt $t(nicht-in-git)"
      fi
    done < "$liste"
  done
  if [ -z "$unbekannt" ]; then
    ok "alle $geprueft Suite-Eintraege sind eingecheckte Dateien"
  else
    bad "Suite-Eintraege ohne eingecheckte Datei:$unbekannt
  Lokal ist damit alles gruen, auf einem frischen Klon rot — und die Tests
  laufen dort nie. Meist faengt eine zu weite .gitignore-Regel sie ein."
  fi
else
  echo "SKIP: kein git-Repository — Suite-Eintraege nicht pruefbar"
fi

echo "----"
echo "$P PASS, $F FAIL"
[ "$F" -eq 0 ]
