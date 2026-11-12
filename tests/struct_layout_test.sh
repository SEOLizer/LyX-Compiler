#!/usr/bin/env bash
# tests/struct_layout_test.sh — #1084: `flat struct` und `packed struct`.
#
# `ebnf.md` §8 führt drei Struct-Formen; der Parser kannte nur die einfache.
# `flat` und `packed` sind laut §2.1 ausdrücklich NICHT reserviert — sie werden
# deshalb als weiche Schlüsselwörter erkannt, und zwar nur unmittelbar vor
# `struct`. Als Bezeichner bleiben sie nutzbar; das prüft dieser Test mit.
#
# Beim Beheben kamen zwei stille Lücken daneben zum Vorschein:
#
#   * `@packed` galt nur für `struct X { ... }`. Bei der ebenso gültigen
#     Schreibweise `type X = struct { ... }` ging die Annotation verloren und
#     die Felder behielten 8 Byte Abstand — ohne jede Meldung.
#   * `sizeof` rechnete Feldzahl × 8 statt das tatsächliche Layout zu lesen.
#     Drei `uint8` in einem gepackten Struct ergaben 24 statt 3. Wer damit
#     allokiert oder serialisiert, rechnet still falsch.
#
# Geprüft wird deshalb nicht nur, dass die Formen übersetzen, sondern die
# tatsächliche ABLAGE: die Bytes im Speicher werden ausgelesen. Ein Test, der
# nur `sizeof` vergleicht, wäre auf beide Lücken hereingefallen.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    echo "FAIL $1: uebersetzt nicht"; FAIL=$((FAIL+1)); return
  fi
  got="$(timeout 10 "$TMP/c" 2>&1)"
  if [ "$got" = "$3" ]; then echo "PASS $1"; PASS=$((PASS+1))
  else echo "FAIL $1: '$got' erwartet '$3'"; FAIL=$((FAIL+1)); fi
}

# Gemeinsamer Rumpf: schreibt drei Felder und liest die ersten sechs Bytes.
bytes_body='import std.io;
import std.alloc;
%s
fn main(): int64 {
  var m: int64 := alloc(64);
  var k: int64 := 0;
  while (k < 64) { poke8(m + k, 0); k := k + 1; }
  var s: S := m as S;
  s.a := 1; s.b := 2; s.c := 3;
  k := 0;
  while (k < 6) { Print(IntToStr(peek8(m + k))); Print(" "); k := k + 1; }
  PrintLn("");
  return 0;
}'

# --- Die Formen aus §8 übersetzen und legen dicht ab ---------------------
out "Repro: flat struct" "$(printf "$bytes_body" 'type S = flat struct { a: uint8; b: uint8; c: uint8; };')" '1 2 3 0 0 0 '
out "Repro: packed struct" "$(printf "$bytes_body" 'type S = packed struct { a: uint8; b: uint8; c: uint8; };')" '1 2 3 0 0 0 '

# @packed muss bei BEIDEN Schreibweisen dasselbe bewirken.
out "@packed auf type-Form" "$(printf "$bytes_body" '@packed
type S = struct { a: uint8; b: uint8; c: uint8; };')" '1 2 3 0 0 0 '
out "@packed auf struct-Form" "$(printf "$bytes_body" '@packed
struct S { a: uint8; b: uint8; c: uint8; }')" '1 2 3 0 0 0 '

# Gegenprobe: ohne Packung gilt die ABI-Ausrichtung (#1516) — nicht mehr der
# fruehere 8-Byte-Abstand fuer JEDES Feld. Bei drei uint8 faellt sie mit der
# gepackten Ablage zusammen; das ist beabsichtigt und C-gleich.
out "ungepackt: uint8 dicht wie in C" "$(printf "$bytes_body" 'type S = struct { a: uint8; b: uint8; c: uint8; };')" '1 2 3 0 0 0 '

# Hier trennen sich die Formen wirklich: uint32 wird ungepackt auf 4
# ausgerichtet (a, drei Byte Fuellung, b), gepackt liegt es unmittelbar
# dahinter. Ohne Ausrichtung saehen beide Faelle gleich aus.
bytes_ab='import std.io;
import std.alloc;
%s
fn main(): int64 {
  var m: int64 := alloc(64);
  var k: int64 := 0;
  while (k < 64) { poke8(m + k, 0); k := k + 1; }
  var s: S := m as S;
  s.a := 1; s.b := 2;
  k := 0;
  while (k < 6) { Print(IntToStr(peek8(m + k))); Print(" "); k := k + 1; }
  PrintLn("");
  return 0;
}'
out "ungepackt: uint32 auf 4 ausgerichtet" "$(printf "$bytes_ab" 'type S = struct { a: uint8; b: uint32; };')" '1 0 0 0 2 0 '
out "gepackt: uint32 direkt dahinter" "$(printf "$bytes_ab" 'type S = packed struct { a: uint8; b: uint32; };')" '1 2 0 0 0 0 '

# --- sizeof folgt dem tatsächlichen Layout -------------------------------
out "sizeof folgt dem Layout" 'import std.io;
type F = flat struct { a: uint8; b: uint8; c: uint8; };
type U = struct { a: int64; b: int64; c: int64; };
@packed
type A = struct { a: uint8; b: uint8; };
struct C { x: int64; y: int64; }
fn main(): int64 {
  PrintLn(IntToStr(sizeof(F)));
  PrintLn(IntToStr(sizeof(U)));
  PrintLn(IntToStr(sizeof(A)));
  PrintLn(IntToStr(sizeof(C)));
  return 0;
}' '3
24
2
16'

# --- packed mit at(): feldweise Ablage ----------------------------------
out "packed mit at()-Klausel" 'import std.io;
import std.alloc;
type S = packed struct { a: uint8 at(0); b: uint8 at(4); };
fn main(): int64 {
  var m: int64 := alloc(64);
  var k: int64 := 0;
  while (k < 64) { poke8(m + k, 0); k := k + 1; }
  var s: S := m as S;
  s.a := 7; s.b := 9;
  k := 0;
  while (k < 6) { Print(IntToStr(peek8(m + k))); Print(" "); k := k + 1; }
  PrintLn("");
  return 0;
}' '7 0 0 0 9 0 '

# --- Gegenproben: flat und packed bleiben gewöhnliche Bezeichner --------
# §2.1 haelt ausdruecklich fest, dass sie NICHT reserviert sind.
out "flat bleibt Bezeichner" 'fn main(): int64 {
  var flat: int64 := 3;
  return flat;
}' ''
out "packed bleibt Bezeichner" 'fn main(): int64 {
  var packed: int64 := 4;
  return packed;
}' ''

out "flat als Funktionsname" 'import std.io;
fn flat(x: int64): int64 { return x + 1; }
fn main(): int64 { PrintLn(IntToStr(flat(41))); return 0; }' '42'

# Einfache Form unveraendert.
out "einfache Form unveraendert" 'import std.io;
import std.alloc;
type S = struct { x: int64; y: int64; };
fn main(): int64 {
  var m: int64 := alloc(64);
  var s: S := m as S;
  s.x := 40; s.y := 2;
  PrintLn(IntToStr(s.x + s.y));
  return 0;
}' '42'

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
