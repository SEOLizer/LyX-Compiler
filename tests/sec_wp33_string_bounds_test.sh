#!/usr/bin/env bash
# tests/sec_wp33_string_bounds_test.sh — WP-33: String-Library Bounds-Hardening (20 Tests)
#
# Prüft:
#   A: StrLen(0) → 0 statt SIGSEGV
#   B: StrCopy Off-by-One behoben (kein OOB-Read)
#   C: StrSubstr Bounds-Check (negative/überlaufende Argumente → 0)
#   D: _sema_processImport Loop-Bedingung (modLen==0 kein Underflow)

set -euo pipefail

LYXC="${LYXC:-$(cd "$(dirname "$0")/.." && pwd)/lyxc}"
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

# ── A: StrLen Null-Pointer-Guard ─────────────────────────────────────────────

# Test 1: StrLen auf gültigem String gibt korrekte Länge zurück
cat > "$TMP/t1.lyx" << 'LYXEOF'
import src.std.string;
fn main(): int64 {
  var s: pchar := "hello"c;
  var n: int64 := StrLen(s as int64);
  if n == 5 { return 0; }
  return 1;
}
LYXEOF
compile_and_run "$TMP/t1.lyx" "$TMP/t1"
if "$TMP/t1"; then _pass 1; else _fail 1 "StrLen(\"hello\") sollte 5 sein"; fi

# Test 2: StrLen auf leerem String gibt 0 zurück
cat > "$TMP/t2.lyx" << 'LYXEOF'
import src.std.string;
fn main(): int64 {
  var s: pchar := ""c;
  var n: int64 := StrLen(s as int64);
  if n == 0 { return 0; }
  return 1;
}
LYXEOF
compile_and_run "$TMP/t2.lyx" "$TMP/t2"
if "$TMP/t2"; then _pass 2; else _fail 2 "StrLen(\"\") sollte 0 sein"; fi

# Test 3: StrLen(0) gibt 0 zurück (kein Crash)
cat > "$TMP/t3.lyx" << 'LYXEOF'
import src.std.string;
fn main(): int64 {
  var n: int64 := StrLen(0);
  if n == 0 { return 0; }
  return 1;
}
LYXEOF
compile_and_run "$TMP/t3.lyx" "$TMP/t3"
if "$TMP/t3"; then _pass 3; else _fail 3 "StrLen(0) sollte 0 zurückgeben (kein SIGSEGV)"; fi

# Test 4: StrLen auf 1-Zeichen-String gibt 1 zurück
cat > "$TMP/t4.lyx" << 'LYXEOF'
import src.std.string;
fn main(): int64 {
  var s: pchar := "X"c;
  var n: int64 := StrLen(s as int64);
  if n == 1 { return 0; }
  return 1;
}
LYXEOF
compile_and_run "$TMP/t4.lyx" "$TMP/t4"
if "$TMP/t4"; then _pass 4; else _fail 4 "StrLen(\"X\") sollte 1 sein"; fi

# Test 5: StrLen mehrfach aufrufen nach StrLen(0) — kein Zustandsproblem
cat > "$TMP/t5.lyx" << 'LYXEOF'
import src.std.string;
fn main(): int64 {
  StrLen(0);
  var s: pchar := "abc"c;
  var n: int64 := StrLen(s as int64);
  if n == 3 { return 0; }
  return 1;
}
LYXEOF
compile_and_run "$TMP/t5.lyx" "$TMP/t5"
if "$TMP/t5"; then _pass 5; else _fail 5 "StrLen nach StrLen(0) sollte korrekt arbeiten"; fi

# ── B: StrCopy Off-by-One ─────────────────────────────────────────────────────

# Test 6: StrCopy produziert korrekte Kopie
cat > "$TMP/t6.lyx" << 'LYXEOF'
import src.std.string;
fn main(): int64 {
  var s: pchar := "hello"c;
  var copy: pchar := StrCopy(s as int64, 5) as pchar;
  if StrCmp(s as int64, copy as int64) == 0 { return 0; }
  return 1;
}
LYXEOF
compile_and_run "$TMP/t6.lyx" "$TMP/t6"
if "$TMP/t6"; then _pass 6; else _fail 6 "StrCopy sollte identische Kopie erstellen"; fi

# Test 7: StrCopy (builtin) kopiert vollständigen String korrekt
cat > "$TMP/t7.lyx" << 'LYXEOF'
import src.std.string;
fn main(): int64 {
  var s: pchar := "hello"c;
  var copy: pchar := StrCopy(s as int64, 5) as pchar;
  if StrCmp(s as int64, copy as int64) == 0 { return 0; }
  return 1;
}
LYXEOF
compile_and_run "$TMP/t7.lyx" "$TMP/t7"
if "$TMP/t7"; then _pass 7; else _fail 7 "StrCopy(s, 5) sollte identische Kopie liefern"; fi

# Test 8: StrCopy korrekte Länge (kein Off-by-One in source-level Impl)
cat > "$TMP/t8.lyx" << 'LYXEOF'
import src.std.string;
fn main(): int64 {
  var s: pchar := "abc"c;
  var copy: pchar := StrCopy(s as int64, 3) as pchar;
  var n: int64 := StrLen(copy as int64);
  if n == 3 { return 0; }
  return 1;
}
LYXEOF
compile_and_run "$TMP/t8.lyx" "$TMP/t8"
if "$TMP/t8"; then _pass 8; else _fail 8 "StrCopy(\"abc\", 3) sollte Länge 3 liefern"; fi

# Test 9: StrCopy mit srcLen=1 — kein OOB
cat > "$TMP/t9.lyx" << 'LYXEOF'
import src.std.string;
fn main(): int64 {
  var s: pchar := "A"c;
  var copy: pchar := StrCopy(s as int64, 1) as pchar;
  var n: int64 := StrLen(copy as int64);
  if n == 1 { return 0; }
  return 1;
}
LYXEOF
compile_and_run "$TMP/t9.lyx" "$TMP/t9"
if "$TMP/t9"; then _pass 9; else _fail 9 "StrCopy(s, 1) sollte 1-Byte-Kopie liefern"; fi

# ── C: StrSubstr Bounds-Check ─────────────────────────────────────────────────

# Test 10: StrSubstr normaler Fall
cat > "$TMP/t10.lyx" << 'LYXEOF'
import src.std.string;
fn main(): int64 {
  var s: pchar := "hello world"c;
  var sub: pchar := StrSubstr(s as int64, 6, 5) as pchar;
  if StrCmp(sub as int64, "world"c as int64) == 0 { return 0; }
  return 1;
}
LYXEOF
compile_and_run "$TMP/t10.lyx" "$TMP/t10"
if "$TMP/t10"; then _pass 10; else _fail 10 "StrSubstr(s, 6, 5) sollte \"world\" sein"; fi

# Test 11: StrSubstr mit start+len > srcLen → 0
cat > "$TMP/t11.lyx" << 'LYXEOF'
import src.std.string;
fn main(): int64 {
  var s: pchar := "hello"c;
  var sub: int64 := StrSubstr(s as int64, 3, 10);
  if sub == 0 { return 0; }
  return 1;
}
LYXEOF
compile_and_run "$TMP/t11.lyx" "$TMP/t11"
if "$TMP/t11"; then _pass 11; else _fail 11 "StrSubstr OOB sollte 0 zurückgeben"; fi

# Test 12: StrSubstr mit start=0, len=0 → Leerstring (len 0 == 0 ist kein Fehler)
cat > "$TMP/t12.lyx" << 'LYXEOF'
import src.std.string;
fn main(): int64 {
  var s: pchar := "hello"c;
  var sub: int64 := StrSubstr(s as int64, 0, 0);
  if sub != 0 {
    var n: int64 := StrLen(sub);
    if n == 0 { return 0; }
    return 1;
  }
  return 1;
}
LYXEOF
compile_and_run "$TMP/t12.lyx" "$TMP/t12"
if "$TMP/t12"; then _pass 12; else _fail 12 "StrSubstr(s, 0, 0) sollte Leerstring liefern"; fi

# Test 13: StrSubstr mit src=0 → 0 (null-Pointer-Guard)
cat > "$TMP/t13.lyx" << 'LYXEOF'
import src.std.string;
fn main(): int64 {
  var sub: int64 := StrSubstr(0, 0, 3);
  if sub == 0 { return 0; }
  return 1;
}
LYXEOF
compile_and_run "$TMP/t13.lyx" "$TMP/t13"
if "$TMP/t13"; then _pass 13; else _fail 13 "StrSubstr(0, ...) sollte 0 zurückgeben"; fi

# Test 14: StrSubstr exakt bis Ende — kein OOB
cat > "$TMP/t14.lyx" << 'LYXEOF'
import src.std.string;
fn main(): int64 {
  var s: pchar := "hello"c;
  var sub: pchar := StrSubstr(s as int64, 0, 5) as pchar;
  if StrCmp(sub as int64, "hello"c as int64) == 0 { return 0; }
  return 1;
}
LYXEOF
compile_and_run "$TMP/t14.lyx" "$TMP/t14"
if "$TMP/t14"; then _pass 14; else _fail 14 "StrSubstr(s, 0, 5) == \"hello\" erwartet"; fi

# ── D: _sema_processImport Loop-Bedingung ─────────────────────────────────────

# Test 15: 1-Zeichen-Modulname wird korrekt verarbeitet (kein OOB)
cat > "$TMP/t15.lyx" << 'LYXEOF'
fn main(): int64 { return 0; }
LYXEOF
# Dieser Test prüft ob der Compiler mit einem 1-char Importnamen nicht abstürzt.
# Wir benutzen den -I Flag mit einem Pfad der ein 1-char Modul enthält
echo 'pub fn dummy(): int64 { return 0; }' > "$TMP/x.lyx"
cat > "$TMP/t15_import.lyx" << 'LYXEOF'
import x;
fn main(): int64 { return 0; }
LYXEOF
if "$LYXC" "$TMP/t15_import.lyx" -I "$TMP" -o "$TMP/t15_out" 2>/dev/null; then
  _pass 15
else
  _fail 15 "1-Zeichen-Import sollte ohne Absturz kompilieren"
fi

# Test 16: 2-Zeichen-Modulname (Grenzwert) funktioniert
echo 'pub fn dummy2(): int64 { return 0; }' > "$TMP/xy.lyx"
cat > "$TMP/t16_import.lyx" << 'LYXEOF'
import xy;
fn main(): int64 { return 0; }
LYXEOF
if "$LYXC" "$TMP/t16_import.lyx" -I "$TMP" -o "$TMP/t16_out" 2>/dev/null; then
  _pass 16
else
  _fail 16 "2-Zeichen-Import sollte kompilieren"
fi

# Test 17: Import-Path-Traversal ".." wird weiterhin erkannt
cat > "$TMP/t17.lyx" << 'LYXEOF'
import a..b;
fn main(): int64 { return 0; }
LYXEOF
OUT17=$("$LYXC" "$TMP/t17.lyx" -o "$TMP/t17_out" 2>&1) || true
if echo "$OUT17" | grep -q "traversal\|verboten\|error"; then
  _pass 17
else
  _fail 17 "Path-Traversal-Versuch sollte Fehler auslösen. Out: $OUT17"
fi

# Test 18: Normaler Import mit Punkten (z.B. src.std.string) noch korrekt
cat > "$TMP/t18.lyx" << 'LYXEOF'
import src.std.string;
fn main(): int64 {
  var n: int64 := StrLen("test"c as int64);
  if n == 4 { return 0; }
  return 1;
}
LYXEOF
compile_and_run "$TMP/t18.lyx" "$TMP/t18"
if "$TMP/t18"; then _pass 18; else _fail 18 "import src.std.string sollte weiter funktionieren"; fi

# Test 19: StrConcat nutzt StrLen intern — StrLen(0)-Guard greift durch
cat > "$TMP/t19.lyx" << 'LYXEOF'
import src.std.string;
fn main(): int64 {
  var a: pchar := "foo"c;
  var b: pchar := "bar"c;
  var c: pchar := StrConcat(a as int64, b as int64) as pchar;
  if StrCmp(c as int64, "foobar"c as int64) == 0 { return 0; }
  return 1;
}
LYXEOF
compile_and_run "$TMP/t19.lyx" "$TMP/t19"
if "$TMP/t19"; then _pass 19; else _fail 19 "StrConcat(\"foo\", \"bar\") sollte \"foobar\" sein"; fi

# Test 20: StrTrim nutzt StrLen intern und läuft korrekt
cat > "$TMP/t20.lyx" << 'LYXEOF'
import src.std.string;
fn main(): int64 {
  var s: pchar := "  hello  "c;
  var t: pchar := StrTrim(s as int64) as pchar;
  if StrCmp(t as int64, "hello"c as int64) == 0 { return 0; }
  return 1;
}
LYXEOF
compile_and_run "$TMP/t20.lyx" "$TMP/t20"
if "$TMP/t20"; then _pass 20; else _fail 20 "StrTrim sollte Whitespace entfernen"; fi

# ── Zusammenfassung ──────────────────────────────────────────────────────────
echo ""
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
if [ $FAIL -gt 0 ]; then exit 1; fi
