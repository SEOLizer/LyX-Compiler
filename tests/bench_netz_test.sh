#!/usr/bin/env bash
# tests/bench_netz_test.sh — Benchmark 1 bleibt messfaehig und rechnet richtig (#2332).
#
# Benchmark 1 der Suite (Funktionsnetz, work/bench-suite-spezifikation.md)
# vergleicht dieselbe Rechnung in drei DARSTELLUNGEN: generierter Lyx-Code,
# generierter C-Code und ein Auswerter ueber der Funktionstabelle
# (tools/bench_netz_ref.py). Die dritte ist die unabhaengige Referenz — eine
# dritte Uebersetzung desselben Algorithmus waere es nicht.
#
# Geprueft wird in klein (60 Funktionen, 6 Module), weil nur die Gleichheit
# gemessen wird, nicht die Zeit:
#
#   1. Generator schreibt Lyx, C und Spec;
#   2. Lyx == C == Referenz bei wenigen Datensaetzen;
#   3. Lyx == C ueber die volle Datensatzzahl (die Referenz ist dafuer zu
#      langsam — sie deutet jede Funktion einzeln);
#   4. mehrere Module werden wirklich benutzt: der Aufrufgraph geht ueber
#      Modulgrenzen (import netz_k<n> in mindestens einem Modul).
#
# Zeiten prueft dieser Test NICHT. Eine Zeitschwelle im Test ist auf einer
# geteilten Maschine ein Wuerfel; der Nachweis gehoert in bench/ergebnisse/.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

if ! python3 -I "$ROOT/tools/gen_bench_netz.py" -f 60 -m 6 -w 20 -o "$TMP/q" >"$TMP/gen.log" 2>&1; then
  no "Generator" "$(tail -2 "$TMP/gen.log" | tr '\n' ' ')"
  echo "=== Results: $PASS passed, $FAIL failed ==="; exit 1
fi
fehlt=""
for f in netz.lyx netz_h.lyx netz_k0.lyx netz.c netz.h netz_h.c netz_k0.c netz_spec.json; do
  [ -s "$TMP/q/$f" ] || fehlt="$fehlt $f"
done
if [ -n "$fehlt" ]; then no "Generator" "leer oder fehlt:$fehlt"; else ok "Generator schreibt Lyx, C und Spec"; fi

# 4. modulueberschreitender Aufrufgraph — ohne den waere es kein Netz, sondern
#    20 unabhaengige Haufen, und die modulueberschreitende Analyse bliebe
#    ungemessen.
if grep -lq '^import netz_k' "$TMP/q"/netz_k*.lyx 2>/dev/null; then
  ok "Aufrufgraph geht ueber Modulgrenzen"
else
  no "Modulgrenzen" "kein netz_k*.lyx importiert ein anderes Modul"
fi

if ! ( cd "$ROOT" && ulimit -v 8000000 && timeout 600 "$LYXC" --std-path="$ROOT" -I "$TMP/q" "$TMP/q/netz.lyx" -o "$TMP/lyx" ) >"$TMP/lyx.log" 2>&1; then
  no "Lyx-Fassung" "uebersetzt nicht: $(grep -iE 'error|parse' "$TMP/lyx.log" | head -2 | tr '\n' ' ')"
  echo "=== Results: $PASS passed, $FAIL failed ==="; exit 1
fi
ok "Lyx-Fassung uebersetzt (8 Dateien, unit/import)"

if ! gcc -O2 -I "$TMP/q" -o "$TMP/c" "$TMP/q/netz.c" "$TMP/q/netz_h.c" "$TMP/q"/netz_k*.c 2>"$TMP/c.log"; then
  no "C-Fassung" "uebersetzt nicht: $(grep -i error "$TMP/c.log" | head -2 | tr '\n' ' ')"
  echo "=== Results: $PASS passed, $FAIL failed ==="; exit 1
fi

ref="$(timeout 600 python3 -I "$ROOT/tools/bench_netz_ref.py" "$TMP/q/netz_spec.json" 3 | tr '\n' ' ' | sed 's/ *$//')"
l3="$( ulimit -c 0; cd "$TMP" && ./lyx 3 | tr '\n' ' ' | sed 's/ *$//')"
c3="$( ulimit -c 0; cd "$TMP" && ./c   3 | tr '\n' ' ' | sed 's/ *$//')"
if [ -z "$ref" ]; then no "Referenz" "liefert nichts"
elif [ "$ref" = "$l3" ] && [ "$ref" = "$c3" ]; then ok "Lyx == C == Referenz ($ref)"
else no "Pruefsumme klein" "Referenz '$ref', Lyx '$l3', C '$c3'"; fi

l20="$( ulimit -c 0; cd "$TMP" && ./lyx 20 | tr '\n' ' ' | sed 's/ *$//')"
c20="$( ulimit -c 0; cd "$TMP" && ./c   20 | tr '\n' ' ' | sed 's/ *$//')"
if [ "$l20" = "$c20" ] && [ -n "$l20" ]; then ok "Lyx == C ueber 20 Datensaetze ($l20)"
else no "Pruefsumme voll" "Lyx '$l20', C '$c20'"; fi

echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
