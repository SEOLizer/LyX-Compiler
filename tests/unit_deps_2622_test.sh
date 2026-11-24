#!/usr/bin/env bash
# tests/unit_deps_2622_test.sh — zieht eine Quellaenderung die Vorkompilate der
# IMPORTIERENDEN Units nach? (#2622)
#
# WARUM DIESER TEST EXISTIERT. Die Musterregel fuer ein .lyu nannte als
# Abhaengigkeiten nur die eigene .lyx und den Compiler. Nach einer Aenderung an
# std/net/tls13.lyx galten std/net/http.lyu und std/cloud/s3.lyu weiter als
# aktuell; gemessen 2026-11-22 am sha256 gegen einen Neubau
# (http.lyu c08efdc88a559367 eingecheckt gegen 560a9f3f17e56edc frisch). Der
# Waechter aus #2557 nimmt eine Stichprobe von zehn aus ueber 500 Units und traf
# die Drift darum nur gelegentlich -- ein Waechter, der zufaellig zuschlaegt,
# wird als erstes ignoriert.
#
# WAS HIER GEMESSEN WIRD -- die WIRKUNG, nicht das Vorhandensein der Datei:
#   1. die erzeugte Huelle ist dieselbe Menge, die lyxc tatsaechlich oeffnet
#      (Gegenprobe ueber strace, nicht gegen die Erwartung des Erzeugers),
#   2. nach `touch` einer tief importierten Quelle ist das abhaengige .lyu
#      nicht mehr aktuell,
#   3. ein .lyu, das diese Quelle NICHT importiert, bleibt aktuell (sonst
#      waere die Regel bloss eine Rundumabhaengigkeit und der Test gruen,
#      ohne etwas zu belegen).
#
# Vor dem Fix waere 2. rot: ohne build/unit_deps.mk meldet make fuer beide
# Ziele "ist bereits aktuell".
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$ROOT/tests/lib/lyxc_guard.sh"; [ -f "$_g" ] && . "$_g"   # #1294
TMP="$(mktemp -d)"
PASS=0; FAIL=0
ulimit -c 0 2>/dev/null
pr() { if [ "$1" = ok ]; then PASS=$((PASS+1)); echo "PASS $2"; else FAIL=$((FAIL+1)); echo "FAIL $2"; fi; }

TIEF="std/net/tls13.lyx"          # importiert von http, nicht von json
ABH="net/http"                    # importiert tls13 (ueber std.net.tls)
UNABH="json"                      # importiert tls13 nicht
BAUM="lyx-compiler/usr/include/lyx/units/x86_64"

# Quellzeitstempel sichern und am Ende zurueckstellen: ein Test, der die
# Zeitstempel des Arbeitsbaums veraendert zurueckgibt, loest beim naechsten
# Bau Arbeit aus, die niemand angefordert hat.
cp -p "$TIEF" "$TMP/tief.bak"
aufraeumen() { touch -r "$TMP/tief.bak" "$TIEF" 2>/dev/null; rm -rf "$TMP"; }
trap aufraeumen EXIT

# ── 1. Huelle gegen die Wirklichkeit ────────────────────────────────────────
echo "--- erzeugte Huelle gegen die von lyxc geoeffneten Quellen ---"
if ! bash tools/unit_deps.sh > "$TMP/deps.mk" 2>"$TMP/deps.err"; then
  head -5 "$TMP/deps.err" >&2
  pr fail "tools/unit_deps.sh laeuft durch"
else
  pr ok "tools/unit_deps.sh laeuft durch"

  # Jede genannte Abhaengigkeit muss existieren.
  fehlend=0
  while read -r _ziel rest; do
    for q in $rest; do [ -f "$q" ] || { echo "    fehlt: $q"; fehlend=$((fehlend+1)); }; done
  done < <(grep -E '^\$\((UNITS|DATA)_DST\)/' "$TMP/deps.mk" | sed 's/:/ /')
  [ "$fehlend" -eq 0 ] && pr ok "alle genannten Quellen existieren" \
                       || pr fail "$fehlend genannte Quellen existieren nicht"

  if ! command -v strace >/dev/null 2>&1; then
    echo "    (SKIP Gegenprobe: strace fehlt)"
  elif [ ! -x "$LYXC" ]; then
    echo "    (SKIP Gegenprobe: $LYXC fehlt)"
  else
    for u in net/http cloud/s3; do
      soll="$(grep -E "^\\\$\(UNITS_DST\)/$u\.lyu:" "$TMP/deps.mk" \
                | sed 's/^[^:]*://' | tr ' ' '\n' | grep -c '\.lyx$')"
      strace -f -e trace=%file -o "$TMP/st.log" \
        "$LYXC" --std-path=. --with-objcode --compile-unit "std/$u.lyx" \
        -o "$TMP/u.lyu" >/dev/null 2>&1
      # Die eigene Quelle zieht lyxc ebenfalls -- sie steht in der Musterregel
      # und nicht in der Huelle, darum hier abziehen.
      ist="$(grep -oE 'open\("[^"]*\.lyx"' "$TMP/st.log" | sed 's/open("//;s/"//' \
               | sort -u | grep -v "^std/$u\.lyx$" | wc -l)"
      if [ "$soll" = "$ist" ] && [ "$ist" -gt 0 ]; then
        pr ok "std/$u: Huelle $soll == geoeffnete Quellen $ist"
      else
        pr fail "std/$u: Huelle $soll, geoeffnet $ist"
      fi
    done
  fi
fi

# ── 2./3. Wirkung im Bau ────────────────────────────────────────────────────
echo "--- zieht eine Aenderung an $TIEF die Importeure nach? ---"
if [ ! -d "$BAUM" ]; then
  echo "    (SKIP: $BAUM fehlt)"
elif [ ! -s "$BAUM/std/$ABH.lyu" ] || [ ! -s "$BAUM/std/$UNABH.lyu" ]; then
  echo "    (SKIP: Vorkompilate fehlen -- 'make precompile-units' fahren)"
else
  # Ausgangszustand: alle Vorkompilate juenger als Compiler UND Quellen.
  [ -f ./lyxc ] && touch ./lyxc
  sleep 1
  find "$BAUM" -name '*.lyu' -exec touch {} +
  if make -q "$BAUM/std/$ABH.lyu" >/dev/null 2>&1; then
    pr ok "Ausgangszustand: $ABH.lyu ist aktuell"
  else
    pr fail "Ausgangszustand: $ABH.lyu gilt schon vor der Aenderung als veraltet"
  fi

  sleep 1
  touch "$TIEF"
  if make -q "$BAUM/std/$ABH.lyu" >/dev/null 2>&1; then
    pr fail "$ABH.lyu gilt nach Aenderung an $TIEF weiter als aktuell (#2622)"
  else
    pr ok "$ABH.lyu wird nachgezogen"
  fi
  if make -q "$BAUM/std/$UNABH.lyu" >/dev/null 2>&1; then
    pr ok "$UNABH.lyu bleibt aktuell (keine Rundumabhaengigkeit)"
  else
    pr fail "$UNABH.lyu wird mitgezogen, obwohl es $TIEF nicht importiert"
  fi
fi

echo ""
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
