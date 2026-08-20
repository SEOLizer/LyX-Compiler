#!/usr/bin/env bash
# tests/tuple_test.sh — #1088: Tupel in der Schreibweise der Grammatik.
#
# Die Maschinerie war vollständig da — Tupel-Rückgabetyp, Rückgabe zweier
# Werte, Entpacken über `var a, b := f()` —, aber nur in ECKIGEN Klammern
# (`[int64, int64]`). `ebnf.md` §7 (TupleType) und §15 (TupleExpr) schreiben
# RUNDE, und die Dokumentation ebenso. Damit scheiterte jedes Beispiel aus der
# Doku, obwohl die Umsetzung darunter funktionierte.
#
# Beide Formen sind jetzt gültig: die runde als die spezifizierte, die eckige
# weiterhin, weil der Bestand sie benutzt (tests/wp04_tuple_return.lyx).
#
# Geprüft werden alle vier Kombinationen aus Typ- und Ausdrucksform. Ein Test
# nur über die runde Form hätte nicht gezeigt, ob die eckige noch trägt.
#
# NICHT unterstützt und bewusst nicht ergänzt: `var (q, r) := f()` mit
# Klammern. `ebnf.md` §12 (TupleUnpackStmt) schreibt die Form OHNE Klammern
# vor; die geklammerte steht nur in der DokuWiki. Der Test hält das fest,
# damit die Doku die richtige Form übernehmen kann.

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

# --- Alle vier Kombinationen aus Typ- und Ausdrucksform -----------------
out "runder Typ, runder Ausdruck" 'import std.io;
fn dm(a: int64, b: int64): (int64, int64) { return (a / b, a % b); }
fn main(): int64 {
  var q, r := dm(17, 5);
  PrintLn(IntToStr(q)); PrintLn(IntToStr(r));
  return 0;
}' '3
2'

out "runder Typ, eckiger Ausdruck" 'import std.io;
fn dm(a: int64, b: int64): (int64, int64) { return [a / b, a % b]; }
fn main(): int64 {
  var q, r := dm(17, 5);
  PrintLn(IntToStr(q)); PrintLn(IntToStr(r));
  return 0;
}' '3
2'

out "eckiger Typ, runder Ausdruck" 'import std.io;
fn dm(a: int64, b: int64): [int64, int64] { return (a / b, a % b); }
fn main(): int64 {
  var q, r := dm(17, 5);
  PrintLn(IntToStr(q)); PrintLn(IntToStr(r));
  return 0;
}' '3
2'

# Die eckige Form muss weiterlaufen — der Bestand benutzt sie.
out "eckiger Typ, eckiger Ausdruck (Bestand)" 'import std.io;
fn dm(a: int64, b: int64): [int64, int64] { return [a / b, a % b]; }
fn main(): int64 {
  var q, r := dm(17, 5);
  PrintLn(IntToStr(q)); PrintLn(IntToStr(r));
  return 0;
}' '3
2'

# --- Mehr als zwei Elemente ----------------------------------------------
# Die Aufrufkonvention traegt zwei Rueckgabewerte (rax, rdx). Ein groesseres
# Tupel liess sich bisher DEKLARIEREN -- die ueberzaehligen Werte waeren beim
# Aufrufer stillschweigend verlorengegangen, und das Entpacken scheiterte mit
# einer Meldung ueber ein fehlendes `:=`, die die Ursache nicht nannte.
rejects "Tupel mit drei Elementen wird gemeldet" 'import std.io;
fn drei(): (int64, int64, int64) { return (1, 2, 3); }
fn main(): int64 { return 0; }' "mehr als zwei Elementen"

rejects "auch in eckiger Form" 'import std.io;
fn drei(): [int64, int64, int64] { return [1, 2, 3]; }
fn main(): int64 { return 0; }' "mehr als zwei Elementen"

# --- Tupeltyp als Variablentyp und Tupel als Ausdruck --------------------
out "Tupeltyp als Variablentyp" 'import std.io;
fn main(): int64 {
  var t: (int64, int64);
  PrintLn("ok");
  return 0;
}' 'ok'

out "Tupel-Ausdruck ohne Aufruf" 'import std.io;
fn main(): int64 {
  var u := (1, 2);
  PrintLn("ok");
  return 0;
}' 'ok'

# --- Gegenproben ---------------------------------------------------------
# Ein geklammerter Ausdruck OHNE Komma bleibt ein geklammerter Ausdruck —
# ohne diese Probe waere die Tupel-Erkennung womoeglich zu breit.
out "geklammerter Ausdruck bleibt Ausdruck" 'import std.io;
fn main(): int64 {
  var x: int64 := (2 + 3) * 4;
  PrintLn(IntToStr(x));
  return 0;
}' '20'

out "verschachtelte Klammern unveraendert" 'import std.io;
fn f(a: int64): int64 { return a; }
fn main(): int64 {
  PrintLn(IntToStr(f((1 + 2)) * 2));
  return 0;
}' '6'

# Die geklammerte Entpackform ist NICHT spezifiziert (ebnf.md §12 kennt sie
# ohne Klammern) und wird abgewiesen — die DokuWiki fuehrt sie faelschlich.
rejects "geklammerte Entpackform nicht spezifiziert" 'import std.io;
fn dm(a: int64, b: int64): (int64, int64) { return (a / b, a % b); }
fn main(): int64 { var (q, r): (int64, int64) := dm(17, 5); return 0; }' "expected IDENT"

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
