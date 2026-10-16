#!/usr/bin/env bash
# tests/ir_sprungweite_test.sh — #2112: grosse Programme auf arm64 und riscv.
#
# Ein `main` mit rund 750 poke8 stuerzte auf arm64 vor der ersten Ausgabe ab
# (SIGILL, darueber SIGSEGV), x86 lief. Ursache war keine Sprungweite, sondern
# ein fester 128-KiB-Puffer in lyxc.lyx (emitARM64): der Code wurde per memcpy
# darueber hinaus kopiert, das Codeende danach ueberschrieben — der erste
# Aufruf (alloc) zielte in Nullen.
#
# Beim Nachmessen fanden sich auf beiden Zielen weitere feste Grenzen, die
# still abschnitten — jede hier mit einem eigenen Fall:
#   - arm64: Patchliste fest 1024 (ueber das ganze Programm) → gut tausend
#     Aufrufe, und der Rest blieb BL +0 (Endlosschleife)
#   - arm64 + riscv: Funktionstabelle fest 256, Markentabelle fest 1024
#   - riscv: BEQ/BNE (+/-4 KiB) fuer jeden bedingten Sprung — ein while-Rumpf
#     ueber rund 16 poke8 sprang beim Verlassen irgendwohin; JAL (+/-1 MiB)
#     fuer jeden Aufruf — ab 1 MiB Code traf der Aufruf von alloc ins Leere
#
# Gemessen wird der WERT: "VOR" und die Summe der geschriebenen Bytes, gegen
# die in Python gerechnete Erwartung. Fuer einen bedingten Sprung ueber mehr
# als 1 MiB innerhalb EINER Funktion darf der Compiler laut ablehnen — oder
# richtig uebersetzen; ein still falsches Programm ist in beiden Faellen rot.
set -uo pipefail
ulimit -c 0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
. "$(dirname "$0")/lib/qemu.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

if [ -z "$QEMU_ARM64" ];   then echo "FAIL qemu-aarch64 fehlt — NICHT gemessen"; exit 1; fi
if [ -z "$QEMU_RISCV64" ]; then echo "FAIL qemu-riscv64 fehlt — NICHT gemessen"; exit 1; fi

# Der Generator aus dem Issue, woertlich.
cat > "$TMP/mini.py" <<'EOF'
# mini.py <n> <out.lyx>
import sys
n = int(sys.argv[1])
L = ['import std.alloc;', 'import std.io;',
     'fn tief(a: int64, b: int64): int64 {', '    var s: int64 := 0;', '    var i: int64 := 0;',
     '    while (i < b) { s := s + peek8(a + i); i := i + 1; }', '    return s;', '}',
     'fn main(): int64 {', '    var junk: int64 := alloc(8192);']
for i in range(n):
    L.append('    poke8(junk + %d, %d);' % (i, (i * 7) % 251 + 1))
L += ['    PrintLn("VOR"c);', '    PrintLn(IntToStr(tief(junk, %d)));' % n, '    return 0;', '}']
open(sys.argv[2], 'w').write('\n'.join(L) + '\n')
EOF

# Weitere Formen: gen.py <art> <n> <out.lyx>; gibt die erwartete Ausgabe aus.
cat > "$TMP/gen.py" <<'EOF'
import sys
art, n, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
b = lambda i: (i * 7) % 251 + 1
L = ['import std.alloc;', 'import std.io;',
     'fn tief(a: int64, b: int64): int64 {', '    var s: int64 := 0;', '    var i: int64 := 0;',
     '    while (i < b) { s := s + peek8(a + i); i := i + 1; }', '    return s;', '}',
     'fn eins(): int64 { return 1; }']
if art == 'funcs':
    for k in range(n):
        L.append('fn g_%d(x: int64): int64 { return x + %d; }' % (k, k))
L += ['fn main(): int64 {', '    var junk: int64 := alloc(%d);' % (n + 8),
      '    var flag: int64 := GetArgC();']
pokes = ['    poke8(junk + %d, %d);' % (i, b(i)) for i in range(n)]
if art == 'mini':
    L += pokes
    erw = sum(b(i) for i in range(n))
elif art == 'while':
    L += ['    var w: int64 := 0;', '    while (w < flag) {'] + pokes + ['    w := w + 1;', '    }']
    erw = sum(b(i) for i in range(n))
elif art == 'if':
    L += ['    if (flag == 1) {'] + pokes + ['    }']
    erw = sum(b(i) for i in range(n))
elif art == 'calls':
    L += ['    var s: int64 := 0;'] + ['    s := s + eins();'] * n
    erw = n
elif art == 'ifs':
    L.append('    var s: int64 := 0;')
    for i in range(n):
        L.append('    if (flag == 1) { s := s + %d; } else { s := s - 1; }' % (i % 7 + 1))
    erw = sum(i % 7 + 1 for i in range(n))
elif art == 'funcs':
    erw = n
L.append('    PrintLn("VOR"c);')
if art in ('calls', 'ifs'):
    L.append('    PrintLn(IntToStr(s));')
elif art == 'funcs':
    L.append('    PrintLn(IntToStr(g_%d(1)));' % (n - 1))
else:
    L.append('    PrintLn(IntToStr(tief(junk, %d)));' % n)
L += ['    return 0;', '}']
open(out, 'w').write('\n'.join(L) + '\n')
print('VOR|%d|' % erw)
EOF

uebersetze() {  # ziel, quelle, binary → rc
  ( cd "$ROOT" && timeout 240 "$LYXC" --std-path="$ROOT" --target="$1" "$2" -o "$3" ) >"$TMP/bl.log" 2>&1
}
fuehre() {  # ziel, binary → Ausgabe in $TMP/out, rc
  local q="$QEMU_ARM64"; [ "$1" = riscv ] && q="$QEMU_RISCV64"
  ( cd "$TMP" && timeout 60 "$q" "$2" >"$TMP/out" 2>/dev/null )
}

# Wert messen: Uebersetzen muss gelingen, Ausgabe muss stimmen.
pruefe() {  # name, ziel, art, n
  local src="$TMP/p.lyx" bin="$TMP/p" soll
  rm -f "$bin"
  if [ "$3" = issue ]; then
    python3 "$TMP/mini.py" "$4" "$src"
    soll="$(python3 "$TMP/gen.py" mini "$4" "$TMP/ungenutzt.lyx")"
  else
    soll="$(python3 "$TMP/gen.py" "$3" "$4" "$src")"
  fi
  if ! uebersetze "$2" "$src" "$bin"; then
    nok "$1 [$2]: uebersetzt nicht ($(grep -m1 -iE 'error' "$TMP/bl.log"))"; return
  fi
  fuehre "$2" "$bin"; local rc=$?
  local ist; ist="$(tr '\n' '|' < "$TMP/out")"
  if [ "$rc" = 0 ] && [ "$ist" = "$soll" ]; then ok "$1 [$2]: $ist"
  else nok "$1 [$2]: [$ist] rc=$rc statt [$soll] rc=0"; fi
}

# Ueber 1 MiB in einer Funktion: laute Ablehnung ODER richtiger Wert.
pruefe_grenze() {  # name, ziel, art, n
  local src="$TMP/p.lyx" bin="$TMP/p" soll
  rm -f "$bin"
  soll="$(python3 "$TMP/gen.py" "$3" "$4" "$src")"
  if ! uebersetze "$2" "$src" "$bin"; then
    if grep -q 'ueberschreitet die Reichweite' "$TMP/bl.log"; then
      ok "$1 [$2]: laut abgelehnt ($(grep -m1 -o 'error: .*' "$TMP/bl.log" | cut -c1-100))"
    else
      nok "$1 [$2]: abgelehnt, aber ohne Reichweitenmeldung ($(grep -m1 -iE 'error' "$TMP/bl.log"))"
    fi
    return
  fi
  fuehre "$2" "$bin"; local rc=$?
  local ist; ist="$(tr '\n' '|' < "$TMP/out")"
  if [ "$rc" = 0 ] && [ "$ist" = "$soll" ]; then ok "$1 [$2]: $ist"
  else nok "$1 [$2]: still falsch — [$ist] rc=$rc statt [$soll]"; fi
}

for ziel in arm64 riscv; do
  # Der Fall aus dem Issue; 4500 und 8000 liegen ueber 1 MiB Code (riscv:
  # JAL-Grenze fuer den Aufruf von alloc/tief hinter main).
  for n in 700 750 1200 4500 8000; do
    pruefe "Issue-Generator n=$n" "$ziel" issue "$n"
  done
  pruefe "while-Rumpf mit 40 poke8 (ueber 4 KiB)"  "$ziel" while 40
  pruefe "while-Rumpf mit 300 poke8"               "$ziel" while 300
  pruefe "1100 Aufrufe (ueber 1024 Patches)"       "$ziel" calls 1100
  pruefe "300 Funktionen (ueber 256)"              "$ziel" funcs 300
  pruefe "700 if/else (ueber 1024 Marken)"         "$ziel" ifs 700
  pruefe "if-Rumpf mit 2000 poke8"                 "$ziel" if 2000
  pruefe_grenze "if-Rumpf mit 9000 poke8 (ueber 1 MiB)" "$ziel" if 9000
done

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
