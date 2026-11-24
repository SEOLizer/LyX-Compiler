#!/usr/bin/env bash
# tests/unit_baum_gelistet_2642_test.sh — ist jeder EINGECHECKTE Unit-Baum in
# LYU_BAEUME gelistet? (#2642)
#
# BEFUND. Commit 2fe2bbfe (#2607) hat 501 lyxos-.lyu mitversioniert -- 106 MB --,
# weil der Baum zum Pruefen gebaut und dann mit `git add -A` aufgenommen wurde.
# `lyxos` steht aber nicht in LYU_BAEUME, und die Schranke in `units-baeume`
# (aus #2633, sie verhindert, dass ein Paketbau einen eingecheckten Baum
# nebenbei loescht) brach daraufhin JEDEN Lauf ab, bevor eine einzige Unit
# gebaut wurde. Wer eine stdlib-Unit aenderte, konnte die Vorkompilate nicht
# mehr auf dem vorgesehenen Weg nachziehen -- obwohl
# tests/paket_lyu_frisch_2557_test.sh genau darauf verweist.
#
# WARUM HIER UND NICHT NUR DORT. Die Schranke ist richtig, aber sie feuert erst,
# wenn jemand `make units-baeume` faehrt. Dieser Test laeuft in `make test` und
# damit in der CI: ein versehentlich mitversionierter Baum fliegt sofort auf und
# nicht erst beim naechsten, der den Bauweg braucht.
#
# Geprueft wird nur EINE Richtung. Ein Baum, der in LYU_BAEUME steht und nicht
# eingecheckt ist, ist in Ordnung -- den baut `units-baeume` ja gerade.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PASS=0; FAIL=0
pr() { if [ "$1" = ok ]; then PASS=$((PASS+1)); echo "PASS $2"; else FAIL=$((FAIL+1)); echo "FAIL $2"; fi; }

BASIS="lyx-compiler/usr/include/lyx/units"

# Die Liste kommt aus dem Makefile und wird nicht abgeschrieben -- sonst waere
# sie eine zweite Aufzaehlung derselben Sache.
LISTE="$(sed -n 's/^LYU_BAEUME *?*= *//p' Makefile | head -1)"
if [ -z "$LISTE" ]; then
  pr fail "LYU_BAEUME ist im Makefile nicht lesbar -- wurde die Variable umbenannt?"
  echo "Ergebnis: $PASS PASS, $FAIL FAIL"; exit 1
fi
pr ok "LYU_BAEUME aus dem Makefile gelesen: $LISTE"

# Welche Baeume sind VERSIONIERT? git ls-files, nicht das Dateisystem: ein
# lokal gebauter Baum ist erlaubt, ein eingecheckter nicht.
EINGECHECKT="$(git ls-files "$BASIS" 2>/dev/null | sed "s|^$BASIS/||" | cut -d/ -f1 | sort -u)"

pruefe() { # liste, eingecheckt -> nicht gelistete Baeume auf stdout
  local liste=" $1 "; local b
  for b in $2; do
    case "$liste" in *" $b "*) ;; *) echo "$b" ;; esac
  done
}

NICHT_GELISTET="$(pruefe "$LISTE" "$EINGECHECKT")"
if [ -z "$NICHT_GELISTET" ]; then
  pr ok "jeder eingecheckte Unit-Baum steht in LYU_BAEUME ($(printf '%s' "$EINGECHECKT" | tr '\n' ' '))"
else
  pr fail "eingecheckt, aber nicht in LYU_BAEUME: $(printf '%s' "$NICHT_GELISTET" | tr '\n' ' ')"
  echo "      'make units-baeume' bricht damit ab, bevor eine Unit gebaut wird (#2642)."
  echo "      Entweder nach LYU_BAEUME aufnehmen (dann Paketgroesse pruefen, #2536:"
  echo "      lyxos ist installiert 274 MB gegen 2,4 MB bei x86_64) oder entfernen:"
  for b in $NICHT_GELISTET; do echo "        git rm -r $BASIS/$b/"; done
fi

# Gegenprobe: der Vergleich muss einen nicht gelisteten Baum auch FINDEN.
# Ohne sie waere der Test auch von einer Fassung erfuellt, die nie etwas meldet.
if [ -n "$(pruefe "x86_64" "x86_64 lyxos")" ]; then
  pr ok "der Vergleich findet einen nicht gelisteten Baum (Gegenprobe)"
else
  pr fail "Gegenprobe: ein nicht gelisteter Baum wird NICHT gefunden"
fi

echo ""
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
