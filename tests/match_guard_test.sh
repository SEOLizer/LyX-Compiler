#!/usr/bin/env bash
# tests/match_guard_test.sh — #1080: `case _ if <bedingung>` im match.
#
# Ein bedingter Wildcard-Arm wurde vom Parser und von sema angenommen, traf zur
# Laufzeit aber nie — ohne Fehlermeldung, ohne Warnung. Die Ursache lag im
# Codegen: JEDER Wildcard-Arm wurde ans Ende verschoben und in EINEN
# `defaultCaseNode` gelegt. Damit
#
#   * verlor ein bedingter Wildcard gegen jeden späteren konkreten Fall
#     (er wurde ja erst hinter ihm geprüft), und
#   * überschrieb ein zweiter Wildcard den ersten stillschweigend.
#
# Der Test prüft deshalb nicht nur, dass der einfache Repro-Fall stimmt,
# sondern die REIHENFOLGE: welcher Arm bei mehreren passenden trifft. Ein
# reiner Ergebnistest über einen einzigen Arm wäre schon vor dem Fix grün
# gewesen — genau der Fall, den die Arbeitsregeln als wertlos benennen.
#
# Dazu die Gegenproben, ohne die eine zu breite Regel („Wildcard trifft
# immer") unbemerkt bliebe: ein falscher Guard darf NICHT treffen, und der
# unbedingte Wildcard muss weiterhin als letzter Ausweg greifen.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
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

# --- Der Repro aus dem Issue, wörtlich -----------------------------------
out "Repro aus dem Issue" 'import std.io;
fn main(): int64 {
    var x: int64 := 5;
    match (x) {
        case _ if x > 3 => PrintLn("A");
        case _          => PrintLn("B");
    }
    return 0;
}' 'A'

# --- Reihenfolge: welcher Arm gewinnt ------------------------------------
# Der bedingte Wildcard steht VOR dem konkreten Fall und muss ihn schlagen.
# Vor dem Fix gewann der konkrete Fall, weil der Wildcard ans Ende wanderte.
out "bedingter Wildcard vor konkretem Fall" 'import std.io;
fn main(): int64 {
    var x: int64 := 5;
    match (x) {
        case _ if x > 3 => PrintLn("wild");
        case 5          => PrintLn("konkret");
    }
    return 0;
}' 'wild'

# Umgekehrt: der konkrete Fall steht vorn und muss gewinnen.
out "konkreter Fall vor bedingtem Wildcard" 'import std.io;
fn main(): int64 {
    var x: int64 := 5;
    match (x) {
        case 5          => PrintLn("konkret");
        case _ if x > 3 => PrintLn("wild");
    }
    return 0;
}' 'konkret'

# Mehrere bedingte Wildcards: der erste mit wahrer Bedingung trifft.
# Vor dem Fix gingen beide verloren, weil der unbedingte sie überschrieb.
out "mehrere bedingte Wildcards" 'import std.io;
fn main(): int64 {
    var x: int64 := 5;
    match (x) {
        case _ if x > 9 => PrintLn("erster");
        case _ if x > 3 => PrintLn("zweiter");
        case _          => PrintLn("default");
    }
    return 0;
}' 'zweiter'

# --- Gegenproben ---------------------------------------------------------
# Falscher Guard darf nicht treffen; der unbedingte Wildcard fängt auf.
out "falscher Guard faellt durch" 'import std.io;
fn main(): int64 {
    var x: int64 := 2;
    match (x) {
        case _ if x > 3 => PrintLn("guard");
        case _          => PrintLn("default");
    }
    return 0;
}' 'default'

# Einziger Arm, Guard falsch: es darf gar nichts laufen.
out "einziger Arm mit falschem Guard" 'import std.io;
fn main(): int64 {
    var x: int64 := 2;
    PrintLn("vor");
    match (x) { case _ if x > 3 => PrintLn("guard"); }
    PrintLn("nach");
    return 0;
}' 'vor
nach'

# Guard auf konkretem Muster — funktionierte schon vorher und muss es bleiben.
out "Guard auf konkretem Muster" 'import std.io;
fn main(): int64 {
    var x: int64 := 5;
    match (x) {
        case 5 if x > 3 => PrintLn("ja");
        case _          => PrintLn("nein");
    }
    match (x) {
        case 5 if x > 9 => PrintLn("ja");
        case _          => PrintLn("nein");
    }
    return 0;
}' 'ja
nein'

# Unbedingter Wildcard ohne jeden Guard — der Fall aus #1008, der nicht
# zurueckfallen darf.
out "unbedingter Wildcard trifft weiterhin" 'import std.io;
fn main(): int64 {
    var i: int64 := 0;
    while (i < 3) {
        match (i) {
            case 1 => PrintLn("eins");
            case _ => PrintLn("rest");
        }
        i := i + 1;
    }
    return 0;
}' 'rest
eins
rest'

# Der Rumpf des getroffenen Arms laeuft genau einmal, der des anderen gar
# nicht. Der Arm-Rumpf ist ein Ausdruck ODER ein Block (#1024) -- eine
# Zuweisung ist in Lyx kein Ausdruck, sie braucht also die Blockform.
out "nur der getroffene Rumpf laeuft" 'import std.io;
fn main(): int64 {
    var x: int64 := 5;
    var n: int64 := 0;
    match (x) {
        case _ if x > 3 => { n := n + 1; }
        case _          => { n := n + 100; }
    }
    PrintLn(n);
    return 0;
}' '1'

# Guard mit Seiteneffekt: er wird ausgewertet, bis einer trifft -- danach
# nicht mehr. Zaehlt die Auswertungen ueber eine Funktion, prueft also den
# WEG und nicht nur das Ergebnis.
out "Guards werden bis zum Treffer ausgewertet" 'import std.io;
var calls: int64 := 0;
fn probe(v: int64): int64 { calls := calls + 1; return v; }
fn main(): int64 {
    var x: int64 := 5;
    match (x) {
        case _ if probe(0) == 1 => { PrintLn("erster"); }
        case _ if probe(1) == 1 => { PrintLn("zweiter"); }
        case _ if probe(1) == 1 => { PrintLn("dritter"); }
        case _                  => { PrintLn("default"); }
    }
    PrintLn(calls);
    return 0;
}' 'zweiter
2'

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
