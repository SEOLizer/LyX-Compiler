#!/bin/bash
# #1127: f32 wird als Fliesskommatyp behandelt (zuvor: rohes Bitmuster).
set -u
LYXC="${LYXC:-./lyxc}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail=0
check() {
  printf '%s\n' "$2" > "$TMP/t.lyx"
  if ! "$LYXC" "$TMP/t.lyx" -I . -o "$TMP/t.bin" >/dev/null 2>&1; then
    echo "  FAIL $1: uebersetzt nicht"; fail=1; return; fi
  got="$("$TMP/t.bin" 2>&1)"
  if [ "$got" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1: '$got' statt '$3'"; fail=1; fi
}

check "f32-Literal, as int64" 'import std.io;
fn main(): int64 { var a: f32 := 1.5; PrintLn(IntToStr(a as int64)); return 0; }' "1"

check "f32-Addition" 'import std.io;
fn main(): int64 { var a: f32 := 1.5; var b: f32 := 2.5;
  PrintLn(IntToStr((a + b) as int64)); return 0; }' "4"

check "f32-Zwischenvariable" 'import std.io;
fn main(): int64 { var a: f32 := 1.5; var b: f32 := 2.5; var c: f32 := a + b;
  PrintLn(IntToStr(c as int64)); return 0; }' "4"

check "f32-Division" 'import std.io;
fn main(): int64 { var a: f32 := 10.0; var b: f32 := 4.0;
  PrintLn(IntToStr((a / b) as int64)); return 0; }' "2"

check "f32 als Rueckgabetyp" 'import std.io;
fn F(): f32 { return 2.5; }
fn main(): int64 { PrintLn(IntToStr(F() as int64)); return 0; }' "2"

check "int64 as f32" 'import std.io;
fn main(): int64 { var i: int64 := 7; var f: f32 := i as f32;
  PrintLn(IntToStr(f as int64)); return 0; }' "7"

# Gegenprobe: f64 unveraendert
check "f64 bleibt korrekt" 'import std.io;
fn main(): int64 { var a: f64 := 1.5; var b: f64 := 2.5;
  PrintLn(IntToStr((a + b) as int64)); return 0; }' "4"

exit $fail
