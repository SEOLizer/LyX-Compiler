#!/usr/bin/env bash
# tests/sec_wp36_securezero_test.sh — WP-36: SecureZero() Compiler-Barriere (20 Tests)
#
# Prüft:
#   A: Regression — ct.lyx-Funktionen außer SecureZero funktionieren weiterhin
#   B: SecureZero nullt Speicher korrekt
#   C: Edge-Cases (len=0, len=1, große Buffer)
#   D: Implementierung nutzt explicit_bzero (Quellcode-Check)
#   E: Integration — SecureZero mit PQC-Crypto-Units nutzbar

set -euo pipefail

LYXC="$(cd "$(dirname "$0")/.." && pwd)/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

_pass() { echo "PASS $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

CT_LYX="lyx-compiler/usr/include/lyx/units/std/crypto/ct.lyx"

# ── A: Regression — andere ct-Funktionen weiterhin korrekt ───────────────────

# Test 1: CTSelect wählt a bei mask=-1
cat > "$TMP/t1.lyx" << 'LYXEOF'
import std.crypto.ct;
fn main(): int64 {
  var r: int64 := CTSelect(42, 99, 0 - 1);
  if r == 42 { return 0; }
  return 1;
}
LYXEOF
EC=0; "$LYXC" "$TMP/t1.lyx" -o "$TMP/t1" 2>/dev/null && "$TMP/t1" || EC=$?
if [ $EC -eq 0 ]; then _pass 1; else _fail 1 "CTSelect(42, 99, -1) != 42 (EC=$EC)"; fi

# Test 2: CTSelect wählt b bei mask=0
cat > "$TMP/t2.lyx" << 'LYXEOF'
import std.crypto.ct;
fn main(): int64 {
  var r: int64 := CTSelect(42, 99, 0);
  if r == 99 { return 0; }
  return 1;
}
LYXEOF
EC=0; "$LYXC" "$TMP/t2.lyx" -o "$TMP/t2" 2>/dev/null && "$TMP/t2" || EC=$?
if [ $EC -eq 0 ]; then _pass 2; else _fail 2 "CTSelect(42, 99, 0) != 99 (EC=$EC)"; fi

# Test 3: CTEqual erkennt gleiche Werte
cat > "$TMP/t3.lyx" << 'LYXEOF'
import std.crypto.ct;
fn main(): int64 {
  var r: int64 := CTEqual(7, 7);
  if r == 0 - 1 { return 0; }
  return 1;
}
LYXEOF
EC=0; "$LYXC" "$TMP/t3.lyx" -o "$TMP/t3" 2>/dev/null && "$TMP/t3" || EC=$?
if [ $EC -eq 0 ]; then _pass 3; else _fail 3 "CTEqual(7, 7) != -1 (EC=$EC)"; fi

# Test 4: CTEqual erkennt ungleiche Werte
cat > "$TMP/t4.lyx" << 'LYXEOF'
import std.crypto.ct;
fn main(): int64 {
  var r: int64 := CTEqual(7, 8);
  if r == 0 { return 0; }
  return 1;
}
LYXEOF
EC=0; "$LYXC" "$TMP/t4.lyx" -o "$TMP/t4" 2>/dev/null && "$TMP/t4" || EC=$?
if [ $EC -eq 0 ]; then _pass 4; else _fail 4 "CTEqual(7, 8) != 0 (EC=$EC)"; fi

# ── B: SecureZero nullt Speicher korrekt ──────────────────────────────────────

# Test 5: 64-Byte-Buffer mit 0xFF füllen, dann SecureZero, alles 0 prüfen
cat > "$TMP/t5.lyx" << 'LYXEOF'
import std.alloc;
import std.crypto.ct;
fn main(): int64 {
  var buf: int64 := alloc(64);
  var i: int64 := 0;
  while i < 64 { poke8(buf + i, 255); i := i + 1; }
  SecureZero(buf, 64);
  i := 0;
  while i < 64 {
    if peek8(buf + i) != 0 { return 1; }
    i := i + 1;
  }
  return 0;
}
LYXEOF
EC=0; "$LYXC" "$TMP/t5.lyx" -o "$TMP/t5" 2>/dev/null && "$TMP/t5" || EC=$?
if [ $EC -eq 0 ]; then _pass 5; else _fail 5 "SecureZero 64B nicht korrekt (EC=$EC)"; fi

# Test 6: 1-Byte-Buffer SecureZero
cat > "$TMP/t6.lyx" << 'LYXEOF'
import std.alloc;
import std.crypto.ct;
fn main(): int64 {
  var buf: int64 := alloc(1);
  poke8(buf, 0xAB);
  SecureZero(buf, 1);
  if peek8(buf) == 0 { return 0; }
  return 1;
}
LYXEOF
EC=0; "$LYXC" "$TMP/t6.lyx" -o "$TMP/t6" 2>/dev/null && "$TMP/t6" || EC=$?
if [ $EC -eq 0 ]; then _pass 6; else _fail 6 "SecureZero 1B nicht korrekt (EC=$EC)"; fi

# Test 7: 32-Byte-Buffer (typische Schlüsselgröße) SecureZero
cat > "$TMP/t7.lyx" << 'LYXEOF'
import std.alloc;
import std.crypto.ct;
fn main(): int64 {
  var buf: int64 := alloc(32);
  var i: int64 := 0;
  while i < 32 { poke8(buf + i, 0x42); i := i + 1; }
  SecureZero(buf, 32);
  i := 0;
  while i < 32 {
    if peek8(buf + i) != 0 { return 1; }
    i := i + 1;
  }
  return 0;
}
LYXEOF
EC=0; "$LYXC" "$TMP/t7.lyx" -o "$TMP/t7" 2>/dev/null && "$TMP/t7" || EC=$?
if [ $EC -eq 0 ]; then _pass 7; else _fail 7 "SecureZero 32B nicht korrekt (EC=$EC)"; fi

# Test 8: 256-Byte-Buffer SecureZero
cat > "$TMP/t8.lyx" << 'LYXEOF'
import std.alloc;
import std.crypto.ct;
fn main(): int64 {
  var buf: int64 := alloc(256);
  var i: int64 := 0;
  while i < 256 { poke8(buf + i, 0xDE); i := i + 1; }
  SecureZero(buf, 256);
  i := 0;
  while i < 256 {
    if peek8(buf + i) != 0 { return 1; }
    i := i + 1;
  }
  return 0;
}
LYXEOF
EC=0; "$LYXC" "$TMP/t8.lyx" -o "$TMP/t8" 2>/dev/null && "$TMP/t8" || EC=$?
if [ $EC -eq 0 ]; then _pass 8; else _fail 8 "SecureZero 256B nicht korrekt (EC=$EC)"; fi

# Test 9: SecureZero nur Teilbereich (Bytes außerhalb unberührt)
cat > "$TMP/t9.lyx" << 'LYXEOF'
import std.alloc;
import std.crypto.ct;
fn main(): int64 {
  var buf: int64 := alloc(16);
  var i: int64 := 0;
  while i < 16 { poke8(buf + i, 0xFF); i := i + 1; }
  SecureZero(buf + 4, 8);
  if peek8(buf + 0) != 255 { return 1; }
  if peek8(buf + 3) != 255 { return 2; }
  i := 4;
  while i < 12 {
    if peek8(buf + i) != 0 { return 3; }
    i := i + 1;
  }
  if peek8(buf + 12) != 255 { return 4; }
  if peek8(buf + 15) != 255 { return 5; }
  return 0;
}
LYXEOF
EC=0; "$LYXC" "$TMP/t9.lyx" -o "$TMP/t9" 2>/dev/null && "$TMP/t9" || EC=$?
if [ $EC -eq 0 ]; then _pass 9; else _fail 9 "SecureZero Teilbereich fehlerhaft (EC=$EC)"; fi

# Test 10: SecureZero zweimal auf demselben Buffer → noch immer 0
cat > "$TMP/t10.lyx" << 'LYXEOF'
import std.alloc;
import std.crypto.ct;
fn main(): int64 {
  var buf: int64 := alloc(32);
  var i: int64 := 0;
  while i < 32 { poke8(buf + i, 0x55); i := i + 1; }
  SecureZero(buf, 32);
  SecureZero(buf, 32);
  i := 0;
  while i < 32 {
    if peek8(buf + i) != 0 { return 1; }
    i := i + 1;
  }
  return 0;
}
LYXEOF
EC=0; "$LYXC" "$TMP/t10.lyx" -o "$TMP/t10" 2>/dev/null && "$TMP/t10" || EC=$?
if [ $EC -eq 0 ]; then _pass 10; else _fail 10 "SecureZero doppelt fehlerhaft (EC=$EC)"; fi

# ── C: Edge-Cases ─────────────────────────────────────────────────────────────

# Test 11: len=0 → kein Absturz, kein Effekt
cat > "$TMP/t11.lyx" << 'LYXEOF'
import std.alloc;
import std.crypto.ct;
fn main(): int64 {
  var buf: int64 := alloc(8);
  poke8(buf, 0xAA);
  SecureZero(buf, 0);
  if peek8(buf) == 0xAA { return 0; }
  return 1;
}
LYXEOF
EC=0; "$LYXC" "$TMP/t11.lyx" -o "$TMP/t11" 2>/dev/null && "$TMP/t11" || EC=$?
if [ $EC -eq 0 ]; then _pass 11; else _fail 11 "SecureZero len=0 crasht oder ändert Daten (EC=$EC)"; fi

# Test 12: negativer len → kein Absturz
cat > "$TMP/t12.lyx" << 'LYXEOF'
import std.alloc;
import std.crypto.ct;
fn main(): int64 {
  var buf: int64 := alloc(8);
  poke8(buf, 0xBB);
  SecureZero(buf, 0 - 1);
  return 0;
}
LYXEOF
EC=0; "$LYXC" "$TMP/t12.lyx" -o "$TMP/t12" 2>/dev/null && "$TMP/t12" || EC=$?
if [ $EC -ne 139 ]; then _pass 12; else _fail 12 "SecureZero negativer len → SIGSEGV (EC=$EC)"; fi

# Test 13: len=1 → exakt 1 Byte genullt
cat > "$TMP/t13.lyx" << 'LYXEOF'
import std.alloc;
import std.crypto.ct;
fn main(): int64 {
  var buf: int64 := alloc(4);
  poke8(buf + 0, 0x11);
  poke8(buf + 1, 0x22);
  poke8(buf + 2, 0x33);
  poke8(buf + 3, 0x44);
  SecureZero(buf + 1, 1);
  if peek8(buf + 0) != 0x11 { return 1; }
  if peek8(buf + 1) != 0    { return 2; }
  if peek8(buf + 2) != 0x33 { return 3; }
  if peek8(buf + 3) != 0x44 { return 4; }
  return 0;
}
LYXEOF
EC=0; "$LYXC" "$TMP/t13.lyx" -o "$TMP/t13" 2>/dev/null && "$TMP/t13" || EC=$?
if [ $EC -eq 0 ]; then _pass 13; else _fail 13 "SecureZero len=1 Einzelbyte fehlerhaft (EC=$EC)"; fi

# Test 14: 4096-Byte-Buffer (eine Speicherseite) SecureZero
cat > "$TMP/t14.lyx" << 'LYXEOF'
import std.alloc;
import std.crypto.ct;
fn main(): int64 {
  var buf: int64 := alloc(4096);
  var i: int64 := 0;
  while i < 4096 { poke8(buf + i, 0xCC); i := i + 1; }
  SecureZero(buf, 4096);
  i := 0;
  while i < 4096 {
    if peek8(buf + i) != 0 { return 1; }
    i := i + 1;
  }
  return 0;
}
LYXEOF
EC=0; "$LYXC" "$TMP/t14.lyx" -o "$TMP/t14" 2>/dev/null && "$TMP/t14" || EC=$?
if [ $EC -eq 0 ]; then _pass 14; else _fail 14 "SecureZero 4096B fehlerhaft (EC=$EC)"; fi

# Test 15: Zwei unabhängige Buffer — nur einer genullt
cat > "$TMP/t15.lyx" << 'LYXEOF'
import std.alloc;
import std.crypto.ct;
fn main(): int64 {
  var a: int64 := alloc(16);
  var b: int64 := alloc(16);
  var i: int64 := 0;
  while i < 16 { poke8(a + i, 0xAA); poke8(b + i, 0xBB); i := i + 1; }
  SecureZero(a, 16);
  i := 0;
  while i < 16 {
    if peek8(a + i) != 0    { return 1; }
    if peek8(b + i) != 0xBB { return 2; }
    i := i + 1;
  }
  return 0;
}
LYXEOF
EC=0; "$LYXC" "$TMP/t15.lyx" -o "$TMP/t15" 2>/dev/null && "$TMP/t15" || EC=$?
if [ $EC -eq 0 ]; then _pass 15; else _fail 15 "SecureZero betrifft falschen Buffer (EC=$EC)"; fi

# ── D: Implementierungscheck ──────────────────────────────────────────────────

# D: libc-freies SecureZero (PR #800: explicit_bzero entfernt; poke8-Compiler-
# Barriere statt libc). Tests prüfen jetzt das libc-FREIE Design.

# Test 16: ct.lyx hat KEINEN explicit_bzero-Extern (libc-frei)
if grep -q "extern fn explicit_bzero" "$CT_LYX" 2>/dev/null; then
  _fail 16 "explicit_bzero-Extern noch in $CT_LYX — soll libc-frei sein"
else
  _pass 16
fi

# Test 17: ct.lyx verlinkt NICHT gegen libc.so.6
if grep -q 'link "libc.so.6"' "$CT_LYX" 2>/dev/null; then
  _fail 17 "link libc.so.6 noch in $CT_LYX — soll libc-frei sein"
else
  _pass 17
fi

# Test 18: SecureZero nutzt KEIN explicit_bzero
if grep -A6 "pub fn SecureZero" "$CT_LYX" 2>/dev/null | grep -q "explicit_bzero"; then
  _fail 18 "SecureZero nutzt noch explicit_bzero in $CT_LYX"
else
  _pass 18
fi

# Test 19: SecureZero nutzt die poke8-Compiler-Barriere (WP-36, DSE-fest)
if grep -A6 "pub fn SecureZero" "$CT_LYX" 2>/dev/null | grep -q "poke8(ptr"; then
  _pass 19
else
  _fail 19 "SecureZero hat keine poke8-Barriere in $CT_LYX"
fi

# ── E: Integration ────────────────────────────────────────────────────────────

# Test 20: CTMemEqual + SecureZero zusammen (typischer Crypto-Workflow)
cat > "$TMP/t20.lyx" << 'LYXEOF'
import std.alloc;
import std.crypto.ct;
fn main(): int64 {
  var key: int64 := alloc(32);
  var cmp: int64 := alloc(32);
  var i:   int64 := 0;
  while i < 32 { poke8(key + i, 0x7E); poke8(cmp + i, 0x7E); i := i + 1; }
  var eq: int64 := CTMemEqual(key, cmp, 32);
  if eq != 0 - 1 { return 1; }
  SecureZero(key, 32);
  var eq2: int64 := CTMemEqual(key, cmp, 32);
  if eq2 != 0 { return 2; }
  return 0;
}
LYXEOF
EC=0; "$LYXC" "$TMP/t20.lyx" -o "$TMP/t20" 2>/dev/null && "$TMP/t20" || EC=$?
if [ $EC -eq 0 ]; then _pass 20; else _fail 20 "CTMemEqual+SecureZero Integration fehlerhaft (EC=$EC)"; fi

# ── Zusammenfassung ──────────────────────────────────────────────────────────
echo ""
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
if [ $FAIL -gt 0 ]; then exit 1; fi
