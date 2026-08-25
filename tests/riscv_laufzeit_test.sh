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

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
