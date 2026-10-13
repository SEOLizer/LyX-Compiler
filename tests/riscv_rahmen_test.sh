#!/usr/bin/env bash
# tests/riscv_rahmen_test.sh — #2061: riscv legt auch grosse Stapelrahmen
# richtig an und adressiert jeden Slot darin.
#
# ADDI, LD und SD tragen ihren Direktwert in zwoelf Bit (-2048 … 2047). Das
# Backend schnitt groessere Werte mit `& 0xFFF` ab — still. Ab 2048 Byte
# Rahmen (rund 128 lokale Variablen) lief die Rahmenanlage in die falsche
# Richtung: aus `addi sp, sp, -2672` wurde `addi sp, sp, +1424`.
#
# Das Tueckische: das Ergebnis stimmte oft trotzdem. Eine Funktion mit 160
# Variablen, die nichts mehr ruft, lieferte den richtigen Wert; sichtbar
# abgestuerzt ist es erst ab rund 250, mit einem Aufruf darin ab 200. Ein Test
# auf "rechnet richtig" haette den Fehler bei 160 nicht gesehen.
#
# GEMESSEN WIRD DESHALB ZWEIERLEI:
#   * die Wirkung — Werte an niedrigen, mittleren und hohen Slots, nach einem
#     Aufruf, und die Variablen des Aufrufers danach;
#   * das Erzeugnis — kein Prolog darf den Stapelzeiger nach oben setzen.
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

# $1 Beschreibung, $2 Quelle, $3 erwarteter Rueckgabewert
riscv_lauf() {
  local was="$1" src="$2" erw="$3" bin="$TMP/b"
  rm -f "$bin"
  if ! ( cd "$ROOT" && timeout 300 "$LYXC" --target=riscv "$src" -o "$bin" ) >"$TMP/bl.log" 2>&1; then
    nok "$was: uebersetzt nicht ($(grep -m1 -E '^lyxc:|error' "$TMP/bl.log"))"; return
  fi
  [ -n "$QEMU_RISCV64" ] || { nok "$was: qemu fehlt — NICHT gemessen"; return; }
  local rc
  rc="$( ( timeout 60 "$QEMU_RISCV64" "$bin" >/dev/null 2>&1 ) 2>/dev/null; echo $? )"
  if [ "$rc" = "$erw" ]; then ok "$was (rc=$rc)"
  else nok "$was: rc=$rc statt $erw"; fi
}

echo "--- GEGENPROBE: ein kleiner Rahmen ging schon immer ---"
schlicht 100
riscv_lauf "100 Variablen" "$TMP/s100.lyx" 99

echo
echo "--- #2061: Werte in grossen Rahmen ---"
#
# 250 ist die Zahl, ab der es vorher abstuerzte; 600 und 2000 zeigen, dass
# nicht nur die Schwelle verschoben wurde.
for n in 250 600 2000; do
  schlicht "$n"
  riscv_lauf "$n Variablen, erste und letzte" "$TMP/s$n.lyx" $(( (n - 1) % 200 ))
done

echo
echo "--- #2061: ein AUFRUF aus einem grossen Rahmen ---"
#
# Der haertere Fall. Steht der Stapelzeiger falsch, legt die gerufene Funktion
# ihren Rahmen ueber fremden Speicher. Vorher: Absturz ab 200 Variablen.
for n in 200 400 1000; do
  mit_aufruf "$n"
  riscv_lauf "$n Variablen, Aufruf, eigene und fremde Variablen danach heil" "$TMP/a$n.lyx" 17
done

echo
echo "--- #2061: Gleitkomma-Slots (FLD/FSD) ---"
gleitkomma 300
riscv_lauf "300 f64-Variablen: 0.0 + 299.0" "$TMP/f300.lyx" 99

echo
echo "--- #2061: kein Prolog setzt den Stapelzeiger nach OBEN ---"
#
# Die Pruefung am Erzeugnis, fuer genau den Bereich, in dem das Ergebnis
# vorher zufaellig stimmte (160 Variablen). Gesucht wird `addi sp, sp, imm`
# mit positivem imm ueber 16 — die 16 gehoeren dem Epilog, der den
# Sicherungsbereich abraeumt. Vor dem Fix stand dort +1424.
schlicht 160
if ( cd "$ROOT" && timeout 300 "$LYXC" --target=riscv "$TMP/s160.lyx" -o "$TMP/p160" ) >"$TMP/bl.log" 2>&1; then
  hoch="$(python3 - "$TMP/p160" <<'PY'
import struct, sys
d = open(sys.argv[1], 'rb').read()
# ELF64: e_phoff @32, e_phentsize @54, e_phnum @56; erstes PT_LOAD mit X
phoff, = struct.unpack_from('<Q', d, 32)
phentsize, phnum = struct.unpack_from('<HH', d, 54)
funde = []
for i in range(phnum):
    p = phoff + i * phentsize
    ptype, flags = struct.unpack_from('<II', d, p)
    off, = struct.unpack_from('<Q', d, p + 8)
    filesz, = struct.unpack_from('<Q', d, p + 32)
    if ptype != 1 or not (flags & 1):
        continue
    for a in range(off, off + filesz - 3, 4):
        w, = struct.unpack_from('<I', d, a)
        if (w & 0xFFFFF) == 0x10113:          # addi sp, sp, imm
            imm = w >> 20
            if imm & 0x800:
                imm -= 0x1000
            if imm > 16:
                funde.append(imm)
print(' '.join(str(x) for x in funde))
PY
)"
  if [ -z "$hoch" ]; then
    ok "160 Variablen: der Prolog senkt den Stapelzeiger (kein addi sp, sp, +n)"
  else
    nok "160 Variablen: der Stapelzeiger wird nach OBEN gesetzt (addi sp, sp, +$hoch)"
  fi
else
  nok "160 Variablen: uebersetzt nicht ($(grep -m1 -E '^lyxc:|error' "$TMP/bl.log"))"
fi

echo
echo "--- das Beispiel, an dem es auffiel ---"
#
# examples/test_zlib.lyx stuerzte auf riscv ab. Es muss dieselbe letzte Zeile
# liefern wie auf x86.
if ( cd "$ROOT" && timeout 300 "$LYXC" --target=riscv examples/test_zlib.lyx -o "$TMP/zlib" ) >"$TMP/bl.log" 2>&1; then
  if [ -n "$QEMU_RISCV64" ]; then
    letzte="$( ( timeout 60 "$QEMU_RISCV64" "$TMP/zlib" 2>/dev/null | tail -1 ) 2>/dev/null )"
    if [ "$letzte" = "Roundtrip successful!" ]; then ok "test_zlib laeuft auf riscv durch"
    else nok "test_zlib auf riscv: letzte Zeile '$letzte'"; fi
  else
    nok "test_zlib: qemu fehlt — NICHT gemessen"
  fi
else
  nok "test_zlib uebersetzt nicht fuer riscv ($(grep -m1 -E '^lyxc:|error' "$TMP/bl.log"))"
fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
