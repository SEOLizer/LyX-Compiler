#!/usr/bin/env bash
# tests/dyn_array_decl_test.sh — #1177: dynamisches Array ohne Initialisierung.
#
# `var a: Array<T>;` blieb NULL. `len(a)` und `a[0]` trafen die Null, und
# `a[0] := 5` schrieb dorthin — Absturz ohne Meldung. Betroffen waren alle drei
# Schreibweisen und jeder Elementtyp; das Ausgangs-Issue (#1109) schrieb den
# Absturz faelschlich dem Struct-Elementtyp zu.
#
# Auffaellig war der Widerspruch im Bestand: `int64[N]` wird seit jeher belegt,
# `var s: S;` seit WP-10d, und `push` legte lazy an — die dynamische
# Schreibweise fiel als einzige heraus.
#
# Entschieden: bei der Deklaration dasselbe leere Array anlegen, das `push`
# sonst beim ersten Aufruf erzeugt (cap=1024, len=0). Abweisen schied aus —
# `var a: int64[]; push(a, 5);` funktioniert nachweislich und wuerde damit
# brechen.
#
# Geprueft wird das VERHALTEN vor dem ersten `push`: `len` muss 0 liefern statt
# abzustuerzen, und ein Schreibzugriff muss ankommen.

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

K='import src.std.io;
type S = struct { v: int64; };'

# --- Alle drei Schreibweisen sind belegt ---------------------------------
out "int64[] ohne Initialisierung" "$K
fn main(): int64 {
    var a: int64[];
    PrintLn(len(a));
    return 0;
}" '0'

out "Array<T> ohne Initialisierung" "$K
fn main(): int64 {
    var b: Array<int64>;
    PrintLn(len(b));
    return 0;
}" '0'

out "array[T] ohne Initialisierung" "$K
fn main(): int64 {
    var c: array[int64];
    PrintLn(len(c));
    return 0;
}" '0'

# Der Elementtyp spielte nie eine Rolle — das Ausgangs-Issue vermutete es.
out "Struct-Elementtyp" "$K
fn main(): int64 {
    var d: Array<S>;
    PrintLn(len(d));
    return 0;
}" '0'

# --- Der Zeiger ist gesetzt, nicht null ----------------------------------
out "Zeiger ist gesetzt" "$K
fn main(): int64 {
    var a: int64[];
    if ((a as int64) != 0) { PrintLn(1); } else { PrintLn(0); }
    return 0;
}" '1'

# --- Schreiben und Lesen vor dem ersten push -----------------------------
out "direkter Schreibzugriff kommt an" "$K
fn main(): int64 {
    var b: Array<int64>;
    b[0] := 7;
    PrintLn(b[0]);
    return 0;
}" '7'

# --- push arbeitet auf demselben Array weiter ----------------------------
# `push` legte bis 1.0.13G selbst an; jetzt findet es den Zeiger gesetzt vor
# und ueberspringt seinen Allokationszweig. Beide Wege muessen dieselbe
# Struktur ergeben.
out "push nach der Deklaration" "$K
fn main(): int64 {
    var a: int64[];
    push(a, 5);
    PrintLn(len(a));
    PrintLn(a[0]);
    return 0;
}" '1
5'

out "mehrfaches push zaehlt hoch" "$K
fn main(): int64 {
    var a: int64[];
    push(a, 1);
    push(a, 2);
    push(a, 3);
    PrintLn(len(a));
    PrintLn(a[2]);
    return 0;
}" '3
3'

# --- Gegenproben ---------------------------------------------------------
# Mit Initialisierung darf NICHT zusaetzlich belegt werden.
out "let mit leerer Liste unveraendert" "$K
fn main(): int64 {
    let a: int64[] = [];
    push(a, 3);
    PrintLn(len(a));
    return 0;
}" '1'

out "Initialisierung mit Werten unveraendert" "$K
fn main(): int64 {
    var b: int64[] = [7, 8, 9];
    PrintLn(len(b));
    PrintLn(b[1]);
    return 0;
}" '3
8'

# Feste Groessen haben ihren eigenen Weg und bleiben unberuehrt.
out "int64[N] unveraendert" "$K
fn main(): int64 {
    var f: int64[4];
    f[0] := 1;
    PrintLn(len(f));
    PrintLn(f[0]);
    return 0;
}" '4
1'

out "S[N] unveraendert" "$K
fn main(): int64 {
    var s: S[2];
    s[1].v := 5;
    PrintLn(len(s));
    PrintLn(s[1].v);
    return 0;
}" '2
5'

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
test "$FAIL" -eq 0
