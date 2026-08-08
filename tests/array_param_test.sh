#!/usr/bin/env bash
# tests/array_param_test.sh — #1115: Array als Funktionsparameter.
#
# Lesen lieferte eine Adresse statt eines Werts, Schreiben kam beim Aufrufer
# nicht an — uebersetzt ohne Meldung. Die Uebergabe selbst war in Ordnung: der
# Aufrufer legt den Zeiger auf die Ablage ins Register. Im Callee fehlte die
# Merkung "das ist ein Array": `localIsArray` blieb 0, weil der Prologue den
# Parametertyp nur fuer NK_TYPE_NAME auswertete und nicht fuer
# NK_TYPE_ARRAY_FIXED. Der Indexzugriff fiel damit in den Zweig fuer einen
# rohen Zeiger.
#
# Im Bestand fiel das nicht auf, weil `std/` und `src/` keinen einzigen
# Array-Parameter verwenden — dort laufen Puffer durchgaengig als
# `int64`-Adresse mit peek/poke.
#
# Geprueft wird der WERT im Callee und die Wirkung beim Aufrufer. Ein Test auf
# Uebersetzbarkeit waere gruen gewesen: uebersetzt wurde immer.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
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

K='import src.std.io;'

# --- Der Repro aus dem Issue: Lesen --------------------------------------
out "Repro: a[0] im Callee" "$K
fn F(a: int64[4]): int64 { return a[0]; }
fn main(): int64 {
    var x: int64[4];
    x[0] := 42;
    PrintLn(F(x));
    return 0;
}" '42'

# Ein anderer Index muss einen anderen Wert liefern — vorher kam dreimal
# dieselbe Adresse, der Index wirkte also gar nicht.
out "verschiedene Indizes, verschiedene Werte" "$K
fn F(a: int64[4]): int64 { return a[0]; }
fn G(a: int64[4]): int64 { return a[1]; }
fn main(): int64 {
    var x: int64[4];
    x[0] := 42; x[1] := 7;
    PrintLn(F(x));
    PrintLn(G(x));
    return 0;
}" '42
7'

out "Index ist selbst Parameter" "$K
fn F(a: int64[4], i: int64): int64 { return a[i]; }
fn main(): int64 {
    var x: int64[4];
    x[2] := 13;
    PrintLn(F(x, 2));
    return 0;
}" '13'

# --- Der Repro aus dem Issue: Schreiben ----------------------------------
# Das Array wird als Zeiger uebergeben, die Zuweisung im Callee muss beim
# Aufrufer sichtbar sein.
out "Repro: Schreiben wirkt beim Aufrufer" "$K
fn F(a: int64[4]): void { a[1] := 99; }
fn main(): int64 {
    var x: int64[4];
    x[1] := 8;
    F(x);
    PrintLn(x[1]);
    return 0;
}" '99'

out "Callee fuellt das ganze Array" "$K
fn Fill(a: int64[4]): void {
    var i: int64 := 0;
    while (i < 4) { a[i] := i * 10; i := i + 1; }
}
fn main(): int64 {
    var x: int64[4];
    Fill(x);
    PrintLn(x[0]);
    PrintLn(x[3]);
    return 0;
}" '0
30'

# --- Die uebrigen Uebergabewege ------------------------------------------
# Methodenparameter laufen durch einen eigenen Prologue.
out "Methodenparameter" "$K
type C = class { n: int64; fn Sum(a: int64[3]): int64 { return a[0] + a[1] + a[2] + self.n; } };
fn main(): int64 {
    var x: int64[3];
    x[0] := 1; x[1] := 2; x[2] := 3;
    var c: C := new C();
    c.n := 10;
    PrintLn(c.Sum(x));
    return 0;
}" '16'

# Ab dem siebten Argument liegen Parameter auf dem Stack — wieder ein eigener
# Weg im Prologue.
out "Array als Stack-Parameter (7. Argument)" "$K
fn many(p1: int64, p2: int64, p3: int64, p4: int64, p5: int64, p6: int64, a: int64[2]): int64 {
    return a[0] + a[1] + p1 + p6;
}
fn main(): int64 {
    var y: int64[2];
    y[0] := 5; y[1] := 6;
    PrintLn(many(1, 0, 0, 0, 0, 2, y));
    return 0;
}" '14'

# Elementtyp struct: der Feldzugriff im Callee braucht die Klasse (#1109).
out "Array von Structs als Parameter" "$K
type S = struct { v: int64; };
fn structs(a: S[2]): int64 { return a[0].v + a[1].v; }
fn main(): int64 {
    var s: S[2];
    s[0].v := 7; s[1].v := 8;
    PrintLn(structs(s));
    return 0;
}" '15'

out "len() im Callee" "$K
fn withLen(a: int64[5]): int64 { return len(a); }
fn main(): int64 {
    var z: int64[5];
    PrintLn(withLen(z));
    return 0;
}" '5'

# --- Zusammenspiel mit der Bereichspruefung (#1156) ----------------------
# Weil die Groesse jetzt am Parameter vermerkt ist, greift sie auch hier.
out "Bereichspruefung greift am Parameter" "$K
fn F(a: int64[3], i: int64): int64 { return a[i]; }
fn main(): int64 {
    var x: int64[3];
    x[0] := 1;
    PrintLn(F(x, 0));
    return 0;
}" '1'

# --- Gegenproben ---------------------------------------------------------
# Ein gewoehnlicher int64-Parameter darf nicht als Array gelten.
out "int64-Parameter bleibt int64" "$K
fn F(a: int64): int64 { return a + 1; }
fn main(): int64 {
    PrintLn(F(41));
    return 0;
}" '42'

# Das lokale Array bleibt unberuehrt.
out "lokales Array unveraendert" "$K
fn main(): int64 {
    var a: int64[3];
    a[0] := 7;
    a[2] := 9;
    PrintLn(a[0]);
    PrintLn(a[2]);
    return 0;
}" '7
9'

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
test "$FAIL" -eq 0
