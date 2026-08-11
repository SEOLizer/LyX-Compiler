#!/usr/bin/env bash
# tests/global_aggregate_test.sh — #1256 und #1299.
#
# Ein Aggregat auf Modulebene — `[N]T` oder ein Struct — bekam bis 1.0.16G
# denselben 8-Byte-Slot wie ein Skalar, und der blieb 0. Die drei Auspraegungen:
#
#   * `q[0] := 3` schrieb nach Adresse 16 (der Lesepfad ueberspringt den
#     {cap,len}-Kopf) und stuerzte ab.
#   * Ein Array-Startwert fiel weg; bis 1.0.15C still, danach als Fehler.
#   * `s.x := 3` verpuffte: ohne Klassenindex war der Feldoffset -1, und die
#     Zuweisung fiel durch alle Schreibzweige, ohne etwas zu tun.
#
# Zwei davon waren STILL — das Programm lief weiter und rechnete mit Nullen.
# Deshalb prueft dieser Test die AUSGABE. tests/run_lyx_suite.sh vergleicht sie
# nicht (siehe #1299): dort war test_global_array gruen, obwohl er 0/0/0 druckte.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
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

# ── #1256.1: Schreiben in ein globales Array (war SIGSEGV)
out "globales Array: schreiben und lesen" 'import std.io;
var q: [8]int64;
fn main(): int64 {
  q[0] := 3; q[7] := 11;
  PrintLn(IntToStr(q[0]));
  PrintLn(IntToStr(q[7]));
  PrintLn(IntToStr(q[3]));
  return 0;
}' "3
11
0"

# ── #1256.2: Startwert eines globalen Arrays (war 0, dann Fehler)
out "globales Array: Startwert steht im Datenbereich" 'import std.io;
var q: [8]int64 := [1,2,3,4,5,6,7,8];
fn main(): int64 {
  PrintLn(IntToStr(q[0]));
  PrintLn(IntToStr(q[2]));
  PrintLn(IntToStr(q[7]));
  return 0;
}' "1
3
8"

# ── #1299: Typ ohne Groessenangabe, Laenge kommt aus dem Literal
out "globales Array-Literal ohne Groessenangabe" 'import std.io;
var arr: array := [10, 20, 30];
fn main(): int64 {
  PrintInt(arr[0]); Print("\n");
  PrintInt(arr[1]); Print("\n");
  PrintInt(arr[2]); Print("\n");
  return 0;
}' "10
20
30"

# ── #1256.3: Schreiben in ein globales Struct (war still wirkungslos)
out "globales Struct: Feld schreiben wirkt" 'import std.io;
type S = struct { x: int64; y: int64; };
var s: S;
pub var t: S;
fn main(): int64 {
  s.x := 3; s.y := 4; t.x := 9;
  PrintLn(IntToStr(s.x));
  PrintLn(IntToStr(s.y));
  PrintLn(IntToStr(t.x));
  PrintLn(IntToStr(t.y));
  return 0;
}' "3
4
9
0"

# Der Typ darf auch WEITER UNTEN stehen — die Groesse muss dann vorgezogen
# werden. Ohne das Vorziehen bekaeme die Variable wieder einen Slot ohne Ziel.
out "globales Struct: Typ erst nach der Variablen deklariert" 'import std.io;
var s: S;
type S = struct { a: int64; b: int64; };
fn main(): int64 { s.b := 42; PrintLn(IntToStr(s.b)); return 0; }' "42"

# ── len() kennt die feste Groesse einer globalen Variablen
out "len eines globalen [N]T" 'import std.io;
var q: [5]int64;
fn main(): int64 { PrintLn(IntToStr(len(q))); return 0; }' "5"

# ── Aus einer Funktion heraus, ueber mehrere Aufrufe hinweg: der Block liegt im
#    Datenbereich, nicht auf dem Stack — der Wert muss den Ruecksprung ueberleben.
out "globales Array haelt den Wert ueber Aufrufe" 'import std.io;
var q: [4]int64;
fn W(i: int64, v: int64): int64 { q[i] := v; return 0; }
fn main(): int64 {
  var i: int64 := 0;
  while (i < 4) { W(i, i * 7); i := i + 1; }
  PrintLn(IntToStr(q[0]));
  PrintLn(IntToStr(q[3]));
  return 0;
}' "0
21"

# ── Gegenproben: was NICHT ausrechenbar ist, wird gemeldet statt still genullt.
rejects "nicht konstantes Element im Startwert wird gemeldet" 'import std.io;
fn f(): int64 { return 1; }
var q: [2]int64 := [f(), 2];
fn main(): int64 { return 0; }' "nicht bekannt"

rejects "zu langer Startwert wird gemeldet" 'import std.io;
var q: [2]int64 := [1, 2, 3];
fn main(): int64 { return 0; }' "mehr Elemente"

# Struct-Elemente eines globalen Arrays sind offen (#1256). Sie muessen
# gemeldet werden — ein Slot mit Nullzeiger saehe sonst aus wie ein Objekt.
rejects "globales Array mit Struct-Elementen wird gemeldet" 'import std.io;
type S = struct { x: int64; };
var q: [2]S;
fn main(): int64 { return 0; }' "noch nicht umgesetzt"

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
