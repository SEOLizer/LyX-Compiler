#!/usr/bin/env bash
# tests/multidim_array_test.sh — #1230.
#
# `[N][M]T` stuerzte bei JEDEM Zugriff ab, lesend wie schreibend, mit und ohne
# Initialisierer: der Belegungszweig legte N Slots zu je 8 Byte an, fuer den
# Elementtyp — der hier selbst ein Array ist — entstand kein Speicher. `m[0]`
# las eine Null und `m[0][0]` indizierte in sie hinein.
#
# Das Layout ist jetzt FLACH: N*M Slots hinter einem {cap,len}-Kopf, `m[i]`
# liefert die Adresse der Zeile. Deshalb prueft dieser Test nicht nur, dass ein
# geschriebener Wert zurueckkommt, sondern auch, dass die NACHBARN unberuehrt
# bleiben — eine falsche Schrittweite faellt sonst nicht auf, solange man nur
# eine einzige Zelle liest.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

out() { # name, quelltext, erwartete ausgabe, [zusaetzliche compileroption]
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! "$LYXC" --std-path="$ROOT" ${4:-} "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    no "$1" "uebersetzt nicht"; return
  fi
  got="$(timeout 30 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then no "$1" "ABSTURZ (rc=$rc)"; return; fi
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1" "'$got' erwartet '$3'"; fi
}

rejects() { # name, quelltext, erwartetes Textstueck der Meldung
  printf '%s\n' "$2" > "$TMP/r.lyx"; rm -f "$TMP/r"
  msg="$("$LYXC" --std-path="$ROOT" "$TMP/r.lyx" -o "$TMP/r" 2>&1)"
  if [ -f "$TMP/r" ]; then no "$1" "uebersetzt, statt zu melden"; return; fi
  case "$msg" in *"$3"*) ok "$1" ;; *) no "$1" "Meldung nennt '$3' nicht: $msg" ;; esac
}

# ── Der Repro aus dem Issue
out "lokales [2][2]int64: schreiben und lesen" 'import std.io;
fn main(): int64 {
    var m: [2][2]int64;
    m[0][0] := 5;
    PrintLn(IntToStr(m[0][0]));
    return 0;
}' "5"

# ── Alle vier Zellen getrennt: eine falsche Schrittweite laesst zwei davon
#    zusammenfallen, was ein Test mit nur einer Zelle nicht sieht.
out "vier Zellen bleiben getrennt" 'import std.io;
fn main(): int64 {
    var m: [2][2]int64;
    m[0][0] := 1; m[0][1] := 2; m[1][0] := 3; m[1][1] := 4;
    PrintLn(IntToStr(m[0][0]));
    PrintLn(IntToStr(m[0][1]));
    PrintLn(IntToStr(m[1][0]));
    PrintLn(IntToStr(m[1][1]));
    return 0;
}' "1
2
3
4"

# ── Das Beispiel aus sprache/arrays.txt (8x8, flaches Layout)
out "8x8-Matrix aus der Doku" 'import std.io;
fn main(): int64 {
    var grid: [8][8]int64;
    grid[3][4] := 99;
    var val: int64 := grid[3][4];
    PrintLn(IntToStr(val));
    PrintLn(IntToStr(grid[4][3]));
    PrintLn(IntToStr(grid[7][7]));
    return 0;
}' "99
0
0"

# ── Nicht quadratisch: N und M duerfen nicht verwechselt werden. Bei [2][5]
#    traefe eine vertauschte Schrittweite ausserhalb der ersten Zeile daneben.
out "nicht quadratisch [2][5]" 'import std.io;
fn main(): int64 {
    var m: [2][5]int64;
    var i: int64 := 0;
    while (i < 2) {
      var j: int64 := 0;
      while (j < 5) { m[i][j] := i * 10 + j; j := j + 1; }
      i := i + 1;
    }
    PrintLn(IntToStr(m[0][4]));
    PrintLn(IntToStr(m[1][0]));
    PrintLn(IntToStr(m[1][4]));
    return 0;
}' "4
10
14"

# ── Auf Modulebene (haengt an #1256: globale Aggregate bekommen echten Speicher)
out "globales [3][4]int64" 'import std.io;
var g: [3][4]int64;
fn W(i: int64, j: int64, v: int64): int64 { g[i][j] := v; return 0; }
fn main(): int64 {
  W(2, 3, 42); W(0, 1, 7);
  PrintLn(IntToStr(g[2][3]));
  PrintLn(IntToStr(g[0][1]));
  PrintLn(IntToStr(g[1][1]));
  return 0;
}' "42
7
0"

# ── Der zweite Index war im Array-Pfad der einzige unbewachte Zugriff. Die
#    Pruefung haengt an --runtime-checks, also wird sie hier angefordert; ohne
#    die Option belegt der Test nichts.
out "zweiter Index wird geprueft" 'import std.io;
fn main(): int64 {
  var m: [2][2]int64;
  var j: int64 := 5;
  m[0][j] := 1;
  PrintLn("nicht erreicht");
  return 0;
}
' "index out of bounds" "--runtime-checks"

# ── Gegenproben
rejects "Zuweisung an eine ganze Zeile wird gemeldet" 'import std.io;
fn main(): int64 {
  var m: [2][2]int64;
  var x: int64 := 1;
  m[0] := x;
  return 0;
}' "ganze Zeile"

rejects "drei Dimensionen werden gemeldet" 'import std.io;
fn main(): int64 {
  var m: [2][2][2]int64;
  return 0;
}' "mehr als zwei Dimensionen"

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
