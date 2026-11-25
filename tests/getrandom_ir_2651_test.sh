#!/usr/bin/env bash
# tests/getrandom_ir_2651_test.sh — #2651: sys_getrandom (Builtin 70) in den
# Linux-Zweigen von arm64 und riscv64.
#
# Vorher war die ID in beiden Backends unbehandelt: `std.crypto.rand` und damit
# der ganze TLS/DTLS-Stapel waren auf diesen Zielen NICHT baubar. Das kostete
# zusaetzlich die Gegensonde — ein gemeldeter lyxos-Befund wird sonst auf
# arm64/riscv nachgemessen, weil die drei Ziele denselben IR-Weg gehen (#1786,
# #1787, #1798 waren so entlarvt). Bei #2647 und #2649 fiel genau das aus.
#
# Geprueft wird die WIRKUNG, nicht das Vorhandensein:
#
#   1. rc == 256            der Kernel meldet 256 Byte geliefert
#   2. >= 240 Byte geaendert er hat auch GESCHRIEBEN (Puffer war auf 0xAA)
#   3. zweiter Ruf anders    es ist Zufall und keine Konstante
#   4. std.crypto.rand baut  der eigentliche Zweck der ID
#
# Punkt 2 und 3 sind der Kern: ein Test, der nur `rc == 256` prueft, waere auch
# von einer Fassung erfuellt, die nichts schreibt und 256 zurueckgibt — genau
# die Invariantenfalle, die `WriteString` jahrelang gedeckt hat (#1827).
#
# Die SCHWELLE ist gerechnet, nicht geraten. Mit 32 Byte und der Erwartung
# "alle nicht null" waere der Test FLAKY: die Wahrscheinlichkeit, dass unter 32
# Zufallsbytes mindestens eine Null ist, betraegt 1 - (255/256)^32 = 11,8 %.
# Genau das ist beim ersten Lauf zweimal passiert — der Test lag falsch, nicht
# der Code. Darum 256 Byte und die Frage "wieviele weichen von 0xAA ab":
# erwartet 255, und P(hoechstens 240) ist verschwindend. Die Vorbelegung ist
# 0xAA und nicht 0, damit auch eine Fassung auffaellt, die nur nullt.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
. "$(dirname "$0")/lib/qemu.sh"   # #2048
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

ZIELE=""
[ -n "$QEMU_ARM64" ]   && ZIELE="$ZIELE arm64"   || echo "HINWEIS: Emulator fuer arm64 fehlt"
[ -n "$QEMU_RISCV64" ] && ZIELE="$ZIELE riscv"   || echo "HINWEIS: Emulator fuer riscv fehlt"

cat > "$TMP/g.lyx" <<'EOS'
import std.io;
import std.string;
import std.alloc;
fn main(): int64 {
  var b: int64 := alloc(512);
  var i: int64 := 0;
  while (i < 256) { poke8(b + i, 0xAA); i := i + 1; }
  var rc: int64 := sys_getrandom(b, 256, 0);
  Print("rc "); PrintLn(IntToStr(rc));
  var nz: int64 := 0; i := 0;
  while (i < 256) { if (peek8(b + i) != 0xAA) { nz := nz + 1; } i := i + 1; }
  Print("nz "); PrintLn(IntToStr(nz));
  var c: int64 := alloc(512);
  sys_getrandom(c, 256, 0);
  var gleich: int64 := 1; i := 0;
  while (i < 256) { if (peek8(b + i) != peek8(c + i)) { gleich := 0; } i := i + 1; }
  Print("gleich "); PrintLn(IntToStr(gleich));
  return 0;
}
EOS

# Der Zweck: eine Unit, die Zufall braucht. std.crypto.rand ist die Stelle,
# ueber die der TLS-Stapel sie zieht.
cat > "$TMP/t.lyx" <<'EOS'
import std.io;
import std.string;
import std.alloc;
import std.crypto.rand;
fn main(): int64 {
  var b: int64 := alloc(512);
  var i: int64 := 0;
  while (i < 256) { poke8(b + i, 0xAA); i := i + 1; }
  RandBytes(b, 256);
  var nz: int64 := 0; i := 0;
  while (i < 256) { if (peek8(b + i) != 0xAA) { nz := nz + 1; } i := i + 1; }
  Print("rand-nz "); PrintLn(IntToStr(nz));
  return 0;
}
EOS

# linux als Gegenstand: dort ging es immer, also muss es weiter gehen.
for z in linux $ZIELE; do
  case "$z" in
    linux) OPT="--target=linux"; Q="" ;;
    arm64) OPT="--target=arm64"; Q="$QEMU_ARM64" ;;
    riscv) OPT="--target=riscv"; Q="$QEMU_RISCV64" ;;
  esac

  if ! "$LYXC" --std-path="$ROOT" $OPT "$TMP/g.lyx" -o "$TMP/g_$z" >"$TMP/bau_$z.log" 2>&1; then
    nok "$z: sys_getrandom uebersetzt nicht ($(grep -oE 'error:.*' "$TMP/bau_$z.log" | head -1))"
    continue
  fi
  AUS="$($Q "$TMP/g_$z" 2>&1)"
  RC_WERT="$(echo "$AUS" | grep -oE '^rc [0-9-]+' | awk '{print $2}')"
  NZ="$(echo "$AUS" | grep -oE '^nz [0-9]+' | awk '{print $2}')"
  GL="$(echo "$AUS" | grep -oE '^gleich [0-9]+' | awk '{print $2}')"

  [ "$RC_WERT" = "256" ] && ok "$z: rc == 256" \
                         || nok "$z: rc ist '$RC_WERT', erwartet 256"
  if [ -n "$NZ" ] && [ "$NZ" -ge 240 ]; then
    ok "$z: $NZ von 256 Byte geaendert (Schwelle 240)"
  else
    nok "$z: nur '$NZ' von 256 Byte von 0xAA abweichend (Schwelle 240)"
  fi
  [ "$GL" = "0" ]        && ok "$z: zweiter Aufruf liefert andere Bytes" \
                         || nok "$z: zweiter Aufruf liefert DIESELBEN Bytes — kein Zufall"

  # Der Zweck: std.crypto.rand baut und wirkt.
  if "$LYXC" --std-path="$ROOT" $OPT "$TMP/t.lyx" -o "$TMP/t_$z" >"$TMP/tbau_$z.log" 2>&1; then
    TNZ="$($Q "$TMP/t_$z" 2>&1 | grep -oE '^rand-nz [0-9]+' | awk '{print $2}')"
    if [ -n "$TNZ" ] && [ "$TNZ" -ge 240 ]; then
      ok "$z: std.crypto.rand aendert $TNZ von 256 Byte"
    else
      nok "$z: std.crypto.rand aendert nur '$TNZ' von 256 Byte (Schwelle 240)"
    fi
  else
    nok "$z: std.crypto.rand uebersetzt nicht ($(grep -oE 'error:.*' "$TMP/tbau_$z.log" | head -1))"
  fi
done

echo "---"
echo "$PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
