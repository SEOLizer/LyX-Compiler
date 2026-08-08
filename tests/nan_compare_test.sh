#!/bin/bash
# #1128: Vergleiche mit NaN folgen IEEE 754 — jeder ist false, ausser `!=`.
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
nan_cmp() { # name  operator  erwartet
  check "$1" "import std.io;
fn main(): int64 {
  var z: f64 := 0.0; var n: f64 := 0.0 / z; var m: f64 := 1.0;
  if (n $2 m) { PrintLn(\"T\"); } else { PrintLn(\"F\"); } return 0; }" "$3"
}

nan_cmp "NaN == 1.0"  "==" "F"
nan_cmp "NaN != 1.0"  "!=" "T"
nan_cmp "NaN < 1.0"   "<"  "F"
nan_cmp "NaN > 1.0"   ">"  "F"
nan_cmp "NaN <= 1.0"  "<=" "F"
nan_cmp "NaN >= 1.0"  ">=" "F"

check "n == n ist falsch" 'import std.io;
fn main(): int64 { var z: f64 := 0.0; var n: f64 := 0.0 / z;
  if (n == n) { PrintLn("T"); } else { PrintLn("F"); } return 0; }' "F"

check "NaN-Idiom x != x erkennt NaN" 'import std.io;
fn main(): int64 { var z: f64 := 0.0; var n: f64 := 0.0 / z;
  if (n != n) { PrintLn("T"); } else { PrintLn("F"); } return 0; }' "T"

# Gegenproben: gewoehnliche Werte unveraendert
check "1.0 < 2.0"   'import std.io;
fn main(): int64 { var x: f64 := 1.0; var y: f64 := 2.0;
  if (x < y) { PrintLn("T"); } else { PrintLn("F"); } return 0; }' "T"
check "2.0 <= 1.0"  'import std.io;
fn main(): int64 { var x: f64 := 2.0; var y: f64 := 1.0;
  if (x <= y) { PrintLn("T"); } else { PrintLn("F"); } return 0; }' "F"
check "1.0 == 1.0"  'import std.io;
fn main(): int64 { var x: f64 := 1.0; var y: f64 := 1.0;
  if (x == y) { PrintLn("T"); } else { PrintLn("F"); } return 0; }' "T"
check "1.0 != 2.0"  'import std.io;
fn main(): int64 { var x: f64 := 1.0; var y: f64 := 2.0;
  if (x != y) { PrintLn("T"); } else { PrintLn("F"); } return 0; }' "T"

exit $fail
