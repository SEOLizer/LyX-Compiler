#!/usr/bin/env bash
# tests/lyu_reproduzierbar_test.sh — #2446.
#
# Sobald das Debian-Paket die Standardbibliothek nur noch als .lyu ausliefert
# (#2447), IST die .lyu das Lieferartefakt. Dann muss zweimaliges
# Vorkompilieren derselben Quelle dieselben Bytes ergeben -- sonst laesst sich
# nicht sagen, ob zwei Pakete dieselbe Bibliothek enthalten, und ein
# Paketvergleich ist wertlos. Dasselbe gilt fuer den AUFRUFORT: ein im
# Erzeugnis eingebetteter Aufrufpfad macht den Baurechner zum Bestandteil des
# Pakets.
#
# Gemessen beim Anlegen dieses Tests (lyxc 1.2.34B, alle 500 Units je zweimal):
#
#   zweimal am selben Ort    500 bytegleich, 0 Abweichungen
#   Repo gegen /tmp, absoluter Quellpfad   500 bytegleich, 0 Abweichungen
#
# MIT --debug-symbols war es nicht so: der Debug-Abschnitt (#1555) schrieb den
# Pfad so, wie er auf der Befehlszeile stand -- "std/url.lyx" aus dem Repo
# (4420 Byte) gegen "/home/.../aurum/std/url.lyx" von aussen (4457 Byte),
# Unterschied ab Byte 24. Behoben mit LywPfadOhneWurzel; dieser Test haelt
# beide Formen fest.
#
# Der Umfang ist bewusst begrenzt: eine Auswahl statt aller 500 Units, damit
# das test-Ziel nicht um Minuten waechst. Die Auswahl deckt die Bauformen ab,
# bei denen ein Unterschied entstehen koennte -- Konstanten, Klassen und
# Strukturen, Enums, Ressourcen-API, dazu eine grosse Unit mit vielen
# Symbolen.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

echo "--- #2446: .lyu ist reproduzierbar und ortsunabhaengig ---"

UNITS="std/fs.lyx std/url.lyx std/math.lyx std/res.lyx std/time.lyx std/net/types.lyx"

# --- 1. Zweimal am selben Ort ------------------------------------------------
gleich=0; anders=""
for u in $UNITS; do
  ( cd "$ROOT" && ulimit -v 4000000; "$LYXC" "$u" --compile-unit -o "$TMP/a.lyu" --std-path=. ) >"$TMP/l" 2>&1 \
    || { nok "$u laesst sich nicht vorkompilieren: $(grep -m1 -iE 'error' "$TMP/l" | cut -c1-100)"; continue; }
  ( cd "$ROOT" && ulimit -v 4000000; "$LYXC" "$u" --compile-unit -o "$TMP/b.lyu" --std-path=. ) >"$TMP/l" 2>&1
  if cmp -s "$TMP/a.lyu" "$TMP/b.lyu"; then gleich=$((gleich+1)); else anders="$anders $u"; fi
done
if [ -z "$anders" ]; then
  ok "$gleich Units: zweimal vorkompiliert ergibt dieselben Bytes"
else
  nok "nicht reproduzierbar:$anders"
fi

# --- 2. Anderer Aufrufort, absoluter Quellpfad -------------------------------
# Das ist der Fall, der fuer ein Paket zaehlt: gebaut wird nicht immer aus dem
# Repo heraus.
gleich=0; ortsab=""
for u in $UNITS; do
  ( cd "$ROOT" && ulimit -v 4000000; "$LYXC" "$u" --compile-unit -o "$TMP/a.lyu" --std-path=. ) >"$TMP/l" 2>&1 || continue
  ( cd "$TMP" && ulimit -v 4000000; "$LYXC" "$ROOT/$u" --compile-unit -o "$TMP/c.lyu" --std-path="$ROOT" ) >"$TMP/l" 2>&1 \
    || { nok "$u uebersetzt aus fremdem Verzeichnis nicht: $(grep -m1 -iE 'error' "$TMP/l" | cut -c1-100)"; continue; }
  if cmp -s "$TMP/a.lyu" "$TMP/c.lyu"; then gleich=$((gleich+1)); else ortsab="$ortsab $u"; fi
done
if [ -z "$ortsab" ]; then
  ok "$gleich Units: Ergebnis haengt nicht am Aufrufort"
else
  nok "ortsabhaengig:$ortsab"
fi

# --- 3. Dasselbe MIT --debug-symbols ----------------------------------------
# Hier lag der Defekt. Der Test prueft beides: Bytegleichheit UND dass der
# gespeicherte Pfad die relative Form ist -- waere er leer oder nur der
# Dateiname, waere Teil 3 ebenfalls gruen, und die Angabe im Debug-Abschnitt
# waere nutzlos geworden.
( cd "$ROOT" && ulimit -v 4000000; "$LYXC" std/url.lyx --compile-unit --debug-symbols \
    -o "$TMP/d1.lyu" --std-path=. ) >"$TMP/l" 2>&1
( cd "$TMP" && ulimit -v 4000000; "$LYXC" "$ROOT/std/url.lyx" --compile-unit --debug-symbols \
    -o "$TMP/d2.lyu" --std-path="$ROOT" ) >"$TMP/l" 2>&1
# Und einmal mit Schlussschraegstrich an der Wurzel: daran darf es nicht haengen.
( cd "$TMP" && ulimit -v 4000000; "$LYXC" "$ROOT/std/url.lyx" --compile-unit --debug-symbols \
    -o "$TMP/d3.lyu" --std-path="$ROOT/" ) >"$TMP/l" 2>&1

if cmp -s "$TMP/d1.lyu" "$TMP/d2.lyu" && cmp -s "$TMP/d2.lyu" "$TMP/d3.lyu"; then
  ok "--debug-symbols: ortsunabhaengig, auch mit Schlussschraegstrich an der Wurzel"
else
  nok "--debug-symbols: $(stat -c%s "$TMP/d1.lyu") / $(stat -c%s "$TMP/d2.lyu") / $(stat -c%s "$TMP/d3.lyu") Byte -- der Pfad steckt im Erzeugnis"
fi

# Die Zeichenketten der .lyu sind LAENGENPRAEFIGIERT, nicht nullterminiert --
# `strings` haengt deshalb das Folgebyte an ("std/url.lyxd"). Geprueft wird
# also der Anfang, und zusaetzlich, dass kein absoluter Pfad drinsteht; sonst
# waere die Pruefung auch von "/home/.../std/url.lyx" erfuellt.
gespeichert="$(strings "$TMP/d2.lyu" | grep -m1 'url\.lyx' || true)"
case "$gespeichert" in
  "std/url.lyx"*)
      ok "der Debug-Abschnitt nennt den Pfad relativ zur Bibliothekswurzel" ;;
  *)  nok "Debug-Abschnitt nennt '$gespeichert', erwartet 'std/url.lyx' am Anfang" ;;
esac
if strings "$TMP/d2.lyu" | grep -q "^/"; then
  nok "im Erzeugnis steht ein absoluter Pfad: $(strings "$TMP/d2.lyu" | grep -m1 '^/')"
else
  ok "kein absoluter Pfad im Erzeugnis"
fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
