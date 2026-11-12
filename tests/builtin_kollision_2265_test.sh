#!/usr/bin/env bash
# tests/builtin_kollision_2265_test.sh — keine Builtin-ID mit zwei Bedeutungen (#2265).
#
# peekf64/pokef64/peek32f/poke32f liefen bis 1.2.20J ueber die IDs 253-256 —
# dieselben wie cpu_id, cpu_xgetbv, popcount und clz. Im lyxos-Emitter gewann
# der erste Zweig der else-if-Kette: cpu_id las 8 Byte an der Adresse `leaf`,
# cpu_xgetbv SCHRIEB, popcount(x) las an x, clz(x) schrieb dorthin. Auf
# arm64/riscv kannten die Backends peek32f/poke32f gar nicht und fuehrten
# unter 255/256 popcount/clz aus. Von aussen unsichtbar: der Aufruf traf einen
# falschen, aber vorhandenen Zweig.
#
# Geprueft:
#   1. statisch: die Verteilerkette in emit_lyxos (emitBuiltinCall) nennt
#      jede ID hoechstens einmal (die Argumentzahl-Tabelle lxW17ac ausgenommen);
#   2. am Erzeugnis: lyxos-cpu_id enthaelt CPUID (0F A2);
#   3. die Wirkung auf x86, arm64, riscv: f32/f64-Speicher hin und zurueck,
#      popcount und clz.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
. "$(dirname "$0")/lib/qemu.sh"   # #2048
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ulimit -c 0
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# 1. Doppelte IDs in der lyxos-Verteilerkette.
dup=$(awk '/fn emitBuiltinCall\(/{f=1} f && /^    fn / && !/emitBuiltinCall/{f=0} f' "$ROOT/src/backend/lyxos/emit_lyxos.lyx" \
      | grep -v 'lxW17ac' | grep -oE 'id == [0-9]+ *\{' | grep -oE '[0-9]+' | sort -n | uniq -d | tr '\n' ' ')
if [ -z "$dup" ]; then ok "lyxos-Verteilerkette: jede ID genau einmal"; else no "doppelte IDs" "$dup"; fi

# 2. lyxos: cpu_id fuehrt CPUID aus.
printf 'fn main(): int64 { var a: int64 := cpu_id(0, 0, 1); return a & 1; }\n' > "$TMP/c.lyx"
if (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" --target=lyxos "$TMP/c.lyx" -o "$TMP/c.lyxos" >/dev/null 2>&1); then
  n=$(xxd -p "$TMP/c.lyxos" | tr -d '\n' | grep -o '0fa2' | wc -l)
  if [ "$n" -ge 1 ]; then ok "lyxos cpu_id enthaelt CPUID ($n x)"; else no "lyxos cpu_id" "kein CPUID im Erzeugnis"; fi
else no "lyxos cpu_id" "uebersetzt nicht"; fi

# 3. Wirkung.
cat > "$TMP/w.lyx" <<'LYX'
import std.io;
import std.alloc;
fn main(): int64 {
  var p: int64 := alloc(32);
  var a: f64 := 1.5;
  poke32f(p, a);
  var b: f64 := peek32f(p);
  var bi: int64 := (b * 4.0) as int64;
  PrintLn(bi);
  var c: f64 := 2.75;
  pokef64(p + 8, c);
  var d: f64 := peekf64(p + 8);
  var di: int64 := (d * 4.0) as int64;
  PrintLn(di);
  var pc: int64 := popcount(255);
  PrintLn(pc);
  var cz: int64 := clz(1);
  PrintLn(cz);
  return 0;
}
LYX
ERW="6 11 8 63"
for z in x86 arm64 riscv; do
  opt=""; q=""
  [ "$z" = arm64 ] && { [ -n "$QEMU_ARM64" ] || continue; opt="--target=arm64"; q="$QEMU_ARM64"; }
  [ "$z" = riscv ] && { [ -n "$QEMU_RISCV64" ] || continue; opt="--target=riscv"; q="$QEMU_RISCV64"; }
  if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" $opt "$TMP/w.lyx" -o "$TMP/w.$z" >"$TMP/w.$z.log" 2>&1); then
    no "Wirkung $z" "uebersetzt nicht: $(grep -m1 -i error "$TMP/w.$z.log")"; continue; fi
  got=$( cd "$TMP" && timeout 60 $q "$TMP/w.$z" 2>&1 | tr '\n' ' ' ); got="${got% }"
  if [ "$got" = "$ERW" ]; then ok "Wirkung $z: $got"; else no "Wirkung $z" "'$got' erwartet '$ERW'"; fi
done

echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
