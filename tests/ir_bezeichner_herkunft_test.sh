#!/usr/bin/env bash
# tests/ir_bezeichner_herkunft_test.sh — #2127: jeder Bezeichner als Wert hat
# auf dem IR-Weg (arm64, riscv) eine Herkunft — oder die Uebersetzung bricht
# LAUT ab.
#
# Bis 1.2.14C pruefte lowerExpr (NK_IDENT) Local, Param, Modulvariable und
# Funktion; traf nichts, kam ein UNBESCHRIEBENER Temp zurueck. Betroffen:
#   - Enum-Elemente, mit und ohne Typpraefix (`Rot`, `Farbe.Rot`, `white`
#     aus std.crt) — der IR-Weg kannte Enums gar nicht;
#   - `con` im Funktionsrumpf (`con PI := 314159`, FNV_OFFSET_BASIS in
#     src/std/map.lyx) — lowerStmt verwarf NK_CON_DECL still;
#   - eingebaute Konstanten (PROT_RW, MAP_ANON, FD_NONE, O_*, TARGET_ARCH).
# Dazu auf x86: ein Enum-Element ohne Praefix mit berechnetem Wert
# (`A = 2 + 3`) bekam den Positionswert statt des Werts.
#
# Gemessen wird der WERT auf x86_64, arm64 und riscv (qemu); die Gegenseite:
# ein Name, fuer den der IR-Weg keine Herkunft hat (extern-Datum), wird laut
# abgewiesen statt still uebersetzt.
set -uo pipefail
ulimit -c 0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
. "$(dirname "$0")/lib/qemu.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

if [ -z "$QEMU_ARM64" ] || [ -z "$QEMU_RISCV64" ]; then echo "FAIL qemu fuer arm64/riscv fehlt — NICHT gemessen"; exit 1; fi

lauf() {  # ziel, binary
  case "$1" in
    linux) timeout 30 "$2" ;;
    arm64) timeout 30 "$QEMU_ARM64" "$2" ;;
    riscv) timeout 30 "$QEMU_RISCV64" "$2" ;;
  esac
}

# pruefe name datei soll-linux soll-arm64 soll-riscv
pruefe_je() {
  local t soll
  for t in linux arm64 riscv; do
    case $t in linux) soll="$3" ;; arm64) soll="$4" ;; riscv) soll="$5" ;; esac
    rm -f "$TMP/p"
    if ! ( cd "$ROOT" && timeout 240 "$LYXC" --std-path="$ROOT" --target=$t "$2" -o "$TMP/p" ) >"$TMP/bl.log" 2>&1; then
      nok "$1 [$t]: uebersetzt nicht ($(grep -m1 -iE 'error' "$TMP/bl.log"))"; continue
    fi
    local aus rc
    aus="$(lauf $t "$TMP/p" 2>/dev/null | tr '\n' '|')"; rc=${PIPESTATUS[0]}
    if [ "$aus" = "$soll" ] && [ "$rc" = "0" ]; then ok "$1 [$t]: [$aus]"
    else nok "$1 [$t]: [$aus] rc=$rc statt [$soll]"; fi
  done
}
pruefe() { pruefe_je "$1" "$2" "$3" "$3" "$3"; }

# 1. Enum der eigenen Datei: ohne Praefix, mit Praefix, berechneter Wert,
#    Weiterzaehlen, als Fallmarke und in einer Modulkonstanten.
cat > "$TMP/enum.lyx" <<'EOF'
enum Farbe { Rot, Gruen = 5, Blau, Lila = 2 + 3 * 4, Gelb }
con MIT_ENUM: int64 := Blau * 100;
fn name(f: int64): int64 {
  switch (f) {
    case Rot:  { return 10; }
    case Blau: { return 30; }
    case Gelb: { return 50; }
  }
  return 99;
}
fn main(): int64 {
  var f: int64 := Gruen;
  PrintInt(Rot); Print(" "); PrintInt(f); Print(" "); PrintInt(Blau); Print(" ");
  PrintInt(Lila); Print(" "); PrintInt(Gelb); Print(" ");
  PrintInt(Farbe.Blau); Print(" "); PrintInt(Farbe.Lila); Print(" ");
  PrintInt(name(Blau)); Print(" "); PrintInt(name(Farbe.Gelb)); Print(" ");
  PrintInt(name(Gruen)); Print(" "); PrintInt(MIT_ENUM); Print("\n");
  return 0;
}
EOF
pruefe "Enum der Datei" "$TMP/enum.lyx" "0 5 6 14 15 6 14 30 50 99 600|"

# 2. Enum einer importierten Unit (std.crt: crt_color), auch als Fallmarke.
cat > "$TMP/crt.lyx" <<'EOF'
import std.crt;
fn art(c: int64): int64 {
  switch (c) {
    case black: { return 1; }
    case cyan:  { return 2; }
    case white: { return 3; }
  }
  return 9;
}
fn main(): int64 {
  PrintInt(white); Print(" "); PrintInt(cyan); Print(" ");
  PrintInt(art(cyan)); PrintInt(art(white)); PrintInt(art(black)); PrintInt(art(red)); Print("\n");
  return 0;
}
EOF
pruefe "Enum aus std.crt" "$TMP/crt.lyx" "15 3 2319|"

# 3. `con` im Funktionsrumpf, auch abgeleitet von einer Modulkonstanten und
#    verdeckt von einem Parameter gleichen Namens.
cat > "$TMP/lcon.lyx" <<'EOF'
con G: int64 := 7;
fn h(len: int64): int64 {
  con BASIS: int64 := 2166136261;
  con PRIM: int64 := 16777619;
  con ABL: int64 := G * 3;
  var x: int64 := BASIS;
  x := x ^ len;
  x := x * PRIM;
  return x + ABL;
}
fn verdeckt(PI: int64): int64 { return PI + 1; }
fn main(): int64 {
  con PI: int64 := 314159;
  PrintInt(PI); Print(" "); PrintInt(h(3)); Print(" "); PrintInt(verdeckt(4)); Print("\n");
  return 0;
}
EOF
pruefe "con im Rumpf" "$TMP/lcon.lyx" "314159 36342608905920199 5|"

# 4. FNV-1a aus src/std/map.lyx (lokale con FNV_OFFSET_BASIS). Sollwert nach
#    der Definition, bytweise ueber "abc", modulo 2^64 als int64:
#    6851979267275221259.
cat > "$TMP/fnv.lyx" <<'EOF'
import src.std.map;
fn main(): int64 {
  var s: pchar := "abc";
  PrintInt(HashString(s as int64, 3)); Print("\n");
  var t: int64 := alloc(4);
  poke8(t, 97); poke8(t + 1, 98); poke8(t + 2, 99);
  PrintInt(HashString(t, 3)); Print("\n");
  return 0;
}
EOF
pruefe "FNV HashString" "$TMP/fnv.lyx" "6851979267275221259|6851979267275221259|"

# 5. Eingebaute Konstanten — Wert UND Wirkung (mmap mit diesen Argumenten).
#    (O_* fuehrt sema nicht, siehe cg_addBuiltinCons — hier nicht erreichbar.)
cat > "$TMP/eingebaut.lyx" <<'EOF'
fn main(): int64 {
  PrintInt(PROT_RW * 1000 + MAP_ANON); Print(" "); PrintInt(FD_NONE); Print(" ");
  PrintInt(PROT_READ + PROT_WRITE * 10 + MAP_PRIVATE * 100 + MAP_SHARED * 1000); Print(" ");
  var p: int64 := mmap(0, 4096, PROT_RW, MAP_ANON, FD_NONE, 0);
  poke64(p + 8, 4242);
  PrintInt(peek64(p + 8)); Print("\n");
  return 0;
}
EOF
pruefe "eingebaute Konstanten" "$TMP/eingebaut.lyx" "3034 -1 1221 4242|"

# 6. Zielkonstanten: Wert je Ziel (x86_64=1, arm64=2, riscv=3).
cat > "$TMP/ziel.lyx" <<'EOF'
fn main(): int64 {
  PrintInt(TARGET_ARCH); Print(" "); PrintInt(TARGET_OS); Print(" ");
  PrintInt(TARGET_IS_ARM64); PrintInt(TARGET_LINUX); Print(" "); PrintInt(ARCH_RISCV64); Print("\n");
  return 0;
}
EOF
pruefe_je "Zielkonstanten" "$TMP/ziel.lyx" "1 1 01 3|" "2 1 11 3|" "3 1 01 3|"

# 7. Gegenseite: ein extern-Datum hat auf dem IR-Weg keine Herkunft. Bis
#    1.2.14C uebersetzte das fehlerfrei mit einem Zufallswert; jetzt laut,
#    mit dem Namen.
cat > "$TMP/unbekannt.lyx" <<'EOF'
extern "asm" kernel_tab: int64;
fn main(): int64 {
  var p: int64 := kernel_tab;
  PrintInt(p); Print("\n");
  return 0;
}
EOF
for t in arm64 riscv; do
  ( cd "$ROOT" && timeout 240 "$LYXC" --std-path="$ROOT" --target=$t "$TMP/unbekannt.lyx" -o "$TMP/u" ) >"$TMP/u.log" 2>&1; rc=$?
  if [ "$rc" != "0" ] && grep -q "'kernel_tab'.*#2127" "$TMP/u.log"; then ok "unbekannter Name [$t]: laut abgewiesen"
  else nok "unbekannter Name [$t]: rc=$rc, keine #2127-Meldung mit dem Namen"; fi
done

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
