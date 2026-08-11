#!/usr/bin/env bash
# tests/array_decl_test.sh — #1229, #1289 und #1230.
#
# #1229: `var a: int64[4] := [];` stuerzte beim ersten Zugriff ab. Die Ursache
# lag NICHT dort, wo der Bericht sie vermutete: der Zweig, der die Elemente
# eines Array-Literals zaehlt, ueberschreibt die DEKLARIERTE Groesse in
# localArraySize mit der Literal-Laenge — bei `[]` also mit 0 — und setzt die
# Markierung 2 ("feste Groesse", #1155) auf 1 zurueck. Der Belegungszweig
# verlangt aber `> 0` und lief deshalb nicht: es entstand gar kein Speicher,
# rax trug einen beliebigen Wert als Array-Zeiger.
#
# #1289: `append(a, x)` fiel in den Catch-all, der rax nullt — der Abfang vor
# der Argumentauswertung kannte nur `push` und `pop`. Der Kommentar dort sagte
# "should not reach here"; genau das war die falsche Annahme.
#
# #1230: `[N][M]T` legte N Slots zu je 8 Byte an; fuer den Elementtyp, der
# selbst ein Array ist, entstand kein Speicher, und `m[0][0]` indizierte in
# eine Null. Seit 1.0.16G liegt es FLACH (N*M Slots hinter einem
# {cap,len}-Kopf); die Einzelheiten prueft tests/multidim_array_test.sh, hier
# steht nur, dass zwei Dimensionen tragen und die dritte gemeldet wird.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

lyxc_run() { ( ulimit -v $(( 4 * 1024 * 1024 )); timeout 60 "$LYXC" "$@" ); }
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! lyxc_run --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    no "$1" "uebersetzt nicht"; return
  fi
  got="$(timeout 10 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then no "$1" "ABSTURZ (rc=$rc)"; return; fi
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1" "'$got' erwartet '$3'"; fi
}

rejects() { # name, quelltext, erwartete meldung
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  got=$(lyxc_run --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then no "$1" "Exit 0 — nicht abgewiesen"; return; fi
  if echo "$got" | grep -q "$3"; then ok "$1 (abgewiesen)"
  else no "$1" "andere Meldung — '$(echo "$got" | tail -1)'"; fi
}

KOPF='import src.std.io;'

# ===========================================================================
# #1229 — leeres Literal an einem Array fester Groesse
# ===========================================================================

out "leeres Literal: Zugriff nach dem Schreiben" "$KOPF
fn main(): int64 {
    var a: [4]int64 := [];
    a[2] := 7;
    PrintLn(IntToStr(a[2]));
    return 0;
}" "7"

# Reines Lesen traf denselben Nullzeiger — der Fall ist unabhaengig vom
# Schreiben.
out "leeres Literal: reines Lesen" "$KOPF
fn main(): int64 {
    var a: [4]int64 := [];
    PrintLn(IntToStr(a[0]));
    return 0;
}" "0"

# Beide Schreibweisen der festen Groesse.
out "Suffixform int64[4] := []" "$KOPF
fn main(): int64 {
    var a: int64[4] := [];
    a[3] := 5;
    PrintLn(IntToStr(a[3]));
    return 0;
}" "5"

# Gegenproben: die Formen, die schon vorher liefen, bleiben unveraendert.
out "ohne Initialisierer unveraendert" "$KOPF
fn main(): int64 {
    var a: [4]int64;
    a[2] := 7;
    PrintLn(IntToStr(a[2]));
    return 0;
}" "7"

out "gefuelltes Literal unveraendert" "$KOPF
fn main(): int64 {
    var a: [4]int64 := [1,2,3,4];
    PrintLn(IntToStr(a[0]));
    PrintLn(IntToStr(a[3]));
    return 0;
}" "1
4"

# Das dynamische Array mit leerem Literal ist ein ANDERER Fall (#1177) und darf
# sich nicht mitveraendern.
out "dynamisches Array mit leerem Literal" "$KOPF
fn main(): int64 {
    var c: array<int64> := [];
    c.push(9);
    PrintLn(IntToStr(len(c)));
    PrintLn(IntToStr(c[0]));
    return 0;
}" "1
9"

# ===========================================================================
# #1289 — append
# ===========================================================================

out "append haengt an und len zaehlt mit" "$KOPF
fn main(): int64 {
  var a: array<int64> := [];
  append(a, 10);
  append(a, 20);
  PrintLn(IntToStr(len(a)));
  PrintLn(IntToStr(a[0]));
  PrintLn(IntToStr(a[1]));
  return 0;
}" "2
10
20"

# Gegenprobe: push tut weiterhin dasselbe.
out "push unveraendert" "$KOPF
fn main(): int64 {
  var a: array<int64> := [];
  push(a, 7);
  PrintLn(IntToStr(len(a)));
  PrintLn(IntToStr(a[0]));
  return 0;
}" "1
7"

# ===========================================================================
# #1230 — mehrdimensionale Arrays
# ===========================================================================
# Bei der Gegenprobe werden Meldung UND Exit-Code geprueft: ein Compiler, der
# meldet und trotzdem ein Binary hinlegt, waere sonst ebenso gruen.

out "mehrdimensionales Array traegt" "$KOPF
fn main(): int64 {
    var m: [2][2]int64;
    m[0][0] := 5;
    m[1][1] := 7;
    PrintLn(IntToStr(m[0][0]));
    PrintLn(IntToStr(m[1][1]));
    return 0;
}" "5
7"

rejects "drei Dimensionen werden gemeldet" "$KOPF
fn main(): int64 {
    var m: [3][3][3]int64;
    return 0;
}" "mehr als zwei Dimensionen"

# Gegenprobe: eindimensional bleibt erlaubt — sonst waere die Pruefung zu weit
# gefasst.
out "eindimensional bleibt erlaubt" "$KOPF
fn main(): int64 {
    var a: [4]int64;
    a[1] := 3;
    PrintLn(IntToStr(a[1]));
    return 0;
}" "3"

echo
echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
