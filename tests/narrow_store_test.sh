#!/usr/bin/env bash
# tests/narrow_store_test.sh — #1266, #1248 und #1274.
#
# Beides waren Speicherkorruption im SCHREIBpfad, und beide Male war der
# Lesepfad laengst richtig — die Asymmetrie hat die Stelle eingegrenzt:
#
# #1266: `p[i] := x` auf einem pchar schrieb 8 Byte an Offset i*8 statt 1 Byte
# an Offset i. `p[0]` belegte damit die Bytes 0-7, `p[1]` die Bytes 8-15.
# std.conv war dadurch unbrauchbar (IntToHex(255,2) ergab "F" statt "FF").
#
# #1248: Ein Feldschreibzugriff emittierte immer `mov [rax+off], rsi` mit
# REX.W, also volle 8 Byte, unabhaengig von der Feldbreite. In einem packed
# struct wurden die Nachbarfelder mitgenullt. Der Lesepfad verschmaelert seit
# #1038 — der Kommentar dort behauptet sogar, das Schreiben beachte die Breite
# "laengst"; genau diese Annahme fehlte.
#
# #1274: Die Aufrufkonvention fuer fn-Zeiger hat sich geaendert (Closure-
# Deskriptor -> direkte Codeadresse, Argumente nach SysV ab rdi). Das ist die
# gewollte Konvention; der Test haelt sie fest, damit ein Rueckfall auffaellt.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
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

KOPF='import src.std.io;'

# ===========================================================================
# #1266 — Indexzuweisung auf pchar
# ===========================================================================
# Gemessen wird der SPEICHER byteweise, nicht das, was der Lesepfad daraus
# macht: der war schon vorher richtig und haette den Fehler verdeckt.

out "p[i] := x schreibt EIN Byte an Offset i" "$KOPF
fn main(): int64 {
  var d: int64 := alloc(32);
  var i: int64 := 0; while (i < 32) { poke8(d+i, 255); i := i + 1; }
  var p: pchar := d as pchar;
  p[0] := 65;
  p[1] := 66;
  var j: int64 := 0;
  while (j < 4) { PrintLn(IntToStr(peek8(d+j))); j := j + 1; }
  return 0;
}" "65
66
255
255"

# Lesen und Schreiben muessen zusammenpassen.
out "geschriebene Zeichen sind wieder lesbar" "$KOPF
fn main(): int64 {
  var d: int64 := alloc(16);
  var p: pchar := d as pchar;
  p[0] := 72; p[1] := 105; p[2] := 0;
  PrintLn(p);
  PrintLn(IntToStr(p[1]));
  return 0;
}" "Hi
105"

# Die praktische Folge: std.conv baut seine Ausgabe ueber p[i] := auf. Vor dem
# Fix lieferte IntToHex(255, 2) den Wert \"F\" statt \"FF\", weil jedes Zeichen
# acht Byte weiter landete.
out "std.conv liefert wieder vollstaendige Zeichenketten" 'import std.io;
import std.conv;
fn main(): int64 {
  PrintLn(IntToHex(255, 2));
  PrintLn(IntToHex(4096, 4));
  return 0;
}' "FF
1000"

# Gegenprobe: ein echtes Array mit 8-Byte-Elementen behaelt die Schrittweite 8.
out "int64-Array behaelt Schrittweite 8" "$KOPF
fn main(): int64 {
  var a: array<int64> := [10, 20, 30];
  a[1] := 99;
  PrintLn(IntToStr(a[0]));
  PrintLn(IntToStr(a[1]));
  PrintLn(IntToStr(a[2]));
  return 0;
}" "10
99
30"

# ===========================================================================
# #1248 — Feldschreibzugriff in packed struct
# ===========================================================================
# Gemessen wird das NACHBARfeld nach dem Schreiben — genau das, was der
# 64-Bit-Schreibzugriff zerstoerte.

out "packed struct: Schreiben zerstoert den Nachbarn nicht" "$KOPF
type S = packed struct { a: int16; b: int8; };
fn main(): int64 {
    var s: S;
    s.b := 64;
    s.a := 20;
    PrintLn(IntToStr(s.b));
    PrintLn(IntToStr(s.a));
    return 0;
}" "64
20"

# Die Gegenrichtung: ein int8-Feld an Offset 0 darf das folgende int16 nicht
# loeschen.
out "packed struct: int8 vor int16" "$KOPF
type T = packed struct { b: int8; a: int16; };
fn main(): int64 {
    var t: T;
    t.a := 20;
    t.b := 64;
    PrintLn(IntToStr(t.a));
    PrintLn(IntToStr(t.b));
    return 0;
}" "20
64"

out "packed struct: int32 neben int8" "$KOPF
type U = packed struct { a: int32; b: int8; };
fn main(): int64 {
    var u: U;
    u.b := 7;
    u.a := 100000;
    PrintLn(IntToStr(u.b));
    PrintLn(IntToStr(u.a));
    return 0;
}" "7
100000"

# Gegenproben: ungepackte Strukturen und int64-Felder bleiben unveraendert.
out "ungepackte struct unveraendert" "$KOPF
type V = struct { a: int16; b: int8; };
fn main(): int64 {
    var v: V;
    v.b := 64;
    v.a := 20;
    PrintLn(IntToStr(v.b));
    PrintLn(IntToStr(v.a));
    return 0;
}" "64
20"

out "int64-Felder unveraendert" "$KOPF
type W = packed struct { a: int64; b: int64; };
fn main(): int64 {
    var w: W;
    w.a := 1234567890123;
    w.b := 42;
    PrintLn(IntToStr(w.a));
    PrintLn(IntToStr(w.b));
    return 0;
}" "1234567890123
42"

# Vorzeichenbehaftete schmale Felder: der Lesepfad erweitert das Vorzeichen,
# der Schreibzugriff darf die Breite nicht ueberschreiten.
out "negativer Wert in schmalem Feld" "$KOPF
type N = packed struct { a: int16; b: int8; };
fn main(): int64 {
    var n: N;
    n.b := 5;
    n.a := 0 - 300;
    PrintLn(IntToStr(n.a));
    PrintLn(IntToStr(n.b));
    return 0;
}" "-300
5"

# ===========================================================================
# #1274 — Aufrufkonvention fuer fn-Zeiger
# ===========================================================================
# Der Wert IST die Codeadresse, die Argumente folgen SysV ab rdi. Der Test
# haelt das fest: zwei Stueck Maschinencode, eines gibt rdi zurueck, das
# andere rsi. Faellt die Konvention auf den Closure-Deskriptor zurueck, liest
# das erste die Umgebung statt arg0 und der Test wird rot.

out "fn-Zeiger: Argumente in rdi und rsi" "$KOPF
fn main(): int64 {
  var b: int64 := mmap(0, 64, 7, 34, -1, 0);
  poke8(b+0, 0x48); poke8(b+1, 0x89); poke8(b+2, 0xF8); poke8(b+3, 0xC3);
  var b2: int64 := mmap(0, 64, 7, 34, -1, 0);
  poke8(b2+0, 0x48); poke8(b2+1, 0x89); poke8(b2+2, 0xF0); poke8(b2+3, 0xC3);
  var f1: fn(int64,int64): int64 := b as fn(int64,int64): int64;
  PrintLn(IntToStr(f1(4369, 8738)));
  var f2: fn(int64,int64): int64 := b2 as fn(int64,int64): int64;
  PrintLn(IntToStr(f2(4369, 8738)));
  return 0;
}" "4369
8738"

# Der Bruch gehoert dokumentiert — ohne den Eintrag findet ihn niemand, der
# von 0.9.x kommt.
if grep -q "Aufrufkonvention für \`fn\`-Zeiger (#1274)" "$ROOT/CHANGELOG.md"; then
  ok "CHANGELOG nennt den Bruch der Aufrufkonvention"
else
  no "CHANGELOG" "Eintrag zu #1274 fehlt"
fi

echo
echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
