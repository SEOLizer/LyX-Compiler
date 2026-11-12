#!/usr/bin/env bash
# tests/storage_class_test.sh — #1083: Speicherklassen `let` und `co`.
#
# `ebnf.md` §5 kennt drei Speicherklassen: `VarKind = "var" | "let" | "co"`.
# Der Lexer führte `co` als reserviertes Wort, der Parser nahm es aber nirgends
# an — es war damit in BEIDEN Rollen unbrauchbar: nicht als Speicherklasse
# (Parse-Fehler) und, weil reserviert, auch nicht als Bezeichner.
#
# Beim Beheben fiel der Nachbar auf: `let` wurde zwar geparst, band aber gar
# nichts fest. `let a := 3; a := 9;` lief kommentarlos durch und ergab 9 —
# der Schreibschutz stand nur im Namen. examples/basics/variables.lyx führte
# die Zeile sogar als Kommentar mit dem Vermerk „Würde einen Fehler erzeugen!".
#
# Der Test prüft deshalb beide Speicherklassen in beide Richtungen: die
# Deklaration muss funktionieren, und die Zuweisung danach muss gemeldet
# werden — auch die zusammengesetzte (`+=`), die derselbe Knoten ist.
#
# Gegenproben, ohne die eine zu breite Regel unbemerkt bliebe: `var` muss
# weiterhin beschreibbar sein, und die Initialisierung selbst darf nicht als
# Zuweisung gelten.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

runs() { # name, quelltext, erwarteter exit
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    echo "FAIL $1: uebersetzt nicht"; FAIL=$((FAIL+1)); return
  fi
  timeout 10 "$TMP/c" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq "$3" ]; then echo "PASS $1"; PASS=$((PASS+1))
  else echo "FAIL $1: exit=$rc erwartet $3"; FAIL=$((FAIL+1)); fi
}

rejects() { # name, quelltext, erwartete meldung
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  got=$("$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)
  if echo "$got" | grep -q "$3"; then echo "PASS $1 (abgewiesen)"; PASS=$((PASS+1))
  else echo "FAIL $1: nicht abgewiesen — '$(echo "$got" | tail -1)'"; FAIL=$((FAIL+1)); fi
}

# --- co als Speicherklasse -----------------------------------------------
runs "Repro: co als lokale Bindung" 'import std.io;
fn main(): int64 {
    co c: int64 := 3;
    PrintLn(IntToStr(c));
    return c;
}' 3

runs "co auf oberster Ebene" 'co G: int64 := 7;
fn main(): int64 { return G; }' 7

runs "co ohne Typangabe" 'fn main(): int64 {
    co c := 5;
    return c;
}' 5

# --- let und co binden fest ----------------------------------------------
rejects "Zuweisung an co" 'fn main(): int64 {
    co c: int64 := 3;
    c := 9;
    return c;
}' "assignment to let/co binding not allowed"

rejects "Zuweisung an let" 'fn main(): int64 {
    let a: int64 := 3;
    a := 9;
    return a;
}' "assignment to let/co binding not allowed"

# Zusammengesetzte Zuweisung ist derselbe Knoten und muss ebenso greifen.
rejects "zusammengesetzte Zuweisung an let" 'fn main(): int64 {
    let a: int64 := 3;
    a += 1;
    return a;
}' "assignment to let/co binding not allowed"

rejects "zusammengesetzte Zuweisung an co" 'fn main(): int64 {
    co c: int64 := 3;
    c += 1;
    return c;
}' "assignment to let/co binding not allowed"

# --- Gegenproben ---------------------------------------------------------
# var bleibt beschreibbar — sonst wäre die Regel zu breit.
runs "var bleibt beschreibbar" 'fn main(): int64 {
    var v: int64 := 3;
    v := 9;
    v += 1;
    return v;
}' 10

# Die Initialisierung selbst ist keine Zuweisung.
runs "Initialisierung ist keine Zuweisung" 'fn main(): int64 {
    let a: int64 := 3;
    co b: int64 := 4;
    return a + b;
}' 7

# let und co dürfen gelesen werden, so oft man will.
runs "lesender Zugriff bleibt erlaubt" 'fn main(): int64 {
    let a: int64 := 3;
    var s: int64 := 0;
    s := s + a;
    s := s + a;
    return s;
}' 6

# co bleibt reserviert und damit kein Bezeichner — das war vor dem Fix schon so
# und muss so bleiben, sonst wäre die Sprache uneindeutig.
rejects "co bleibt reserviert" 'fn main(): int64 {
    var co: int64 := 1;
    return co;
}' "expected IDENT"

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
