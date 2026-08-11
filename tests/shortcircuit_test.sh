#!/usr/bin/env bash
# tests/shortcircuit_test.sh — Kurzschlussauswertung von && und || (Issue #1023).
#
# Beide Operatoren werteten IMMER beide Seiten aus: der Codegen erzeugte für
# `a && b` keine Verzweigung, sondern wertete a und b zu Werten aus und
# verknüpfte sie danach. Damit lief das übliche Null-Guard-Idiom
#
#     if (p != 0 && deref(p)) { ... }
#
# auch bei `p == 0` in die Dereferenzierung — Segfault. Gefunden beim Bau des
# Paketmanagers lpm, dort an zwei Stellen.
#
# Der Test prüft nicht nur das Ergebnis, sondern ZÄHLT die Auswertungen der
# rechten Seite. Ein reiner Ergebnistest wäre auch ohne Kurzschluss grün
# gewesen — das Ergebnis stimmte ja, nur der Weg dorthin war falsch.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# Liefert "<wert> <anzahl auswertungen der rechten seite>"
probe() { # name, bedingung, erwarteter wert, erwartete auswertungen
  cat > "$TMP/c.lyx" <<EOF
import std.io;
pub var g_n: int64;
fn side(v: int64): int64 { g_n := g_n + 1; return v; }
fn main(): int64 {
  g_n := 0;
  var hit: int64 := 0;
  if ($2) { hit := 1; }
  Print(hit); Print(" "); PrintLn(g_n);
  return 0;
}
EOF
  rm -f "$TMP/c"
  if ! (cd "$ROOT" && "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1); then
    no "$1" "compile fehlgeschlagen"; return
  fi
  got=$(timeout 5 "$TMP/c" 2>&1); rc=$?
  if [ "$rc" -ne 0 ]; then no "$1" "Laufzeit rc=$rc"; return; fi
  want="$3 $4"
  if [ "$got" = "$want" ]; then ok "$1"; else no "$1" "'$got' erwartet '$want'"; fi
}

# --- && ---------------------------------------------------------------
probe "&& linke Seite falsch: rechte NICHT ausgewertet" "0 != 0 && side(1) != 0" 0 0
probe "&& linke Seite wahr: rechte ausgewertet"          "1 != 0 && side(1) != 0" 1 1
probe "&& beide wahr"                                     "1 != 0 && side(1) != 0" 1 1
probe "&& rechte Seite falsch"                            "1 != 0 && side(0) != 0" 0 1

# --- || ---------------------------------------------------------------
probe "|| linke Seite wahr: rechte NICHT ausgewertet"    "1 != 0 || side(1) != 0" 1 0
probe "|| linke Seite falsch: rechte ausgewertet"         "0 != 0 || side(1) != 0" 1 1
probe "|| beide falsch"                                   "0 != 0 || side(0) != 0" 0 1

# --- Verkettung: die dritte Seite darf nicht laufen -------------------
probe "&& dreifach, erste falsch"  "0 != 0 && side(1) != 0 && side(1) != 0" 0 0
probe "|| dreifach, erste wahr"    "1 != 0 || side(1) != 0 || side(1) != 0" 1 0

# --- Der Fall aus dem Issue: Null-Guard vor Dereferenzierung ----------
cat > "$TMP/g.lyx" <<'EOF'
import std.io;
fn deref(p: int64): int64 { return peek8(p); }
fn main(): int64 {
  var p: int64 := 0;
  if (p != 0 && deref(p) == 65) { PrintLn("Zweig genommen"); }
  PrintLn("ueberlebt");
  return 42;
}
EOF
rm -f "$TMP/g"
if (cd "$ROOT" && "$LYXC" --std-path="$ROOT" "$TMP/g.lyx" -o "$TMP/g" >/dev/null 2>&1); then
  timeout 5 "$TMP/g" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 42 ]; then ok "Null-Guard segfaultet nicht"; else no "Null-Guard segfaultet nicht" "exit=$rc"; fi
else
  no "Null-Guard segfaultet nicht" "compile fehlgeschlagen"
fi

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
