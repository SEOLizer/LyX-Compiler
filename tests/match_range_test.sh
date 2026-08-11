#!/usr/bin/env bash
# tests/match_range_test.sh — #1113: Bereichsmuster in match (§14).
#
# `case 0..500 =>` scheiterte mit "expected =>, got '..'". Der Ersatz war
# schlecht: eine OR-Liste braeuchte 501 Alternativen, und eine if-Kette nimmt
# `match` genau den Vorteil, fuer den es da ist. Die Bausteine lagen vor — `..`
# ist ein etabliertes Token, und die Grenzenauswertung gibt es seit den
# Bereichstypen (#1082).
#
# Geprueft wird, WELCHER Zweig trifft — an den Grenzen und daneben. Ein Test,
# der nur schaut, ob etwas uebersetzt, wuerde einen Bereich nicht von einem
# Wildcard unterscheiden.
#
# Grenzen sind EINSCHLIESSLICH, wie beim Bereichstyp. Die obere Grenze darf
# fehlen (`case 13001.. =>`); die untere nicht — so steht es in der Produktion
# RangePattern = RangeBound ".." [ RangeBound ].

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
  if ! echo "$got" | grep -q "$3"; then
    echo "FAIL $1: nicht abgewiesen — '$(echo "$got" | grep -iE 'error' | head -1)'"; FAIL=$((FAIL+1)); return
  fi
  echo "PASS $1 (abgewiesen)"; PASS=$((PASS+1))
}

# --- Der Fall aus dem Issue: Klassifikation ueber Zahlenbaender -----------
K='import src.std.io;
fn klass(a: int64): int64 {
    match (a) {
        case 0..500      => { return 1; }
        case 501..3000   => { return 2; }
        case 3001..10000 => { return 3; }
        case 13001..     => { return 9; }
        case _           => { return 0; }
    }
    return 0 - 1;
}'

# Die Grenzen selbst gehoeren dazu: einschliesslich heisst, 500 trifft noch den
# ersten und 501 schon den zweiten Zweig.
out "Repro: Baender samt Grenzen" "$K
fn main(): int64 {
    PrintLn(klass(0));
    PrintLn(klass(500));
    PrintLn(klass(501));
    PrintLn(klass(3000));
    PrintLn(klass(5000));
    return 0;
}" '1
1
2
2
3'

# Eine Luecke zwischen den Baendern faellt an den Wildcard — nicht an den
# naechstliegenden Bereich.
out "Luecke faellt an den Wildcard" "$K
fn main(): int64 {
    PrintLn(klass(12000));
    return 0;
}" '0'

out "offene obere Grenze" "$K
fn main(): int64 {
    PrintLn(klass(13001));
    PrintLn(klass(999999));
    return 0;
}" '9
9'

# --- Vorzeichen -----------------------------------------------------------
out "negative Grenzen" 'import src.std.io;
fn f(a: int64): int64 {
    match (a) {
        case -10..-1 => { return 7; }
        case 0..9    => { return 8; }
        case _       => { return 0; }
    }
    return 0 - 1;
}
fn main(): int64 {
    PrintLn(f(0 - 5));
    PrintLn(f(0 - 10));
    PrintLn(f(0));
    PrintLn(f(0 - 11));
    return 0;
}' '7
7
8
0'

# --- Zusammenspiel mit dem Bestand ---------------------------------------
# Bereich als Alternative eines Or-Musters. Anders als der Gleichheitsvergleich
# braucht ein Bereich zwei Vergleiche; der Treffer-Sprung darf erst fallen,
# wenn beide zusagen.
out "Bereich im Or-Muster" 'import src.std.io;
fn f(a: int64): int64 {
    match (a) {
        case 0..9 | 20..29 => { return 8; }
        case _             => { return 0; }
    }
    return 0 - 1;
}
fn main(): int64 {
    PrintLn(f(5));
    PrintLn(f(25));
    PrintLn(f(15));
    return 0;
}' '8
8
0'

out "Bereich mit Guard" 'import src.std.io;
fn f(a: int64): int64 {
    match (a) {
        case 30..39 if a > 35 => { return 5; }
        case _                => { return 0; }
    }
    return 0 - 1;
}
fn main(): int64 {
    PrintLn(f(37));
    PrintLn(f(31));
    return 0;
}' '5
0'

out "Bereich und Einzelwert nebeneinander" 'import src.std.io;
fn main(): int64 {
    match (42) {
        case 1..10 => { PrintLn(11); }
        case 42    => { PrintLn(42); }
        case _     => { PrintLn(0); }
    }
    return 0;
}' '42'

# match als AUSDRUCK, der haeufigste Anwendungsfall (HTTP-Statusklassen).
out "match als Ausdruck" 'import src.std.io;
fn main(): int64 {
    var s: int64 := 404;
    var k: int64 := match (s) {
        case 100..199 => 1;
        case 200..299 => 2;
        case 300..399 => 3;
        case 400..499 => 4;
        case _        => 0;
    };
    PrintLn(k);
    return 0;
}' '4'

# Bei Ueberschneidung gewinnt der ERSTE Zweig — die Reihenfolge entscheidet,
# wie bei den uebrigen Mustern auch.
out "Ueberschneidung: der erste Zweig gewinnt" 'import src.std.io;
fn main(): int64 {
    match (7) {
        case 0..9 => { PrintLn(1); }
        case 0..9 => { PrintLn(2); }
        case _    => { PrintLn(3); }
    }
    return 0;
}' '1'

# --- Abgewiesen -----------------------------------------------------------
rejects "verdrehte Grenzen" 'fn main(): int64 {
    match (5) {
        case 9..1 => { return 1; }
        case _    => { return 0; }
    }
    return 0;
}' "obere Grenze liegt unter"

# --- Gegenproben ----------------------------------------------------------
# Ein Einzelwert-Muster darf sich nicht wie ein Bereich verhalten.
out "Einzelwert bleibt Einzelwert" 'import src.std.io;
fn main(): int64 {
    match (5) {
        case 4 => { PrintLn(4); }
        case 5 => { PrintLn(5); }
        case 6 => { PrintLn(6); }
        case _ => { PrintLn(0); }
    }
    return 0;
}' '5'

# `..` bleibt ausserhalb von Mustern, was es war — hier als Bereichstyp (#1082).
out "Bereichstyp unberuehrt" 'import src.std.io;
type Alt = int64 range 0..100;
fn main(): int64 {
    var a: Alt := 50;
    PrintLn(a);
    return 0;
}' '50'

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
test "$FAIL" -eq 0
