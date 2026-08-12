#!/usr/bin/env bash
# tests/f64_typspur_test.sh — #1373, #1374 (und die Vorgeschichte).
#
# Der Codegen führt eine einzige Stelle, an der er entscheidet, ob ein
# Ausdruck einen Gleitkommawert liefert: cg_isF64Expr. Kennt sie eine
# Knotenart nicht, gilt der Ausdruck als Ganzzahl — `x as int64` gibt dann das
# rohe IEEE-Bitmuster aus, und Arithmetik rechnet auf den Bits.
#
# Dieselbe Lücke ist inzwischen VIERMAL aufgetreten:
#   #905   `as`-Cast          (a as f64) / (b as f64) lief als Integer-Division
#   #1203  Feldzugriff        s.lat as int64 lieferte das Bitmuster
#   #1358  Einheitentyp       utype-Wert galt als int64
#   #1373  globale Variable   \
#   #1374  Array-Element      / beide hier behoben
#
# Deshalb prüft dieser Test nicht nur die zwei gemeldeten Fälle, sondern
# reihum JEDE Knotenart, die einen f64 liefern kann. Kommt eine neue dazu,
# gehört sie hier hinein — dann hört die Serie auf.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/p.lyx"; rm -f "$TMP/p"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p" >/dev/null 2>&1; then
    no "$1" "uebersetzt nicht"; return
  fi
  got="$(timeout 30 "$TMP/p" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then no "$1" "ABSTURZ (rc=$rc)"; return; fi
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1" "'$got' erwartet '$3'"; fi
}

# ===========================================================================
# #1373 — globale f64
# ===========================================================================

out "globale f64 als int64" 'import std.io;
var g: f64 := 2.5;
fn main(): int64 { PrintLn(IntToStr(g as int64)); return 0; }' "2"

out "globale f64 in der Arithmetik" 'import std.io;
var g: f64 := 2.5;
var h: f64 := 1.5;
fn main(): int64 { PrintLn(IntToStr((g + h) as int64)); return 0; }' "4"

# Der Vergleich war schon vorher richtig — und muss es bleiben. Er ist die
# Gegenprobe dafuer, dass hier nicht pauschal alles als f64 gilt.
out "globale int64 bleibt Ganzzahl" 'import std.io;
var n: int64 := 7;
fn main(): int64 { PrintLn(IntToStr(n as int64)); return 0; }' "7"

out "globale f32 zaehlt ebenso" 'import std.io;
var f: f32 := 3.5;
fn main(): int64 { PrintLn(IntToStr(f as int64)); return 0; }' "3"

# ===========================================================================
# #1374 — Array-Element
# ===========================================================================

out "f64-Element aus [N]f64" 'import std.io;
fn main(): int64 {
  var arr: [3]f64;
  arr[0] := 1.5;
  PrintLn(IntToStr(arr[0] as int64));
  return 0;
}' "1"

out "Element und globale zusammen" 'import std.io;
var g: f64 := 2.5;
fn main(): int64 {
  var arr: [3]f64;
  arr[0] := 1.5;
  var s: f64 := arr[0] + g;
  PrintLn(IntToStr(s as int64));
  return 0;
}' "4"

out "Rechnung unmittelbar im Ausdruck" 'import std.io;
var g: f64 := 2.5;
fn main(): int64 {
  var arr: [3]f64;
  arr[0] := 1.5;
  PrintLn(IntToStr((arr[0] * g) as int64));
  return 0;
}' "3"

# Gegenprobe: ein int64-Array darf NICHT als Gleitkomma gelten, sonst waere
# aus dem Fix ein neuer Fehler in der Gegenrichtung geworden.
out "int64-Element bleibt Ganzzahl" 'import std.io;
fn main(): int64 {
  var arr: [3]int64;
  arr[0] := 7;
  PrintLn(IntToStr(arr[0] + 1));
  return 0;
}' "8"

out "f64-Element in einer Schleife" 'import std.io;
fn main(): int64 {
  var arr: [4]f64;
  arr[0] := 1.5; arr[1] := 2.5; arr[2] := 3.0; arr[3] := 0.5;
  var summe: f64 := 0.0;
  for i := 0 to 3 { summe := summe + arr[i]; }
  PrintLn(IntToStr(summe as int64));
  return 0;
}' "7"

# ===========================================================================
# Die frueheren Faelle derselben Luecke — sie muessen richtig bleiben
# ===========================================================================

out "#905: Cast in der Division" 'import std.io;
fn main(): int64 {
  var a: int64 := 7;
  var b: int64 := 2;
  PrintLn(IntToStr(((a as f64) / (b as f64)) as int64));
  return 0;
}' "3"

out "#1203: f64-Feld einer Struktur" 'import std.io;
type P = struct { lat: f64; lon: f64; };
fn main(): int64 {
  var p: P;
  p.lat := 48.5;
  PrintLn(IntToStr(p.lat as int64));
  return 0;
}' "48"

out "#1358: Einheitentyp rechnet ganzzahlig" 'import std.io;
dim Laenge;
utype m: Laenge = 1.0;
fn main(): int64 {
  var d: m := 100;
  PrintLn(IntToStr((d as f64) as int64));
  return 0;
}' "100"

out "lokale f64 (war immer richtig)" 'import std.io;
fn main(): int64 { var x: f64 := 2.5; PrintLn(IntToStr(x as int64)); return 0; }' "2"

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
