#!/usr/bin/env bash
# tests/paket_ohne_quellen_test.sh — #2447 (zuvor packaged_units_sync_test.sh, #1362).
#
# WAS DIESER TEST ERSETZT
#
# Bis #2447 lag die Standardbibliothek DOPPELT: als Quelle unter std/ und als
# .lyx-Kopie im Paketbaum. Weil der Resolver .lyx vor .lyu zieht, waren die
# gepackten Quelltexte funktional massgeblich -- eine veraltete Kopie lieferte
# dem Benutzer anderen Code als den geprueften. Genau das war #1362: #1179
# machte die link-Klausel zur Pflicht und zog die 33 betroffenen Deklarationen
# in std/ nach, der Paketbaum blieb stehen, und fuer das ausgelieferte lyxc
# uebersetzten 296 von 391 Units nicht mehr -- fuer `make test` unsichtbar,
# weil es mit --std-path gegen std/ arbeitet.
#
# Der Vorgaenger pruefte deshalb "jede Quelle hat eine inhaltsgleiche Kopie".
# Diese Frage gibt es nicht mehr: das Paket liefert KEINEN Quellcode aus.
# Geprueft wird jetzt, was an ihre Stelle tritt.
#
#   1. Im Paketbaum liegt kein Quellcode. Eine wieder hineinkopierte .lyx
#      wuerde beim Benutzer gegen die .lyu gewinnen -- die Doppelablage waere
#      zurueck, und mit ihr #1362.
#   2. Die ausgelieferten .lyu gehoeren zum aktuellen Quellstand. Diese Frage
#      ist erst seit #2446 beantwortbar: zweimaliges Vorkompilieren ergibt
#      bytegleiche Dateien (ueber alle 500 Units gemessen), ein Vergleich hat
#      also Aussagekraft. Mit Zeitstempeln ginge es NICHT -- ein Branchwechsel
#      schreibt die Arbeitskopie neu und macht jede mtime wertlos.
#
# Der Umfang von Teil 2 ist eine Stichprobe: ein voller Durchlauf ueber 500
# Units dauert Minuten. Die Vollpruefung macht `make precompile-units`, weil
# dort jede Quelle, die neuer als ihr Vorkompilat ist, neu uebersetzt wird;
# `tools/make_deb.sh` prueft zusaetzlich beim Paketieren.
#
# Die VOLLSTAENDIGKEIT (zu jeder Unit ein .lyu) prueft
# tests/paket_lyu_vollstaendig_test.sh (#2444) -- hier nicht doppelt.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_pp="$(dirname "$0")/lib/paket_pfad.sh"; [ -f "$_pp" ] || _pp="$(dirname "$0")/../lib/paket_pfad.sh"; . "$_pp"   # #2499
PKG="$PKG_UNITS"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

cd "$ROOT" || exit 1
echo "--- #2447: der Paketbaum traegt nur Vorkompilate ---"

# --- 1. Kein Quellcode im Paketbaum ------------------------------------------
quellen="$(find "$PKG" \( -name '*.lyx' -o -name '*.pas' -o -name '*.dpr' \) | head -10)"
if [ -z "$quellen" ]; then
  ok "kein Quellcode im Paketbaum ($(find "$PKG" -name '*.lyu' | wc -l) Vorkompilate)"
else
  no "Quelldateien im Paketbaum" "$(printf '%s ' $quellen | cut -c1-200)"
fi

# Auch im Index, nicht nur auf der Platte: eine eingecheckte Kopie kaeme bei
# jedem anderen wieder hoch, waehrend sie hier nur zufaellig fehlt.
verzeichnet="$(git -C "$ROOT" ls-files 'lyx-compiler/usr/include/lyx/units/*' 2>/dev/null \
               | grep -cE '\.lyx$|\.pas$|\.dpr$' || true)"
if [ "${verzeichnet:-0}" -eq 0 ]; then
  ok "auch im Index steht kein Quellcode des Paketbaums"
else
  no "im Index stehen $verzeichnet Quelldateien des Paketbaums" "git rm sie"
fi

# --- 2. Stichprobe: .lyu stimmt mit der Quelle ueberein ----------------------
# Die Auswahl deckt die Bauformen ab, bei denen ein Unterschied auffallen
# wuerde: viele Symbole (fs), Klassen und Strukturen (string), Konstanten
# (math/constants), Krypto mit @capabilities (sha256), eine Datenunit.
STICH="std/fs.lyx std/io.lyx std/string.lyx std/math/constants.lyx std/crypto/sha256.lyx data/core.lyx"
abw=""; geprueft=0
for f in $STICH; do
  [ -f "$f" ] || { no "Stichprobe" "$f fehlt"; continue; }
  lyu="$PKG/${f%.lyx}.lyu"
  if [ ! -f "$lyu" ]; then no "Stichprobe" "$lyu fehlt (make precompile-units)"; continue; fi
  # #2499: dieselben Schalter wie das Makefile (PKG_OBJCODE) -- sonst
  # vergleicht die Stichprobe eine .lyu MIT Abbild gegen eine OHNE und nennt
  # das einen Unterschied.
  if ! (ulimit -v 4000000; "$LYXC" "$f" $PKG_OBJCODE --compile-unit -o "$TMP/p.lyu" --std-path=.) >"$TMP/l" 2>&1; then
    no "Stichprobe" "$f laesst sich nicht vorkompilieren: $(grep -m1 -i error "$TMP/l" | cut -c1-90)"
    continue
  fi
  geprueft=$((geprueft+1))
  cmp -s "$TMP/p.lyu" "$lyu" || abw="$abw $f"
done
if [ -z "$abw" ] && [ "$geprueft" -gt 0 ]; then
  ok "$geprueft Vorkompilate stimmen byteweise mit ihrer Quelle ueberein"
elif [ -n "$abw" ]; then
  no "Vorkompilat weicht von der Quelle ab:$abw" "make precompile-units"
fi

# --- 3. Gegenprobe: der Vergleich ist scharf ---------------------------------
# Ohne diesen Teil waere Teil 2 auch von einem Vergleich erfuellt, der immer
# gleich sagt (etwa weil der Pfad falsch gebildet wird und beide Seiten
# dieselbe Datei sind).
if (ulimit -v 4000000; "$LYXC" std/url.lyx --compile-unit -o "$TMP/u.lyu" --std-path=.) >"$TMP/l" 2>&1; then
  if cmp -s "$TMP/u.lyu" "$PKG/std/math.lyu"; then
    no "der Vergleich ist blind" "url.lyu und math.lyu gelten als gleich"
  else
    ok "der Vergleich unterscheidet zwei verschiedene Units"
  fi
else
  no "Gegenprobe" "std/url.lyx laesst sich nicht vorkompilieren"
fi

echo
echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
