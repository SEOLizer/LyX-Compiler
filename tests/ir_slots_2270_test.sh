#!/usr/bin/env bash
# tests/ir_slots_2270_test.sh — Slots werden wiederverwendet, Namen sind
# blockweise gueltig (#2270).
#
# Auf den IR-Zielen bekam jeder Temp einen eigenen Slot fuer die ganze
# Funktion. Im IR-Erzeugnis des Compilers hatte cg_genStmt damit 107 KB
# Rahmen (x86: 1,7 KB); jede Ebene einer `else if`-Kette rekursiert dort
# hindurch, und der arm64-/riscv-Compiler lief an parser.lyx in den
# Stapelueberlauf. Jetzt teilen sich Temps abgeschlossener Anweisungen ihre
# Slots (ir_lower._slotsFrei, Abbildung in slotOff).
#
# Gemessen wird die WIRKUNG gegen x86 als Referenz:
#   1. Rekursion durch eine Funktion mit langer `else if`-Kette, 3000 tief.
#      Vorher rund 17 KB Rahmen je Ebene — 50 MB, SIGSEGV. Wert pruefen.
#   2. Verschattung: `var x := 1; if c { var x := 7; } PrintLn(x)` gab auf
#      den IR-Zielen 7 statt 1 — die Namenssuche fand nach dem Block noch das
#      innere x. Mit geteilten Slots laege dort ein fremder Wert.
#   3. Block-Locals, verschachtelte Zweige und for-Variablen in Schleifen:
#      Slots werden in jeder Runde neu belegt; die Werte muessen stimmen.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
. "$(dirname "$0")/lib/qemu.sh"   # #2048
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ulimit -c 0
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

ZIELE="x86"
[ -n "$QEMU_ARM64" ] && ZIELE="$ZIELE arm64" || no "arm64" "Emulator fehlt — NICHT gemessen"
[ -n "$QEMU_RISCV64" ] && ZIELE="$ZIELE riscv" || no "riscv" "Emulator fehlt — NICHT gemessen"

fall() { # name erwartet  (Quelle in $TMP/name.lyx)
  local name="$1" erw="$2" z
  for z in $ZIELE; do
    local opt="" q=""
    [ "$z" = arm64 ] && { opt="--target=arm64"; q="$QEMU_ARM64"; }
    [ "$z" = riscv ] && { opt="--target=riscv"; q="$QEMU_RISCV64"; }
    if ! (cd "$ROOT" && "$LYXC" --std-path="$ROOT" $opt "$TMP/$name.lyx" -o "$TMP/$name.$z" >"$TMP/$name.$z.log" 2>&1); then
      no "$name $z" "uebersetzt nicht: $(grep -m1 -iE 'error' "$TMP/$name.$z.log")"; continue
    fi
    local got rc
    got=$( cd "$TMP" && timeout 60 $q "$TMP/$name.$z" 2>&1 | tr '\n' ' ' ); rc=${PIPESTATUS[0]}
    got="${got% }"
    if [ "$got" = "$erw" ]; then ok "$name $z: $got"; else no "$name $z" "'$got' erwartet '$erw'"; fi
  done
}

# 1. 300 Glieder, je Glied Bedingung und Zuweisung; 3000 Ebenen.
python3 - "$TMP/tief.lyx" <<'PY'
import sys
L = ["import std.io;", "fn tief(n: int64, a: int64): int64 {",
     "  if n == 0 { return a; }", "  var s: int64 := 0;",
     "  if a == 0 { s := s + 1000; }"]
for k in range(1, 300):
    L.append(f"  else if a == {k} {{ s := s + {k} * 2 + 1; }}")
L += ["  return tief(n - 1, a) + s;", "}",
      "fn main(): int64 {", "  PrintLn(tief(3000, 7));", "  PrintLn(tief(10, 299));",
      "  return 0;", "}"]
open(sys.argv[1], "w").write("\n".join(L) + "\n")
PY
# tief(3000, 7) = 3000 * 15 + 7; tief(10, 299) = 10 * 599 + 299
fall tief "45007 6289"

# 2. Verschattung: inneres x gilt nur im Block (if und while).
cat > "$TMP/schatten.lyx" <<'LYX'
import std.io;
fn main(): int64 {
  var x: int64 := 1;
  var c: int64 := 1;
  if c == 1 { var x: int64 := 7; PrintLn(x); }
  PrintLn(x);
  while c < 3 { var x: int64 := c * 100; c := c + 1; PrintLn(x); }
  PrintLn(x);
  return 0;
}
LYX
fall schatten "7 1 100 200 1"

# 3. Block-Locals und Zweige in Schleifen; die Summe ueber alle Runden.
cat > "$TMP/schleife.lyx" <<'LYX'
import std.io;
fn f(v: int64): int64 { return v * 2 + 1; }
fn main(): int64 {
  var total: int64 := 0;
  var i: int64 := 0;
  while i < 20 {
    var q: int64 := i * 3;
    if q % 2 == 0 {
      var r: int64 := q + f(i);
      total := total + r;
    } else if q % 5 == 0 {
      var r2: int64 := f(q) - i;
      total := total + r2 * 2;
    } else {
      var j: int64 := 0;
      while j < i { var t: int64 := f(j) + q; total := total + t % 7; j := j + 1; }
    }
    i := i + 1;
  }
  PrintLn(total);
  var a: int64 := 5;
  var b: int64 := 9;
  var m: int64 := (a + b) * (a + b);
  var n: int64 := (a + b) + m;
  PrintLn(n);
  return 0;
}
LYX
# Referenz: x86 (gleiches Programm, ohne IR).
ref=$( (cd "$ROOT" && "$LYXC" --std-path="$ROOT" "$TMP/schleife.lyx" -o "$TMP/ref" >/dev/null 2>&1) && "$TMP/ref" | tr '\n' ' ' ); ref="${ref% }"
if [ -n "$ref" ]; then fall schleife "$ref"; else no "schleife" "x86-Referenz fehlt"; fi

echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
