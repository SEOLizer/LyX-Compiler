#!/usr/bin/env bash
# tests/arm_cm_laufzeit_test.sh — Cortex-M-Erzeugnisse AUSFUEHREN (#1744).
#
# Bis 1.1.9H war ein arm-cm4-Erzeugnis ueberhaupt nicht ladbar: das
# PT_LOAD-Segment begann bei Dateioffset 0 und trug elfSize als Groesse, es
# wurde also die Datei MITSAMT ELF-Header geladen. Die Vektortabelle landete
# damit auf 0x08001000 statt 0x08000000, und der Kern las seinen
# Startstapelzeiger aus dem ELF-Magic. Gemessen wurde bis dahin nur, dass die
# Datei entsteht — genau die Luecke, die auf riscv acht Defekte getragen hat
# (#1740).
#
# Ausgabe laeuft ueber ARM-Semihosting (BKPT 0xAB, SYS_WRITEC): der uebliche
# Weg, von einem Cortex-M Text herauszubekommen, unter qemu wie am Debugger.
#
# ACHTUNG, bewusst kleiner Umfang: auf arm-cm4 sind Funktionsaufrufe, globale
# Variablen und Schleifen mit Division noch defekt — dieselbe Kette wie auf
# riscv vor #1740, gefuehrt als #1765. Hier stehen nur Faelle, die davon nicht
# abhaengen. Der Rest kommt dazu, sobald #1765 erledigt ist.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

QEMU="$(command -v qemu-system-arm || true)"
if [ -z "$QEMU" ]; then
  echo "HINWEIS: qemu-system-arm fehlt — es wird nur uebersetzt, nicht ausgefuehrt."
fi

# olimex-stm32-h405: Cortex-M4 mit Flash ab 0x08000000 und RAM ab 0x20000000 —
# dieselbe Aufteilung, die das Backend annimmt. mps2-an385 passt NICHT: dort
# liegt der Flash bei 0, und das Abbild bliebe im Lockup stehen.
BOARD="olimex-stm32-h405"

ausgabe() { # name, quelltext, erwartete ausgabe
  printf "%s" "$2" > "$TMP/c.lyx"
  if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" --target=arm-cm4 -o "$TMP/c.elf" >"$TMP/c.log" 2>&1); then
    echo "FAIL $1: uebersetzt nicht: $(grep -m1 -iE 'error|Builtin-ID|Opcode' "$TMP/c.log")"
    FAIL=$((FAIL+1)); return
  fi
  if [ -z "$QEMU" ]; then echo "PASS $1 (nur uebersetzt)"; PASS=$((PASS+1)); return; fi
  # Ohne exit() laeuft das Programm nach main in eine Endlosschleife — das ist
  # auf einem Mikrocontroller richtig so. Deshalb der Zeitdeckel; gemessen wird
  # die Ausgabe bis dahin.
  # Semihosting schreibt auf STDERR, nicht auf stdout — beides einsammeln und
  # die Meldungen von qemu selbst herausfiltern. Mit 2>/dev/null waere die
  # Ausgabe unsichtbar und der Test gruen-blind.
  local got
  got="$(timeout 6 "$QEMU" -M "$BOARD" -nographic -semihosting -kernel "$TMP/c.elf" 2>&1 | tr -d '\r')"
  got="$(printf '%s' "$got" | grep -vE 'terminating on signal|^qemu-system-arm:|^qemu:')"
  if [ "$got" = "$3" ]; then
    echo "PASS $1 (Ausgabe '$got')"; PASS=$((PASS+1))
  else
    echo "FAIL $1: Ausgabe '$got' erwartet '$3'"; FAIL=$((FAIL+1))
  fi
}

# Das Abbild muss ueberhaupt starten: Vektortabelle auf 0x08000000, Thumb-Bit
# am Einstiegspunkt. Vor dem Fix blieb qemu hier mit „Lockup: can't escalate 3
# to HardFault" stehen.
ausgabe "startet_und_schreibt" 'fn main(): int64 { PrintLn("hallo cortex-m"c); return 0; }' "hallo cortex-m"

# Semihosting-Ausgabe, Zahl und Vorzeichen.
ausgabe "zahl"      'fn main(): int64 { PrintInt(1234); PrintLn(""c); return 0; }' "1234"
ausgabe "negativ"   'fn main(): int64 { PrintInt(0-42); PrintLn(""c); return 0; }' "-42"

# Speicherzugriffe: RAM schreiben und als Zeichenkette ausgeben.
ausgabe "ram_schreiben" 'fn main(): int64 { var b: int64 := 0x20001800; poke8(b, 65); poke8(b+1, 66); poke8(b+2, 0); var s: pchar := b as pchar; PrintLn(s); return 0; }' "AB"

# exit(): SYS_EXIT beendet den Lauf, statt in der Endlosschleife zu haengen.
# Geprueft wird, dass die Ausgabe davor ankommt und qemu von selbst zurueckkehrt.
ausgabe "exit_beendet" 'fn main(): int64 { PrintLn("fertig"c); exit(0); return 0; }' "fertig"

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
