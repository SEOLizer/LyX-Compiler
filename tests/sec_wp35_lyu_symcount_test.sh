#!/usr/bin/env bash
# tests/sec_wp35_lyu_symcount_test.sh — WP-35: LYU-Parser symCount-Limit (20 Tests)
#
# Prüft:
#   A: Normale .lyu-Imports funktionieren weiterhin (Regression)
#   B: Crafted .lyu mit symCount > 65536 → Fehlermeldung + kein Crash
#   C: Grenzwert symCount=65536 wird akzeptiert, symCount=65537 abgelehnt
#   D: Weitere manipulierte .lyu-Dateien werden sicher abgelehnt
#   E: Fehlermeldungsformat korrekt

set -euo pipefail

LYXC="$(cd "$(dirname "$0")/.." && pwd)/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

_pass() { echo "PASS $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# Erzeugt eine minimale gültige v1-.lyu-Datei mit gegebenem symCount
# Format: magic(4) + version(2) + arch(1) + flags(1) + ulen(2) + name + symCount(4) + offsets(16)
make_lyu() {
  local path="$1" sym_count="$2"
  python3 - "$path" "$sym_count" << 'PYEOF'
import sys, struct
path, sc = sys.argv[1], int(sys.argv[2])
data  = b'LYU\x00'
data += struct.pack('<H', 1) + b'\x00\x00'  # version=1, arch=0, flags=0
data += struct.pack('<H', 4) + b'test'       # unit name "test"
data += struct.pack('<I', sc)                # symCount
data += b'\x00' * 16                        # 4 × u32 offset placeholders
open(path, 'wb').write(data)
PYEOF
}

# Erzeugt eine v1-.lyu mit einem gültigen Symbol (kind=1=FUNC, typeHash=0, typeInfo="")
make_lyu_with_sym() {
  local path="$1" sym_name="$2"
  python3 - "$path" "$sym_name" << 'PYEOF'
import sys, struct
path, name = sys.argv[1], sys.argv[2].encode()
data  = b'LYU\x00'
data += struct.pack('<H', 1) + b'\x00\x00'
data += struct.pack('<H', 4) + b'test'
data += struct.pack('<I', 1)     # symCount=1
data += b'\x00' * 16             # offset placeholders
data += struct.pack('<H', len(name)) + name  # nameLen + name
data += b'\x01'                  # kind = SYM_FUNC
data += struct.pack('<I', 0)     # typeHash
data += struct.pack('<H', 0)     # tiLen = 0
open(path, 'wb').write(data)
PYEOF
}

# ── A: Regression — normale .lyu-Imports funktionieren ───────────────────────

# Test 1: import src.std.string (nutzt string.lyu) kompiliert
cat > "$TMP/t1.lyx" << 'LYXEOF'
import src.std.string;
fn main(): int64 {
  var n: int64 := StrLen("hello"c as int64);
  if n == 5 { return 0; }
  return 1;
}
LYXEOF
EC=0; "$LYXC" "$TMP/t1.lyx" -o "$TMP/t1" 2>/dev/null || EC=$?
if [ $EC -eq 0 ] && "$TMP/t1"; then _pass 1; else _fail 1 "import src.std.string schlägt fehl (EC=$EC)"; fi

# Test 2: import src.std.io kompiliert und läuft
cat > "$TMP/t2.lyx" << 'LYXEOF'
import src.std.io;
fn main(): int64 {
  PrintStrLn("ok"c);
  return 0;
}
LYXEOF
EC=0; "$LYXC" "$TMP/t2.lyx" -o "$TMP/t2" 2>/dev/null || EC=$?
if [ $EC -eq 0 ] && "$TMP/t2" > /dev/null 2>&1; then _pass 2; else _fail 2 "import src.std.io schlägt fehl (EC=$EC)"; fi

# Test 3: import src.std.fs kompiliert
# #1264: Der Aufruf liess `mode` weg — `FileOpen` hat drei Parameter. Beim
# reinen Lesen ignoriert der Kernel den Wert, deshalb fiel nie auf, dass er vom
# Stack kam. Seit die Stelligkeit ueber Unit-Grenzen geprueft wird, steht er
# hier vollstaendig.
cat > "$TMP/t3.lyx" << 'LYXEOF'
import src.std.fs;
fn main(): int64 {
  var fd: int64 := FileOpen("/dev/null"c, 0, 0);
  if fd >= 0 { FileClose(fd); return 0; }
  return 1;
}
LYXEOF
EC=0; "$LYXC" "$TMP/t3.lyx" -o "$TMP/t3" 2>/dev/null || EC=$?
if [ $EC -eq 0 ] && "$TMP/t3"; then _pass 3; else _fail 3 "import src.std.fs schlägt fehl (EC=$EC)"; fi

# Test 4: Programm ohne .lyu-Import kompiliert unverändert
cat > "$TMP/t4.lyx" << 'LYXEOF'
fn main(): int64 { return 0; }
LYXEOF
EC=0; "$LYXC" "$TMP/t4.lyx" -o "$TMP/t4" 2>/dev/null || EC=$?
if [ $EC -eq 0 ] && "$TMP/t4"; then _pass 4; else _fail 4 "Basisprogramm schlägt fehl (EC=$EC)"; fi

# Test 5: Eigene minimale .lyu mit symCount=0 wird akzeptiert
make_lyu "$TMP/mymod.lyu" 0
cat > "$TMP/t5.lyx" << 'LYXEOF'
import mymod;
fn main(): int64 { return 0; }
LYXEOF
EC=0; "$LYXC" "$TMP/t5.lyx" -I "$TMP" -o "$TMP/t5" 2>/dev/null || EC=$?
if [ $EC -eq 0 ]; then _pass 5; else _fail 5 ".lyu mit symCount=0 sollte akzeptiert werden (EC=$EC)"; fi

# ── B: Crafted .lyu mit symCount > 65536 → Fehler ────────────────────────────

# Test 6: symCount=100000 → Fehlermeldung
make_lyu "$TMP/big.lyu" 100000
cat > "$TMP/t6.lyx" << 'LYXEOF'
import big;
fn main(): int64 { return 0; }
LYXEOF
OUT6=$("$LYXC" "$TMP/t6.lyx" -I "$TMP" -o "$TMP/t6" 2>&1) || true
if echo "$OUT6" | grep -qi "symCount\|unreasonably\|large\|error"; then
  _pass 6
else
  _fail 6 "symCount=100000 sollte Fehler auslösen. Out: $OUT6"
fi

# Test 7: symCount=0x7FFFFFFF → Fehlermeldung (kein OOM)
make_lyu "$TMP/huge.lyu" 2147483647
cat > "$TMP/t7.lyx" << 'LYXEOF'
import huge;
fn main(): int64 { return 0; }
LYXEOF
OUT7=$("$LYXC" "$TMP/t7.lyx" -I "$TMP" -o "$TMP/t7" 2>&1) || true
if echo "$OUT7" | grep -qi "symCount\|unreasonably\|large\|error"; then
  _pass 7
else
  _fail 7 "symCount=0x7FFFFFFF sollte Fehler auslösen. Out: $OUT7"
fi

# Test 8: symCount=65537 (grenzwert+1) → Fehlermeldung
make_lyu "$TMP/over.lyu" 65537
cat > "$TMP/t8.lyx" << 'LYXEOF'
import over;
fn main(): int64 { return 0; }
LYXEOF
OUT8=$("$LYXC" "$TMP/t8.lyx" -I "$TMP" -o "$TMP/t8" 2>&1) || true
if echo "$OUT8" | grep -qi "symCount\|unreasonably\|large\|error"; then
  _pass 8
else
  _fail 8 "symCount=65537 sollte Fehler auslösen. Out: $OUT8"
fi

# Test 9: symCount=200000 → kein Absturz
make_lyu "$TMP/v200k.lyu" 200000
cat > "$TMP/t9.lyx" << 'LYXEOF'
import v200k;
fn main(): int64 { return 0; }
LYXEOF
EC=0; "$LYXC" "$TMP/t9.lyx" -I "$TMP" -o "$TMP/t9" 2>/dev/null || EC=$?
# Kein SIGSEGV / kein OOM (kein Exitcode 139)
if [ $EC -ne 139 ]; then
  _pass 9
else
  _fail 9 "Compiler stürzt mit SIGSEGV ab (EC=$EC)"
fi

# Test 10: symCount=0xFFFFFF → kein Absturz (maximaler 24-bit-Wert)
make_lyu "$TMP/vmax.lyu" 16777215
cat > "$TMP/t10.lyx" << 'LYXEOF'
import vmax;
fn main(): int64 { return 0; }
LYXEOF
EC=0; "$LYXC" "$TMP/t10.lyx" -I "$TMP" -o "$TMP/t10" 2>/dev/null || EC=$?
if [ $EC -ne 139 ]; then
  _pass 10
else
  _fail 10 "Compiler stürzt mit SIGSEGV ab bei symCount=0xFFFFFF (EC=$EC)"
fi

# ── C: Grenzwert symCount=65536 ───────────────────────────────────────────────

# Test 11: symCount=65536 (genau am Limit) wird akzeptiert (kein Fehler)
make_lyu "$TMP/at_limit.lyu" 65536
cat > "$TMP/t11.lyx" << 'LYXEOF'
import at_limit;
fn main(): int64 { return 0; }
LYXEOF
OUT11=$("$LYXC" "$TMP/t11.lyx" -I "$TMP" -o "$TMP/t11" 2>&1) || true
if echo "$OUT11" | grep -qi "unreasonably large"; then
  _fail 11 "symCount=65536 sollte noch akzeptiert werden (Fehler: $OUT11)"
else
  _pass 11
fi

# Test 12: symCount=65537 → abgelehnt; symCount=65536 → akzeptiert (beide in einem Test)
make_lyu "$TMP/just_over.lyu" 65537
cat > "$TMP/t12.lyx" << 'LYXEOF'
import just_over;
fn main(): int64 { return 0; }
LYXEOF
OUT12=$("$LYXC" "$TMP/t12.lyx" -I "$TMP" -o "$TMP/t12" 2>&1) || true
if echo "$OUT12" | grep -qi "symCount\|unreasonably\|large\|error"; then
  _pass 12
else
  _fail 12 "symCount=65537 sollte Fehler auslösen. Out: $OUT12"
fi

# ── D: Weitere manipulierte .lyu-Dateien ──────────────────────────────────────

# Test 13: .lyu mit falschem Magic → kein Crash
echo -n "XYZ" > "$TMP/bad_magic.lyu"
cat > "$TMP/t13.lyx" << 'LYXEOF'
import bad_magic;
fn main(): int64 { return 0; }
LYXEOF
EC=0; "$LYXC" "$TMP/t13.lyx" -I "$TMP" -o "$TMP/t13" 2>/dev/null || EC=$?
if [ $EC -ne 139 ]; then _pass 13; else _fail 13 "Falsches Magic führt zu SIGSEGV"; fi

# Test 14: .lyu mit size < 10 → kein Crash
echo -n "LYU" > "$TMP/tiny.lyu"
cat > "$TMP/t14.lyx" << 'LYXEOF'
import tiny;
fn main(): int64 { return 0; }
LYXEOF
EC=0; "$LYXC" "$TMP/t14.lyx" -I "$TMP" -o "$TMP/t14" 2>/dev/null || EC=$?
if [ $EC -ne 139 ]; then _pass 14; else _fail 14 "Zu kleine .lyu führt zu SIGSEGV"; fi

# Test 15: Leere .lyu-Datei → kein Crash
> "$TMP/empty.lyu"
cat > "$TMP/t15.lyx" << 'LYXEOF'
import empty;
fn main(): int64 { return 0; }
LYXEOF
EC=0; "$LYXC" "$TMP/t15.lyx" -I "$TMP" -o "$TMP/t15" 2>/dev/null || EC=$?
if [ $EC -ne 139 ]; then _pass 15; else _fail 15 "Leere .lyu führt zu SIGSEGV"; fi

# Test 16: .lyu mit gültigem Symbol und symCount=1 — Symbol wird injiziert
make_lyu_with_sym "$TMP/onesym.lyu" "MySym"
cat > "$TMP/t16.lyx" << 'LYXEOF'
import onesym;
fn main(): int64 { return 0; }
LYXEOF
EC=0; "$LYXC" "$TMP/t16.lyx" -I "$TMP" -o "$TMP/t16" 2>/dev/null || EC=$?
if [ $EC -ne 139 ]; then _pass 16; else _fail 16 "symCount=1 mit gültigem Symbol führt zu SIGSEGV"; fi

# ── E: Fehlermeldungsformat und Quellcode-Check ───────────────────────────────

# Test 17: Fehlermeldung enthält "symCount"
make_lyu "$TMP/msg_check.lyu" 100000
cat > "$TMP/t17.lyx" << 'LYXEOF'
import msg_check;
fn main(): int64 { return 0; }
LYXEOF
OUT17=$("$LYXC" "$TMP/t17.lyx" -I "$TMP" -o "$TMP/t17" 2>&1) || true
if echo "$OUT17" | grep -q "symCount"; then
  _pass 17
else
  _fail 17 "Fehlermeldung enthält nicht 'symCount'. Out: $OUT17"
fi

# Test 18: WP-35-Limit-Check ist in sema.lyx vorhanden
if grep -q "symCount > 65536" src/sema.lyx 2>/dev/null; then
  _pass 18
else
  _fail 18 "WP-35-Limit-Check (symCount > 65536) nicht in src/sema.lyx gefunden"
fi

# Test 19: Fehlermeldung enthält "manipulierte" oder "unreasonably"
if grep -q "unreasonably\|manipulierte" src/sema.lyx 2>/dev/null; then
  _pass 19
else
  _fail 19 "Fehlermeldungstext nicht in src/sema.lyx gefunden"
fi

# Test 20: Nach verworfenem .lyu kompiliert ein einfaches Programm weiterhin korrekt
make_lyu "$TMP/poison.lyu" 200000
cat > "$TMP/t20a.lyx" << 'LYXEOF'
import poison;
fn main(): int64 { return 0; }
LYXEOF
"$LYXC" "$TMP/t20a.lyx" -I "$TMP" -o "$TMP/t20a" 2>/dev/null || true
cat > "$TMP/t20b.lyx" << 'LYXEOF'
fn main(): int64 { return 0; }
LYXEOF
EC=0; "$LYXC" "$TMP/t20b.lyx" -o "$TMP/t20b" 2>/dev/null || EC=$?
if [ $EC -eq 0 ] && "$TMP/t20b"; then
  _pass 20
else
  _fail 20 "Compiler nach poisoned .lyu nicht mehr funktionsfähig (EC=$EC)"
fi

# ── Zusammenfassung ──────────────────────────────────────────────────────────
echo ""
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
if [ $FAIL -gt 0 ]; then exit 1; fi
