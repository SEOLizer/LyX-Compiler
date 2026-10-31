#!/usr/bin/env bash
# tests/div_magie_2330_test.sh — #2330 Schritt 2: Division und Rest durch
# einen BELIEBIGEN konstanten Divisor ohne idiv.
#
# Schritt 1 (tests/div_konstante_2330_test.sh) nahm nur die Zweierpotenzen.
# Dieser Schritt ersetzt `idiv` auch fuer alles andere durch eine
# Multiplikation mit einem im Compiler ausgerechneten Faktor
# (Granlund/Montgomery; Warren, Hacker's Delight, Kapitel 10):
#
#   q = (M * n) >> (64 + s),  plus zwei Korrekturen.
#
# Die beiden Korrekturen sind der ganze Grund fuer diesen Test. Jede einzelne
# macht bei Weglassen falsche Zahlen, und beide treffen nur einen TEIL der
# Divisoren — ein Test mit einem einzigen Divisor haette sie nicht gesehen:
#
#   * M kann 2^63 erreichen und ist dann als vorzeichenbehaftete Zahl
#     negativ; der Codegen muss `add rdx, n` einschieben. Betrifft 5712 der
#     Divisoren unter 20000 — darunter 15, 21, 23, 25, die hier drin sind.
#   * Der Shift rundet gegen minus unendlich, Lyx (wie C) gegen null. Ohne
#     `sub rdx, (n >> 63)` ist jedes Ergebnis mit negativem Dividenden um
#     eins zu klein.
#   * s kann 0 sein, dann entfaellt der Shift ganz (d = 3, 6, 9, 19 ...).
#
# Geprueft wird in vier Richtungen:
#
#   1. DIFFERENTIELL gegen den idiv-Weg: derselbe Divisor einmal als
#      Literal (neuer Weg) und einmal durch eine Variable verdeckt (idiv).
#      Ueber alle Vorzeichenkombinationen und die Grenzwerte INT64_MIN/MAX.
#      Ein Ergebnistest ohne diese Gegenseite waere wertlos: er wuerde
#      dasselbe falsche Ergebnis zweimal bestaetigen, wenn der Erwartungswert
#      von Hand daneben liegt (CLAUDE.md: Erwartungswert gegenrechnen).
#   2. AM ERZEUGNIS, beide Seiten: mit Literal darf KEINE eigene Division
#      uebrig sein, mit Variable MUSS eine drin sein. Ohne die zweite
#      Haelfte wuerde der Test auch bestehen, wenn gar nicht umgeformt wird.
#   3. GEGENSEITE DER ERKENNUNG: ein vorzeichenLOSER Dividend bleibt bewusst
#      bei `div` (anderer Faktor, Zusatzstufe mit Uebertrag — nicht in
#      diesem Schritt). Belegt, dass die Bedingung nicht zu weit greift.
#   4. GRENZE DER ZULASSUNG: ein Divisor ueber 2^62 wird abgelehnt und muss
#      weiter ueber die Division laufen UND richtig rechnen.

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

# Die Divisoren. Jeder steht fuer eine Eigenschaft des Verfahrens:
#   3,6,9,19   -> s == 0, der Shift entfaellt
#   15,21,23,25 -> M < 0, die Additionskorrektur greift
#   1000       -> der Fall aus #2329, Faktor identisch mit gcc -O3
#   10, 100, 7, 11, 1001, 65537, 1000000007 -> gemischt
#   6148914691236517206 -> ueber 2^62, muss ABGELEHNT werden (Richtung 4)
DIVS="3 6 7 9 10 11 15 19 21 23 25 100 1000 1001 65537 1000000007 2147483647 4294967297 6148914691236517206"

# ---------------------------------------------------------------- 1
# Erzeugt ein Programm, das fuer jeden Divisor BEIDE Wege rechnet und nur
# meldet, wenn sie auseinanderlaufen. Der variable Weg bekommt den Divisor
# ueber eine Funktion, die der Compiler nicht zusammenfalten kann.
python3 -I - "$TMP/diff.lyx" "$DIVS" <<'PY'
import sys
pfad, divs = sys.argv[1], sys.argv[2].split()
L = []
L.append('unit main;')
L.append('import std.io;')
L.append('import std.alloc;')
L.append('// Der Compiler darf den Divisor hier nicht sehen: der Wert kommt')
L.append('// aus einer Tabelle, die er nicht zusammenfalten kann.')
L.append('var tab: int64;')
L.append('fn verdeckt(i: int64): int64 { return peek64(tab + i * 8); }')
for i, d in enumerate(divs):
    L.append('fn kd%d(x: int64): int64 { return x / %s; }' % (i, d))
    L.append('fn km%d(x: int64): int64 { return x %% %s; }' % (i, d))
L.append('fn konstD(x: int64, i: int64): int64 {')
for i in range(len(divs)):
    L.append('  if (i == %d) { return kd%d(x); }' % (i, i))
L.append('  return 0;')
L.append('}')
L.append('fn konstM(x: int64, i: int64): int64 {')
for i in range(len(divs)):
    L.append('  if (i == %d) { return km%d(x); }' % (i, i))
L.append('  return 0;')
L.append('}')
L.append('fn main(): int64 {')
L.append('  tab := alloc(%d);' % (8 * len(divs)))
for i, d in enumerate(divs):
    L.append('  poke64(tab + %d, %s);' % (i * 8, d))
L.append('  var mn: int64 := 1 << 63;          // INT64_MIN')
L.append('  var mx: int64 := 0 - 1 - mn;       // INT64_MAX, ohne Ueberlauf')
L.append('  var n: int64 := 23;')
L.append('  var vals: int64 := alloc(n * 8);')
vals = ['0','1','0 - 1','2','0 - 2','7','0 - 7','999','0 - 999','1000','0 - 1000',
        '1001','0 - 1001','mn','mx','mn + 1','mx - 1','1 << 62','0 - (1 << 62)',
        '1 << 32','0 - (1 << 32)','1000000007','0 - 1000000007']
assert len(vals) == 23, len(vals)
for j, v in enumerate(vals):
    L.append('  poke64(vals + %d, %s);' % (j * 8, v))
L.append('  var schlecht: int64 := 0;')
L.append('  var geprueft: int64 := 0;')
L.append('  var i: int64 := 0;')
L.append('  while (i < %d) {' % len(divs))
L.append('    var d: int64 := verdeckt(i);')
L.append('    var j: int64 := 0;')
L.append('    while (j < n) {')
L.append('      var x: int64 := peek64(vals + j * 8);')
L.append('      var a: int64 := konstD(x, i);')
L.append('      var b: int64 := x / d;')
L.append('      if (a != b) { schlecht := schlecht + 1;')
L.append('        Print("DIV d="); Print(IntToStr(d)); Print(" x="); Print(IntToStr(x));')
L.append('        Print(" konst="); Print(IntToStr(a)); Print(" idiv="); PrintLn(IntToStr(b)); }')
L.append('      var c: int64 := konstM(x, i);')
L.append('      var e: int64 := x % d;')
L.append('      if (c != e) { schlecht := schlecht + 1;')
L.append('        Print("MOD d="); Print(IntToStr(d)); Print(" x="); Print(IntToStr(x));')
L.append('        Print(" konst="); Print(IntToStr(c)); Print(" idiv="); PrintLn(IntToStr(e)); }')
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
  if printf '%s' "$AUS" | grep -q '^DIFF OK$' && [ "${ANZ:-0}" -ge 700 ]; then
    ok "differentiell gegen idiv ($ANZ Faelle, 19 Divisoren x 23 Werte x 2 Operationen)"
  else
    no "differentiell gegen idiv" "$(printf '%s' "$AUS" | head -12)"
  fi
else
  no "differentiell gegen idiv" "uebersetzt nicht: $(tail -5 "$TMP/diff.log")"
fi

# ---------------------------------------------------------------- 2a
cat > "$TMP/konst.lyx" <<'EOF'
unit main;
fn r(x: int64, w: int64): int64 {
  if (w == 1) { return x / 1000; }
  if (w == 2) { return x % 1000; }
  if (w == 3) { return x / 15; }
  if (w == 4) { return x % 15; }
  if (w == 5) { return x / 3; }
  return x % 3;
}
fn main(): int64 { return r(7777, 2) - 777; }
EOF
# Der Grundstand: ein leeres Programm traegt die Divisionen der Laufzeit
# (IntToStr und Nachbarn) ohnehin. Gemessen wird der UNTERSCHIED, sonst
# prueft der Test die stdlib mit.
cat > "$TMP/leer.lyx" <<'EOF'
unit main;
fn main(): int64 { return 0; }
EOF
baue leer; GRUND="$(divzahl "$TMP/leer")"
if baue konst; then
  N="$(divzahl "$TMP/konst")"
  if [ "$N" -eq "$GRUND" ]; then ok "Erzeugnis mit Literal: keine eigene Division ($N == Grundstand $GRUND)"
  else no "Erzeugnis mit Literal" "$N Divisionen, Grundstand ist $GRUND"; fi
  "$TMP/konst"; RC=$?
  if [ $RC -eq 0 ]; then ok "Literal-Fassung rechnet richtig (7777 % 1000 == 777)"
  else no "Literal-Fassung" "rc=$RC"; fi
else
  no "Erzeugnis mit Literal" "uebersetzt nicht: $(tail -5 "$TMP/konst.log")"
fi

# ---------------------------------------------------------------- 2b
# Gegenseite: variabler Divisor MUSS eine Division behalten. Ohne diese
# Haelfte wuerde 2a auch bestehen, wenn der Zaehler gar nichts findet.
cat > "$TMP/varia.lyx" <<'EOF'
unit main;
import std.alloc;
var t: int64;
fn r(x: int64): int64 { return x / peek64(t) + x % peek64(t); }
fn main(): int64 { t := alloc(8); poke64(t, 1000); return r(7777) - 784; }
EOF
if baue varia; then
  N="$(divzahl "$TMP/varia")"
  if [ "$N" -gt "$GRUND" ]; then ok "Erzeugnis mit Variable: Division bleibt ($N > Grundstand $GRUND)"
  else no "Erzeugnis mit Variable" "$N Divisionen, Grundstand $GRUND — der Zaehler sieht nichts"; fi
  "$TMP/varia"; RC=$?
  if [ $RC -eq 0 ]; then ok "Variable-Fassung rechnet richtig"
  else no "Variable-Fassung" "rc=$RC"; fi
else
  no "Erzeugnis mit Variable" "uebersetzt nicht: $(tail -5 "$TMP/varia.log")"
fi

# ---------------------------------------------------------------- 3
# Vorzeichenloser Dividend bleibt bei `div` — und rechnet richtig.
cat > "$TMP/unsig.lyx" <<'EOF'
unit main;
fn r(x: uint64): uint64 { return x / 1000; }
fn main(): int64 {
  var a: uint64 := 7777;
  if (r(a) != 7) { return 1; }
  return 0;
}
EOF
if baue unsig; then
  N="$(divzahl "$TMP/unsig")"
  if [ "$N" -gt "$GRUND" ]; then ok "vorzeichenlos bleibt bei div ($N) — Bedingung nicht zu weit"
  else no "vorzeichenlos" "Division verschwunden, der Faktor gilt dort nicht"; fi
  "$TMP/unsig"; RC=$?
  if [ $RC -eq 0 ]; then ok "vorzeichenlose Fassung rechnet richtig"
  else no "vorzeichenlose Fassung" "rc=$RC"; fi
else
  no "vorzeichenlos" "uebersetzt nicht: $(tail -5 "$TMP/unsig.log")"
fi

# ---------------------------------------------------------------- 4
# Divisor ueber 2^62: abgelehnt, Division bleibt stehen.
cat > "$TMP/gross.lyx" <<'EOF'
unit main;
fn r(x: int64): int64 { return x / 6148914691236517206; }
fn main(): int64 {
  if (r(6148914691236517206) != 1) { return 1; }
  if (r(0 - 6148914691236517206) != 0 - 1) { return 2; }
  if (r(1000) != 0) { return 3; }
  return 0;
}
EOF
if baue gross; then
  N="$(divzahl "$TMP/gross")"
  if [ "$N" -gt "$GRUND" ]; then ok "Divisor ueber 2^62 abgelehnt, Division bleibt ($N)"
  else no "Divisor ueber 2^62" "umgeformt, obwohl der Faktor dort nicht belegt ist"; fi
  "$TMP/gross"; RC=$?
  if [ $RC -eq 0 ]; then ok "grosser Divisor rechnet richtig"
  else no "grosser Divisor" "rc=$RC"; fi
else
  no "Divisor ueber 2^62" "uebersetzt nicht: $(tail -5 "$TMP/gross.log")"
fi

# ---------------------------------------------------------------- 5
# f64 bleibt unberuehrt (cg_isF64Expr-Sperre).
cat > "$TMP/fl.lyx" <<'EOF'
unit main;
fn main(): int64 {
  var a: f64 := 7.5;
  var b: f64 := a / 3.0;
  if (b < 2.4 || b > 2.6) { return 1; }
  return 0;
}
EOF
if baue fl; then
  "$TMP/fl"; RC=$?
  if [ $RC -eq 0 ]; then ok "f64-Division unberuehrt (7.5 / 3.0 == 2.5)"
  else no "f64-Division" "rc=$RC"; fi
else
  no "f64-Division" "uebersetzt nicht: $(tail -5 "$TMP/fl.log")"
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
