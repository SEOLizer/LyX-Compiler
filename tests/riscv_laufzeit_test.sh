#!/usr/bin/env bash
# tests/riscv_laufzeit_test.sh — riscv-Erzeugnisse AUSFUEHREN, nicht nur uebersetzen (#1740).
#
# Bis 1.1.8G pruefte kein Test, ob ein riscv-Programm laeuft; gemessen wurde
# ausschliesslich, ob der Uebersetzer durchlaeuft und ob bestimmte Bytes
# entstehen. Deshalb blieb unbemerkt, dass
#   * jeder Vorwaertsaufruf auf Code-Offset 0 gepatcht wurde (main rief sich
#     selbst, bis der Stapel ueberlief),
#   * der _start-Rumpf fest die ZUERST erzeugte Funktion aufrief statt main,
#   * Argumente aus den Slots 0..N-1 statt aus dem Argumentblock kamen,
#   * eingehende Argumentregister nie in die Param-Slots gespillt wurden,
#   * globale Variablen ihren Index als Adresse benutzten (Zugriff auf 0),
#   * poke8/16/32/64 die Adresse aus einem fremden Slot las.
# Jeder Fall unten war vor dem Fix rot, die meisten mit Signal 11.
#
# Ausgefuehrt wird mit qemu-riscv64-static; fehlt es, laufen die Faelle als
# reine Uebersetzungspruefung weiter, damit dieser Test nirgends stumm ausfaellt.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

QEMU="$(command -v qemu-riscv64-static || true)"
if [ -z "$QEMU" ]; then
  echo "HINWEIS: qemu-riscv64-static fehlt — es wird nur uebersetzt, nicht ausgefuehrt."
fi

run() { # name, quelltext, erwarteter exit-code
  printf "%s" "$2" > "$TMP/c.lyx"
  if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" --target=riscv -o "$TMP/c" >"$TMP/c.log" 2>&1); then
    echo "FAIL $1: uebersetzt nicht: $(grep -m1 -iE 'error|Builtin-ID|Opcode' "$TMP/c.log")"
    FAIL=$((FAIL+1)); return
  fi
  if [ -z "$QEMU" ]; then
    echo "PASS $1 (nur uebersetzt)"; PASS=$((PASS+1)); return
  fi
  timeout 10 "$QEMU" "$TMP/c" >/dev/null 2>&1; local rc=$?
  if [ "$rc" -eq "$3" ]; then
    echo "PASS $1 (=$rc)"; PASS=$((PASS+1))
  else
    echo "FAIL $1: exit=$rc erwartet $3"; FAIL=$((FAIL+1))
  fi
}

# --- Grundlagen: laeuft ueberhaupt etwas, und kommt main dran? ---
run "leeres_programm"   'fn main(): int64 { return 42; }' 42
run "schleife"          'fn main(): int64 { var s: int64 := 0; var i: int64 := 0; while i < 10 { s := s + i; i := i + 1; } return s; }' 45

# #1740: der _start-Rumpf sprang fest auf die zuerst erzeugte Funktion. Steht
# main nicht vorn, lief das Programm in eine fremde Funktion.
run "main_nicht_zuerst" 'fn vorher(): int64 { return 1; } fn main(): int64 { return 23; }' 23

# #1740: Vorwaertsaufruf — der Aufruf steht VOR der gerufenen Funktion.
run "vorwaertsaufruf"   'fn main(): int64 { return spaeter(); } fn spaeter(): int64 { return 17; }' 17

# #1740: Argumente kamen aus den Slots 0..N-1 statt aus dem Argumentblock, und
# der Callee spillte seine Argumentregister gar nicht erst.
run "drei_argumente"    'fn f(a: int64, b: int64, c: int64): int64 { return a*100 + b*10 + c; } fn main(): int64 { return f(1,2,3); }' 123
run "sechs_argumente"   'fn f(a: int64, b: int64, c: int64, d: int64, e: int64, f: int64): int64 { return a+b+c+d+e+f; } fn main(): int64 { return f(1,2,3,4,5,6); }' 21
run "rekursion"         'fn fak(n: int64): int64 { if n <= 1 { return 1; } return n * fak(n - 1); } fn main(): int64 { return fak(5); }' 120

# #1740: globale Variablen benutzten ihren Index als Adresse — Lesen von 0,
# Schreiben acht Byte VOR den Datenbereich (mitten in den Code, SIGSEGV).
run "global_lesen"      'var g: int64 := 5; fn main(): int64 { return g; }' 5
run "global_schreiben"  'var g: int64 := 5; fn bump(): int64 { g := g + 2; return g; } fn main(): int64 { bump(); bump(); return g; }' 9

# #1740: der Kern der Meldung — alloc() stuerzte ab, ein leeres Programm lief.
run "alloc_nicht_null"  'import std.alloc; fn main(): int64 { var p: int64 := alloc(64); if (p == 0) { return 9; } return 7; }' 7
run "alloc_schreiben"   'import std.alloc; fn main(): int64 { var p: int64 := alloc(64); poke64(p, 41); return peek64(p) + 1; }' 42
run "alloc_bytes"       'import std.alloc; fn main(): int64 { var p: int64 := alloc(16); poke8(p, 65); poke8(p+1, 66); return peek8(p) + peek8(p+1); }' 131

# ---------------------------------------------------------------------------
# #1764: Gleitkomma, weite Konstanten, Feldzugriff, Ausgabe.
#
# Vorher scheiterte all das LAUT beim Uebersetzen (Opcode 21 = IRO_FSUB,
# Opcode 86 = IRO_LOAD_IDX, Builtin 210 = memcpy) oder lieferte still falsche
# Werte (ITOF/FTOI kopierten den Slot, rv_LI64 schnitt auf 32 Bit ab, der
# Laengen-Sentinel von PrintLn ging roh an write).
#
# Die Erwartungen bleiben unter 256: der Exit-Code ist ein Byte, 375 kaeme als
# 119 zurueck und der Test wuerde etwas anderes messen als er behauptet.
# ---------------------------------------------------------------------------
run "f64_addition"    'fn main(): int64 { var a: f64 := 1.5; var b: f64 := 2.25; return ((a + b) * 10.0) as int64; }' 37
run "f64_subtraktion" 'fn main(): int64 { var a: f64 := 5.5; var b: f64 := 2.25; return ((a - b) * 10.0) as int64; }' 32
run "f64_mal_geteilt" 'fn main(): int64 { var a: f64 := 7.0; var b: f64 := 2.0; return ((a * b) + (a / b)) as int64; }' 17
run "f64_negation"    'fn main(): int64 { var a: f64 := 3.5; var b: f64 := 0.0 - a; return (0.0 - b) as int64; }' 3
run "f64_vergleiche"  'fn main(): int64 { var a: f64 := 1.5; var b: f64 := 2.5; var r: int64 := 0; if a < b { r := r + 1; } if b > a { r := r + 2; } if a <= a { r := r + 4; } if a == a { r := r + 8; } if a != b { r := r + 16; } return r; }' 31
# ITOF/FTOI: `7 as f64` muss 7.0 ergeben, nicht das Bitmuster der Sieben.
run "f64_aus_ganzzahl" 'fn main(): int64 { var a: f64 := 7 as f64; var b: f64 := a / 2.0; return (b * 10.0) as int64; }' 35
# rv_LI64 deckte nur 32 Bit ab — genau daran starb auch jedes f64-Literal.
run "weite_konstante" 'fn main(): int64 { var a: int64 := 1099511627776; return a / 137438953472; }' 8
run "feld_index"      'fn main(): int64 { var a: [4]int64; a[0] := 5; a[3] := 9; return a[0] + a[3]; }' 14

# Ausgabe: der Sentinel-Fall (pchar-Variable) schwieg, das Literal schrieb.
ausgabe() { # name, quelltext, erwartete ausgabe
  printf "%s" "$2" > "$TMP/o.lyx"
  if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/o.lyx" --target=riscv -o "$TMP/o" >"$TMP/o.log" 2>&1); then
    echo "FAIL $1: uebersetzt nicht: $(grep -m1 -iE 'error|Builtin-ID|Opcode' "$TMP/o.log")"
    FAIL=$((FAIL+1)); return
  fi
  if [ -z "$QEMU" ]; then echo "PASS $1 (nur uebersetzt)"; PASS=$((PASS+1)); return; fi
  local got; got="$(timeout 10 "$QEMU" "$TMP/o" 2>/dev/null)"
  if [ "$got" = "$3" ]; then
    echo "PASS $1 (Ausgabe '$got')"; PASS=$((PASS+1))
  else
    echo "FAIL $1: Ausgabe '$got' erwartet '$3'"; FAIL=$((FAIL+1))
  fi
}
ausgabe "println_literal"  'import src.std.io; fn main(): int64 { PrintLn("hallo riscv"c); return 0; }' "hallo riscv"
ausgabe "println_variable" 'import src.std.io; fn main(): int64 { var s: pchar := "abc"c; PrintLn(s); return 0; }' "abc"
ausgabe "println_zahl"     'import src.std.io; fn main(): int64 { PrintLn(IntToStr(1234)); return 0; }' "1234"

# ---------------------------------------------------------------------------
# #1770: Gleitkomma als Text. Bis 1.1.9E meldeten sich FloatToStr (Builtin 403)
# und PrintFloat (ID 9) laut als unbehandelt, ebenso fFloor/fCeil/fRound
# (400/401/402). Verglichen wird gegen den x86-Weg: Vorzeichen, ganzer Teil,
# Punkt, GENAU sechs Nachkommastellen, abgeschnitten statt gerundet — deshalb
# wird aus 2.675 dort wie hier 2.674999.
# ---------------------------------------------------------------------------
ausgabe "floattostr_einfach"  'import src.std.io; fn main(): int64 { PrintLn(FloatToStr(2.5)); return 0; }' "2.500000"
ausgabe "floattostr_negativ"  'import src.std.io; fn main(): int64 { PrintLn(FloatToStr(0.0-3.25)); return 0; }' "-3.250000"
ausgabe "floattostr_null"     'import src.std.io; fn main(): int64 { PrintLn(FloatToStr(0.0)); return 0; }' "0.000000"
ausgabe "floattostr_stellen"  'import src.std.io; fn main(): int64 { PrintLn(FloatToStr(123.456)); return 0; }' "123.456000"
# Abschneiden, nicht runden — dieselbe Ziffernfolge wie auf x86.
ausgabe "floattostr_abschnitt" 'import src.std.io; fn main(): int64 { PrintLn(FloatToStr(2.675)); return 0; }' "2.674999"
# Sonderfaelle an den Bits erkannt, nicht gerechnet.
ausgabe "floattostr_inf"      'import src.std.io; fn main(): int64 { var e: f64 := 1.0; var n: f64 := 0.0; PrintLn(FloatToStr(e/n)); return 0; }' "inf"
ausgabe "floattostr_nan"      'import src.std.io; fn main(): int64 { var n: f64 := 0.0; PrintLn(FloatToStr(n/n)); return 0; }' "nan"
# PrintFloat schreibt direkt, ohne den Umweg ueber den Zeiger — einmal ohne
# und einmal mit std.io-Import. Der zweite Fall ist der aus #1776: dort stand
# eine gleichnamige Lyx-Funktion, die auf den IR-Zielen das Builtin verdeckte.
ausgabe "printfloat"          'fn main(): int64 { PrintFloat(1.25); return 0; }' "1.250000"
# #1776: MIT std.io-Import gab riscv frueher "1.0" aus — dort gewann die
# gleichnamige Lyx-Funktion, waehrend auf x86 das Builtin zog. Die Fassung ist
# entfernt, jetzt entscheidet ueberall das Builtin.
ausgabe "printfloat_mit_import" 'import src.std.io; fn main(): int64 { PrintFloat(1.25); return 0; }' "1.250000"
# fRound rundet zur naechsten GERADEN Zahl, wie roundsd-Modus 0 auf x86.
ausgabe "runden"              'import src.std.io; fn main(): int64 { var a: f64 := 2.7; PrintLn(FloatToStr(fFloor(a))); return 0; }' "2.000000"
ausgabe "aufrunden"           'import src.std.io; fn main(): int64 { var a: f64 := 2.7; PrintLn(FloatToStr(fCeil(a))); return 0; }' "3.000000"
ausgabe "kaufmaennisch"       'import src.std.io; fn main(): int64 { PrintLn(FloatToStr(fRound(2.5))); return 0; }' "2.000000"

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

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
