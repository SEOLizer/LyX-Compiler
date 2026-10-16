#!/usr/bin/env bash
# tests/ir_rahmen_test.sh — #2061 (riscv) und #2062 (arm64): die IR-Backends
# legen auch grosse Stapelrahmen richtig an und adressieren jeden Slot darin.
#
# Beide Befehlssaetze tragen Direktwerte in zwoelf Bit. Jenseits davon ging es
# auf zwei verschiedene Arten schief:
#
#   riscv  schnitt mit `& 0xFFF` ab — still. Ab 2048 Byte Rahmen lief die
#          Rahmenanlage in die falsche Richtung: aus `addi sp, sp, -2672`
#          wurde `addi sp, sp, +1424`. Das Ergebnis stimmte oft trotzdem;
#          abgestuerzt ist es ab rund 250 Variablen.
#   arm64  meldete seit #1388 laut "Rahmen zu gross" und lehnte jede Funktion
#          mit mehr als 512 Slots ab. Dahinter lag ein zweiter Fehler, den die
#          Meldung verdeckte: die Rahmenanlage fuer grosse Rahmen benutzte ein
#          Befehlswort, das als `neg xzr, x9, lsl #48` dekodiert — sie haette
#          gar keinen Rahmen angelegt.
#
# Ein Skript fuer beide Ziele, weil es dieselbe Grenze ist und dieselben Faelle
# sie pruefen; nur die Pruefung am Erzeugnis ist je Befehlssatz eine andere.
#
# GEMESSEN WIRD ZWEIERLEI:
#   * die Wirkung — Werte an niedrigen, mittleren und hohen Slots, nach einem
#     Aufruf, und die Variablen des Aufrufers danach;
#   * das Erzeugnis — der Prolog senkt den Stapelzeiger um den ganzen Rahmen.
#     Diese Pruefung faengt den Bereich, in dem das Ergebnis frueher zufaellig
#     stimmte.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
. "$(dirname "$0")/lib/qemu.sh"   # #2048: beide Paketnamen
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

# Eine Funktion mit n Variablen; liefert (v0 + v{n-1}) % 200.
schlicht() {
  python3 - "$1" > "$TMP/s$1.lyx" <<'PY'
import sys
n = int(sys.argv[1])
print('unit main;')
print('fn main(): int64 {')
for i in range(n):
    print(f'  var v{i}: int64 := {i};')
print(f'  return (v0 + v{n-1}) % 200;')
print('}')
PY
}

# Eine Funktion mit n Variablen, die NACH der Rahmenanlage etwas ruft und
# danach ihre eigenen Variablen prueft; der Aufrufer prueft die seinen.
# Erwartet: 17 (3+0 + 3+11 aus `blatt`).
mit_aufruf() {
  python3 - "$1" > "$TMP/a$1.lyx" <<'PY'
import sys
n = int(sys.argv[1])
print('unit main;')
print('fn blatt(a: int64): int64 {')
for i in range(12):
    print(f'  var x{i}: int64 := a + {i};')
print('  return x0 + x11;')
print('}')
print('fn gross(): int64 {')
for i in range(n):
    print(f'  var v{i}: int64 := {i};')
print('  var r: int64 := blatt(3);')
print(f'  if (v0 != 0) {{ return 201; }}')
print(f'  if (v{n//2} != {n//2}) {{ return 203; }}')
print(f'  if (v{n-1} != {n-1}) {{ return 202; }}')
print('  return r;')
print('}')
print('fn main(): int64 {')
print('  var m0: int64 := 71; var m1: int64 := 72; var m2: int64 := 73; var m3: int64 := 74;')
print('  var r: int64 := gross();')
print('  if (m0 != 71) { return 10; }')
print('  if (m1 != 72) { return 11; }')
print('  if (m2 != 73) { return 12; }')
print('  if (m3 != 74) { return 13; }')
print('  return r;')
print('}')
PY
}

# n Gleitkommavariablen — die laufen ueber FLD/FSD, einen eigenen Befehlssatz
# mit demselben Zwoelf-Bit-Versatz. Liefert die letzte als Ganzzahl % 200.
gleitkomma() {
  python3 - "$1" > "$TMP/f$1.lyx" <<'PY'
import sys
n = int(sys.argv[1])
print('unit main;')
print('fn main(): int64 {')
# Nicht `f{i}`: f32 und f64 sind reservierte Woerter.
for i in range(n):
    print(f'  var gk{i}: f64 := {i}.0;')
print(f'  var s: f64 := gk0 + gk{n-1};')
print('  return (s as int64) % 200;')
print('}')
PY
}

# $1 Ziel, $2 Beschreibung, $3 Quelle, $4 erwarteter Rueckgabewert
lauf() {
  local ziel="$1" was="$2 [$1]" src="$3" erw="$4" bin="$TMP/b" pre=""
  rm -f "$bin"
  if ! ( cd "$ROOT" && timeout 300 "$LYXC" --target="$ziel" "$src" -o "$bin" ) >"$TMP/bl.log" 2>&1; then
    nok "$was: uebersetzt nicht ($(grep -m1 -E '^lyxc:|error' "$TMP/bl.log"))"; return
  fi
  case "$ziel" in
    arm64) pre="$QEMU_ARM64" ;;
    riscv) pre="$QEMU_RISCV64" ;;
  esac
  [ -n "$pre" ] || { nok "$was: qemu fehlt — NICHT gemessen"; return; }
  local rc
  rc="$( ( timeout 60 "$pre" "$bin" >/dev/null 2>&1 ) 2>/dev/null; echo $? )"
  if [ "$rc" = "$erw" ]; then ok "$was (rc=$rc)"
  else nok "$was: rc=$rc statt $erw"; fi
}

# Groesse des Rahmens, den der erste Prolog mit grossem Rahmen wirklich anlegt,
# aus dem Erzeugnis gelesen — oder ein Kennwort, wenn dort etwas Falsches steht.
#   riscv: lui/addi s11 + `sub sp, sp, s11`
#   arm64: `sub sp, sp, #hoch, lsl #12` und gegebenenfalls `sub sp, sp, #tief`
prolog() {
  python3 - "$1" "$2" <<'PYEOF'
import struct, sys
ziel, pfad = sys.argv[1], sys.argv[2]
d = open(pfad, 'rb').read()
phoff, = struct.unpack_from('<Q', d, 32)
phentsize, phnum = struct.unpack_from('<HH', d, 54)
w = []
for i in range(phnum):
    p = phoff + i * phentsize
    ptype, flags = struct.unpack_from('<II', d, p)
    off, = struct.unpack_from('<Q', d, p + 8)
    filesz, = struct.unpack_from('<Q', d, p + 32)
    if ptype == 1 and (flags & 1):
        w = [struct.unpack_from('<I', d, a)[0] for a in range(off, off + filesz - 3, 4)]
        break
def s12(x):
    return x - 0x1000 if x & 0x800 else x
if ziel == 'riscv':
    for i, x in enumerate(w):
        if (x & 0xFFFFF) == 0x10113:                 # addi sp, sp, imm
            imm = s12(x >> 20)
            if imm > 16:
                print('HOCH+%d' % imm); sys.exit()   # Stapelzeiger nach oben
        if x == 0x41B10133:                          # sub sp, sp, s11
            hi = lo = 0                              # davor: lui s11, hi [addi s11, s11, lo]
            for y in w[max(0, i - 2):i]:
                if (y & 0xFFF) == 0xDB7: hi = (y >> 12) << 12
                if (y & 0xFFFFF) == 0xD8D93: lo = s12(y >> 20)
            print(hi + lo); sys.exit()
    print('KLEIN')
else:
    for i, x in enumerate(w):
        if x == 0xCB09C3FF:                          # das alte, wirkungslose Wort
            print('NEG-XZR'); sys.exit()
        if (x & 0xFFC003FF) == 0xD14003FF:           # sub sp, sp, #hoch, lsl #12
            n = ((x >> 10) & 0xFFF) << 12
            if i + 1 < len(w) and (w[i + 1] & 0xFFC003FF) == 0xD10003FF:
                n += (w[i + 1] >> 10) & 0xFFF
            print(n); sys.exit()
    print('KLEIN')
PYEOF
}

for ZIEL in riscv arm64; do
  echo "=== $ZIEL ==="
  echo "--- GEGENPROBE: ein kleiner Rahmen ging schon immer ---"
  schlicht 100
  lauf "$ZIEL" "100 Variablen" "$TMP/s100.lyx" 99

  echo "--- Werte in grossen Rahmen ---"
  #
  # 250 ist die Zahl, ab der riscv abstuerzte und arm64 ablehnte; 600 und 2000
  # zeigen, dass nicht nur die Schwelle verschoben wurde. 2000 Variablen sind
  # rund 32 KB Rahmen — auf arm64 der Bereich, in dem der Versatz in zwei
  # Schritten gebaut werden muss.
  for n in 250 600 2000; do
    schlicht "$n"
    lauf "$ZIEL" "$n Variablen, erste und letzte" "$TMP/s$n.lyx" $(( (n - 1) % 200 ))
  done

  echo "--- ein AUFRUF aus einem grossen Rahmen ---"
  #
  # Der haertere Fall. Steht der Stapelzeiger falsch (oder gar nicht tiefer),
  # legt die gerufene Funktion ihren Rahmen ueber die Variablen des Rufers.
  for n in 200 400 1000; do
    mit_aufruf "$n"
    lauf "$ZIEL" "$n Variablen, Aufruf, eigene und fremde Variablen danach heil" "$TMP/a$n.lyx" 17
  done

  echo "--- Gleitkomma-Slots ---"
  gleitkomma 300
  lauf "$ZIEL" "300 f64-Variablen: 0.0 + 299.0" "$TMP/f300.lyx" 99

  echo "--- der Prolog legt den GANZEN Rahmen an ---"
  #
  # Am Erzeugnis, fuer 600 Variablen. Erwartet wird die Rahmengroesse, die der
  # Prolog vom Stapelzeiger abzieht: mindestens 600 Slots zu acht Byte. Die
  # Kennworte stehen fuer die beiden alten Fehler — HOCH+n: der Stapelzeiger
  # wandert nach oben (riscv), NEG-XZR: das wirkungslose Befehlswort (arm64).
  schlicht 600
  if ( cd "$ROOT" && timeout 300 "$LYXC" --target="$ZIEL" "$TMP/s600.lyx" -o "$TMP/p600" ) >"$TMP/bl.log" 2>&1; then
    rahmen="$(prolog "$ZIEL" "$TMP/p600")"
    case "$rahmen" in
      ''|*[!0-9]*) nok "Prolog bei 600 Variablen [$ZIEL]: $rahmen statt einer Rahmengroesse" ;;
      *) if [ "$rahmen" -ge 4800 ]; then ok "Prolog bei 600 Variablen [$ZIEL]: senkt den Stapelzeiger um $rahmen Byte"
         else nok "Prolog bei 600 Variablen [$ZIEL]: nur $rahmen Byte — 600 Slots brauchen mindestens 4800"; fi ;;
    esac
  else
    nok "Prolog bei 600 Variablen [$ZIEL]: uebersetzt nicht ($(grep -m1 -E '^lyxc:|error' "$TMP/bl.log"))"
  fi

  echo "--- das Beispiel, an dem es auffiel ---"
  #
  # examples/test_zlib.lyx stuerzte auf riscv ab und war fuer arm64 nicht
  # uebersetzbar. Es muss dieselbe letzte Zeile liefern wie auf x86.
  pre="$QEMU_ARM64"; [ "$ZIEL" = "riscv" ] && pre="$QEMU_RISCV64"
  if ( cd "$ROOT" && timeout 300 "$LYXC" --target="$ZIEL" examples/test_zlib.lyx -o "$TMP/zlib" ) >"$TMP/bl.log" 2>&1; then
    if [ -n "$pre" ]; then
      # #2105: Ausgabe, stderr und Rueckgabewert aufheben — der Abbruch tritt
      # nur im vollen `make test` auf, und bisher sah man nur die letzte Zeile.
      ( timeout 60 "$pre" "$TMP/zlib" >"$TMP/zlib.out" 2>"$TMP/zlib.err" ); zrc=$?
      letzte="$(tail -1 "$TMP/zlib.out")"
      if [ "$letzte" = "Roundtrip successful!" ]; then ok "test_zlib laeuft durch [$ZIEL]"
      else
        nok "test_zlib [$ZIEL]: letzte Zeile '$letzte', rc=$zrc"
        echo "  stderr: $(head -c 400 "$TMP/zlib.err" | tr '\n' ' ')"
        echo "  ulimit -v $(ulimit -v), -s $(ulimit -s); frei: $(free -m | awk '/^Mem/{print $7}') MB"
      fi
    else
      nok "test_zlib [$ZIEL]: qemu fehlt — NICHT gemessen"
    fi
  else
    nok "test_zlib [$ZIEL]: uebersetzt nicht ($(grep -m1 -E '^lyxc:|error' "$TMP/bl.log"))"
  fi
  echo
done

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
