#!/usr/bin/env bash
# tests/bounds_check_test.sh — #1156: Array-Bereichsprüfung.
#
# `--runtime-checks` versprach "Runtime-Assertions (bounds, null, zero)" und
# emittierte für Indizes nichts: `arr[5]` bei `int64[3]` las den Speicher
# hinter dem Array und lief weiter. Der Rückgabewert war Stack-Müll und
# wechselte von Lauf zu Lauf. Eine Option, die Prüfungen zusagt und keine
# erzeugt, begründet Vertrauen, das nichts trägt.
#
# Geprüft wird die AUSFÜHRUNG, nicht die Übersetzung. Ein Test, der nur schaut,
# ob etwas übersetzt, wäre auch vor dieser Änderung grün gewesen.
#
# Jede Prüfung kommt paarweise: der Zugriff ausserhalb muss abbrechen, der
# gültige unverändert durchlaufen. Ohne die Gegenprobe wäre eine Prüfung, die
# IMMER abbricht, ebenso grün. Und weil die Prüfung an einem Schalter hängt,
# wird beides auch OHNE `--runtime-checks` gemessen — sonst bliebe unbemerkt,
# wenn der Schalter gar nichts mehr steuert.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
. "$ROOT/tests/lib/lyxc_guard.sh"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

# Bricht mit der Bereichsmeldung ab, und die Zeile danach kommt nicht mehr.
panics() { # name, flags, quelltext
  printf '%s\n' "$3" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! "$LYXC" $2 --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    echo "FAIL $1: uebersetzt nicht"; FAIL=$((FAIL+1)); return
  fi
  got="$(timeout 10 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "FAIL $1: laeuft durch (rc=0) — nicht geprueft"; FAIL=$((FAIL+1)); return
  fi
  if echo "$got" | grep -q "weiter"; then
    echo "FAIL $1: rechnet nach dem Fehler weiter"; FAIL=$((FAIL+1)); return
  fi
  if echo "$got" | grep -q "index out of bounds"; then
    echo "PASS $1 (bricht ab)"; PASS=$((PASS+1))
  else
    echo "FAIL $1: bricht ab, aber ohne Bereichsmeldung — '$(echo "$got" | tail -1)'"; FAIL=$((FAIL+1))
  fi
}

# Laeuft durch und liefert genau diese Ausgabe.
out() { # name, flags, quelltext, erwartete ausgabe
  printf '%s\n' "$3" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! "$LYXC" $2 --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    echo "FAIL $1: uebersetzt nicht"; FAIL=$((FAIL+1)); return
  fi
  got="$(timeout 10 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then echo "FAIL $1: ABSTURZ (rc=$rc)"; FAIL=$((FAIL+1)); return; fi
  if [ "$got" = "$4" ]; then echo "PASS $1"; PASS=$((PASS+1))
  else echo "FAIL $1: '$got' erwartet '$4'"; FAIL=$((FAIL+1)); fi
}

# Wird schon beim Uebersetzen abgewiesen.
rejects() { # name, quelltext, erwartete meldung
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  got=$("$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)
  if echo "$got" | grep -q "$3"; then echo "PASS $1 (abgewiesen)"; PASS=$((PASS+1))
  else echo "FAIL $1: nicht abgewiesen — '$(echo "$got" | tail -1)'"; FAIL=$((FAIL+1)); fi
}

KOPF='import src.std.io;'

# --- Konstanter Index: schon zur Uebersetzungszeit entscheidbar -----------
# `arr[5]` bei drei Elementen braucht keinen Laufzeitschalter. Bis 1.0.11D
# uebersetzte genau das klaglos.
rejects "konstanter Index hinter dem Ende" "$KOPF
fn main(): int64 {
    let arr: int64[3] = [1, 2, 3];
    PrintLn(arr[5]);
    return 0;
}" "Index liegt ausserhalb"

rejects "konstanter Index, Groesse aus dem Literal" "$KOPF
fn main(): int64 {
    var arr := [1, 2, 3];
    return arr[3];
}" "Index liegt ausserhalb"

rejects "negativer konstanter Index" "$KOPF
fn main(): int64 {
    var arr := [1, 2, 3];
    return arr[0 - 1];
}" "Index liegt ausserhalb"

out "letzter gueltiger konstanter Index" "" "$KOPF
fn main(): int64 {
    var arr := [1, 2, 3];
    PrintLn(arr[2]);
    return 0;
}" '3'

# --- Der Repro aus dem Issue: berechneter Index ---------------------------
LESEN="$KOPF
fn main(): int64 {
    var arr := [1, 2, 3];
    var i: int64 := 5;
    PrintLn(arr[i]);
    PrintLn(\"weiter\");
    return 0;
}"

panics "Repro: Lesen ausserhalb" "--runtime-checks" "$LESEN"

out "Lesen innerhalb bleibt unveraendert" "--runtime-checks" "$KOPF
fn main(): int64 {
    var arr := [1, 2, 3];
    var i: int64 := 1;
    PrintLn(arr[i]);
    return 0;
}" '2'

# --- Schreiben ------------------------------------------------------------
panics "Schreiben ausserhalb" "--runtime-checks" "$KOPF
fn main(): int64 {
    var arr := [1, 2, 3];
    var i: int64 := 7;
    arr[i] := 42;
    PrintLn(\"weiter\");
    return 0;
}"

out "Schreiben innerhalb bleibt unveraendert" "--runtime-checks" "$KOPF
fn main(): int64 {
    var arr := [1, 2, 3];
    var i: int64 := 1;
    arr[i] := 42;
    PrintLn(arr[1]);
    return 0;
}" '42'

# --- Dynamisches Array: Laenge steht im {cap,len}-Kopf --------------------
panics "dynamisches Array, Index hinter der Laenge" "--runtime-checks" "$KOPF
fn main(): int64 {
    let arr: int64[] = [];
    push(arr, 10);
    push(arr, 20);
    var i: int64 := 4;
    PrintLn(arr[i]);
    PrintLn(\"weiter\");
    return 0;
}"

out "dynamisches Array innerhalb bleibt unveraendert" "--runtime-checks" "$KOPF
fn main(): int64 {
    let arr: int64[] = [];
    push(arr, 10);
    push(arr, 20);
    var i: int64 := 1;
    PrintLn(arr[i]);
    return 0;
}" '20'

# --- Die Prueflast haengt am Schalter -------------------------------------
# Ohne --runtime-checks darf NICHT geprueft werden. Ohne diese Gegenprobe
# bliebe unbemerkt, wenn die Prüfung immer laeuft — dann waere die Option
# wieder bedeutungslos, nur in die andere Richtung.
run_ok_no_panic() { # name, flags, quelltext
  printf '%s\n' "$3" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! "$LYXC" $2 --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    echo "FAIL $1: uebersetzt nicht"; FAIL=$((FAIL+1)); return
  fi
  got="$(timeout 10 "$TMP/c" 2>&1)"
  if echo "$got" | grep -q "index out of bounds"; then
    echo "FAIL $1: prueft, obwohl es nicht soll"; FAIL=$((FAIL+1)); return
  fi
  if echo "$got" | grep -q "weiter"; then
    echo "PASS $1 (keine Pruefung, laeuft weiter)"; PASS=$((PASS+1))
  else
    echo "FAIL $1: laeuft nicht bis zum Ende — '$(echo "$got" | tail -1)'"; FAIL=$((FAIL+1))
  fi
}

run_ok_no_panic "ohne --runtime-checks wird nicht geprueft" "" "$LESEN"

# @bounds_check(false) schaltet die Pruefung im Geltungsbereich ab, auch wenn
# --runtime-checks gesetzt ist.
run_ok_no_panic "@bounds_check(false) schaltet ab" "--runtime-checks" "$KOPF
fn main(): int64 {
    @bounds_check(false);
    var arr := [1, 2, 3];
    var i: int64 := 5;
    PrintLn(arr[i]);
    PrintLn(\"weiter\");
    return 0;
}"

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
test "$FAIL" -eq 0
