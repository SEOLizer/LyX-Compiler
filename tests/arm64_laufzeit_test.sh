#!/usr/bin/env bash
# tests/arm64_laufzeit_test.sh — arm64-Erzeugnisse AUSFUEHREN, nicht nur uebersetzen (#1769).
#
# Fuer arm64 gab es bis 1.1.9D keine Laufzeitpruefung: gemessen wurde, ob der
# Uebersetzer durchlaeuft und ob bestimmte Bytes entstehen. Auf riscv hat
# genau diese Luecke acht Defekte jahrelang getragen (#1740), auf arm64 blieb
# so unbemerkt, dass `PrintLn` ueberhaupt nicht uebersetzte: es fehlten
# IRO_NOT samt der BIT-Familie, die Breitenwechsel, memcpy (Builtin 210) und
# read/write (222/223). Dazu ging der Laengen-Sentinel -1 roh an write.
#
# Ausgefuehrt wird mit qemu-aarch64-static; fehlt es, laufen die Faelle als
# reine Uebersetzungspruefung weiter, damit dieser Test nirgends stumm
# ausfaellt. Erwartungen bleiben unter 256 — der Exit-Code ist ein Byte.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

QEMU="$(command -v qemu-aarch64-static || true)"
if [ -z "$QEMU" ]; then
  echo "HINWEIS: qemu-aarch64-static fehlt — es wird nur uebersetzt, nicht ausgefuehrt."
fi

uebersetze() { # quelltext, ziel-datei  → 0 = ok
  printf "%s" "$1" > "$TMP/c.lyx"
  (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" --target=arm64 -o "$2" >"$TMP/c.log" 2>&1)
}

run() { # name, quelltext, erwarteter exit-code
  if ! uebersetze "$2" "$TMP/c"; then
    echo "FAIL $1: uebersetzt nicht: $(grep -m1 -iE 'error|Builtin-ID|Opcode' "$TMP/c.log")"
    FAIL=$((FAIL+1)); return
  fi
  if [ -z "$QEMU" ]; then echo "PASS $1 (nur uebersetzt)"; PASS=$((PASS+1)); return; fi
  timeout 10 "$QEMU" "$TMP/c" >/dev/null 2>&1; local rc=$?
  if [ "$rc" -eq "$3" ]; then echo "PASS $1 (=$rc)"; PASS=$((PASS+1))
  else echo "FAIL $1: exit=$rc erwartet $3"; FAIL=$((FAIL+1)); fi
}

ausgabe() { # name, quelltext, erwartete ausgabe
  if ! uebersetze "$2" "$TMP/o"; then
    echo "FAIL $1: uebersetzt nicht: $(grep -m1 -iE 'error|Builtin-ID|Opcode' "$TMP/c.log")"
    FAIL=$((FAIL+1)); return
  fi
  if [ -z "$QEMU" ]; then echo "PASS $1 (nur uebersetzt)"; PASS=$((PASS+1)); return; fi
  local got; got="$(timeout 10 "$QEMU" "$TMP/o" 2>/dev/null)"
  if [ "$got" = "$3" ]; then echo "PASS $1 (Ausgabe '$got')"; PASS=$((PASS+1))
  else echo "FAIL $1: Ausgabe '$got' erwartet '$3'"; FAIL=$((FAIL+1)); fi
}

# --- Grundlagen ---
run "leeres_programm" 'fn main(): int64 { return 42; }' 42
run "schleife"        'fn main(): int64 { var s: int64 := 0; var i: int64 := 0; while i < 10 { s := s + i; i := i + 1; } return s; }' 45
run "vorwaertsaufruf" 'fn main(): int64 { return spaeter(); } fn spaeter(): int64 { return 17; }' 17
run "acht_argumente"  'fn f(a: int64, b: int64, c: int64, d: int64, e: int64, f: int64, g: int64, h: int64): int64 { return h; } fn main(): int64 { return f(1,2,3,4,5,6,7,88); }' 88
run "global_schreiben" 'var g: int64 := 5; fn bump(): int64 { g := g + 2; return g; } fn main(): int64 { bump(); bump(); return g; }' 9
run "alloc_schreiben"  'import std.alloc; fn main(): int64 { var p: int64 := alloc(64); poke64(p, 41); return peek64(p) + 1; }' 42

# --- Rechnen ---
run "f64_addition"     'fn main(): int64 { var a: f64 := 1.5; var b: f64 := 2.25; return ((a + b) * 10.0) as int64; }' 37
run "f64_aus_ganzzahl" 'fn main(): int64 { var a: f64 := 7 as f64; return (a / 2.0 * 10.0) as int64; }' 35
run "weite_konstante"  'fn main(): int64 { var a: int64 := 1099511627776; return a / 137438953472; }' 8
run "feld_index"       'fn main(): int64 { var a: [4]int64; a[0] := 5; a[3] := 9; return a[0] + a[3]; }' 14

# #1769: NOT und die BIT-Familie fehlten im Dispatcher — Opcode 50 brach den
# Uebersetzungslauf ab, bevor irgendetwas lief.
run "bitweise"         'fn main(): int64 { var a: int64 := 12; var b: int64 := 10; return (a & b) + (a | b) + (a ^ b); }' 28
run "bitnot"           'fn main(): int64 { var a: int64 := 0; var b: int64 := ~a; return 0 - b; }' 1

# --- Ausgabe ---
# Das Literal ging schon immer (Laenge steht fest). Die pchar-VARIABLE nicht:
# ir_lower legt -1 in den Laengen-Slot, und arm64 reichte das roh an write.
ausgabe "println_literal"  'import src.std.io; fn main(): int64 { PrintLn("hallo arm64"c); return 0; }' "hallo arm64"
ausgabe "println_variable" 'import src.std.io; fn main(): int64 { var s: pchar := "abc"c; PrintLn(s); return 0; }' "abc"
ausgabe "println_zahl"     'import src.std.io; fn main(): int64 { PrintLn(IntToStr(1234)); return 0; }' "1234"

# ---------------------------------------------------------------------------
# #1776: Gleitkomma als Text. Builtin 9 (PrintFloat) war auf dem Linux-Zweig
# ein No-op — geladen wurde der Wert, getan nichts —, Builtin 403
# (FloatToStr) fehlte ganz. Ausgegeben hat stattdessen eine gleichnamige
# Lyx-Funktion aus std/io, die auf x86 vom Builtin verdeckt wurde: derselbe
# Quelltext gab je nach Ziel etwas anderes aus. Verglichen wird deshalb mit
# den Werten des x86-Wegs, MIT std.io-Import — genau die Stellung, in der die
# Verdeckung auffiel.
# ---------------------------------------------------------------------------
ausgabe "floattostr_einfach"   'import src.std.io; fn main(): int64 { PrintLn(FloatToStr(2.5)); return 0; }' "2.500000"
ausgabe "floattostr_negativ"   'import src.std.io; fn main(): int64 { PrintLn(FloatToStr(0.0-3.25)); return 0; }' "-3.250000"
ausgabe "floattostr_null"      'import src.std.io; fn main(): int64 { PrintLn(FloatToStr(0.0)); return 0; }' "0.000000"
ausgabe "floattostr_stellen"   'import src.std.io; fn main(): int64 { PrintLn(FloatToStr(123.456)); return 0; }' "123.456000"
ausgabe "floattostr_abschnitt" 'import src.std.io; fn main(): int64 { PrintLn(FloatToStr(2.675)); return 0; }' "2.674999"
ausgabe "floattostr_inf"       'import src.std.io; fn main(): int64 { var e: f64 := 1.0; var n: f64 := 0.0; PrintLn(FloatToStr(e/n)); return 0; }' "inf"
ausgabe "floattostr_nan"       'import src.std.io; fn main(): int64 { var n: f64 := 0.0; PrintLn(FloatToStr(n/n)); return 0; }' "nan"
# Der gemeldete Fall aus #1776: MIT Import gab arm64/riscv "1.0" aus, x86
# "1.250000". Jetzt entscheidet ueberall das Builtin.
ausgabe "printfloat_mit_import" 'import src.std.io; fn main(): int64 { PrintFloat(1.25); return 0; }' "1.250000"

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
