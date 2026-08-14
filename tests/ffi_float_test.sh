#!/usr/bin/env bash
# tests/ffi_float_test.sh — #1486.
#
# Der Codegen legte ALLE Argumente eines FFI-Aufrufs in die Ganzzahlregister
# rdi/rsi/rdx/rcx/r8/r9. Die SysV-ABI führt aber zwei getrennte Reihen:
# Ganzzahlen und Zeiger dort, Gleitkommawerte in xmm0..xmm7, jede Reihe für
# sich durchgezählt. Ein f64-Argument landete deshalb in rdi, während der
# Callee xmm0 las — und der Rückgabewert kam aus xmm0, gelesen wurde rax.
#
# Die Meldung nannte f32; gemessen betraf es JEDE Gleitkommaübergabe:
# `fabs(-2.5)` lieferte 0.00 statt 2.50.
#
# GEPRÜFT WIRD GEGEN DIE C-BIBLIOTHEK SELBST. Eine Gegenprobe mit einer
# Lyx-eigenen Funktion würde nichts sagen — Lyx-interne Aufrufe benutzen ihre
# eigene Konvention und waren nie betroffen. Erst libm sagt, ob die Werte
# wirklich nach ABI übergeben werden.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

if [ ! -e /lib/x86_64-linux-gnu/libm.so.6 ] && [ ! -e /usr/lib/x86_64-linux-gnu/libm.so.6 ]; then
  echo "SKIP libm.so.6 nicht gefunden — ohne C-Bibliothek ist nichts zu messen"
  echo "--- 0 PASS, 0 FAIL"
  exit 0
fi

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/p.lyx"; rm -f "$TMP/p"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p" >/dev/null 2>&1; then
    no "$1" "uebersetzt nicht: $("$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p" 2>&1 | grep -i error | head -1)"
    return
  fi
  got="$(timeout 30 "$TMP/p" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then no "$1" "ABSTURZ (rc=$rc)"; return; fi
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1" "'$got' erwartet '$3'"; fi
}

# ===========================================================================
# f64 — der Fall, den die Meldung nicht nannte
# ===========================================================================

out "#1486: f64-Argument und -Rueckgabe" 'import std.io;
@cap(system.ffi)
extern fn fabs(x: f64): f64 link "libm.so.6";
fn main(): int64 {
  PrintLn(FloatToStr(fabs(0.0 - 2.5), 3));
  return 0;
}' "2.500"

# Zwei Gleitkommaargumente: xmm0 UND xmm1 muessen stimmen. Mit nur einem
# richtigen Register waere pow(2,10) immer noch falsch.
out "#1486: zwei f64-Argumente" 'import std.io;
@cap(system.ffi)
extern fn pow(b: f64, e: f64): f64 link "libm.so.6";
@cap(system.ffi)
extern fn atan2(y: f64, x: f64): f64 link "libm.so.6";
fn main(): int64 {
  PrintStr(FloatToStr(pow(2.0, 10.0), 1)); PrintStr(" ");
  PrintLn(FloatToStr(atan2(1.0, 1.0), 6));
  return 0;
}' "1024.0 0.785398"

# ===========================================================================
# f32 — der gemeldete Fall
# ===========================================================================

# Intern fuehrt Lyx f32 als f64-Bits (#1127). Ohne cvtsd2ss liest der Callee
# die unteren 32 Bit eines double; fuer 1.0 ist das exakt 0.0f.
out "#1486: f32-Argumente und -Rueckgaben" 'import std.io;
@cap(system.ffi)
extern fn fabsf(x: f32): f32 link "libm.so.6";
@cap(system.ffi)
extern fn powf(b: f32, e: f32): f32 link "libm.so.6";
@cap(system.ffi)
extern fn sqrtf(x: f32): f32 link "libm.so.6";
fn main(): int64 {
  PrintStr(FloatToStr(fabsf(0.0 - 2.5), 3)); PrintStr(" ");
  PrintStr(FloatToStr(powf(2.0, 10.0), 1)); PrintStr(" ");
  PrintLn(FloatToStr(sqrtf(16.0), 3));
  return 0;
}' "2.500 1024.0 4.000"

# ===========================================================================
# Gemischt — hier zeigt sich, ob die Reihen getrennt gezaehlt werden
# ===========================================================================

# ldexp(f64, int) : der zweite Parameter ist eine GANZZAHL und gehoert nach
# rdi, nicht nach rsi — die Gleitkommaposition davor faellt in der
# Ganzzahlreihe weg. Ein Fix, der nur die Floats umlaedt und die Ganzzahlen
# stehen laesst, faellt genau hier durch.
out "#1486: gemischte Signatur (f64, int64)" 'import std.io;
@cap(system.ffi)
extern fn ldexp(x: f64, n: int64): f64 link "libm.so.6";
fn main(): int64 {
  PrintStr(FloatToStr(ldexp(3.0, 4), 1)); PrintStr(" ");
  PrintLn(FloatToStr(ldexp(1.0, 10), 1));
  return 0;
}' "48.0 1024.0"

# Und die Gegenrichtung: Ganzzahl zuerst, Gleitkomma danach.
out "#1486: gemischte Signatur (int64, f64)" 'import std.io;
@cap(system.ffi)
extern fn fmax(a: f64, b: f64): f64 link "libm.so.6";
@cap(system.ffi)
extern fn abs(x: int64): int64 link "libc.so.6";
fn main(): int64 {
  PrintStr(IntToStr(abs(0 - 7))); PrintStr(" ");
  PrintLn(FloatToStr(fmax(2.5, 7.5), 1));
  return 0;
}' "7 7.5"

# ===========================================================================
# Gegenproben
# ===========================================================================

# Rein ganzzahlige Aufrufe waren nie betroffen und muessen es bleiben.
out "#1486: reine Ganzzahlaufrufe unveraendert" 'import std.io;
@cap(system.ffi)
extern fn abs(x: int64): int64 link "libc.so.6";
@cap(system.ffi)
extern fn labs(x: int64): int64 link "libc.so.6";
fn main(): int64 {
  PrintStr(IntToStr(abs(0 - 7))); PrintStr(" ");
  PrintLn(IntToStr(labs(0 - 123456789)));
  return 0;
}' "7 123456789"

# Lyx-eigene Aufrufe benutzen ihre eigene Konvention — der FFI-Umbau darf sie
# nicht anfassen.
out "#1486: Lyx-interne f64-Aufrufe unveraendert" 'import std.io;
import std.math;
fn eigen(a: f64, b: f64): f64 { return fAdd(fMul(a, b), 1.0); }
fn main(): int64 {
  PrintStr(FloatToStr(eigen(2.5, 4.0), 2)); PrintStr(" ");
  PrintLn(FloatToStr(SqrtF64(16.0), 2));
  return 0;
}' "11.00 4.00"

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
