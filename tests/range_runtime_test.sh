#!/usr/bin/env bash
# tests/range_runtime_test.sh — #1097: Bereichstypen zur Laufzeit.
#
# `type X = int64 range LO..HI;` sicherte seit #1082 nur zu, was zur
# ÜBERSETZUNGSZEIT feststand. Berechnete Werte, Parameter, Rückgaben und
# Strukturfelder liefen ungeprüft durch — der Typ versprach mehr, als er hielt.
#
# Der Test prüft die AUSFÜHRUNG, nicht die Übersetzung. Ein Test, der nur
# schaut, ob etwas übersetzt, wäre auch vor dieser Änderung grün gewesen:
# genau das war ja der Befund. Gemessen wird deshalb, ob das Programm mit
# `panic` endet statt weiterzurechnen — erkennbar daran, dass die Zeile NACH
# dem Fehler nicht mehr kommt.
#
# Jeder Eintrittspunkt kommt paarweise: der Wert ausserhalb muss abbrechen,
# der gültige unverändert durchlaufen. Ohne die Gegenprobe wäre eine Prüfung,
# die IMMER abbricht, ebenso grün.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

# Der Wert ausserhalb des Bereichs: das Programm muss abbrechen, die Meldung
# den Typ nennen, und "weiter" darf NICHT mehr erscheinen.
panics() { # name, quelltext
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    echo "FAIL $1: uebersetzt nicht"; FAIL=$((FAIL+1)); return
  fi
  got="$(timeout 10 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "FAIL $1: laeuft durch (rc=0) — nicht geprueft"; FAIL=$((FAIL+1)); return
  fi
  if echo "$got" | grep -q "weiter"; then
    echo "FAIL $1: rechnet nach dem Fehler weiter"; FAIL=$((FAIL+1)); return
  fi
  if echo "$got" | grep -q "Bereichstyp Alt"; then
    echo "PASS $1 (bricht ab: $(echo "$got" | tail -1))"; PASS=$((PASS+1))
  else
    echo "FAIL $1: bricht ab, aber ohne Bereichsmeldung — '$(echo "$got" | tail -1)'"; FAIL=$((FAIL+1))
  fi
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

rejects() { # name, quelltext, erwartete meldung
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  got=$("$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)
  if echo "$got" | grep -q "$3"; then echo "PASS $1 (abgewiesen)"; PASS=$((PASS+1))
  else echo "FAIL $1: nicht abgewiesen — '$(echo "$got" | tail -1)'"; FAIL=$((FAIL+1)); fi
}

KOPF='import std.io;
type Alt = int64 range 0..100;
type P = struct { a: Alt; b: int64; };
type K = class { v: int64; fn Put(x: Alt): int64 { self.v := x; return 0; } fn Get(): Alt { return self.v; } };
var gv: Alt := 0;
fn ausser(): int64 { return 500; }
fn drin(): int64 { return 50; }
fn nimm(x: Alt): int64 { return x; }
fn gib(n: int64): Alt { return n; }'

# --- Der Repro aus dem Issue ---------------------------------------------
panics "Repro: berechneter Wert bei der Initialisierung" "$KOPF
fn main(): int64 {
    var a: Alt := ausser();
    PrintLn(\"weiter\");
    return 0;
}"

out "gueltiger berechneter Wert laeuft durch" "$KOPF
fn main(): int64 {
    var a: Alt := drin();
    PrintLn(IntToStr(a));
    return 0;
}" '50'

# --- Zuweisung, lokal und global -----------------------------------------
panics "Zuweisung an lokale Variable" "$KOPF
fn main(): int64 {
    var a: Alt := 5;
    a := ausser();
    PrintLn(\"weiter\");
    return 0;
}"

out "gueltige Zuweisung laeuft durch" "$KOPF
fn main(): int64 {
    var a: Alt := 5;
    a := drin();
    PrintLn(IntToStr(a));
    return 0;
}" '50'

# Globale Variablen liegen in einer eigenen Tabelle — ohne diesen Fall waere
# das der eine Weg, auf dem die Zusicherung weiter durchfiele.
panics "Zuweisung an globale Variable" "$KOPF
fn main(): int64 {
    gv := ausser();
    PrintLn(\"weiter\");
    return 0;
}"

out "gueltige globale Zuweisung laeuft durch" "$KOPF
fn main(): int64 {
    gv := drin();
    PrintLn(IntToStr(gv));
    return 0;
}" '50'

# --- Parameter und Rueckgabe ---------------------------------------------
panics "Parameter" "$KOPF
fn main(): int64 {
    PrintLn(IntToStr(nimm(ausser())));
    PrintLn(\"weiter\");
    return 0;
}"

out "gueltiger Parameter laeuft durch" "$KOPF
fn main(): int64 {
    PrintLn(IntToStr(nimm(drin())));
    return 0;
}" '50'

panics "Rueckgabe" "$KOPF
fn main(): int64 {
    PrintLn(IntToStr(gib(500)));
    PrintLn(\"weiter\");
    return 0;
}"

out "gueltige Rueckgabe laeuft durch" "$KOPF
fn main(): int64 {
    PrintLn(IntToStr(gib(50)));
    return 0;
}" '50'

# --- Strukturfeld ---------------------------------------------------------
panics "Strukturfeld" "$KOPF
fn main(): int64 {
    var p: P;
    p.a := ausser();
    PrintLn(\"weiter\");
    return 0;
}"

out "gueltiges Strukturfeld laeuft durch" "$KOPF
fn main(): int64 {
    var p: P;
    p.a := drin();
    PrintLn(IntToStr(p.a));
    return 0;
}" '50'

# --- Methoden -------------------------------------------------------------
# Ohne diese Faelle gaelte die Zusicherung fuer freie Funktionen und nicht fuer
# Methoden — eine Zusicherung, die vom Ort der Deklaration abhinge.
panics "Methoden-Parameter" "$KOPF
fn main(): int64 {
    var k: K := new K();
    k.Put(ausser());
    PrintLn(\"weiter\");
    return 0;
}"

panics "Methoden-Rueckgabe" "$KOPF
fn main(): int64 {
    var k: K := new K();
    k.v := 500;
    PrintLn(IntToStr(k.Get()));
    PrintLn(\"weiter\");
    return 0;
}"

out "gueltige Methodenwerte laufen durch" "$KOPF
fn main(): int64 {
    var k: K := new K();
    k.Put(drin());
    PrintLn(IntToStr(k.Get()));
    return 0;
}" '50'

# --- Beide Grenzen, und zwar einschliesslich -----------------------------
# Ohne die Randwerte bliebe offen, ob die Grenzen selbst noch dazugehoeren.
out "LO und HI liegen im Bereich" "$KOPF
fn main(): int64 {
    var lo: Alt := drin() - 50;
    var hi: Alt := drin() + 50;
    PrintLn(IntToStr(lo));
    PrintLn(IntToStr(hi));
    return 0;
}" '0
100'

panics "unterhalb von LO" "$KOPF
fn main(): int64 {
    var a: Alt := drin() - 51;
    PrintLn(\"weiter\");
    return 0;
}"

panics "oberhalb von HI" "$KOPF
fn main(): int64 {
    var a: Alt := drin() + 51;
    PrintLn(\"weiter\");
    return 0;
}"

# Negative Grenzen — der Vergleich muss vorzeichenbehaftet sein. Mit einem
# vorzeichenlosen waere -5 groesser als jede obere Grenze.
out "negative Grenzen" 'import std.io;
type Neg = int64 range -10..-1;
fn w(): int64 { return 0 - 5; }
fn main(): int64 {
    var a: Neg := w();
    PrintLn(IntToStr(a));
    return 0;
}' '-5'

panics2() { # name, quelltext, typname
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    echo "FAIL $1: uebersetzt nicht"; FAIL=$((FAIL+1)); return
  fi
  got="$(timeout 10 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] && echo "$got" | grep -q "Bereichstyp $3" && ! echo "$got" | grep -q "weiter"; then
    echo "PASS $1 (bricht ab)"; PASS=$((PASS+1))
  else
    echo "FAIL $1: rc=$rc '$(echo "$got" | tail -1)'"; FAIL=$((FAIL+1))
  fi
}

panics2 "positiver Wert in negativem Bereich" 'import std.io;
type Neg = int64 range -10..-1;
fn w(): int64 { return 5; }
fn main(): int64 {
    var a: Neg := w();
    PrintLn("weiter");
    return 0;
}' 'Neg'

# --- Die Pruefung aus #1082 bleibt bestehen ------------------------------
# Was schon zur Uebersetzungszeit feststeht, wird weiterhin dort gemeldet und
# nicht erst zur Laufzeit — sonst waere die statische Pruefung verlorengegangen.
rejects "konstanter Wert weiterhin zur Uebersetzungszeit" 'type Alt = int64 range 0..100;
fn main(): int64 { var a: Alt := 500; return 0; }' "ausserhalb des Bereichs"

# --- Gegenproben: gewoehnliche Typen unveraendert ------------------------
out "int64 ohne Bereich unveraendert" 'import std.io;
fn f(): int64 { return 99999; }
fn main(): int64 {
    var a: int64 := f();
    PrintLn(IntToStr(a));
    return 0;
}' '99999'

out "Typalias ohne range unveraendert" 'import std.io;
type Zahl = int64;
fn f(): int64 { return 99999; }
fn main(): int64 {
    var a: Zahl := f();
    PrintLn(IntToStr(a));
    return 0;
}' '99999'

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
