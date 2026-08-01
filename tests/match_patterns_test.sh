#!/usr/bin/env bash
# tests/match_patterns_test.sh — Mustervergleich in `match` (Issue #1008).
#
# Zwei Fehler machten `match` praktisch unbrauchbar, obwohl Parser, sema und
# Codegen es alle kannten:
#
#   1. Der Lexer gab `_` nie als TK_UNDER zurueck. Die Pruefung dafuer stand
#      INNERHALB des `len == 3`-Blocks und war damit toter Code -- `_` hat
#      Laenge 1. Der Parser erzeugte deshalb kein Wildcard-Muster, sondern ein
#      Bezeichner-Muster namens "_".
#   2. Im Codegen unterschied der Vergleichszweig Ganzzahl-Literal und
#      Bezeichner an `ival != 0`. Fuer den vermeintlichen Bezeichner "_" fand
#      er nichts, lud 0 und verglich den Wert damit: `case _ =>` traf
#      ausgerechnet nur, wenn der Wert 0 war. Dieselbe Pruefung hielt
#      `case 0 =>` faelschlich fuer einen Bezeichner.
#
# Beides zusammen ergab ein `match`, das nur mit Ganzzahl-Literalen ungleich 0
# funktionierte -- und still das Falsche tat statt zu melden.
#
# Der Test deckt alle unterstuetzten Musterarten ab und prueft dabei, dass die
# RICHTIGE Verzweigung laeuft, nicht nur dass etwas laeuft.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

runs() { # name, quelltext, erwarteter exit
  printf "%s" "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  out=$(cd "$ROOT" && "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)
  if [ ! -f "$TMP/c" ]; then
    no "$1" "compile: $(echo "$out" | grep -iE 'error' | head -1)"; return
  fi
  timeout 5 "$TMP/c" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq "$3" ]; then ok "$1 (=$rc)"; else no "$1" "exit=$rc erwartet $3"; fi
}

# Fallruempfe muessen AUSDRUECKE sein -- eine Zuweisung ist in Lyx keiner.
# Welche Verzweigung lief, wird deshalb ueber einen Funktionsaufruf beobachtet,
# der ein Unit-Global setzt.
PRE='enum C { R, G, B } con SEVEN: int64 := 7; pub var g_hit: int64; fn set(n: int64): int64 { g_hit := n; return n; }'

# Wildcard trifft jeden Wert -- der eigentliche Kern des Fehlers.
runs "Wildcard bei 7"  "$PRE fn main(): int64 { g_hit := 0; match 7 { case 1 => set(1); case _ => set(42); } return g_hit; }" 42
runs "Wildcard bei 0"  "$PRE fn main(): int64 { g_hit := 0; match 0 { case 1 => set(1); case _ => set(42); } return g_hit; }" 42

# Literal 0 muss gegen den Wildcard gewinnen (frueher als Bezeichner behandelt).
runs "Literal 0 schlaegt Wildcard" "$PRE fn main(): int64 { g_hit := 0; match 0 { case 0 => set(42); case _ => set(9); } return g_hit; }" 42

# Enum-Mitglieder und Konstanten werden ueber die Konstantentabelle aufgeloest.
runs "Enum-Mitglied"   "$PRE fn main(): int64 { g_hit := 0; match C.G { case R => set(10); case G => set(42); case B => set(12); } return g_hit; }" 42
runs "Konstante"       "$PRE fn main(): int64 { g_hit := 0; match 7 { case SEVEN => set(42); case _ => set(9); } return g_hit; }" 42

# Guard und Or-Muster.
runs "Guard trifft"        "$PRE fn main(): int64 { g_hit := 0; match 5 { case 5 if 1 == 1 => set(42); case _ => set(9); } return g_hit; }" 42
runs "Guard trifft nicht"  "$PRE fn main(): int64 { g_hit := 0; match 5 { case 5 if 1 == 2 => set(9); case _ => set(42); } return g_hit; }" 42
runs "Or-Muster"           "$PRE fn main(): int64 { g_hit := 0; match 3 { case 1 | 3 => set(42); case _ => set(9); } return g_hit; }" 42

# Ein blankes Bezeichner-Muster, das nichts benennt, ist ein Fehler statt
# stillschweigend nie zu treffen. Bindende Muster gibt es (noch) nicht.
printf 'fn main(): int64 { match 7 { case unbekannt => 1; } return 0; }' > "$TMP/b.lyx"
out=$(cd "$ROOT" && "$LYXC" "$TMP/b.lyx" -o "$TMP/b" 2>&1)
if echo "$out" | grep -q "weder Konstante noch lokale Variable"; then
  ok "unbekanntes Muster wird gemeldet"
else
  no "unbekanntes Muster wird gemeldet" "keine Meldung: $(echo "$out" | tail -1)"
fi

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
