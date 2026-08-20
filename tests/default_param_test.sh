#!/usr/bin/env bash
# tests/default_param_test.sh — #1089: Default-Werte für Parameter.
#
# Die Deklaration `fn F(a: int64 = 5)` wurde angenommen, der Aufruf `F()` aber
# mit „falsche Argument-Anzahl" abgewiesen. Die Deklaration machte damit ein
# Angebot, das nie eingelöst wurde.
#
# Bemerkenswert: der Codegen setzte die Defaults längst ein (WP-MEM-05,
# `cgDefFuncNi`). Es war allein die Arity-Prüfung in sema, die den Aufruf schon
# vorher abwies — die Hälfte des Features war da und kam nur nie zum Zug.
#
# Der Test prüft daher das ERGEBNIS des Aufrufs, nicht bloß dass er übersetzt,
# und deckt beide Richtungen ab: weggelassene Argumente müssen den Vorgabewert
# bekommen, zu wenige oder zu viele weiterhin gemeldet werden.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    echo "FAIL $1: uebersetzt nicht"; FAIL=$((FAIL+1)); return
  fi
  got="$(timeout 10 "$TMP/c" 2>&1)"
  if [ "$got" = "$3" ]; then echo "PASS $1"; PASS=$((PASS+1))
  else echo "FAIL $1: '$got' erwartet '$3'"; FAIL=$((FAIL+1)); fi
}

rejects() { # name, quelltext, erwartete meldung
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  got=$("$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)
  if echo "$got" | grep -q "$3"; then echo "PASS $1 (abgewiesen)"; PASS=$((PASS+1))
  else echo "FAIL $1: nicht abgewiesen — '$(echo "$got" | tail -1)'"; FAIL=$((FAIL+1)); fi
}

# --- Der Repro -----------------------------------------------------------
out "Repro: Default wird eingesetzt" 'import std.io;
fn F(a: int64 = 5): int64 { return a; }
fn main(): int64 {
    PrintLn(IntToStr(F()));
    return 0;
}' '5'

out "uebergebenes Argument schlaegt den Default" 'import std.io;
fn F(a: int64 = 5): int64 { return a; }
fn main(): int64 {
    PrintLn(IntToStr(F(9)));
    return 0;
}' '9'

out "Pflichtparameter davor" 'import std.io;
fn G(a: int64, b: int64 = 5): int64 { return a + b; }
fn main(): int64 {
    PrintLn(IntToStr(G(10)));
    PrintLn(IntToStr(G(10, 1)));
    return 0;
}' '15
11'

out "zwei Defaults, einzeln weggelassen" 'import std.io;
fn K(a: int64 = 3, b: int64 = 4): int64 { return a * 10 + b; }
fn main(): int64 {
    PrintLn(IntToStr(K()));
    PrintLn(IntToStr(K(9)));
    PrintLn(IntToStr(K(9, 8)));
    return 0;
}' '34
94
98'

# Ein Default VOR einem Pflichtparameter laesst sich nicht ueberspringen — die
# Mindestzahl bleibt dann die volle. Ohne diesen Fall waere die Zaehlung
# womoeglich zu grosszuegig.
out "Default vor Pflichtparameter, voll besetzt" 'import std.io;
fn H(a: int64 = 1, b: int64): int64 { return a * 10 + b; }
fn main(): int64 {
    PrintLn(IntToStr(H(7, 2)));
    return 0;
}' '72'

rejects "Default vor Pflichtparameter, nicht ueberspringbar" 'import std.io;
fn H(a: int64 = 1, b: int64): int64 { return a * 10 + b; }
fn main(): int64 { PrintLn(IntToStr(H(7))); return 0; }' "falsche Argument-Anzahl"

# --- Die Arity-Pruefung muss weiter greifen ------------------------------
rejects "zu wenige Argumente" 'fn G(a: int64, b: int64 = 5): int64 { return a + b; }
fn main(): int64 { return G(); }' "falsche Argument-Anzahl"

rejects "zu viele Argumente" 'fn G(a: int64, b: int64 = 5): int64 { return a + b; }
fn main(): int64 { return G(1, 2, 3); }' "falsche Argument-Anzahl"

# --- Default-Werte muessen zur Uebersetzungszeit feststehen --------------
# ebnf.md §15.1. Der Codegen wertet den Ausdruck an JEDER Aufrufstelle aus;
# ein nicht-konstanter Default liefe also bei jedem Aufruf erneut, samt
# Seiteneffekten — vor dieser Pruefung lieferten zwei Aufrufe 1 und 2.
rejects "nicht-konstanter Default" 'import std.io;
var n: int64 := 0;
fn zaehl(): int64 { n := n + 1; return n; }
fn F(a: int64 = zaehl()): int64 { return a; }
fn main(): int64 { PrintLn(IntToStr(F())); return 0; }' "zur Uebersetzungszeit feststehen"

# Alle Literalarten und `con` sind zulaessig — sonst waere die Regel zu streng.
out "Literale und con als Default" 'import std.io;
con D: int64 := 7;
fn F(a: int64 = D, s: pchar = "x"c, f: f64 = 1.5, b: bool = true): int64 { return a; }
fn main(): int64 {
    PrintLn(IntToStr(F()));
    return 0;
}' '7'

out "konstanter Ausdruck als Default" 'import std.io;
fn F(a: int64 = 2 * 3 + 1): int64 { return a; }
fn main(): int64 {
    PrintLn(IntToStr(F()));
    return 0;
}' '7'

# --- Gegenprobe: Funktionen ohne Defaults unveraendert -------------------
out "ohne Default unveraendert" 'import std.io;
fn S(a: int64, b: int64): int64 { return a - b; }
fn main(): int64 {
    PrintLn(IntToStr(S(10, 3)));
    return 0;
}' '7'

rejects "ohne Default bleibt Arity streng" 'fn S(a: int64, b: int64): int64 { return a - b; }
fn main(): int64 { return S(10); }' "falsche Argument-Anzahl"

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
