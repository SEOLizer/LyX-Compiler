#!/usr/bin/env bash
# tests/xtensa_laufzeit_test.sh — Xtensa-Erzeugnisse AUSFUEHREN (#1786).
#
# Bis 1.1.9L erzeugte dieses Backend keinen gueltigen Maschinencode. Nicht
# „mit Luecken" — die Byte-Kodierung selbst war falsch: bei der RRI8-Familie
# (ADDI, L32I, S32I, L8UI, S8I) waren zwei Bytes vertauscht, MOVI trug op0=6
# statt 2, die Sprungform BRI12 op0=7 statt 6, und der Ruecksprung war in
# Wahrheit ein `subx2`. Ein uebersetztes `fn main(): int64 { return 42; }`
# dekodierte als `s8i a1,a1,205 / l8ui a0,a1,96 / j ...`.
#
# Aufgefallen ist es nie, weil der Uebersetzer nur FEHLENDE Opcodes meldet
# (#1339), nicht falsch kodierte — und weil auf diesem Ziel nie etwas
# ausgefuehrt wurde. Dasselbe Muster wie bei riscv (#1740), arm64 (#1769) und
# Cortex-M (#1765), nur eine Ebene tiefer.
#
# Ausgefuehrt wird mit qemu-xtensa-static ueber tests/lib/xtensa_huelle.py:
# das Backend zielt auf ESP32-IRAM (0x40080000), der User-Mode-Emulator reicht
# nur bis 0x3fffffff. Die Huelle legt denselben Code an eine niedrige Adresse
# und stellt einen Rumpf davor, der main ruft und den Rueckgabewert meldet.
# Der Code selbst bleibt unveraendert — Aufrufe und Literale sind PC-relativ,
# geprueft wird also der Emitter, nicht der Ladeort.
#
# NOCH NICHT ABGEDECKT, mit Grund:
#   * Multiplikation. MULL gehoert zur Mul32-Option; KEINER der verfuegbaren
#     qemu-Kerne (dc232b, dc233c, de212, de233_fpu, dsp3400, lx106,
#     sample_controller) hat sie, ESP32s LX6 dagegen schon. Die Kodierung steht
#     nach Konstruktion da, nicht nach Ausfuehrung — ein Testfall hier wuerde
#     nur den fehlenden Kern messen.
#   * Argumente, globale Variablen, Vorwaertsaufrufe: die Defektkette aus
#     #1782, noch offen.
#   * Zeichenkettenliterale: brauchen einen L32R-Literal-Pool, ebenfalls offen.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

QEMU="$(command -v qemu-xtensa-static || true)"
HUELLE="$ROOT/tests/lib/xtensa_huelle.py"
if [ -z "$QEMU" ]; then
  echo "HINWEIS: qemu-xtensa-static fehlt — es wird nur uebersetzt, nicht ausgefuehrt."
fi

run() { # name, quelltext, erwarteter exit-code
  printf "%s" "$2" > "$TMP/c.lyx"
  if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" --target=esp32 -o "$TMP/c.elf" >"$TMP/c.log" 2>&1); then
    echo "FAIL $1: uebersetzt nicht: $(grep -m1 -iE 'error|Builtin-ID|Opcode' "$TMP/c.log")"
    FAIL=$((FAIL+1)); return
  fi
  if [ -z "$QEMU" ]; then echo "PASS $1 (nur uebersetzt)"; PASS=$((PASS+1)); return; fi
  if ! python3 "$HUELLE" "$TMP/c.elf" "$TMP/c.run" >/dev/null 2>&1; then
    echo "FAIL $1: Huelle konnte das Abbild nicht umpacken"
    FAIL=$((FAIL+1)); return
  fi
  timeout 10 "$QEMU" "$TMP/c.run" >/dev/null 2>&1; local rc=$?
  if [ "$rc" -eq "$3" ]; then echo "PASS $1 (=$rc)"; PASS=$((PASS+1))
  else echo "FAIL $1: exit=$rc erwartet $3"; FAIL=$((FAIL+1)); fi
}

# Laeuft ueberhaupt etwas? Vor dem Fix dekodierte schon das hier als Unsinn.
run "konstante"    'fn main(): int64 { return 42; }' 42
run "addition"     'fn main(): int64 { var a: int64 := 20; var b: int64 := 22; return a + b; }' 42
run "subtraktion"  'fn main(): int64 { var a: int64 := 50; var b: int64 := 8; return a - b; }' 42

# MOVI trug den falschen Opcode — jede Konstante war damit ein anderer Befehl.
run "grosse_konstante" 'fn main(): int64 { var a: int64 := 200; var b: int64 := 55; return a - b; }' 145

# RRI8: L32I/S32I sprechen die Slots an. Waren zwei Bytes vertauscht, traf
# jeder Zugriff eine andere Stelle.
run "viele_slots" 'fn main(): int64 { var a: int64 := 1; var b: int64 := 2; var c: int64 := 3; var d: int64 := 4; var e: int64 := 5; var f: int64 := 6; return a + b + c + d + e + f + 21; }' 42

# BRI12 trug op0=7 statt 6, und das Ziel liegt bei PC+4, nicht PC+3: der
# Sprung landete MITTEN im naechsten Drei-Byte-Befehl.
run "vergleich"    'fn main(): int64 { var a: int64 := 3; if a < 5 { return 7; } return 9; }' 7
run "vergleiche"   'fn main(): int64 { var a: int64 := 3; var b: int64 := 5; var r: int64 := 0; if a < b { r := r + 1; } if b > a { r := r + 2; } if a <= a { r := r + 4; } if a == a { r := r + 8; } if a != b { r := r + 16; } if b >= a { r := r + 32; } return r; }' 63
run "schleife"     'fn main(): int64 { var i: int64 := 0; var s: int64 := 0; while i < 5 { s := s + i; i := i + 1; } return s; }' 10

# CALL0 rechnet ab (PC & ~3) + 4 in WORTEN, J dagegen ab PC + 4 in Byte. Der
# Emitter hatte beides gleich behandelt und die Ausrichtung falsch geklammert.
run "aufruf"       'fn hilf(): int64 { return 42; } fn main(): int64 { return hilf(); }' 42
run "ret"          'fn main(): int64 { return 42; }' 42

# SSL/SSR trugen op1=3 statt op2=4; SLL/SRL nehmen ihre Quelle aus
# verschiedenen Feldern.
run "schieben"     'fn main(): int64 { var a: int64 := 5; return (a << 3) + (a >> 1); }' 42
run "bitweise"     'fn main(): int64 { var a: int64 := 12; var b: int64 := 10; return (a & b) + (a | b) + (a ^ b); }' 28

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
