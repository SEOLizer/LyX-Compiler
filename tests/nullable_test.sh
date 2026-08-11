#!/usr/bin/env bash
# tests/nullable_test.sh — #1092: Safe-Access `?.` und Nullable-Suffix `T?`.
#
# Beides steht in ebnf.md (§15 SafeFieldSuffix, §7 `Type = PrimaryType [ "?" ]`),
# der Lexer unterschied `?.` längst von `?` und `??` — nur der Parser nahm es
# nirgends an.
#
# Beim Nullable-Suffix war die Ursache lehrreich: der Zweig dafür stand am ENDE
# von ParseType, die Zweige für eingebaute, generische und benannte Typen
# kehren aber vorher über den gemeinsamen Ausgang zurück und kamen dort nie an.
# `int64?`, `pchar?` und `A?` scheiterten deshalb ALLE — es sah nach einem
# fehlenden Feature aus, war aber ein nie erreichter Zweig.
#
# Der Test misst beim Safe-Access das, worauf es ankommt: dass bei `null` NICHT
# dereferenziert wird. Die Gegenprobe ohne `?.` muss abstürzen — ohne sie
# bewiese ein grüner Lauf nur, dass irgendetwas herauskommt. Ein Absturz wird
# über den Exit-Code als eigene Kategorie gemeldet.

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
  got="$(timeout 10 "$TMP/c" 2>/dev/null)"; rc=$?
  if [ "$rc" -ge 128 ]; then echo "FAIL $1: ABSTURZ (rc=$rc)"; FAIL=$((FAIL+1)); return; fi
  if [ "$got" = "$3" ]; then echo "PASS $1"; PASS=$((PASS+1))
  else echo "FAIL $1: '$got' erwartet '$3'"; FAIL=$((FAIL+1)); fi
}

crashes() { # name, quelltext  — MUSS abstuerzen
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    echo "FAIL $1: uebersetzt nicht"; FAIL=$((FAIL+1)); return
  fi
  timeout 10 "$TMP/c" >/dev/null 2>&1; rc=$?
  if [ "$rc" -ge 128 ]; then echo "PASS $1 (stuerzt ab, wie erwartet)"; PASS=$((PASS+1))
  else echo "FAIL $1: kein Absturz (rc=$rc) — die Gegenprobe traegt nicht mehr"; FAIL=$((FAIL+1)); fi
}

# --- Safe-Access ---------------------------------------------------------
out "Repro: a?.v bei gesetztem Wert" 'import std.io;
type A = class { v: int64; };
fn main(): int64 {
    var a := new A();
    a.v := 5;
    var x := a?.v;
    PrintLn(IntToStr(x));
    return 0;
}' '5'

# Der eigentliche Zweck: bei null wird NICHT dereferenziert.
out "a?.v bei null liefert null und laeuft weiter" 'import std.io;
type A = class { v: int64; };
fn main(): int64 {
    var a: A := null;
    PrintLn("vor");
    var x := a?.v;
    PrintLn(IntToStr(x));
    PrintLn("nach");
    return 0;
}' 'vor
0
nach'

# Gegenprobe: OHNE `?.` muss derselbe Zugriff abstuerzen. Ohne sie bewiese der
# Test oben nur, dass irgendetwas herauskommt.
crashes "ohne ?. stuerzt der Zugriff ab" 'import std.io;
type A = class { v: int64; };
fn main(): int64 { var a: A := null; PrintLn(IntToStr(a.v)); return 0; }'

# Der Empfaenger wird GENAU EINMAL ausgewertet. Eine Pruefung um den ganzen
# Ausdruck herum haette ihn zweimal berechnet, samt Seiteneffekten.
out "Empfaenger wird einmal ausgewertet" 'import std.io;
type A = class { v: int64; };
var n: int64 := 0;
fn mk(): A { n := n + 1; var a: A := new A(); a.v := 7; return a; }
fn main(): int64 {
    var x := mk()?.v;
    PrintLn(IntToStr(x));
    PrintLn(IntToStr(n));
    return 0;
}' '7
1'

# Verkettung: bricht an der ersten null ab, egal an welcher Stelle.
out "Verkettung bricht an der ersten null ab" 'import std.io;
type B = class { w: int64; };
type A = class { b: B; };
fn main(): int64 {
    var a: A := null;
    PrintLn(IntToStr(a?.b?.w));
    var a2: A := new A();
    a2.b := null;
    PrintLn(IntToStr(a2?.b?.w));
    var a3: A := new A();
    a3.b := new B();
    a3.b.w := 3;
    PrintLn(IntToStr(a3?.b?.w));
    return 0;
}' '0
0
3'

# --- Nullable-Suffix -----------------------------------------------------
out "Nullable-Suffix auf eingebautem Typ" 'import std.io;
fn main(): int64 {
    var x: int64? := null;
    var s: pchar? := null;
    PrintLn("ok");
    return 0;
}' 'ok'

out "Nullable-Suffix auf Benutzertyp" 'import std.io;
type A = class { v: int64; };
fn main(): int64 {
    var a: A? := null;
    PrintLn("ok");
    return 0;
}' 'ok'

out "Nullable-Suffix im Parameter und Rueckgabetyp" 'import std.io;
type A = class { v: int64; };
fn f(a: A?): int64? { return 0; }
fn main(): int64 {
    PrintLn(IntToStr(f(null)));
    return 0;
}' '0'

# --- Gegenproben ---------------------------------------------------------
# `.` und `??` bleiben unveraendert — der Lexer muss die drei ?-Formen
# weiterhin auseinanderhalten.
out "gewoehnlicher Feldzugriff unveraendert" 'import std.io;
type A = class { v: int64; };
fn main(): int64 {
    var a := new A();
    a.v := 4;
    PrintLn(IntToStr(a.v));
    return 0;
}' '4'

out "?? unveraendert" 'import std.io;
fn main(): int64 {
    var a: int64 := 0;
    PrintLn(IntToStr(a ?? 7));
    return 0;
}' '7'

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
