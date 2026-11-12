#!/usr/bin/env bash
# tests/for_laufvariable_2277_test.sh — #2277: die Laufvariable einer
# for-Schleife ist BLOCKWEISE, auf jedem Ziel gleich.
#
# Bis 1.2.21D gab derselbe Quelltext je nach Ziel etwas anderes aus:
#
#   var i: int64 := 40;  for i in 0..3 { }  PrintLn(i)
#     x86   -> 4      arm64/riscv -> 40
#
# Ursache war KEINE zweite Lesart, sondern ein Sichtbarkeitsleck im
# x86-Codegen: cg_addLocal haengt immer einen neuen Eintrag an, cg_findLocal
# sucht von hinten. Der Eintrag der Laufvariable blieb nach der Schleife
# stehen und verdeckte fuer den Rest der Funktion die gleichnamige aeussere
# Variable — gedruckt wurde also die Schleifenvariable. Betroffen waren ALLE
# VIER for-Formen (`in a..b`, `:= a to b`, C-artig, `in range(n)`), nicht nur
# die gemeldete. Festgelegt gilt die blockweise Lesart (ebnf.md): das
# aeussere i bleibt, was es war.
#
# Gemessen wird der WERT nach der Schleife auf x86_64, arm64 und riscv —
# alle drei muessen uebereinstimmen. Gegenseite im selben Programm: die
# Schleife muss trotzdem laufen (Summe) und ihre eigene Variable im Rumpf
# lesen und schreiben koennen; ein Codegen, der die Variable zu FRUEH
# unsichtbar macht, faellt daran.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
. "$(dirname "$0")/lib/qemu.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ulimit -c 0
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

ZIELE="x86"
[ -n "$QEMU_ARM64" ] && ZIELE="$ZIELE arm64" || echo "HINWEIS: Emulator fuer arm64 fehlt"
[ -n "$QEMU_RISCV64" ] && ZIELE="$ZIELE riscv" || echo "HINWEIS: Emulator fuer riscv fehlt"

fall() { # name erwartet   (Quelle auf stdin)
  local name="$1" erw="$2"
  cat > "$TMP/$name.lyx"
  local z
  for z in $ZIELE; do
    local opt="" q=""
    [ "$z" = arm64 ] && { opt="--target=arm64"; q="$QEMU_ARM64"; }
    [ "$z" = riscv ] && { opt="--target=riscv"; q="$QEMU_RISCV64"; }
    if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" $opt "$TMP/$name.lyx" -o "$TMP/$name.$z" >"$TMP/$name.$z.log" 2>&1); then
      no "$name $z" "uebersetzt nicht: $(grep -m1 -iE 'error|lyxc:' "$TMP/$name.$z.log")"; continue
    fi
    local got
    got=$( cd "$TMP" && timeout 60 $q "$TMP/$name.$z" 2>&1 | tr '\n' ' ' ); got="${got% }"
    if [ "$got" = "$erw" ]; then ok "$name $z: $got"; else no "$name $z" "'$got' erwartet '$erw'"; fi
  done
}

# 1. Alle vier for-Formen ueber eine VORHANDENE Variable: der aeussere Wert
#    bleibt. Dazu die Gegenseite — die Schleifen rechnen trotzdem richtig.
fall aeussere "40 70 90 50 10 6" <<'LYX'
unit main;
import std.io;
fn main(): int64 {
  var i: int64 := 40;
  for i in 0..3 { }
  PrintInt(i); PrintStr("\n"c);
  var j: int64 := 70;
  for j := 0 to 3 { }
  PrintInt(j); PrintStr("\n"c);
  var k: int64 := 90;
  for k := 0; k < 3; k += 1 { }
  PrintInt(k); PrintStr("\n"c);
  var r: int64 := 50;
  for r in range(3) { }
  PrintInt(r); PrintStr("\n"c);
  // Gegenseite: die Schleifen laufen und lesen ihre eigene Variable.
  var s: int64 := 0;
  for m in 0..4 { s := s + m; }
  PrintInt(s); PrintStr("\n"c);
  var t: int64 := 0;
  for n := 0 to 3 { t := t + n; }
  PrintInt(t); PrintStr("\n"c);
  return 0;
}
LYX

# 2. Die Laufvariable ist im Rumpf SCHREIBBAR und der Schritt setzt sie
#    danach weiter — ein Codegen, der sie zu frueh verwirft, faellt hier.
#    Zugleich: die aeussere Variable bleibt auch dann unberuehrt. `0..3` ist
#    EINSCHLIESSEND, also vier Durchlaeufe (belegt durch summe=10 fuer 0..4
#    im Fall darueber) — `range(3)` dagegen laeuft bis 2.
fall schreibend "7 4" <<'LYX'
unit main;
import std.io;
fn main(): int64 {
  var i: int64 := 7;
  var z: int64 := 0;
  for i in 0..3 {
    i := i + 0;      // Schreibzugriff auf die Laufvariable
    z := z + 1;
  }
  PrintInt(i); PrintStr("\n"c);
  PrintInt(z); PrintStr("\n"c);
  return 0;
}
LYX

# 3. Verschachtelt, gleicher Name innen wie aussen: die innere Schleife
#    verdeckt die aeussere NUR in ihrem Rumpf. 4 aeussere x 3 innere = 12.
fall verschachtelt "4 9" <<'LYX'
unit main;
import std.io;
fn main(): int64 {
  var p: int64 := 9;
  var c: int64 := 0;
  for a in 0..3 {
    for p in 0..2 { c := c + 1; }
  }
  PrintInt(c / 3); PrintStr("\n"c);
  PrintInt(p); PrintStr("\n"c);
  return 0;
}
LYX

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
