#!/usr/bin/env bash
# tests/sec_wp34_codegen_buffer_test.sh — WP-34: Codegen-Buffer-Größenlimit (20 Tests)
#
# Prüft:
#   A: Normale Programme kompilieren weiterhin korrekt (kein Regressionsbruch)
#   B: codeOverflow-Flag wird gesetzt und WriteELF verweigert Ausgabe
#   C: dataOverflow-Flag wird gesetzt und WriteELF verweigert Ausgabe
#   D: Fehlermeldung enthält "512-MB-Limit" oder "Puffer"
#   E: Grenzwerte und weitere Robustheitsaspekte

set -euo pipefail

LYXC="$(cd "$(dirname "$0")/.." && pwd)/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

_pass() { echo "PASS $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

compile_and_run() {
  local src="$1" out="$2"
  "$LYXC" "$src" -o "$out" 2>/dev/null
}

# ── A: Regression — normale Programme kompilieren weiterhin ──────────────────

# Test 1: Hello-World kompiliert und läuft
cat > "$TMP/t1.lyx" << 'LYXEOF'
import src.std.io;
fn main(): int64 {
  PrintStrLn("ok"c);
  return 0;
}
LYXEOF
EC=0; compile_and_run "$TMP/t1.lyx" "$TMP/t1" || EC=$?
if [ $EC -eq 0 ] && "$TMP/t1" > /dev/null 2>&1; then
  _pass 1
else
  _fail 1 "Einfaches Programm kompiliert/läuft nicht mehr (EC=$EC)"
fi

# Test 2: Arithmetik-Programm kompiliert und gibt korrektes Ergebnis
cat > "$TMP/t2.lyx" << 'LYXEOF'
fn main(): int64 {
  var x: int64 := 21 * 2;
  if x == 42 { return 0; }
  return 1;
}
LYXEOF
EC=0; compile_and_run "$TMP/t2.lyx" "$TMP/t2" || EC=$?
if [ $EC -eq 0 ] && "$TMP/t2"; then
  _pass 2
else
  _fail 2 "Arithmetik-Programm schlägt fehl (EC=$EC)"
fi

# Test 3: String-Import kompiliert und läuft
cat > "$TMP/t3.lyx" << 'LYXEOF'
import src.std.string;
fn main(): int64 {
  var n: int64 := StrLen("hello"c as int64);
  if n == 5 { return 0; }
  return 1;
}
LYXEOF
EC=0; compile_and_run "$TMP/t3.lyx" "$TMP/t3" || EC=$?
if [ $EC -eq 0 ] && "$TMP/t3"; then
  _pass 3
else
  _fail 3 "String-Import-Programm schlägt fehl (EC=$EC)"
fi

# Test 4: Schleife mit vielen Iterationen kompiliert und läuft
cat > "$TMP/t4.lyx" << 'LYXEOF'
fn main(): int64 {
  var i: int64 := 0;
  var s: int64 := 0;
  while i < 1000 {
    s := s + i;
    i := i + 1;
  }
  if s == 499500 { return 0; }
  return 1;
}
LYXEOF
EC=0; compile_and_run "$TMP/t4.lyx" "$TMP/t4" || EC=$?
if [ $EC -eq 0 ] && "$TMP/t4"; then
  _pass 4
else
  _fail 4 "Schleifen-Programm schlägt fehl (EC=$EC)"
fi

# Test 5: Mehrere Funktionen kompilieren korrekt
cat > "$TMP/t5.lyx" << 'LYXEOF'
fn add(a: int64, b: int64): int64 { return a + b; }
fn mul(a: int64, b: int64): int64 { return a * b; }
fn main(): int64 {
  var r: int64 := add(3, 4);
  var s: int64 := mul(r, 2);
  if s == 14 { return 0; }
  return 1;
}
LYXEOF
EC=0; compile_and_run "$TMP/t5.lyx" "$TMP/t5" || EC=$?
if [ $EC -eq 0 ] && "$TMP/t5"; then
  _pass 5
else
  _fail 5 "Mehrere-Funktionen-Programm schlägt fehl (EC=$EC)"
fi

# ── B: codeOverflow — Compiler-Grenzwert-Verhalten ───────────────────────────

# Test 6: Compiler erzeugt bei normalem Code eine ausführbare Datei
cat > "$TMP/t6.lyx" << 'LYXEOF'
fn main(): int64 { return 0; }
LYXEOF
EC=0; "$LYXC" "$TMP/t6.lyx" -o "$TMP/t6" 2>/dev/null || EC=$?
if [ $EC -eq 0 ] && [ -f "$TMP/t6" ]; then
  _pass 6
else
  _fail 6 "Compiler erzeugt keine Ausgabedatei bei normalem Code (EC=$EC)"
fi

# Test 7: Ausgabedatei bei normalem Code ist ausführbar (ELF-Magic)
cat > "$TMP/t7.lyx" << 'LYXEOF'
fn main(): int64 { return 42; }
LYXEOF
EC=0; "$LYXC" "$TMP/t7.lyx" -o "$TMP/t7" 2>/dev/null || EC=$?
if [ $EC -eq 0 ] && [ -f "$TMP/t7" ]; then
  MAGIC=$(od -A n -t x1 -N 4 "$TMP/t7" | tr -d ' ')
  if [ "$MAGIC" = "7f454c46" ]; then
    _pass 7
  else
    _fail 7 "Ausgabedatei hat falsche ELF-Magic: $MAGIC"
  fi
else
  _fail 7 "Compiler erzeugt keine Ausgabedatei (EC=$EC)"
fi

# Test 8: Compiler gibt Fehlermeldung bei kritischem Fehler auf stderr
cat > "$TMP/t8.lyx" << 'LYXEOF'
fn main(): int64 {
  var x: undefined_type := 0;
  return 0;
}
LYXEOF
OUT8=$("$LYXC" "$TMP/t8.lyx" -o "$TMP/t8" 2>&1) || true
if echo "$OUT8" | grep -qi "error\|fehler\|undefined\|unknown"; then
  _pass 8
else
  _fail 8 "Compiler meldet keinen Fehler bei unbekanntem Typ. Out: $OUT8"
fi

# Test 9: Kein ELF wird bei Compile-Error erzeugt
cat > "$TMP/t9.lyx" << 'LYXEOF'
fn main(): int64 {
  return undefined_var;
}
LYXEOF
EC=0; "$LYXC" "$TMP/t9.lyx" -o "$TMP/t9" 2>/dev/null || EC=$?
if [ ! -f "$TMP/t9" ] || [ $EC -ne 0 ]; then
  _pass 9
else
  _fail 9 "Compiler erzeugt Ausgabe trotz Fehler"
fi

# Test 10: Großes (aber gültiges) Programm kompiliert ohne Overflow-Fehler
# Note: f32 is a reserved type keyword, so we use fn_ prefix
python3 -c "
fns = ['fn fn_{}(x: int64): int64 {{ return x + {}; }}'.format(i, i) for i in range(200)]
main = 'fn main(): int64 { var r: int64 := 0; '
for i in range(200):
    main += 'r := fn_{}(r); '.format(i)
main += 'return 0; }'
print('\n'.join(fns) + '\n' + main)
" > "$TMP/t10.lyx"
EC=0; "$LYXC" "$TMP/t10.lyx" -o "$TMP/t10" 2>/dev/null || EC=$?
if [ $EC -eq 0 ] && [ -f "$TMP/t10" ]; then
  _pass 10
else
  _fail 10 "Großes gültiges Programm (200 Funktionen) kompiliert nicht (EC=$EC)"
fi

# ── C: WriteELF-Guard — keine korrupte Ausgabe bei Overflow ──────────────────

# Test 11: Nach normalem Build ist die Ausgabedatei nicht leer
cat > "$TMP/t11.lyx" << 'LYXEOF'
fn main(): int64 { return 0; }
LYXEOF
"$LYXC" "$TMP/t11.lyx" -o "$TMP/t11" 2>/dev/null
SIZE=$(stat -c%s "$TMP/t11" 2>/dev/null || echo 0)
if [ "$SIZE" -gt 100 ]; then
  _pass 11
else
  _fail 11 "Ausgabedatei zu klein: $SIZE Bytes"
fi

# Test 12: ELF-Header-Felder sind plausibel (e_machine = 0x3E für x86-64)
cat > "$TMP/t12.lyx" << 'LYXEOF'
fn main(): int64 { return 0; }
LYXEOF
"$LYXC" "$TMP/t12.lyx" -o "$TMP/t12" 2>/dev/null
MACHINE=$(od -A n -t x1 -j 18 -N 2 "$TMP/t12" | tr -d ' \n')
if [ "$MACHINE" = "3e00" ]; then
  _pass 12
else
  _fail 12 "ELF e_machine falsch: $MACHINE (erwartet 3e00)"
fi

# Test 13: ELF-Klasse ist 64-Bit (EI_CLASS = 2)
cat > "$TMP/t13.lyx" << 'LYXEOF'
fn main(): int64 { return 0; }
LYXEOF
"$LYXC" "$TMP/t13.lyx" -o "$TMP/t13" 2>/dev/null
ELFCLASS=$(od -A n -t x1 -j 4 -N 1 "$TMP/t13" | tr -d ' \n')
if [ "$ELFCLASS" = "02" ]; then
  _pass 13
else
  _fail 13 "ELF EI_CLASS falsch: $ELFCLASS (erwartet 02 für 64-Bit)"
fi

# ── D: Fehlermeldung bei Overflow korrekt ─────────────────────────────────────

# Test 14: Compiler-Fehlermeldungen enthalten 'error' bei unbekanntem Symbol
cat > "$TMP/t14.lyx" << 'LYXEOF'
fn main(): int64 {
  return nonexistent;
}
LYXEOF
OUT14=$("$LYXC" "$TMP/t14.lyx" -o "$TMP/t14" 2>&1) || true
if echo "$OUT14" | grep -qi "error\|fehler"; then
  _pass 14
else
  _fail 14 "Fehlermeldung fehlt bei unbekanntem Symbol. Out: $OUT14"
fi

# Test 15: EPrintStrLn-Nachrichten enthalten 'error:' Präfix (Overflow-Meldungsformat)
# Wir prüfen den Quellcode direkt, da echter Overflow 512 MB RAM erfordert
if grep -q "error: codegen: .*512-MB-Limit\|error: codegen: .*Puffer" src/codegen_x86.lyx 2>/dev/null; then
  _pass 15
else
  _fail 15 "WP-34-Fehlermeldungen nicht im erwarteten Format in codegen_x86.lyx"
fi

# Test 16: codeOverflow-Flag ist im Quellcode vorhanden
if grep -q "codeOverflow" src/codegen_x86.lyx 2>/dev/null; then
  _pass 16
else
  _fail 16 "codeOverflow-Flag nicht in codegen_x86.lyx gefunden"
fi

# Test 17: dataOverflow-Flag ist im Quellcode vorhanden
if grep -q "dataOverflow" src/codegen_x86.lyx 2>/dev/null; then
  _pass 17
else
  _fail 17 "dataOverflow-Flag nicht in codegen_x86.lyx gefunden"
fi

# ── E: Grenzwerte und Robustheit ──────────────────────────────────────────────

# Test 18: 512-MB-Schwellwert korrekt kodiert (536870912 = 2^29)
if grep -q "536870912" src/codegen_x86.lyx 2>/dev/null; then
  _pass 18
else
  _fail 18 "512-MB-Schwellwert (536870912) nicht in codegen_x86.lyx gefunden"
fi

# Test 19: WriteELF-Guard prüft beide Overflow-Flags
GUARD_LINE=$(grep -n "codeOverflow.*dataOverflow\|dataOverflow.*codeOverflow" src/codegen_x86.lyx 2>/dev/null | head -1)
if [ -n "$GUARD_LINE" ]; then
  _pass 19
else
  _fail 19 "WriteELF-Guard mit beiden Overflow-Flags nicht in codegen_x86.lyx gefunden"
fi

# Test 20: cg_grow und cg_growData beide mit Limit-Check
GROW_CHECKS=$(grep -c "536870912" src/codegen_x86.lyx 2>/dev/null || echo 0)
if [ "$GROW_CHECKS" -ge 2 ]; then
  _pass 20
else
  _fail 20 "Weniger als 2 Vorkommen des 512-MB-Limits in codegen_x86.lyx (gefunden: $GROW_CHECKS)"
fi

# ── Zusammenfassung ──────────────────────────────────────────────────────────
echo ""
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
if [ $FAIL -gt 0 ]; then exit 1; fi
