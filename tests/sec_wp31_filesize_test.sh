#!/usr/bin/env bash
# tests/sec_wp31_filesize_test.sh — WP-31: Dateigrößen-Limit FileReadAll (20 Tests)
#
# Prüft:
#   A: FileReadAll liest kleine Dateien korrekt (Verhalten unverändert)
#   B: FileReadAll gibt 0 zurück bei >256 MB Dateien
#   C: _sema_readFile gibt 0 zurück bei >256 MB .lyx/.lyu-Dateien (Compiler-Test)

set -euo pipefail

LYXC="${LYXC:-$(cd "$(dirname "$0")/.." && pwd)/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

_pass() { echo "PASS $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# ── Hilfsfunktionen ──────────────────────────────────────────────────────────

# Baut ein Lyx-Programm, das FileReadAll(argv[1]) aufruft.
# Gibt exit code 0 wenn Rückgabe != 0, exit code 1 wenn Rückgabe == 0.
make_reader_prog() {
  local src="$1"
  cat > "$src" << 'LYXEOF'
import src.std.io;
import src.std.alloc;

pub fn main(argc: int64, argv: pchar): int64 {
  if argc < 2 { return 2; }
  var path: pchar := peek64(argv as int64 + 8) as pchar;
  var content: pchar := FileReadAll(path);
  if content == 0 as pchar { return 1; }
  return 0;
}
LYXEOF
}

# Kompiliert das Reader-Programm (einmalig)
READER_SRC="$TMP/reader.lyx"
READER_BIN="$TMP/reader"
make_reader_prog "$READER_SRC"

if ! "$LYXC" "$READER_SRC" -o "$READER_BIN" 2>/dev/null; then
  echo "FATAL: Konnte Reader-Programm nicht kompilieren"
  exit 1
fi

# ── A: Kleine Dateien — FileReadAll muss funktionieren ──────────────────────

# Test 1: leere Datei → FileReadAll gibt 0 zurück (size=0 → return null)
echo -n "" > "$TMP/empty.txt"
if ! "$READER_BIN" "$TMP/empty.txt" > /dev/null 2>&1; then
  _pass 1
else
  _fail 1 "leere Datei sollte 0 zurückgeben (size=0)"
fi

# Test 2: 1-Byte-Datei → FileReadAll gibt non-zero zurück
echo -n "X" > "$TMP/one.txt"
if "$READER_BIN" "$TMP/one.txt" > /dev/null 2>&1; then
  _pass 2
else
  _fail 2 "1-Byte-Datei sollte non-zero zurückgeben"
fi

# Test 3: 1 KB Datei → OK
dd if=/dev/urandom bs=1024 count=1 of="$TMP/1k.bin" 2>/dev/null
if "$READER_BIN" "$TMP/1k.bin" > /dev/null 2>&1; then
  _pass 3
else
  _fail 3 "1-KB-Datei sollte lesbar sein"
fi

# Test 4: 1 MB Datei → OK
dd if=/dev/urandom bs=1048576 count=1 of="$TMP/1m.bin" 2>/dev/null
if "$READER_BIN" "$TMP/1m.bin" > /dev/null 2>&1; then
  _pass 4
else
  _fail 4 "1-MB-Datei sollte lesbar sein"
fi

# Test 5: 16 MB Datei → OK
dd if=/dev/urandom bs=1048576 count=16 of="$TMP/16m.bin" 2>/dev/null
if "$READER_BIN" "$TMP/16m.bin" > /dev/null 2>&1; then
  _pass 5
else
  _fail 5 "16-MB-Datei sollte lesbar sein"
fi

# Test 6: 64 MB Datei → OK
dd if=/dev/urandom bs=1048576 count=64 of="$TMP/64m.bin" 2>/dev/null
if "$READER_BIN" "$TMP/64m.bin" > /dev/null 2>&1; then
  _pass 6
else
  _fail 6 "64-MB-Datei sollte lesbar sein"
fi

# Test 7: 128 MB Datei → OK
dd if=/dev/urandom bs=1048576 count=128 of="$TMP/128m.bin" 2>/dev/null
if "$READER_BIN" "$TMP/128m.bin" > /dev/null 2>&1; then
  _pass 7
else
  _fail 7 "128-MB-Datei sollte lesbar sein"
fi

# ── B: Grenzwert 256 MB ──────────────────────────────────────────────────────

# Test 8: genau 256 MB (= 268435456 Bytes) — exakt am Limit → OK
# Sparse-Datei: kein echter Disk-Verbrauch
truncate -s 268435456 "$TMP/exactly256m.bin"
if "$READER_BIN" "$TMP/exactly256m.bin" > /dev/null 2>&1; then
  _pass 8
else
  _fail 8 "Genau-256-MB-Datei sollte lesbar sein (Limit ist >256 MB)"
fi

# Test 9: 256 MB + 1 Byte (268435457) → ÜBER dem Limit → FileReadAll gibt 0 zurück
truncate -s 268435457 "$TMP/over256m.bin"
if ! "$READER_BIN" "$TMP/over256m.bin" > /dev/null 2>&1; then
  _pass 9
else
  _fail 9 "Datei >256 MB sollte 0 zurückgeben"
fi

# Test 10: 512 MB (sparse) → FileReadAll gibt 0 zurück
truncate -s 536870912 "$TMP/512m.bin"
if ! "$READER_BIN" "$TMP/512m.bin" > /dev/null 2>&1; then
  _pass 10
else
  _fail 10 "512-MB-Datei sollte 0 zurückgeben"
fi

# Test 11: 1 GB (sparse) → FileReadAll gibt 0 zurück
truncate -s 1073741824 "$TMP/1g.bin"
if ! "$READER_BIN" "$TMP/1g.bin" > /dev/null 2>&1; then
  _pass 11
else
  _fail 11 "1-GB-Datei sollte 0 zurückgeben"
fi

# Test 12: 4 GB (sparse) → FileReadAll gibt 0 zurück (OOM-Angriff)
truncate -s 4294967296 "$TMP/4g.bin"
if ! "$READER_BIN" "$TMP/4g.bin" > /dev/null 2>&1; then
  _pass 12
else
  _fail 12 "4-GB-Datei sollte 0 zurückgeben"
fi

# Test 13: Nicht vorhandene Datei → FileReadAll gibt 0 zurück
if ! "$READER_BIN" "$TMP/nonexistent_wp31.bin" > /dev/null 2>&1; then
  _pass 13
else
  _fail 13 "Nicht vorhandene Datei sollte 0 zurückgeben"
fi

# ── C: _sema_readFile: Compiler lehnt >256-MB-.lyx-Datei ab ─────────────────

# Test 14: Normale .lyx-Datei unter dem Limit → Compiler erfolgreich
echo 'fn main(): int64 { return 0; }' > "$TMP/normal.lyx"
if "$LYXC" "$TMP/normal.lyx" -o "$TMP/normal_bin" 2>/dev/null; then
  _pass 14
else
  _fail 14 "Normale .lyx-Datei sollte kompilierbar sein"
fi

# Test 15: Überdimensionale Haupt-.lyx-Datei (sparse) → Compiler gibt Fehler aus
# FileReadAll gibt null → lyxc: "Cannot read input file"
truncate -s 268435457 "$TMP/huge.lyx"
OUT15=$("$LYXC" "$TMP/huge.lyx" -o "$TMP/huge_bin" 2>&1) || true
if [ $? -ne 0 ] || ! echo "$OUT15" | grep -qE "Cannot read|Cannot open|error"; then
  : # The command failed (expected) - $? will be non-zero from the || true
fi
# Re-check: does file-too-large cause compiler failure?
if ! "$LYXC" "$TMP/huge.lyx" -o "$TMP/huge_bin2" 2>/dev/null; then
  _pass 15
else
  _fail 15 "Überdimensionale .lyx-Datei sollte Compiler-Fehler auslösen"
fi

# Test 16: Fehlermeldung enthält "Cannot read" oder "256-MB-Limit"
if echo "$OUT15" | grep -qE "Cannot read|256-MB-Limit"; then
  _pass 16
else
  _fail 16 "Fehlermeldung fehlt in: $OUT15"
fi

# Test 17: Import einer >256 MB .lyu-Datei → _sema_readFile Fehlermeldung mit "256-MB-Limit"
# Simuliere ein zu großes precompiliertes Unit
truncate -s 268435457 "$TMP/fatunit.lyu"
cat > "$TMP/import_fat.lyx" << 'LYXEOF'
import fatunit;
fn main(): int64 { return 0; }
LYXEOF
OUT17=$("$LYXC" "$TMP/import_fat.lyx" -I "$TMP" -o "$TMP/import_fat_bin" 2>&1) || true
if echo "$OUT17" | grep -q "256-MB-Limit"; then
  _pass 17
else
  _fail 17 "Import einer >256-MB-.lyu-Datei sollte '256-MB-Limit' Fehler ausgeben. Out: $OUT17"
fi

# Test 18: Normaldatei nach Limit-Fehler noch lesbar (kein bleibender Zustand)
echo -n "healthy" > "$TMP/healthy.txt"
if "$READER_BIN" "$TMP/healthy.txt" > /dev/null 2>&1; then
  _pass 18
else
  _fail 18 "Normaldatei nach Limit-Test sollte noch lesbar sein"
fi

# Test 19: Grenzwert: 256 MB - 1 Byte (268435455) → noch lesbar
# Diese sparse-Datei hat 268435455 Bytes = 256 MB - 1 → unter Limit
truncate -s 268435455 "$TMP/just_under.bin"
if "$READER_BIN" "$TMP/just_under.bin" > /dev/null 2>&1; then
  _pass 19
else
  _fail 19 "256 MB - 1 Byte sollte lesbar sein"
fi

# Test 20: Mehrfachaufruf mit mix aus kleinen und großen Dateien → kein Zustandsproblem
truncate -s 268435457 "$TMP/big_again.bin"
echo -n "ok" > "$TMP/small_again.txt"
if ! "$READER_BIN" "$TMP/big_again.bin" > /dev/null 2>&1; then
  if "$READER_BIN" "$TMP/small_again.txt" > /dev/null 2>&1; then
    _pass 20
  else
    _fail 20 "Kleine Datei nach großer Datei sollte lesbar sein"
  fi
else
  _fail 20 "Große Datei sollte 0 zurückgeben"
fi

# ── Zusammenfassung ──────────────────────────────────────────────────────────
echo ""
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
if [ $FAIL -gt 0 ]; then exit 1; fi
