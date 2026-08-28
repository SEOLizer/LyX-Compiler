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
#   * Ausgabe: der PrintStr-Helfer schreibt in das UART-Register 0x60000000.
#     Das ist auf dem ESP32 richtig, im User-Mode-Emulator aber unabgebildet —
#     gemessen wird hier deshalb ueber den Rueckgabewert.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# #1789: KEINE Speicherauszüge. Die Zusicherungen loesen ILL aus, das Programm
# stirbt also planmaessig mit SIGILL — und der Kern-Dump laeuft hier ueber
# `apport` (core_pattern ist ein Pipe-Handler). Unter Last dauert das laenger
# als der Zeitdeckel, und der Testfall meldete 124 statt 132: ein Flackern, das
# nichts ueber den Compiler aussagt. Mit Limit 0 ruft der Kern den Dumper gar
# nicht erst auf.
ulimit -c 0
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
  # Zeitdeckel 60, nicht 10: im vollen `make test` laufen viele qemu-Instanzen
  # nebeneinander, und `division_durch_null` fiel dort mit 124 (Deckel) statt
  # 132 (SIGILL) durch — isoliert liefert derselbe Fall reproduzierbar 132.
  # Der Deckel darf die Aussage nicht bestimmen: gemessen wird weiterhin der
  # genaue Rueckgabewert, ein Haenger faellt als 124 weiterhin auf.
  timeout 60 "$QEMU" "$TMP/c.run" >/dev/null 2>&1; local rc=$?
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

# ---------------------------------------------------------------------------
# #1782: die Defektkette. Dieselbe wie auf riscv (#1740) und Cortex-M (#1765).
# ---------------------------------------------------------------------------
# Der Einstiegspunkt im ELF stand auf der ZUERST erzeugten Funktion — lyxc
# reichte getFuncAddr(0) durch. Stand main nicht vorn, startete das Programm
# in einer fremden Funktion.
run "main_nicht_zuerst" 'fn vorher(): int64 { return 1; } fn main(): int64 { return 42; }' 42
# Argumente kamen aus den Slots 0..N-1 statt aus dem Argumentblock, und der
# Callee spillte seine Argumentregister gar nicht erst.
run "ein_argument"  'fn f(a: int64): int64 { return a; } fn main(): int64 { return f(42); }' 42
run "zwei_argumente" 'fn add(a: int64, b: int64): int64 { return a + b; } fn main(): int64 { return add(40, 2); }' 42
# CALL0 haelt sechs Argumente in a2..a7; der Emitter reichte nur vier durch
# und verwarf den Rest still.
run "sechs_argumente" 'fn f(a: int64, b: int64, c: int64, d: int64, e: int64, g: int64): int64 { return a + b + c + d + e + g; } fn main(): int64 { return f(1,2,3,4,5,27); }' 42
run "rekursion"     'fn zaehl(n: int64): int64 { if n <= 0 { return 0; } return 1 + zaehl(n - 1); } fn main(): int64 { return zaehl(42); }' 42
# Vorwaertsaufruf: applyPatches lief je Funktion und setzte patchCount zurueck.
run "vorwaertsaufruf" 'fn main(): int64 { return spaeter(); } fn spaeter(): int64 { return 42; }' 42

# ---------------------------------------------------------------------------
# #1786: Zeichenkettenliterale und globale Variablen, beide PC-relativ.
#
# Xtensa hat keinen Befehl, der den Programmzaehler liest. Die Adresse entsteht
# deshalb ueber ein CALL0 auf eine Marke, die sofort zurueckspringt: die
# Rueckkehradresse landet in a0. Literale liegen inline im Codestrom, der
# Datenbereich der globalen Variablen haengt hinter dem Code und wird ueber
# einen Literal-Pool erreicht, der ABSTAENDE haelt statt Adressen.
#
# Genau das macht diese Faelle ueberhaupt pruefbar: die Huelle laedt den Code an
# eine ANDERE Adresse als das Backend annimmt (0x40080000 ist im User-Mode nicht
# abbildbar, qemu deckelt den reservierten Adressraum bei 0x3fffffff — mit -R
# geprueft). Ein Abbild mit absoluten Adressen waere hier nicht ausfuehrbar.
#
# Bis 1.1.9M meldete das Backend beide Faelle als nicht umgesetzt; davor lieferte
# ein Lesezugriff auf eine globale Variable still 0 und ein Schreibzugriff tat
# gar nichts.
run "literal_strlen"   'fn main(): int64 { var s: pchar := "abcdef"c; return StrLen(s) + StrLen("xy"c) + 34; }' 42
run "literal_zeichen"  'fn main(): int64 { var s: pchar := "Az"c; return StrCharAt(s, 0) + StrCharAt(s, 1) - 100; }' 87
run "global_lesen"     'var g: int64 := 42; fn main(): int64 { return g; }' 42
run "global_schreiben" 'var a: int64 := 10; var b: int64 := 3; fn main(): int64 { a := a + b; b := a - 1; return a + b + 17; }' 42
# Ueber Funktionsgrenzen hinweg: jeder Zugriff bekommt einen eigenen
# Pool-Eintrag, denn der Abstand haengt an der Aufrufstelle.
run "global_ueber_fn"  'var zaehler: int64 := 0; fn tick(): int64 { zaehler := zaehler + 1; return zaehler; } fn main(): int64 { var i: int64 := 0; while i < 20 { tick(); i := i + 1; } return zaehler + 22; }' 42
# #1786: peek/poke und StrLen/StrCharAt. Bis 1.1.9M brach das Backend bei
# jedem dieser Builtins ab; bis 1.1.5C lieferte es still 0.
run "peek_poke"        'fn main(): int64 { var s: pchar := "0000"c; var p: int64 := s as int64; poke8(p, 42); poke8(p+1, 0); return peek8(p) + StrLen(s); }' 43

# ---------------------------------------------------------------------------
# #1789: Division, Rest und die Zusicherungen
#
# Bis 1.1.10F stand bei IRO_DIV und IRO_MOD `MOVI T0, 0` — JEDE Division lieferte
# still 0. Der laute Opcode-Waechter griff nicht, weil beide als „behandelt"
# gefuehrt waren; behandelt wurden sie ja, nur falsch. Verdeckt hat es allein,
# dass die Zusicherung davor den Uebersetzer abbrechen liess.
#
# Die Basis-ISA hat keinen Divisionsbefehl (DIV32 ist eine Option und hier
# ebenso wenig pruefbar wie Mul32). Also eine Softwareroutine — die ist damit
# auf JEDEM Xtensa-Kern richtig, nicht nur auf denen mit der Option.
run "division"        'fn main(): int64 { var a: int64 := 84; var b: int64 := 2; return a / b; }' 42
run "rest"            'fn main(): int64 { var a: int64 := 84; return (a % 5) + 38; }' 42
# Vorzeichen in beide Richtungen. Der Rest folgt dem Dividenden — wie bei / und %
# ueblich und wie der x86-Pfad es tut; die beiden muessen uebereinstimmen.
run "division_negativ" 'fn main(): int64 { var a: int64 := 0-84; var b: int64 := 2; return (a / b) + 84; }' 42
run "division_divneg"  'fn main(): int64 { var a: int64 := 84; var b: int64 := 0-2; return (a / b) + 84; }' 42
run "rest_negativ"     'fn main(): int64 { var a: int64 := 0-20; return (a % 3) + 44; }' 42
# Gegen x86 und riscv gemessen: alle drei liefern 42.
run "division_kette"   'fn main(): int64 { var s: int64 := 0; var i: int64 := 1; while i <= 10 { s := s + (100 / i); i := i + 1; } return s - 249; }' 42

# Die Zusicherungen. ir_lower stellt vor JEDE Division ein IRO_ASSERT_NOT_ZERO;
# ohne sie waere eine Division durch 0 eine Endlosschleife in der Routine.
# Der Abbruch ist ILL (0x00,0x00,0x00) — gegen den Disassembler geprueft und im
# Lauf belegt: SIGILL, also rc 132. Auf dem ESP32 loest er eine Ausnahme aus und
# landet im Panik-Handler, statt weiterzulaufen.
run "division_durch_null" 'fn main(): int64 { var a: int64 := 84; var b: int64 := 0; return a / b; }' 132
# Der gute Fall darf NICHT ausloesen — sonst waere die Zusicherung wertlos.
run "assert_haelt"     'fn main(): int64 { var a: int64 := 84; var b: int64 := 2; assert(b != 0); return a / b; }' 42

# ---------------------------------------------------------------------------
# #1790: Multiplikation als Softwareroutine
#
# MULL gehoert zur Mul32-OPTION. Die hat der ESP32, aber KEINER der hier
# verfuegbaren qemu-Kerne (dc232b, dc233c, de212, de233_fpu, dsp3400, lx106,
# sample_controller) — die Kodierung waere also nur durch Konstruktion belegt.
#
# Was das wert ist, hat #1789 gezeigt: dort stand bei IRO_DIV ein `MOVI T0, 0`,
# das jede Pruefung ausser der Ausfuehrung ueberstanden hat. Deshalb dieselbe
# Entscheidung wie bei der Division — Verschieben und Addieren, 32 Schritte.
# Auf JEDEM Xtensa-Kern richtig und hier nachweisbar.
#
# Vorzeichen brauchen keine Sonderbehandlung: im Zweierkomplement ist das untere
# 32-Bit-Ergebnis fuer vorzeichenbehaftet und vorzeichenlos dasselbe. Das ist der
# Unterschied zur Division, wo mit Betraegen gerechnet werden muss.
run "multiplikation"      'fn main(): int64 { var a: int64 := 6; var b: int64 := 7; return a * b; }' 42
run "mult_negativ"        'fn main(): int64 { var a: int64 := 0-6; var b: int64 := 7; return (a * b) + 84; }' 42
run "mult_beide_negativ"  'fn main(): int64 { var a: int64 := 0-6; var b: int64 := 0-7; return a * b; }' 42
run "mult_null"           'fn main(): int64 { var a: int64 := 123; var b: int64 := 0; return (a * b) + 42; }' 42
run "mult_gross"          'fn main(): int64 { var a: int64 := 1000; var b: int64 := 1000; return (a * b) / 25000 + 2; }' 42
# Der Fall, der vor #1790 mit "Illegal instruction" am MULL abbrach.
run "strlen_mal_sieben"   'fn main(): int64 { return StrLen("abcdef"c) * 7; }' 42

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
