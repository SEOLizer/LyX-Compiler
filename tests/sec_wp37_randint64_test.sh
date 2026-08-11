#!/usr/bin/env bash
# tests/sec_wp37_randint64_test.sh — WP-37: RandInt64() Fehlerbehandlung (20 Tests)
#
# Prüft:
#   A: Regression — RandBytes/RandBytesExact funktionieren weiterhin
#   B: RandInt64 liefert kryptographisch plausible Werte
#   C: RandU32 liefert korrekte Werte im gültigen Bereich
#   D: Implementierungscheck — kein silent-0-Return mehr, exit(1) vorhanden
#   E: Integration — RandInt64/RandU32 zusammen nutzbar

set -euo pipefail

LYXC="$(cd "$(dirname "$0")/.." && pwd)/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

_pass() { echo "PASS $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

RAND_LYX="lyx-compiler/usr/include/lyx/units/std/crypto/rand.lyx"

# ── A: Regression — RandBytes/RandBytesExact weiterhin korrekt ───────────────

# Test 1: RandBytes(32) gibt 32 zurück
cat > "$TMP/t1.lyx" << 'LYXEOF'
import std.crypto.rand;
fn main(): int64 {
  var buf: int64 := mmap(0, 32, 3, 34, -1, 0);
  var rc: int64 := RandBytes(buf, 32);
  munmap(buf, 32);
  if rc == 32 { return 0; }
  return 1;
}
LYXEOF
EC=0; "$LYXC" "$TMP/t1.lyx" -o "$TMP/t1" 2>/dev/null && "$TMP/t1" || EC=$?
if [ $EC -eq 0 ]; then _pass 1; else _fail 1 "RandBytes(32) != 32 (EC=$EC)"; fi

# Test 2: RandBytes-Ausgabe ist nicht all-zero
cat > "$TMP/t2.lyx" << 'LYXEOF'
import std.crypto.rand;
fn main(): int64 {
  var buf: int64 := mmap(0, 32, 3, 34, -1, 0);
  var i: int64 := 0;
  while i < 32 { poke8(buf + i, 0); i := i + 1; }
  RandBytes(buf, 32);
  var nz: int64 := 0;
  i := 0;
  while i < 32 {
    if peek8(buf + i) != 0 { nz := nz + 1; }
    i := i + 1;
  }
  munmap(buf, 32);
  if nz > 0 { return 0; }
  return 1;
}
LYXEOF
EC=0; "$LYXC" "$TMP/t2.lyx" -o "$TMP/t2" 2>/dev/null && "$TMP/t2" || EC=$?
if [ $EC -eq 0 ]; then _pass 2; else _fail 2 "RandBytes-Ausgabe all-zero (EC=$EC)"; fi

# Test 3: RandBytesExact(64) gibt 64 zurück
cat > "$TMP/t3.lyx" << 'LYXEOF'
import std.crypto.rand;
fn main(): int64 {
  var buf: int64 := mmap(0, 64, 3, 34, -1, 0);
  var rc: int64 := RandBytesExact(buf, 64);
  munmap(buf, 64);
  if rc == 64 { return 0; }
  return 1;
}
LYXEOF
EC=0; "$LYXC" "$TMP/t3.lyx" -o "$TMP/t3" 2>/dev/null && "$TMP/t3" || EC=$?
if [ $EC -eq 0 ]; then _pass 3; else _fail 3 "RandBytesExact(64) != 64 (EC=$EC)"; fi

# Test 4: RandBytesExact(0) gibt 0 zurück
cat > "$TMP/t4.lyx" << 'LYXEOF'
import std.crypto.rand;
fn main(): int64 {
  var buf: int64 := mmap(0, 8, 3, 34, -1, 0);
  var rc: int64 := RandBytesExact(buf, 0);
  munmap(buf, 8);
  if rc == 0 { return 0; }
  return 1;
}
LYXEOF
EC=0; "$LYXC" "$TMP/t4.lyx" -o "$TMP/t4" 2>/dev/null && "$TMP/t4" || EC=$?
if [ $EC -eq 0 ]; then _pass 4; else _fail 4 "RandBytesExact(0) != 0 (EC=$EC)"; fi

# Test 5: GRND_NONBLOCK und GRND_RANDOM Konstanten korrekt
cat > "$TMP/t5.lyx" << 'LYXEOF'
import std.crypto.rand;
fn main(): int64 {
  if GRND_NONBLOCK != 1 { return 1; }
  if GRND_RANDOM   != 2 { return 2; }
  return 0;
}
LYXEOF
EC=0; "$LYXC" "$TMP/t5.lyx" -o "$TMP/t5" 2>/dev/null && "$TMP/t5" || EC=$?
if [ $EC -eq 0 ]; then _pass 5; else _fail 5 "GRND_*-Konstanten falsch (EC=$EC)"; fi

# ── B: RandInt64 kryptographisch plausible Werte ──────────────────────────────

# Test 6: Zwei aufeinanderfolgende RandInt64() verschieden
cat > "$TMP/t6.lyx" << 'LYXEOF'
import std.crypto.rand;
fn main(): int64 {
  var a: int64 := RandInt64();
  var b: int64 := RandInt64();
  if a != b { return 0; }
  return 1;
}
LYXEOF
EC=0; "$LYXC" "$TMP/t6.lyx" -o "$TMP/t6" 2>/dev/null && "$TMP/t6" || EC=$?
if [ $EC -eq 0 ]; then _pass 6; else _fail 6 "RandInt64() liefert identische Werte (EC=$EC)"; fi

# Test 7: Fünf RandInt64() alle verschieden voneinander
cat > "$TMP/t7.lyx" << 'LYXEOF'
import std.crypto.rand;
fn main(): int64 {
  var a: int64 := RandInt64();
  var b: int64 := RandInt64();
  var c: int64 := RandInt64();
  var d: int64 := RandInt64();
  var e: int64 := RandInt64();
  if a == b { return 1; }
  if a == c { return 2; }
  if a == d { return 3; }
  if b == c { return 4; }
  if b == d { return 5; }
  if c == d { return 6; }
  return 0;
}
LYXEOF
EC=0; "$LYXC" "$TMP/t7.lyx" -o "$TMP/t7" 2>/dev/null && "$TMP/t7" || EC=$?
if [ $EC -eq 0 ]; then _pass 7; else _fail 7 "RandInt64() Kollision in 5 Werten (EC=$EC)"; fi

# Test 8: RandInt64() nicht konsistent 0 (drei Calls, keiner darf 0 sein)
cat > "$TMP/t8.lyx" << 'LYXEOF'
import std.crypto.rand;
fn main(): int64 {
  var a: int64 := RandInt64();
  var b: int64 := RandInt64();
  var c: int64 := RandInt64();
  if a == 0 { return 1; }
  if b == 0 { return 2; }
  if c == 0 { return 3; }
  return 0;
}
LYXEOF
EC=0; "$LYXC" "$TMP/t8.lyx" -o "$TMP/t8" 2>/dev/null && "$TMP/t8" || EC=$?
if [ $EC -eq 0 ]; then _pass 8; else _fail 8 "RandInt64() returned 0 (Fehlerfall?) (EC=$EC)"; fi

# Test 9: XOR von drei RandInt64() ist nicht 0
cat > "$TMP/t9.lyx" << 'LYXEOF'
import std.crypto.rand;
fn main(): int64 {
  var x: int64 := RandInt64() ^ RandInt64() ^ RandInt64();
  if x != 0 { return 0; }
  return 1;
}
LYXEOF
EC=0; "$LYXC" "$TMP/t9.lyx" -o "$TMP/t9" 2>/dev/null && "$TMP/t9" || EC=$?
if [ $EC -eq 0 ]; then _pass 9; else _fail 9 "XOR dreier RandInt64() == 0 (EC=$EC)"; fi

# Test 10: RandInt64() kumuliertes OR deckt mindestens 8 Bits ab (Entropie-Plausibilität)
cat > "$TMP/t10.lyx" << 'LYXEOF'
import std.crypto.rand;
fn main(): int64 {
  var acc: int64 := 0;
  var i: int64 := 0;
  while i < 8 {
    acc := acc | RandInt64();
    i := i + 1;
  }
  var bits: int64 := 0;
  i := 0;
  while i < 64 {
    if (acc >> i) & 1 == 1 { bits := bits + 1; }
    i := i + 1;
  }
  if bits >= 32 { return 0; }
  return 1;
}
LYXEOF
EC=0; "$LYXC" "$TMP/t10.lyx" -o "$TMP/t10" 2>/dev/null && "$TMP/t10" || EC=$?
if [ $EC -eq 0 ]; then _pass 10; else _fail 10 "RandInt64() deckt < 32 Bits ab (8 Calls) (EC=$EC)"; fi

# ── C: RandU32 korrekte Werte ─────────────────────────────────────────────────

# Test 11: RandU32() liegt in [0, 2^32-1]
cat > "$TMP/t11.lyx" << 'LYXEOF'
import std.crypto.rand;
fn main(): int64 {
  var u: int64 := RandU32();
  if u >= 0 && u <= 0xFFFFFFFF { return 0; }
  return 1;
}
LYXEOF
EC=0; "$LYXC" "$TMP/t11.lyx" -o "$TMP/t11" 2>/dev/null && "$TMP/t11" || EC=$?
if [ $EC -eq 0 ]; then _pass 11; else _fail 11 "RandU32() ausserhalb [0, 2^32-1] (EC=$EC)"; fi

# Test 12: RandU32() high 32 Bits sind 0
cat > "$TMP/t12.lyx" << 'LYXEOF'
import std.crypto.rand;
fn main(): int64 {
  var u: int64 := RandU32();
  var hi: int64 := u >> 32;
  if hi == 0 { return 0; }
  return 1;
}
LYXEOF
EC=0; "$LYXC" "$TMP/t12.lyx" -o "$TMP/t12" 2>/dev/null && "$TMP/t12" || EC=$?
if [ $EC -eq 0 ]; then _pass 12; else _fail 12 "RandU32() setzt High-32-Bits (EC=$EC)"; fi

# Test 13: Zwei RandU32() Calls verschieden
cat > "$TMP/t13.lyx" << 'LYXEOF'
import std.crypto.rand;
fn main(): int64 {
  var a: int64 := RandU32();
  var b: int64 := RandU32();
  if a != b { return 0; }
  return 1;
}
LYXEOF
EC=0; "$LYXC" "$TMP/t13.lyx" -o "$TMP/t13" 2>/dev/null && "$TMP/t13" || EC=$?
if [ $EC -eq 0 ]; then _pass 13; else _fail 13 "RandU32() identische Werte (EC=$EC)"; fi

# Test 14: RandU32() nicht konsistent 0
cat > "$TMP/t14.lyx" << 'LYXEOF'
import std.crypto.rand;
fn main(): int64 {
  var a: int64 := RandU32();
  var b: int64 := RandU32();
  if a == 0 && b == 0 { return 1; }
  return 0;
}
LYXEOF
EC=0; "$LYXC" "$TMP/t14.lyx" -o "$TMP/t14" 2>/dev/null && "$TMP/t14" || EC=$?
if [ $EC -eq 0 ]; then _pass 14; else _fail 14 "RandU32() beide 0 — Fehlerfall? (EC=$EC)"; fi

# Test 15: RandU32() kumuliertes OR über 4 Calls deckt low 16 Bits ab
cat > "$TMP/t15.lyx" << 'LYXEOF'
import std.crypto.rand;
fn main(): int64 {
  var acc: int64 := RandU32() | RandU32() | RandU32() | RandU32();
  var lo16: int64 := acc & 0xFFFF;
  if lo16 != 0 { return 0; }
  return 1;
}
LYXEOF
EC=0; "$LYXC" "$TMP/t15.lyx" -o "$TMP/t15" 2>/dev/null && "$TMP/t15" || EC=$?
if [ $EC -eq 0 ]; then _pass 15; else _fail 15 "RandU32() low-16-Bits alle 0 (4 Calls) (EC=$EC)"; fi

# ── D: Implementierungscheck — kein silent-0-Return mehr ─────────────────────

# Test 16: rand.lyx enthält exit(1) im RandInt64-Bereich
if grep -A15 "pub fn RandInt64" "$RAND_LYX" 2>/dev/null | grep -q "exit(1)"; then
  _pass 16
else
  _fail 16 "exit(1) fehlt in RandInt64-Body ($RAND_LYX)"
fi

# Test 17: Altes silent-0-Muster entfernt — kein "var v: int64 := 0;" in RandInt64
if grep -A15 "pub fn RandInt64" "$RAND_LYX" 2>/dev/null | grep -q "var v.*:=.*0"; then
  _fail 17 "Altes silent-0-Muster noch vorhanden in RandInt64 ($RAND_LYX)"
else
  _pass 17
fi

# Test 18: Kommentar in rand.lyx erwähnt WP-37 oder exit(1)-Verhalten
if grep -q "WP-37\|exit(1)" "$RAND_LYX" 2>/dev/null; then
  _pass 18
else
  _fail 18 "Kein WP-37/exit(1)-Hinweis in $RAND_LYX"
fi

# Test 19: RandInt64-Body prüft rc != 8 (Fehlererkennungs-Pattern)
if grep -A15 "pub fn RandInt64" "$RAND_LYX" 2>/dev/null | grep -q "rc != 8"; then
  _pass 19
else
  _fail 19 "Fehlercheck 'rc != 8' fehlt in RandInt64 ($RAND_LYX)"
fi

# ── E: Integration ────────────────────────────────────────────────────────────

# Test 20: RandInt64 und RandU32 zusammen — typischer Anwendungsfall
cat > "$TMP/t20.lyx" << 'LYXEOF'
import std.crypto.rand;
fn main(): int64 {
  var session: int64 := RandInt64();
  var csrf:    int64 := RandU32();
  var nonce:   int64 := RandInt64();
  if session == 0   { return 1; }
  if csrf > 0xFFFFFFFF { return 2; }
  if nonce == session { return 3; }
  return 0;
}
LYXEOF
EC=0; "$LYXC" "$TMP/t20.lyx" -o "$TMP/t20" 2>/dev/null && "$TMP/t20" || EC=$?
if [ $EC -eq 0 ]; then _pass 20; else _fail 20 "RandInt64+RandU32 Integration fehlerhaft (EC=$EC)"; fi

# ── Zusammenfassung ───────────────────────────────────────────────────────────
echo ""
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
if [ $FAIL -gt 0 ]; then exit 1; fi
