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
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
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

# match als AUSDRUCK: liefert den Wert des getroffenen Fallrumpfes.
runs "Ausdruck: Literal"        "$PRE fn main(): int64 { var r: int64 := match 2 { case 1 => 10; case 2 => 42; case _ => 0; }; return r; }" 42
runs "Ausdruck: Wildcard"       "$PRE fn main(): int64 { var r: int64 := match 99 { case 1 => 10; case _ => 42; }; return r; }" 42
runs "Ausdruck: Enum"           "$PRE fn main(): int64 { var r: int64 := match C.G { case R => 1; case G => 42; case B => 3; }; return r; }" 42
runs "Ausdruck: direkt return"  "$PRE fn main(): int64 { return match 3 { case 3 => 42; case _ => 0; }; }" 42
runs "Ausdruck: in Arithmetik"  "$PRE fn main(): int64 { var r: int64 := 2 + match 1 { case 1 => 40; case _ => 0; }; return r; }" 42
# Ohne Treffer und ohne Default ist der Wert definiert 0 -- vorher stand dort
# der Rest des letzten Vergleichs.
runs "Ausdruck: kein Treffer=0" "$PRE fn main(): int64 { var r: int64 := match 99 { case 1 => 10; }; return r + 42; }" 42

# --- #1024: Blockrumpf, qualifizierte Enum-Muster, Or mit Bezeichnern -----
# Der Fallrumpf darf ein Block sein. Als AUSDRUCK benutzt liefert er den Wert
# seiner letzten Anweisung, sofern das ein Ausdruck ist — sonst 0.
runs "Blockrumpf, mehrere Anweisungen" "$PRE fn main(): int64 { g_hit := 0; match 2 { case 1 => { set(1); } case 2 => { set(10); set(42); } case _ => { set(9); } } return g_hit; }" 42
runs "Blockrumpf mit Zuweisung"        "$PRE fn main(): int64 { var r: int64 := 0; match 2 { case 2 => { r := 40; r := r + 2; } case _ => { r := 1; } } return r; }" 42
runs "Block als Ausdruck: letzte Anweisung ist der Wert" "$PRE fn main(): int64 { var v: int64 := match 1 { case 1 => { set(1); set(42) } case _ => 0; }; return v; }" 42
runs "Blockrumpf mit Waechter"         "$PRE fn main(): int64 { var r: int64 := 0; match 5 { case 5 if 1 == 1 => { r := 42; } case _ => { r := 1; } } return r; }" 42

# Qualifizierte Enum-Muster: ebnf.md §14 fuehrt EnumPattern = Ident "." Ident.
runs "qualifiziertes Enum-Muster"      "$PRE fn main(): int64 { g_hit := 0; match C.G { case C.R => set(10); case C.G => set(42); case C.B => set(12); } return g_hit; }" 42
runs "qualifiziert und blank gemischt" "$PRE fn main(): int64 { g_hit := 0; match C.B { case R => set(10); case C.B => set(42); case _ => set(9); } return g_hit; }" 42

# Or-Muster mit BEZEICHNERN. Hier stand noch die alte Unterscheidung aus #1020:
# `case R | B` traf ausgerechnet R, weil der Fehlschlagpfad 0 lud und R = 0 ist —
# die rechte Seite traf NIE. Deshalb wird beide Seiten einzeln geprueft.
runs "Or mit Bezeichnern, links"       "$PRE fn main(): int64 { g_hit := 0; match C.R { case R | B => set(42); case _ => set(9); } return g_hit; }" 42
runs "Or mit Bezeichnern, rechts"      "$PRE fn main(): int64 { g_hit := 0; match C.B { case R | B => set(42); case _ => set(9); } return g_hit; }" 42
runs "Or mit Bezeichnern, kein Treffer" "$PRE fn main(): int64 { g_hit := 0; match C.G { case R | B => set(9); case _ => set(42); } return g_hit; }" 42
runs "Or qualifiziert"                 "$PRE fn main(): int64 { g_hit := 0; match C.B { case C.R | C.B => set(42); case _ => set(9); } return g_hit; }" 42

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
