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

# ---------------------------------------------------------------------------
# #1784: `x + 0` wurde als "IRO_ADD mit src2 = -1" gefaltet und sollte eine
# Kopie bedeuten — kein Backend liest das so. Sie rechnen slotOff(-1) aus,
# also [fp + 0], und addieren, was dort liegt. Auf lyxos war das eine Null
# (`peek64(p + 0)` lieferte still 0), hier ein Segfault.
#
# Der Fall trifft ausgerechnet den Versatz 0, also das ERSTE Feld einer
# Struktur — und nur, wenn der Zeiger ein Funktionsparameter ist.
# ---------------------------------------------------------------------------
run "peek_param_versatz_null" \
  'import src.std.alloc; fn lies(q: int64): int64 { return peek64(q + 0); } fn main(): int64 { var p: int64 := alloc(64); poke64(p, 7); return lies(p); }' 7
run "peek_param_versatz_acht" \
  'import src.std.alloc; fn lies(q: int64): int64 { return peek64(q + 8); } fn main(): int64 { var p: int64 := alloc(64); poke64(p + 8, 9); return lies(p); }' 9
# Dieselbe Faltung steckte in SUB-mit-0, OR-mit-0 und AND-mit-lauter-Einsen.
run "identitaeten" \
  'fn f(x: int64): int64 { return (x + 0) * 10 + (x - 0) + (x | 0) + (x & (0-1)); } fn main(): int64 { return f(3); }' 39

# ---------------------------------------------------------------------------
# #1798: Anfangswerte von Modul-Konstanten
#
# Gemeldet fuer --target=lyxos: eine `con` mit NEGATIVEM Wert kam beim Aufrufer
# als 0 an, still. Tatsaechlich betraf es alle IR-Backends -- der Anfangswert
# wurde in ir_lower nur uebernommen, wenn der Knoten ein NK_LIT_INT war. `-1`
# ist aber kein Literal, sondern ein unaeres Minus um eines; alles andere fiel
# auf 0. Der Kommentar an der Stelle sagte das sogar ("everything else
# defaults to 0").
#
# Aufgefallen ist es nicht am Wert, sondern an einem Vergleich: `st == BAD`
# war falsch, obwohl `st == -1` stimmte -- und das sieht nach einem Fehler im
# Syscall aus, nicht nach einem im Uebersetzer.
#
# Alle Faelle unten waren vorher rot (die Konstante war 0).
run "con_negativ"        'con A: int64 := -1; fn main(): int64 { return 43 + A; }' 42
run "con_null_minus_eins" 'con A: int64 := 0 - 1; fn main(): int64 { return 43 + A; }' 42
run "con_geklammert"     'con A: int64 := (-1); fn main(): int64 { return 43 + A; }' 42
run "con_produkt"        'con A: int64 := 1 * -1; fn main(): int64 { return 43 + A; }' 42
run "con_gross_negativ"  'con A: int64 := -1000000; fn main(): int64 { return 42 + (A + 1000000); }' 42
run "con_ausdruck"       'con A: int64 := (2 + 3) * 4 - 20; fn main(): int64 { return 42 + A; }' 42
run "con_bitnicht"       'con A: int64 := ~5; fn main(): int64 { return 42 + (A + 6); }' 42
run "con_schieben"       'con A: int64 := 1 << 5; fn main(): int64 { return 10 + A; }' 42
# Gegenprobe: was schon immer ging, muss weiter gehen.
run "con_hex_zweierkompl" 'con A: int64 := 0xFFFFFFFFFFFFFFFF; fn main(): int64 { return 43 + A; }' 42
run "con_positiv"        'con A: int64 := 7; fn main(): int64 { return 35 + A; }' 42
# Konstante aus einer Vergleichskette -- der gemeldete Fall.
run "con_vergleich"      'con BAD: int64 := -1; fn hol(): int64 { return 0 - 1; } fn main(): int64 { if hol() == BAD { return 42; } return 9; }' 42

# ---------------------------------------------------------------------------
# #1801: f64-Modulkonstanten
#
# Sie waren 0. Der Anfangswert lief ueber einen GANZZAHLIGEN Falter, und
# Gleitkomma gehoert da nicht hinein (#1499). Also blieb es bei 0 — `con P:
# f64 := 2.5` kam als 0.0 an. std/math.lyx fuehrt MATH_LN2 und MATH_LN10 so;
# `fDiv(x, MATH_LN2)` war auf diesen Zielen eine Division durch null, ohne
# dass beim Uebersetzen etwas auffiel.
#
# Der Fix rechnet nicht, er legt das BITMUSTER ab — wie es der Zweig fuer
# f64-Literale im Code seit #868 tut.
run "f64_con"           'con P: f64 := 2.5; fn main(): int64 { var a: f64 := P * 4.0; return 32 + (a as int64); }' 42
# Negativ: das Vorzeichenbit wird gekippt, NICHT ganzzahlig negiert. `0 - Bits`
# ergaebe aus -1.5 die Zahl -3.0 — plausibel und falsch (vgl. #1803 im
# x86-Pfad).
run "f64_con_negativ"   'con N: f64 := -1.5; fn main(): int64 { var b: f64 := N * 4.0; return 48 + (b as int64); }' 42
# Der Fall aus std/math.lyx.
run "f64_con_ln2"       'con LN2: f64 := 0.6931471805599453; fn main(): int64 { var q: f64 := 2.0 / LN2; return (q * 10.0) as int64; }' 28
# Gegenprobe: ganzzahlige Konstanten bleiben ganzzahlig.
run "f64_neben_int"     'con P: f64 := 1.5; con I: int64 := 39; fn main(): int64 { var a: f64 := P * 2.0; return I + (a as int64); }' 42

# ---------------------------------------------------------------------------
# #1806: Funktionszeiger als PARAMETER
#
# `fn apply(f: CmpFn, a, b) { return f(a, b); }` scheiterte mit
# "unbekannter Builtin/Funktion: f" — der Parametername wurde als
# FUNKTIONSNAME aufgeloest statt als Wert, der einen Zeiger haelt.
#
# Ursache: _findLocalSlot durchsuchte nur die Locals. Parameter stehen in der
# NK_PARAM-Kette und liegen bei IR_BARG_SLOTS (#1388). Dieselbe Suche steht
# eine Ebene hoeher fuer den LESEzugriff auf einen Parameter laengst da — zwei
# Stellen, die dasselbe wissen muessen, und nur eine wusste es.
#
# Beim Beheben meldeten sich zwei fehlende Opcodes LAUT (so soll es sein):
# riscv kannte IRO_CALL_INDIRECT gar nicht, arm64 fehlte IRO_FUNC_ADDR. Beide
# ergaenzt — sonst waere der Fix nur auf lyxos belegt, das hier nicht laeuft.
run "fnptr_parameter" \
  'pub type CmpFn = fn(int64, int64): int64; fn add(a: int64, b: int64): int64 { return a + b; } fn apply(f: CmpFn, a: int64, b: int64): int64 { return f(a, b); } fn main(): int64 { return apply(add, 20, 22); }' 42
# Zwei Zeiger als Parameter, beide gerufen.
run "fnptr_zwei_parameter" \
  'pub type Op = fn(int64): int64; fn dbl(x: int64): int64 { return x * 2; } fn inc(x: int64): int64 { return x + 1; } fn zwei(f: Op, g: Op, v: int64): int64 { return f(v) + g(v); } fn main(): int64 { return zwei(dbl, inc, 10) + 11; }' 42
# Gegenprobe: lokale Variable und Klassenfeld gingen schon vorher und muessen
# weiter gehen.
run "fnptr_lokal" \
  'pub type Op = fn(int64): int64; fn dbl(x: int64): int64 { return x * 2; } fn main(): int64 { var f: Op := dbl; return f(21); }' 42
run "fnptr_feld" \
  'pub type Op = fn(int64): int64; fn dbl(x: int64): int64 { return x * 2; } pub type TH = class { h: Op; fn Create(): void { } fn ruf(v: int64): int64 { return self.h(v); } }; fn main(): int64 { var o: TH := new TH(); o.h := dbl; return o.ruf(21); }' 42

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
