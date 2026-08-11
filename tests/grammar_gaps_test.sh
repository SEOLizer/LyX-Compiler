#!/usr/bin/env bash
# tests/grammar_gaps_test.sh — #1104: vier Konstrukte, die ebnf.md nicht führte.
#
# Umgekehrte Richtung zu #1084/#1103: dort versprach die Grammatik zu viel,
# hier zu wenig. Weil ebnf.md die maßgebliche Referenz für den Doku-Abgleich
# ist, wird Fehlendes dort fälschlich als Doku-Fehler eingestuft.
#
# Beim Nachmessen fiel auf, dass Punkt 1 des Issues auf einer falschen Prämisse
# stand: Struct-Muster übersetzten zwar, PASSTEN aber immer. Der Melder hatte
# nur den zutreffenden Fall geprüft — der war richtig, und zwar aus dem
# falschen Grund. Genau deshalb steht hier bei jedem Muster auch der Fall,
# der NICHT passen darf.
#
# Der Test hält alle vier Punkte fest, damit die Grammatik nicht wieder von
# der Umsetzung abweicht.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

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

rejects() { # name, quelltext, erwartete meldung
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  got=$("$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)
  if echo "$got" | grep -q "$3"; then echo "PASS $1 (abgewiesen)"; PASS=$((PASS+1))
  else echo "FAIL $1: nicht abgewiesen — '$(echo "$got" | tail -1)'"; FAIL=$((FAIL+1)); fi
}

# --- 1. Struct-Muster (ebnf.md §14) --------------------------------------
# Der Befund: das Muster passte IMMER. Zwei Fehler uebereinander — der Sprung
# bei einem nicht passenden Feld ging auf die naechste Anweisung statt zum
# naechsten Fall, und der Vergleich lief ohnehin nie an (der Parser legt den
# Feldwert als Ausdruck ab, geprueft wurde auf einen Musterknoten).
#
# Deshalb hier drei Faelle mit UNTERSCHIEDLICHEM Ergebnis: ein Test, der nur
# den ersten prueft, ist auch gegen "passt immer" gruen.
out "Repro: Struct-Muster unterscheidet die Faelle" 'import std.io;
type P = struct { t: int64; f: int64; };
fn C(p: P): int64 {
    match (p) {
        case P { t: 1, f: 0 } => { return 10; }
        case P { t: 2, f: 0 } => { return 20; }
        case _                => { return 99; }
    }
}
fn main(): int64 {
    var a: P; a.t := 1; a.f := 0;
    var b: P; b.t := 2; b.f := 0;
    var c: P; c.t := 7; c.f := 7;
    PrintLn(IntToStr(C(a)));
    PrintLn(IntToStr(C(b)));
    PrintLn(IntToStr(C(c)));
    return 0;
}' '10
20
99'

# Ein Muster passt nur, wenn ALLE genannten Felder passen.
out "alle Felder muessen passen" 'import std.io;
type P = struct { t: int64; f: int64; };
fn C(p: P): int64 {
    match (p) {
        case P { t: 1, f: 5 } => { return 1; }
        case _                => { return 0; }
    }
}
fn main(): int64 {
    var a: P; a.t := 1; a.f := 5;
    var b: P; b.t := 1; b.f := 6;
    PrintLn(IntToStr(C(a)));
    PrintLn(IntToStr(C(b)));
    return 0;
}' '1
0'

# `con`, `_` und Bindung als Feldmuster.
out "con, Unterstrich und Bindung im Feldmuster" 'import std.io;
con ZWEI: int64 := 2;
type P = struct { t: int64; f: int64; };
fn C(p: P): int64 {
    match (p) {
        case P { t: ZWEI, f: 0 } => { return 200; }
        case P { t: 1, f: _ }    => { return 100; }
        case P { t: x, f: 9 }    => { return x * 10; }
        case _                   => { return 0; }
    }
}
fn main(): int64 {
    var a: P; a.t := 2; a.f := 0;
    var b: P; b.t := 1; b.f := 77;
    var c: P; c.t := 5; c.f := 9;
    var d: P; d.t := 8; d.f := 8;
    PrintLn(IntToStr(C(a)));
    PrintLn(IntToStr(C(b)));
    PrintLn(IntToStr(C(c)));
    PrintLn(IntToStr(C(d)));
    return 0;
}' '200
100
50
0'

# Ein vertippter Typ- oder Feldname wurde frueher wie ein Wildcard behandelt
# bzw. stillschweigend uebergangen.
rejects "unbekannter Typ im Muster" 'import std.io;
type P = struct { t: int64; };
fn main(): int64 {
    var p: P;
    match (p) { case Q { t: 1 } => { return 1; } case _ => { return 0; } }
}' "type not found"

rejects "unbekanntes Feld im Muster" 'import std.io;
type P = struct { t: int64; };
fn main(): int64 {
    var p: P;
    match (p) { case P { zz: 1 } => { return 1; } case _ => { return 0; } }
}' "unbekanntes Feld im Struktur-Muster"

# Die Asymmetrie aus dem Issue: als MUSTER gueltig, als WERT nicht.
# Festgehalten, damit die Doku sich darauf verlassen kann (§20.1).
rejects "Struct-Literal als Wert bleibt ungueltig" 'import std.io;
type P = struct { t: int64; f: int64; };
fn main(): int64 {
    var p: P := P { t: 1, f: 0 };
    return 0;
}' "expected expression"

# --- 2. and / or / not (ebnf.md §15, §18) --------------------------------
out "and, or, not rechnen richtig" 'import std.io;
fn main(): int64 {
    var t: bool := true;
    var f: bool := false;
    if (t and t) { PrintLn("1"); } else { PrintLn("0"); }
    if (t and f) { PrintLn("1"); } else { PrintLn("0"); }
    if (f or t)  { PrintLn("1"); } else { PrintLn("0"); }
    if (f or f)  { PrintLn("1"); } else { PrintLn("0"); }
    if (not f)   { PrintLn("1"); } else { PrintLn("0"); }
    if (not t)   { PrintLn("1"); } else { PrintLn("0"); }
    return 0;
}' '1
0
1
0
1
0'

# Kurzschluss: gemessen ueber einen Seiteneffekt, nicht ueber das Ergebnis.
# Das Ergebnis waere auch bei vollstaendiger Auswertung richtig.
out "and und or werten kurz aus" 'import std.io;
var n: int64 := 0;
fn Z(): bool { n := n + 1; return true; }
fn main(): int64 {
    var f: bool := false;
    var t: bool := true;
    if (f and Z()) { PrintLn("x"); }
    PrintLn(IntToStr(n));
    if (t or Z()) { PrintLn("or"); }
    PrintLn(IntToStr(n));
    if (t and Z()) { PrintLn("and"); }
    PrintLn(IntToStr(n));
    return 0;
}' '0
or
0
and
1'

# --- 3. public als Synonym fuer pub (ebnf.md §9) -------------------------
out "public an Funktion und Klassenmitglied" 'import std.io;
public fn F(): int64 { return 1; }
type A = class { public v: int64; fn G(): int64 { return self.v; } };
fn main(): int64 {
    var a: A := new A();
    a.v := 5;
    PrintLn(IntToStr(F()));
    PrintLn(IntToStr(a.G()));
    return 0;
}' '1
5'

# --- 4. switch: jeder Zweig endet mit break oder return ------------------
# Die Regel kehrt das Verhalten von C um und stand nirgends in der Grammatik.
rejects "Durchfallender switch-Zweig wird gemeldet" 'import std.io;
fn main(): int64 {
    var x: int64 := 2;
    switch (x) {
        case 1: { PrintLn("eins"); break; }
        case 2: { PrintLn("zwei"); }
        default: { PrintLn("rest"); break; }
    }
    return 0;
}' "may fall through"

out "switch mit break und return unveraendert" 'import std.io;
fn W(x: int64): int64 {
    switch (x) {
        case 1: { return 10; }
        case 2: { PrintLn("zwei"); break; }
        default: { return 99; }
    }
    return 0;
}
fn main(): int64 {
    PrintLn(IntToStr(W(1)));
    PrintLn(IntToStr(W(2)));
    PrintLn(IntToStr(W(5)));
    return 0;
}' '10
zwei
0
99'

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
