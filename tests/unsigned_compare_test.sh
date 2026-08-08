#!/bin/bash
# #1126: uint64-Vergleiche laufen unsigniert (ja/jb statt jg/jl).
# Werte ab 2^63 wurden zuvor als negativ behandelt.
set -u
LYXC="${LYXC:-./lyxc}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail=0

check() { # name  quelltext  erwartet
  printf '%s\n' "$2" > "$TMP/t.lyx"
  if ! "$LYXC" "$TMP/t.lyx" -I . -o "$TMP/t.bin" >/dev/null 2>&1; then
    echo "  FAIL $1: uebersetzt nicht"; fail=1; return
  fi
  got="$("$TMP/t.bin" 2>&1)"
  if [ "$got" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1: '$got' statt '$3'"; fail=1; fi
}

check "2^64-1 > 1" 'import std.io;
fn main(): int64 { var a: uint64 := 18446744073709551615; var b: uint64 := 1;
  if (a > b) { PrintLn("groesser"); } else { PrintLn("kleiner"); } return 0; }' "groesser"

check "2^63 > 5" 'import std.io;
fn main(): int64 { var a: uint64 := 9223372036854775808; var b: uint64 := 5;
  if (a > b) { PrintLn("groesser"); } else { PrintLn("kleiner"); } return 0; }' "groesser"

check "1 < 2^64-1" 'import std.io;
fn main(): int64 { var a: uint64 := 1; var b: uint64 := 18446744073709551615;
  if (a < b) { PrintLn("kleiner"); } else { PrintLn("groesser"); } return 0; }' "kleiner"

check "Literal < uint64 (rhs entscheidet)" 'import std.io;
fn main(): int64 { var b: uint64 := 18446744073709551615;
  if (5 < b) { PrintLn("kleiner"); } else { PrintLn("groesser"); } return 0; }' "kleiner"

check "uint32 2^32-1 > 1" 'import std.io;
fn main(): int64 { var a: uint32 := 4294967295; var b: uint32 := 1;
  if (a > b) { PrintLn("groesser"); } else { PrintLn("kleiner"); } return 0; }' "groesser"

# Gegenprobe: signierte Vergleiche bleiben signiert
check "signed -8 < 1" 'import std.io;
fn main(): int64 { var a: int64 := 0 - 8; var b: int64 := 1;
  if (a < b) { PrintLn("kleiner"); } else { PrintLn("groesser"); } return 0; }' "kleiner"

exit $fail
