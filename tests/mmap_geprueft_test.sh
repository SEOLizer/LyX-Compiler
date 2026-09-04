#!/usr/bin/env bash
# #1947: Eine fehlgeschlagene Speicheranforderung muss MELDEN, nicht abstuerzen.
#
# `push(a, x)` fordert Speicher per mmap an — einmal beim Anlegen des Arrays
# (cg_emitEmptyDynArray) und danach bei jedem Wachstumsschritt
# (cg_genArrayPush). Bis 1.1.19B wurde der Rueckgabewert an BEIDEN Stellen
# ungeprueft als Adresse benutzt. Schlug die Anforderung fehl, lief
# `-ENOMEM` (0xFFFFFFFFFFFFFFF4) als Zeiger weiter und der naechste
# Schreibzugriff traf ihn: SIGSEGV, rc 139.
#
# Warum das mehr ist als ein haesslicher Abbruch: der Absturz sagt nichts. Er
# sieht aus wie ein Codegen-Fehler, und genau dafuer wurde er auch gehalten —
# die Fehlschlaege in tests/kurzsprung_test.sh galten lange als flackernd und
# als Folge eines zu knappen Deckels (#1915). Der Deckel loeste sie aus, die
# fehlende Pruefung war die Ursache. Ein groesserer Deckel verschiebt die
# Grenze nur.
#
# GEMESSEN WIRD DIE WIRKUNG, in BEIDE Richtungen:
#   * unter knappem Deckel: definierter Exit und eine Meldung, die den Grund
#     nennt — nicht 139,
#   * mit reichlich Speicher: das Programm rechnet unveraendert richtig.
# Ohne die zweite Haelfte waere der Test auch von einem Compiler erfuellt, der
# jede Anforderung ablehnt.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

echo "--- Fehlgeschlagene Speicheranforderung meldet, statt abzustuerzen (#1947) ---"

# Genug Wachstum, damit die Anforderung unter einem knappen Deckel wirklich
# scheitert: 3 Mio. Eintraege sind 24 MB, und beim Verdoppeln liegen alter und
# neuer Block gleichzeitig.
cat > "$TMP/gross.lyx" <<'EOF'
unit main;
import std.io;
fn main(): int64 {
  var a: Array<int64>;
  var i: int64 := 0;
  while (i < 3000000) { push(a, i); i := i + 1; }
  PrintLn(IntToStr(len(a)));
  return 0;
}
EOF

if ! ( cd "$ROOT" && timeout 180 "$LYXC" --std-path="$ROOT" "$TMP/gross.lyx" -o "$TMP/gross" ) >"$TMP/build.log" 2>&1; then
  nok "das Pruefprogramm uebersetzt nicht"; sed -n '1,5p' "$TMP/build.log"
  echo; echo "Ergebnis: $PASS PASS, $FAIL FAIL"; exit 1
fi

# --- Richtung 1: knapper Deckel → Meldung statt Absturz ----------------------
#
# 30 MB reichen fuer den Programmstart, aber nicht fuer die wachsende Ablage.
aus="$( ulimit -v 30000; timeout 120 "$TMP/gross" 2>&1 >/dev/null )"
rc="$(  ulimit -v 30000; timeout 120 "$TMP/gross" >/dev/null 2>&1; echo $? )"

if [ "$rc" = "139" ]; then
  nok "unter knappem Deckel: Segfault (rc=139) — der Rueckgabewert wird wieder ungeprueft benutzt"
elif [ "$rc" = "0" ]; then
  nok "unter knappem Deckel lief das Programm durch — der Deckel greift nicht, der Test misst nichts"
else
  ok "unter knappem Deckel: definierter Abbruch (rc=$rc), kein Segfault"
fi

if printf '%s' "$aus" | grep -q "Speicheranforderung fehlgeschlagen"; then
  ok "die Meldung nennt den Grund"
else
  nok "keine Meldung ueber die fehlgeschlagene Anforderung (ausgegeben: '$(printf '%s' "$aus" | head -1)')"
fi

# --- Richtung 2: genug Speicher → unveraendert richtig ------------------------
#
# Ohne diese Haelfte waere der Test auch von einem Compiler erfuellt, der jede
# Anforderung ablehnt.
gut="$( ulimit -v 4194304; timeout 120 "$TMP/gross" 2>/dev/null )"
grc="$( ulimit -v 4194304; timeout 120 "$TMP/gross" >/dev/null 2>&1; echo $? )"
if [ "$grc" = "0" ] && [ "$gut" = "3000000" ]; then
  ok "mit reichlich Speicher rechnet dasselbe Programm richtig (3000000)"
else
  nok "mit reichlich Speicher: rc=$grc, Ausgabe '$gut' (erwartet 0 und 3000000)"
fi

# --- Beide Stellen tragen die Pruefung ---------------------------------------
#
# Die Anforderung steht an zwei Stellen: beim Anlegen und beim Wachsen. Fehlt
# sie an einer, faellt genau der eine Pfad wieder stumm aus — die Klasse
# "zweite Stelle nicht nachgezogen".
n="$(grep -c 'cg_emitMmapGeprueft' "$ROOT/src/codegen_x86.lyx")"
if [ "$n" -ge 3 ]; then
  ok "beide Anforderungsstellen rufen die Pruefung (Definition + $((n-1)) Aufrufe)"
else
  nok "nur $((n-1)) Aufrufstelle(n) von cg_emitMmapGeprueft — eine Anforderung bleibt ungeprueft"
fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
