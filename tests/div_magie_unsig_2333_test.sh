#!/usr/bin/env bash
# tests/div_magie_unsig_2333_test.sh — #2333: VORZEICHENLOSE Division und Rest
# durch einen beliebigen konstanten Divisor ohne `div`.
#
# #2330 Schritt 2 (tests/div_magie_2330_test.sh) nahm nur vorzeichenbehaftete
# Dividenden; vorzeichenlos fiel ausdruecklich auf `div` zurueck. Der Faktor
# wird dort anders gerechnet (`magicu` statt `magics`; Warren, Hacker's
# Delight, Kap. 10-9), und er passt fuer einen TEIL der Divisoren nicht in
# 64 Bit. Fuer diese Faelle kommt eine Stufe mit Uebertrag dazu:
#
#   a == 0:   q = (M*n >>u 64) >>u s                      (ein Shift)
#   a == 1:   t = M*n >>u 64
#             q = ((n - t) >>u 1 + t) >>u (s-1)           (vier Befehle)
#
# Abgezaehlt ueber alle Nicht-Zweierpotenzen von 3 bis 19999: **5896 Divisoren
# brauchen die Zusatzstufe (a == 1), 14088 nicht (a == 0)**. Ein Test mit nur
# einer Sorte haette die halbe Umsetzung nicht ausgefuehrt. In der Liste unten
# stehen deshalb beide Sorten, jede namentlich benannt.
#
# Geprueft wird in fuenf Richtungen:
#
#   1. DIFFERENTIELL gegen den `div`-Weg, mit Werten im OBEREN Bereich
#      (2^64-1, 2^64-2, 2^63, 2^63-1, 2^63+1). Dort schlaegt ein falscher
#      Faktor zu, und dort hat #1352 schon einmal zugeschlagen (2^64-2 durch 2
#      ergab -1). Ein Erwartungswert von Hand waere hier der unsicherste Teil
#      des Tests — gegengerechnet wird gegen die Maschine.
#   2. AM ERZEUGNIS, beide Seiten: mit Literal keine eigene Division, mit
#      verdecktem Divisor MUSS eine drin sein.
#   3. WELCHER Befehl: der vorzeichenlose Weg braucht `mul rcx` (48 F7 E1),
#      der vorzeichenbehaftete `imul rcx` (48 F7 E9). Beide werden im
#      Erzeugnis nachgewiesen — sonst wuerde der Test auch bestehen, wenn der
#      vorzeichenlose Dividend still ueber den vorzeichenbehafteten Faktor
#      laeuft (das waere falsch, der Faktor ist ein anderer).
#   4. GEGENSEITE DER ERKENNUNG: ein vorzeichenbehafteter Dividend nimmt
#      weiter den Weg aus #2330 und nicht den neuen.
#   5. GRENZEN: Divisoren bis dicht unter 2^63 (2^62-1 braucht die
#      Zusatzstufe mit s = 62) rechnen richtig; 0, 1, 2 und Zweierpotenzen
#      bleiben bei den Wegen aus Schritt 1 bzw. bei `div`.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ulimit -c 0
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

baue() { (cd "$TMP" && timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/$1.lyx" -o "$TMP/$1" >"$TMP/$1.log" 2>&1); }

divzahl() {   # Datei -> Anzahl div/idiv (48 F7 /6 oder /7)
  python3 -I - "$1" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
print(sum(1 for i in range(len(d)-2)
          if d[i] == 0x48 and d[i+1] == 0xF7 and (d[i+2] >> 3 & 7) in (6, 7)))
PY
}

bytefolge() { # Datei Hexfolge -> Anzahl Vorkommen
  python3 -I - "$1" "$2" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
m = bytes.fromhex(sys.argv[2])
n = 0; i = d.find(m)
while i >= 0:
    n += 1; i = d.find(m, i + 1)
print(n)
PY
}

# Die Divisoren, nach Faktorart getrennt — abgezaehlt mit `magicu`:
#   a == 0 (ein Shift):       3, 5, 9, 10, 15, 19, 65537, 1000000007, 4294967297
#   a == 1 (Zusatzstufe):     7, 21, 23, 25, 100, 1000, 7919, 2147483647
# Dazu 4611686018427387903 (2^62-1, a == 1, s == 62) als obere Grenze.
DIVS_A0="3 5 9 10 15 19 65537 1000000007 4294967297"
DIVS_A1="7 21 23 25 100 1000 7919 2147483647 4611686018427387903"
DIVS="$DIVS_A0 $DIVS_A1"

# ---------------------------------------------------------------- 1
python3 -I - "$TMP/diff.lyx" "$DIVS" <<'PY'
import sys
pfad, divs = sys.argv[1], sys.argv[2].split()
L = []
L.append('unit main;')
L.append('import std.io;')
L.append('import std.alloc;')
L.append('// Der Divisor kommt aus einer Tabelle — der Compiler kann ihn nicht')
L.append('// zusammenfalten und muss `div` nehmen. Das ist die Gegenseite.')
L.append('var tab: int64;')
L.append('fn verdeckt(i: int64): int64 { return peek64(tab + i * 8); }')
for i, d in enumerate(divs):
    L.append('fn kd%d(x: uint64): uint64 { return x / %s; }' % (i, d))
    L.append('fn km%d(x: uint64): uint64 { return x %% %s; }' % (i, d))
L.append('fn konstD(x: uint64, i: int64): uint64 {')
for i in range(len(divs)):
    L.append('  if (i == %d) { return kd%d(x); }' % (i, i))
L.append('  return 0 as uint64;')
L.append('}')
L.append('fn konstM(x: uint64, i: int64): uint64 {')
for i in range(len(divs)):
    L.append('  if (i == %d) { return km%d(x); }' % (i, i))
L.append('  return 0 as uint64;')
L.append('}')
L.append('fn main(): int64 {')
L.append('  tab := alloc(%d);' % (8 * len(divs)))
for i, d in enumerate(divs):
    L.append('  poke64(tab + %d, %s);' % (i * 8, d))
# Werte als BITMUSTER. Der obere Bereich ist der Punkt des Tests.
vals = ['0', '1', '2', '0 - 1', '0 - 2', '0 - 3', '1 << 63', '0 - 1 - (1 << 63)',
        '(1 << 63) + 1', '1 << 62', '(1 << 62) - 1', '1000000', '1000000007',
        '0 - 1000000007', '7919', '(1 << 32) - 1', '1 << 32', '0 - (1 << 32)',
        '123456789123456789']
L.append('  var n: int64 := %d;' % len(vals))
L.append('  var vals: int64 := alloc(n * 8);')
for j, v in enumerate(vals):
    L.append('  poke64(vals + %d, %s);' % (j * 8, v))
L.append('  var schlecht: int64 := 0;')
L.append('  var geprueft: int64 := 0;')
L.append('  var i: int64 := 0;')
L.append('  while (i < %d) {' % len(divs))
L.append('    var d: uint64 := verdeckt(i) as uint64;')
L.append('    var j: int64 := 0;')
L.append('    while (j < n) {')
L.append('      var x: uint64 := peek64(vals + j * 8) as uint64;')
L.append('      var a: uint64 := konstD(x, i);')
L.append('      var b: uint64 := x / d;')
L.append('      if (a != b) { schlecht := schlecht + 1;')
L.append('        Print("DIV i="); Print(IntToStr(i)); Print(" j="); Print(IntToStr(j));')
L.append('        Print(" konst="); Print(IntToStr(a as int64)); Print(" div="); PrintLn(IntToStr(b as int64)); }')
L.append('      var c: uint64 := konstM(x, i);')
L.append('      var e: uint64 := x % d;')
L.append('      if (c != e) { schlecht := schlecht + 1;')
L.append('        Print("MOD i="); Print(IntToStr(i)); Print(" j="); Print(IntToStr(j));')
L.append('        Print(" konst="); Print(IntToStr(c as int64)); Print(" div="); PrintLn(IntToStr(e as int64)); }')
L.append('      geprueft := geprueft + 2;')
L.append('      j := j + 1;')
L.append('    }')
L.append('    i := i + 1;')
L.append('  }')
L.append('  Print("GEPRUEFT "); PrintLn(IntToStr(geprueft));')
L.append('  if (schlecht == 0) { PrintLn("DIFF OK"); return 0; }')
L.append('  Print("DIFF ROT "); PrintLn(IntToStr(schlecht));')
L.append('  return 1;')
L.append('}')
open(pfad, 'w').write('\n'.join(L) + '\n')
PY

if baue diff; then
  AUS="$("$TMP/diff" 2>&1)"
  ANZ="$(printf '%s' "$AUS" | sed -n 's/^GEPRUEFT //p')"
  if printf '%s' "$AUS" | grep -q '^DIFF OK$' && [ "${ANZ:-0}" -ge 600 ]; then
    ok "differentiell gegen div ($ANZ Faelle, 18 Divisoren x 19 Werte x 2 Operationen)"
  else
    no "differentiell gegen div" "$(printf '%s' "$AUS" | head -12)"
  fi
else
  no "differentiell gegen div" "uebersetzt nicht: $(tail -5 "$TMP/diff.log")"
fi

# ---------------------------------------------------------------- 2 + 3
cat > "$TMP/ukonst.lyx" <<'EOF'
unit main;
fn r(x: uint64, w: int64): uint64 {
  if (w == 1) { return x / 1000; }     // a == 1, Zusatzstufe
  if (w == 2) { return x % 1000; }
  if (w == 3) { return x / 7; }        // a == 1
  if (w == 4) { return x % 7; }
  if (w == 5) { return x / 3; }        // a == 0
  return x % 3;
}
fn main(): int64 { return (r(7777 as uint64, 2) as int64) - 777; }
EOF
cat > "$TMP/vkonst.lyx" <<'EOF'
unit main;
fn r(x: int64, w: int64): int64 {
  if (w == 1) { return x / 1000; }
  if (w == 2) { return x % 1000; }
  if (w == 3) { return x / 15; }
  return x % 3;
}
fn main(): int64 { return r(7777, 2) - 777; }
EOF
cat > "$TMP/uvar.lyx" <<'EOF'
unit main;
import std.alloc;
var t: int64;
fn r(x: uint64): uint64 { return x / (peek64(t) as uint64); }
fn main(): int64 { t := alloc(8); poke64(t, 1000); return (r(7777 as uint64) as int64) - 7; }
EOF
cat > "$TMP/leer.lyx" <<'EOF'
unit main;
fn main(): int64 { return 0; }
EOF
baue leer; GRUND="$(divzahl "$TMP/leer")"

if baue ukonst; then
  N="$(divzahl "$TMP/ukonst")"
  if [ "$N" -eq "$GRUND" ]; then ok "vorzeichenlos mit Literal: keine eigene Division ($N == Grundstand $GRUND)"
  else no "vorzeichenlos mit Literal" "$N Divisionen, Grundstand ist $GRUND"; fi
  if "$TMP/ukonst"; then ok "vorzeichenlose Literal-Fassung rechnet richtig (7777 % 1000 == 777)"
  else no "vorzeichenlose Literal-Fassung" "rc != 0"; fi
  # Richtung 3: mul, nicht imul.
  MUL="$(bytefolge "$TMP/ukonst" 48f7e1)"
  if [ "$MUL" -ge 1 ]; then ok "Erzeugnis enthaelt mul rcx (48 F7 E1), $MUL mal"
  else no "mul rcx fehlt" "der vorzeichenlose Weg wurde nicht genommen"; fi
else
  no "vorzeichenlos mit Literal" "uebersetzt nicht: $(tail -5 "$TMP/ukonst.log")"
fi

if baue uvar; then
  NV="$(divzahl "$TMP/uvar")"
  if [ "$NV" -gt "$GRUND" ]; then ok "verdeckter Divisor: Division bleibt drin ($NV > $GRUND)"
  else no "verdeckter Divisor" "$NV Divisionen, Grundstand $GRUND — die Weiche greift zu weit"; fi
  if "$TMP/uvar"; then ok "verdeckte Fassung rechnet richtig (7777 / 1000 == 7)"
  else no "verdeckte Fassung" "rc != 0"; fi
else
  no "verdeckter Divisor" "uebersetzt nicht: $(tail -5 "$TMP/uvar.log")"
fi

# ---------------------------------------------------------------- 4
if baue vkonst; then
  NS="$(divzahl "$TMP/vkonst")"
  if [ "$NS" -eq "$GRUND" ]; then ok "vorzeichenbehaftet weiter ohne Division ($NS == $GRUND)"
  else no "vorzeichenbehaftet" "$NS Divisionen, Grundstand $GRUND"; fi
  IMUL="$(bytefolge "$TMP/vkonst" 48f7e9)"
  MULS="$(bytefolge "$TMP/vkonst" 48f7e1)"
  if [ "$IMUL" -ge 1 ]; then ok "vorzeichenbehaftet nutzt imul rcx (48 F7 E9), $IMUL mal"
  else no "imul rcx fehlt" "der Weg aus #2330 wurde nicht genommen"; fi
  if [ "$MULS" -eq 0 ]; then ok "vorzeichenbehaftet enthaelt KEIN mul rcx"
  else no "mul rcx im vorzeichenbehafteten Erzeugnis" "$MULS mal — die Wege sind vertauscht"; fi
  if "$TMP/vkonst"; then ok "vorzeichenbehaftete Fassung rechnet weiter richtig"
  else no "vorzeichenbehaftete Fassung" "rc != 0"; fi
else
  no "vorzeichenbehaftet" "uebersetzt nicht: $(tail -5 "$TMP/vkonst.log")"
fi

# ---------------------------------------------------------------- 5
# Zweierpotenzen und die kleinen Divisoren gehoeren nicht hierher: sie laufen
# ueber Schritt 1 (shr/and) bzw. bleiben bei der Division. Geprueft wird, dass
# sie RICHTIG rechnen und keine Magie-Multiplikation bekommen.
cat > "$TMP/klein.lyx" <<'EOF'
unit main;
fn a(x: uint64): uint64 { return x / 1; }
fn b(x: uint64): uint64 { return x / 2; }
fn c(x: uint64): uint64 { return x / 4096; }
fn d(x: uint64): uint64 { return x % 2; }
fn main(): int64 {
  var m: uint64 := (0 - 2) as uint64;          // 2^64-2
  if ((a(m) as int64) != (0 - 2)) { return 1; }
  if ((b(m) as int64) != (0 - 1 - (1 << 63))) { return 2; }   // (2^64-2)/2 = 2^63-1
  if ((c(m) as int64) != 4503599627370495) { return 3; }
  if ((d(m) as int64) != 0) { return 4; }
  return 0;
}
EOF
if baue klein; then
  if "$TMP/klein"; then ok "Zweierpotenzen und 1 rechnen richtig (2^64-2 inklusive)"
  else no "Zweierpotenzen" "rc=$? — der Weg aus Schritt 1 rechnet falsch"; fi
  NK="$(divzahl "$TMP/klein")"
  if [ "$NK" -eq "$GRUND" ]; then ok "Zweierpotenzen ohne eigene Division ($NK == $GRUND)"
  else no "Zweierpotenzen" "$NK Divisionen statt $GRUND"; fi
else
  no "Zweierpotenzen" "uebersetzt nicht: $(tail -5 "$TMP/klein.log")"
fi

echo "=== PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
