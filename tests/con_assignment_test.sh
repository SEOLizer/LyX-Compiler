#!/usr/bin/env bash
# tests/con_assignment_test.sh — #1132: Zuweisung an eine `con`-Konstante.
#
# `con X: int64 := 10; X := 5;` uebersetzte kommentarlos. Die Pruefung gab es
# nur fuer `let`/`co` ("assignment to let/co binding not allowed") und fuer
# con-PARAMETER — die con-Deklaration selbst fiel durch.
#
# Besonders irrefuehrend war der Unterschied nach Geltungsbereich: eine LOKALE
# `con` liess sich tatsaechlich aendern (die Ausgabe war 5), bei einer GLOBALEN
# verpuffte die Zuweisung, weil der Wert als Immediate im Code steht (Ausgabe
# 10). Derselbe Quelltext tat also je nach Ort etwas anderes, und gemeldet
# wurde nichts.
#
# Geprueft wird, dass der Compiler MELDET — und zwar in beiden
# Geltungsbereichen und fuer jede Form der Zuweisung. Die Gegenproben halten
# fest, dass Lesen weiterhin geht und `var` unberuehrt bleibt.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

fails() { # name, quelltext, erwarteter meldungsteil
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  msg="$("$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)"
  if [ -f "$TMP/c" ]; then echo "FAIL $1: uebersetzt, statt zu melden"; FAIL=$((FAIL+1)); return; fi
  case "$msg" in
    *"$3"*) echo "PASS $1"; PASS=$((PASS+1)) ;;
    *) echo "FAIL $1: Meldung ohne '$3'"; FAIL=$((FAIL+1)) ;;
  esac
}

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    echo "FAIL $1: uebersetzt nicht"; FAIL=$((FAIL+1)); return
  fi
  got="$(timeout 10 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then echo "FAIL $1: ABSTURZ (rc=$rc)"; FAIL=$((FAIL+1)); return; fi
  if [ "$got" = "$3" ]; then echo "PASS $1"; PASS=$((PASS+1))
  else echo "FAIL $1: '$got' erwartet '$3'"; FAIL=$((FAIL+1)); fi
}

K='import src.std.io;'
M="assignment to con constant"

# --- Beide Repros aus dem Issue ------------------------------------------
# Lokal: der Wert aenderte sich tatsaechlich.
fails "Repro lokal" "$K
fn main(): int64 { con X: int64 := 10; X := 5; PrintLn(X); return 0; }" "$M"

# Global: die Zuweisung verpuffte — auch das ist ein Fehler, nur ein leiserer.
fails "Repro global" "$K
con X: int64 := 10;
fn main(): int64 { X := 5; PrintLn(X); return 0; }" "$M"

# --- Jede Form der Zuweisung ---------------------------------------------
fails "zusammengesetzte Zuweisung +=" "$K
fn main(): int64 { con X: int64 := 10; X += 5; PrintLn(X); return 0; }" "$M"

fails "zusammengesetzte Zuweisung -=" "$K
con X: int64 := 10;
fn main(): int64 { X -= 5; PrintLn(X); return 0; }" "$M"

fails "Inkrement ++" "$K
fn main(): int64 { con X: int64 := 10; X++; PrintLn(X); return 0; }" "$M"

fails "Dekrement --" "$K
fn main(): int64 { con X: int64 := 10; X--; PrintLn(X); return 0; }" "$M"

# In einer Schleife oder einem Zweig gilt dasselbe.
fails "Zuweisung im if-Zweig" "$K
fn main(): int64 {
    con X: int64 := 10;
    if (X > 5) { X := 1; }
    PrintLn(X);
    return 0;
}" "$M"

fails "Zuweisung in einer Schleife" "$K
con X: int64 := 10;
fn main(): int64 {
    var i: int64 := 0;
    while (i < 2) { X := i; i := i + 1; }
    PrintLn(X);
    return 0;
}" "$M"

fails "con mit pchar" "$K
fn main(): int64 { con S: pchar := \"a\"c; S := \"b\"c; PrintStrLn(S); return 0; }" "$M"

# --- Gegenproben: Lesen und die uebrigen Speicherklassen -----------------
out "con lesen und rechnen geht weiter" "$K
con X: int64 := 10;
fn main(): int64 { var y: int64 := X + 5; PrintLn(y); PrintLn(X); return 0; }" '15
10'

out "lokale con lesen" "$K
fn main(): int64 { con X: int64 := 7; var y: int64 := X * 2; PrintLn(y); return 0; }" '14'

out "var bleibt zuweisbar" "$K
fn main(): int64 { var v: int64 := 1; v := 2; v += 3; PrintLn(v); return 0; }" '5'

out "globale var bleibt zuweisbar" "$K
var g: int64 := 1;
fn main(): int64 { g := 4; PrintLn(g); return 0; }" '4'

# `let` wird weiterhin mit seiner eigenen Meldung abgewiesen (#1083).
fails "let unveraendert abgewiesen" "$K
fn main(): int64 { let x: int64 := 1; x := 2; PrintLn(x); return 0; }" "assignment to let/co binding"

# Enum-Mitglieder sind ebenfalls Konstanten, werden aber ueber den Typnamen
# angesprochen — der Lesezugriff darf nicht betroffen sein.
out "Enum-Mitglied lesen unveraendert" "$K
enum E { A = 1, B = 2 }
fn main(): int64 { var v: int64 := E.A; v := E.B; PrintLn(v); return 0; }" '2'

# Ein con-PARAMETER hatte schon vorher seine eigene Meldung (WP-AS-13).
fails "con-Parameter unveraendert abgewiesen" "$K
fn F(con p: int64): int64 { p := 5; return p; }
fn main(): int64 { PrintLn(F(1)); return 0; }" "con-parameter"

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
test "$FAIL" -eq 0
