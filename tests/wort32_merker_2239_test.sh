#!/usr/bin/env bash
# tests/wort32_merker_2239_test.sh — 64-Bit-Anfangswerte auf esp32/arm-cm werden
# nicht mehr still gekuerzt gelesen (#2239).
#
# Auf beiden 32-Bit-Zielen ist int64 ein Wort. Konstanten IM CODE, die nicht
# hineinpassen, werden seit #2149/#2237 laut abgewiesen; die ANFANGSWERTE von
# Modulvariablen und `con` liefen aber gekuerzt durch: HashFNV1a64("abc")
# lieferte auf esp32 still einen falschen Wert (FNV_OFFSET_BASIS_64).
#
# Jetzt traegt jedes solche Global ein Merkerwort; Schreiben setzt es, Lesen
# bei ungesetztem Merker bricht ab (esp32 ILL -> SIGILL, arm-cm BKPT ->
# Lockup). Ein Abbruch beim Uebersetzen waere zu weit: `import std.hash` muss
# fuer DJB2 benutzbar bleiben (siehe arm_cm_konstanten_2237_test.sh).
#
# Beide Seiten:
#   - Lesen einer nicht darstellbaren `con` bricht ab (vorher: Wert 7, also
#     weitergerechnet mit gekuerztem Hash);
#   - DJB2 aus derselben Unit, eine erst beschriebene Variable, eine nie
#     gelesene und eine Grenz-Konstante (2^32-1) laufen normal.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
. "$(dirname "$0")/lib/qemu.sh"   # #2048
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# #1789: SIGILL ist hier gewollt — keine Speicherauszuege.
ulimit -c 0
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }
HUELLE="$ROOT/tests/lib/xtensa_huelle.py"
QARM="$(command -v qemu-system-arm || true)"

uebersetze() { # quelle ziel ausgabe
  (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" --target="$2" "$1" -o "$3" >"$3.log" 2>&1)
}

# --- esp32: Rueckgabewert ueber die Xtensa-Huelle --------------------------
esp() { # name quelle erwarteter_rc
  printf '%s\n' "$2" > "$TMP/$1.lyx"
  if ! uebersetze "$TMP/$1.lyx" esp32 "$TMP/$1.esp"; then
    no "esp32 $1" "uebersetzt nicht: $(grep -m1 -i error "$TMP/$1.esp.log")"; return; fi
  if [ -z "$QEMU_XTENSA" ]; then ok "esp32 $1 uebersetzt (Emulator fuer xtensa fehlt)"; return; fi
  if ! python3 "$HUELLE" "$TMP/$1.esp" "$TMP/$1.run" >/dev/null 2>&1; then
    no "esp32 $1" "Huelle konnte das Abbild nicht umpacken"; return; fi
  (cd "$TMP" && timeout 60 "$QEMU_XTENSA" "$TMP/$1.run" >/dev/null 2>&1); local rc=$?
  if [ "$rc" -eq "$3" ]; then ok "esp32 $1: rc $rc"; else no "esp32 $1" "rc $rc erwartet $3"; fi
}
# DJB2("abc") in 32 Bit: 193485963, & 127 = 11
esp djb2   'import std.hash;
fn main(): int64 { var d: int64 := HashDJB2("abc"); return d & 127; }' 11
esp fnv    'import std.hash;
fn main(): int64 { var h: int64 := HashFNV1a64("abc"); return 7; }' 132
esp gesetzt 'var g: int64 := 6833185961996073490;
fn main(): int64 { g := 77; return g; }' 77
esp ungelesen 'var g: int64 := 6833185961996073490;
fn main(): int64 { return 9; }' 9
esp grenze 'con M: int64 := 4294967295;
fn main(): int64 { return M & 127; }' 127
esp con64  'con K: int64 := 6833185961996073490;
fn main(): int64 { var k: int64 := K; return 5; }' 132

# --- arm-cm4: Semihosting-Ausgabe; der Halt beendet die Ausgabe -------------
cm() { # name quelle erwartete_ausgabe
  printf '%s\n' "$2" > "$TMP/$1.lyx"
  if ! uebersetze "$TMP/$1.lyx" arm-cm4 "$TMP/$1.cm"; then
    no "arm-cm $1" "uebersetzt nicht: $(grep -m1 -i error "$TMP/$1.cm.log")"; return; fi
  if [ -z "$QARM" ]; then ok "arm-cm $1 uebersetzt (qemu-system-arm fehlt)"; return; fi
  local got
  got="$(timeout 10 "$QARM" -M olimex-stm32-h405 -nographic -semihosting -kernel "$TMP/$1.cm" 2>&1 </dev/null \
         | tr -d '\r' | awk '/^qemu/ {exit} NF {print}' | tr '\n' ' ')"   # Registerauszug nach dem Halt abschneiden
  got="${got% }"
  if [ "$got" = "$3" ]; then ok "arm-cm $1: '$got'"; else no "arm-cm $1" "'$got' erwartet '$3'"; fi
}
cm fnv 'import std.io;
import std.hash;
fn main(): int64 {
  var d: int64 := HashDJB2("abc");
  PrintInt(d & 255); PrintLn(""c);
  var h: int64 := HashFNV1a64("abc");
  PrintLn("nach dem Lesen"c);
  return 0;
}' "139"
cm gesetzt 'import std.io;
var g: int64 := 6833185961996073490;
fn main(): int64 { g := 77; PrintInt(g); PrintLn(""c); return 0; }' "77"

echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
