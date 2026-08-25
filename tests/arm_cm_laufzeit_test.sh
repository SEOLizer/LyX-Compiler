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
# Seit #1765 deckt der Test auch Aufrufe, Argumente, globale Variablen,
# Vergleiche und Schleifen ab — dieselbe Kette, die riscv vor #1740 hatte.

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

# ACHTUNG: qemu gibt die Semihosting-Konsole ZEILENWEISE aus. Ein Programm
# ohne abschliessenden Zeilenumbruch sieht deshalb aus, als haette es nichts
# geschrieben — jeder Fall unten endet darum mit einem PrintLn.
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

# ---------------------------------------------------------------------------
# #1765: die Defektkette. Jeder Fall unten war vorher rot, die meisten mit
# Stillstand statt falschem Wert.
# ---------------------------------------------------------------------------
# Der Reset-Rumpf sprang fest auf die ZUERST erzeugte Funktion — stand main
# nicht vorn, lief das Programm in eine fremde Funktion.
ausgabe "main_nicht_zuerst" 'fn vorher(): int64 { return 1; } fn main(): int64 { PrintLn("main laeuft"c); return 0; }' "main laeuft"
ausgabe "aufruf_rueckwaerts" 'fn hilf(): int64 { return 42; } fn main(): int64 { PrintInt(hilf()); PrintLn(""c); return 0; }' "42"
ausgabe "aufruf_vorwaerts"   'fn main(): int64 { PrintInt(spaeter()); PrintLn(""c); return 0; } fn spaeter(): int64 { return 17; }' "17"
# Argumente kamen aus den Slots 0..N-1 statt aus dem Argumentblock, und der
# Callee spillte seine Argumentregister gar nicht erst.
ausgabe "zwei_argumente"  'fn add(a: int64, b: int64): int64 { return a + b; } fn main(): int64 { PrintInt(add(40, 2)); PrintLn(""c); return 0; }' "42"
# Ab dem fuenften Argument geht es ueber den Stapel — vorher fielen sie weg.
ausgabe "fuenf_argumente" 'fn f(a: int64, b: int64, c: int64, d: int64, e: int64): int64 { return e; } fn main(): int64 { PrintInt(f(1,2,3,4,55)); PrintLn(""c); return 0; }' "55"
ausgabe "sechs_argumente" 'fn f(a: int64, b: int64, c: int64, d: int64, e: int64, g: int64): int64 { return a + g; } fn main(): int64 { PrintInt(f(1,2,3,4,5,60)); PrintLn(""c); return 0; }' "61"
ausgabe "rekursion"       'fn fak(n: int64): int64 { if n <= 1 { return 1; } return n * fak(n - 1); } fn main(): int64 { PrintInt(fak(5)); PrintLn(""c); return 0; }' "120"
# MOVS setzt in Thumb die Flags: es stand ZWISCHEN CMP und bedingtem Sprung
# und hat den Vergleich ueberschrieben. Jede Bedingung fiel gleich aus.
ausgabe "vergleiche" 'fn main(): int64 { var a: int64 := 3; var b: int64 := 5; var r: int64 := 0; if a < b { r := r + 1; } if b > a { r := r + 2; } if a <= a { r := r + 4; } if a == a { r := r + 8; } if a != b { r := r + 16; } if b >= a { r := r + 32; } PrintInt(r); PrintLn(""c); return 0; }' "63"
ausgabe "schleife"   'fn main(): int64 { var i: int64 := 0; var s: int64 := 0; while i < 5 { s := s + i; i := i + 1; } PrintInt(s); PrintLn(""c); return 0; }' "10"
# Globale Variablen benutzten ihren Index als Adresse — Zugriff auf 0, und auf
# einem Cortex-M endet das im Stillstand. Sie liegen jetzt im RAM, main setzt
# die Anfangswerte.
ausgabe "global_lesen"     'var g: int64 := 5; fn main(): int64 { PrintInt(g); PrintLn(""c); return 0; }' "5"
ausgabe "global_schreiben" 'var g: int64 := 5; fn bump(): int64 { g := g + 2; return g; } fn main(): int64 { bump(); bump(); PrintInt(g); PrintLn(""c); return 0; }' "9"
# StrLen: der Ausstieg war in Zweibyte-Schritten gezaehlt, cm_ADD ist aber ein
# 32-Bit-Befehl — der Sprung landete auf dem Ruecksprung, die Schleife lief
# endlos.
ausgabe "strlen" 'fn main(): int64 { PrintInt(StrLen("abcdef"c)); PrintLn(""c); return 0; }' "6"
# Slots wurden mit ACHT Bit Offset vom Rahmenzeiger adressiert: ab Slot 63 traf
# der Zugriff einen fremden Slot. IntToStrIn schrieb dadurch "10" statt "1234".
ausgabe "inttostrin"  'import src.std.string_in; fn main(): int64 { var b: int64 := 0x20001800; var n: int64 := IntToStrIn(0-1234, b, 32); var s: pchar := b as pchar; PrintLn(s); return 0; }' "-1234"
ausgabe "strsubin"    'import src.std.string_in; fn main(): int64 { var b: int64 := 0x20001800; var m: int64 := StrSubIn("abcdef"c, 2, 3, b, 32); var s: pchar := b as pchar; PrintLn(s); return 0; }' "cde"

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
