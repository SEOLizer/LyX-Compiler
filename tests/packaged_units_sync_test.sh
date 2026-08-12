#!/usr/bin/env bash
# tests/packaged_units_sync_test.sh — #1362.
#
# Die Standardbibliothek liegt DOPPELT: als Quelle unter std/ und als Kopie im
# Paketbaum unter lyx-compiler/usr/include/lyx/units/std/. Der Resolver zieht
# .lyx der .lyu vor — eine veraltete Kopie ist deshalb kein Schönheitsfehler,
# sondern liefert dem Benutzer anderen Code als den geprüften.
#
# Genau das ist passiert: #1179 machte die link-Klausel zur Pflicht und zog die
# 33 betroffenen Deklarationen in std/ nach; der Paketbaum blieb stehen. Für
# den ausgelieferten Compiler übersetzten daraufhin 296 von 391 Units nicht
# mehr — `make test` merkte nichts davon, weil es mit --std-path gegen std/
# arbeitet und den Paketbaum nie ansieht.
#
# Dieser Test prüft beides: dass die Kopien mit den Quellen übereinstimmen und
# dass die Kernunits des Paketbaums für sich übersetzen.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
PKG="$ROOT/lyx-compiler/usr/include/lyx/units"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# --- 1. Jede Quelle hat eine Kopie, und sie ist inhaltsgleich -----------------
diffs=0; missing=0
while IFS= read -r f; do
  rel="${f#std/}"
  dst="$PKG/std/$rel"
  if [ ! -f "$dst" ]; then
    missing=$((missing+1)); [ "$missing" -le 3 ] && echo "    fehlt: $rel"
    continue
  fi
  if ! cmp -s "$ROOT/$f" "$dst"; then
    diffs=$((diffs+1)); [ "$diffs" -le 3 ] && echo "    abweichend: $rel"
  fi
done < <(cd "$ROOT" && find std -name "*.lyx" | sort)

if [ "$missing" -eq 0 ]; then ok "jede std/-Quelle hat eine Kopie im Paketbaum"
else no "jede std/-Quelle hat eine Kopie im Paketbaum" "$missing fehlen — 'make sync-units-src'"; fi

if [ "$diffs" -eq 0 ]; then ok "Kopien sind inhaltsgleich mit den Quellen"
else no "Kopien sind inhaltsgleich mit den Quellen" "$diffs abweichend — 'make sync-units-src'"; fi

# --- 2. Der Paketbaum uebersetzt fuer sich ------------------------------------
# Stichprobe statt Vollsweep: die vollstaendige Runde ueber 404 Units dauert
# Minuten. Genommen werden die Wurzeln aus #1362 — std/alloc.lyx reisst den
# groessten Teil der Bibliothek mit — plus die beiden Units, die an der
# pub-Sichtbarkeit von std.os haengen (log, qt5_core).
bad=0
for u in std/alloc.lyx std/io.lyx std/os.lyx std/time.lyx std/fs.lyx std/log.lyx std/qt5_core.lyx std/env.lyx; do
  if [ ! -f "$PKG/$u" ]; then echo "    fehlt: $u"; bad=$((bad+1)); continue; fi
  msg="$(cd "$PKG" && timeout 60 "$LYXC" --compile-unit "$u" -o /tmp/lyx_pkgsync.lyu -I . 2>&1 | grep -iE "(parse error|sema error|codegen error)" | head -1)"
  if [ -n "$msg" ]; then echo "    $u: $msg"; bad=$((bad+1)); fi
done
rm -f /tmp/lyx_pkgsync.lyu
if [ "$bad" -eq 0 ]; then ok "Kernunits des Paketbaums uebersetzen"
else no "Kernunits des Paketbaums uebersetzen" "$bad fehlerhaft"; fi

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
