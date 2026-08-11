#!/usr/bin/env bash
# tests/dynamic_array_new_test.sh — #1255.
#
# `new T[n]` mit einer erst zur LAUFZEIT bekannten Laenge gab es nicht: `new`
# verlangte eine Klammer, und `array`/`Array<T>` waren zwar deklarierbar, aber
# nie belegbar. Wer eine gerechnete Groesse brauchte, wich auf alloc/poke64 aus.
#
# Die Form fiel danach zunaechst in den Zweig fuer Klasseninstanzen und belegte
# die feste Instanzgroesse von 4096 Byte: ab 512 Elementen schrieb der Zugriff
# hinter die Belegung (SIGSEGV), und der {cap,len}-Kopf blieb leer, weshalb
# `len(a)` still 0 meldete. Beides prueft dieser Test ausdruecklich — eine
# Belegung, die nur fuer kleine n stimmt, sieht sonst gesund aus.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
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

# ── Der Repro aus dem Issue: die Laenge steht in einer Variablen.
out "new int64[n] mit Laufzeitlaenge" 'import std.io;
fn main(): int64 {
  var n: int64 := 4;
  var a: array := new int64[n];
  a[0] := 7; a[3] := 9;
  PrintLn(IntToStr(a[0]));
  PrintLn(IntToStr(a[3]));
  return 0;
}' "7
9"

# ── Die Laenge kommt aus einem Aufruf: nichts davon ist zur Uebersetzungszeit
#    bekannt, der Kopf muss also zur Laufzeit entstehen.
out "gerechnete Laenge, alle Elemente getrennt" 'import std.io;
fn size(k: int64): int64 { return k * 3 + 1; }
fn main(): int64 {
  var n: int64 := size(5);
  var a: array := new int64[n];
  var i: int64 := 0;
  while (i < n) { a[i] := i * i; i := i + 1; }
  var bad: int64 := 0;
  i := 0;
  while (i < n) { if (a[i] != i * i) { bad := 1; } i := i + 1; }
  PrintLn(IntToStr(bad));
  return 0;
}' "0"

# ── `len(a)` liest [rax+8]. Blieb der Kopf leer, meldete es still 0 — der Fall
#    faellt ohne diese Pruefung nirgends auf.
out "len liest die Laenge aus dem Kopf" 'import std.io;
fn main(): int64 {
  var n: int64 := 16;
  var a: array := new int64[n];
  PrintLn(IntToStr(len(a)));
  return 0;
}' "16"

# ── Ueber 512 Elemente: genau hier endete die feste 4096-Byte-Belegung.
out "2000 Elemente sprengen die alte Festgroesse nicht mehr" 'import std.io;
fn main(): int64 {
  var n: int64 := 2000;
  var a: array := new int64[n];
  var i: int64 := 0;
  while (i < n) { a[i] := i; i := i + 1; }
  PrintLn(IntToStr(a[1999]));
  PrintLn(IntToStr(len(a)));
  return 0;
}' "1999
2000"

# ── Die dynamische Schranke liest dieselbe Laenge. Ohne Kopf waere sie 0
#    gewesen und haette JEDEN Zugriff abgewiesen.
out "gueltiger Index mit --runtime-checks bleibt zulaessig" 'import std.io;
fn main(): int64 {
  var n: int64 := 3;
  var a: array := new int64[n];
  var i: int64 := 2;
  a[i] := 42;
  PrintLn(IntToStr(a[i]));
  return 0;
}' "42" "--runtime-checks"

out "Index hinter dem Ende wird gemeldet" 'import std.io;
fn main(): int64 {
  var n: int64 := 3;
  var a: array := new int64[n];
  var i: int64 := 5;
  PrintLn(IntToStr(a[i]));
  return 0;
}' "index out of bounds" "--runtime-checks"

# ── n <= 0 waere ein leeres oder negatives mmap: es scheitert, liefert -errno,
#    und der Kopf-Schreibzugriff darauf stuerzt ab. Melden statt danebentreffen.
out "Laenge 0 wird zur Laufzeit gemeldet" 'import std.io;
fn main(): int64 {
  var n: int64 := 0;
  var a: array := new int64[n];
  PrintLn("nicht erreicht");
  return 0;
}' "new T[n]: Laenge muss > 0 sein"

out "negative Laenge wird zur Laufzeit gemeldet" 'import std.io;
fn main(): int64 {
  var n: int64 := 0 - 7;
  var a: array := new int64[n];
  PrintLn("nicht erreicht");
  return 0;
}' "new T[n]: Laenge muss > 0 sein"

# ── Gegenprobe: `new T()` darf davon unberuehrt bleiben.
out "new T() ohne Klammer-Index bleibt eine Instanz" 'import std.io;
type P = struct { x: int64; y: int64; };
fn main(): int64 {
  var p: P := new P();
  p.x := 3; p.y := 4;
  PrintLn(IntToStr(p.x + p.y));
  return 0;
}' "7"

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
