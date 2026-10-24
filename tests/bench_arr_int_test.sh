#!/usr/bin/env bash
# tests/bench_arr_int_test.sh — Ganzzahl-Feldkerne aus bench/ rechnen wie C (#2195).
#
# tools/bench_runtime.sh misst bench/arr_int.lyx gegen gcc/clang und misst
# nur, wenn die Pruefsummen gleich sind. Das Messgeschirr haengt an keinem
# Ziel; ohne diesen Test faellt eine abweichende Pruefsumme erst beim
# naechsten Messlauf auf. Geprueft wird deshalb:
#
#   1. fuer 8/16/32 Bit und add/mul/sum die Pruefsumme der Lyx-Fassung gegen
#      die der C-Fassung (gcc -O2) — mit Belegungen ueber die volle Breite,
#      add und mul laufen also wirklich ueber;
#   2. dasselbe auf arm64 und riscv unter qemu: die Kerne gehen dort ueber
#      den IR-Weg (peek/poke je Breite), nicht ueber den x86-Codegen.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
. "$(dirname "$0")/lib/qemu.sh"   # #2048
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# 1000 Elemente, 1300 Wiederholungen: jedes Element von a wird mindestens
# einmal veraendert, bevor die Pruefsumme steht.
N=1000; W=1300

if ! gcc -O2 -o "$TMP/ref" "$ROOT/bench/arr_int.c" 2>"$TMP/gcc.log"; then
  no "Referenz" "bench/arr_int.c uebersetzt nicht: $(head -2 "$TMP/gcc.log" | tr '\n' ' ')"
  echo "=== Results: $PASS passed, $FAIL failed ==="; exit 1
fi
declare -A SOLL=()
for b in 8 16 32; do for op in 1 2 3; do
  SOLL["$b $op"]="$("$TMP/ref" "$b" "$op" "$N" "$W")"
done; done

ziel() { # name target runner
  local name="$1" t="$2" run="$3" opt=""
  [ -n "$t" ] && opt="--target=$t"
  if ! (cd "$ROOT" && ulimit -v 4000000 && timeout 200 "$LYXC" --std-path="$ROOT" $opt bench/arr_int.lyx -o "$TMP/k.$name" >"$TMP/$name.log" 2>&1); then
    no "$name" "uebersetzt nicht: $(grep -v Copyright "$TMP/$name.log" | grep -i error | head -2 | tr '\n' ' ')"; return
  fi
  if [ "$name" != x86 ] && [ -z "$run" ]; then
    echo "HINWEIS: qemu fuer $name fehlt — nur uebersetzt."; ok "$name uebersetzt"; return
  fi
  local b op got falsch=0
  for b in 8 16 32; do for op in 1 2 3; do
    got=$( ulimit -c 0; cd "$TMP" && timeout 60 $run "$TMP/k.$name" "$b" "$op" "$N" "$W" 2>/dev/null )
    if [ "$got" != "${SOLL["$b $op"]}" ]; then
      no "$name breite $b op $op" "'$got' erwartet '${SOLL["$b $op"]}'"; falsch=1
    fi
  done; done
  [ "$falsch" -eq 0 ] && ok "$name: 9 Pruefsummen wie gcc"
}
ziel x86 "" ""
ziel arm64 arm64 "$QEMU_ARM64"
ziel riscv riscv "$QEMU_RISCV64"

echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
