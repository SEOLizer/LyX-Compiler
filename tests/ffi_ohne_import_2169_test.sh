#!/usr/bin/env bash
# tests/ffi_ohne_import_2169_test.sh — #2169: extern fn auf Zielen ohne FFI-Weg.
#
# Bis 1.2.17C uebersetzten macos-arm64 und windows-arm64 einen Aufruf einer
# `extern fn` mit rc 0: Mach-O mit NOUNDEFS, PE ohne Importverzeichnis, der
# Name stand nicht einmal im Erzeugnis. Am Aufrufort lag die Linux-Folge
# `LDR x9,[pc+8]; B +12; .quad 0; BLR x9` — der GOT-Platz wurde nie gefuellt,
# der Aufruf sprang zur Laufzeit nach 0. Jetzt laut abgewiesen, mit dem
# Symbolnamen; der eigentliche Weg ist #2170.
#
# Gegenseite: dasselbe Programm OHNE extern fn uebersetzt auf beiden Zielen,
# und mit extern fn auf arm64-Linux (dort gibt es den Weg) weiterhin.
set -uo pipefail
ulimit -c 0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

baue() {  # ziel quelle ausgabe
  ( cd "$ROOT" && timeout 240 "$LYXC" --std-path="$ROOT" --target="$1" "$2" -o "$3" ) >"$3.log" 2>&1
}

cat > "$TMP/ffi.lyx" <<'LYX'
@cap(system.ffi)
extern fn pow(b: f64, e: f64): f64 link "libm.so.6";
fn main(): int64 { var r: f64 := pow(2.0, 5.0); return r as int64; }
LYX
printf 'fn main(): int64 { var r: f64 := 2.0 * 16.0; return r as int64; }\n' > "$TMP/ohne.lyx"

for t in macos-arm64 windows-arm64; do
  rm -f "$TMP/f.$t"
  if baue $t "$TMP/ffi.lyx" "$TMP/f.$t"; then
    nok "$t: extern fn uebersetzt (Erzeugnis ohne Import)"
  elif grep -q "extern fn wird auf diesem Ziel nicht gebunden" "$TMP/f.$t.log" && grep -q '`pow`' "$TMP/f.$t.log"; then
    ok "$t: extern fn laut abgewiesen, Symbol genannt"
  else
    nok "$t: $(grep -m1 -iE 'error' "$TMP/f.$t.log")"
  fi
  if baue $t "$TMP/ohne.lyx" "$TMP/o.$t" && [ -s "$TMP/o.$t" ]; then ok "$t: ohne extern fn uebersetzt"
  else nok "$t: ohne extern fn: $(grep -m1 -iE 'error' "$TMP/o.$t.log")"; fi
done

if baue arm64 "$TMP/ffi.lyx" "$TMP/f.arm64" && grep -q "pow" "$TMP/f.arm64"; then
  ok "arm64-Linux: extern fn weiterhin gebunden"
else nok "arm64-Linux: extern fn: $(grep -m1 -iE 'error' "$TMP/f.arm64.log")"; fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
