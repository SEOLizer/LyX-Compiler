#!/usr/bin/env bash
# tests/riscv_zusicherung_test.sh — #2105: die Zusicherungen auf riscv
# springen im guten Fall UEBER den Abbruch, nicht auf sein ecall.
#
# ASSERT_NOT_ZERO (vor jeder Division), ASSERT_NOT_NULL, ASSERT_TRUE und
# ASSERT_BOUNDS sprangen mit fester Weite +12 — der Abbruch ist aber drei
# Befehle lang (li, li, ecall), das Ziel war das ecall SELBST. Im guten Fall
# lief also ein Systemaufruf mit dem, was gerade in a7/a0 stand: nach einer
# Ausgabe ein write(<Wert>, ...). In `malloc` (align_to_8 teilt durch 8) traf
# das im vollen `make test` eine geerbte Pipe — SIGPIPE, rc 141, mitten in
# examples/test_zlib, einzeln nie.
#
# Gemessen wird am ERZEUGNIS: qemu -strace zeigt jeden Systemaufruf. Im guten
# Fall darf es kein write auf einen anderen Deskriptor als 1 geben; im
# verletzten Fall muss das Programm mit 1 abbrechen.
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

if [ -z "$QEMU_RISCV64" ]; then echo "FAIL qemu-riscv64 fehlt — NICHT gemessen"; exit 1; fi

pruefe() {  # name, quelltext, soll-ausgabe, soll-rc
  printf '%s\n' "$2" > "$TMP/p.lyx"; rm -f "$TMP/p"
  if ! ( cd "$ROOT" && timeout 240 "$LYXC" --std-path="$ROOT" --target=riscv "$TMP/p.lyx" -o "$TMP/p" ) >"$TMP/bl.log" 2>&1; then
    nok "$1: uebersetzt nicht ($(grep -m1 -iE 'error' "$TMP/bl.log"))"; return
  fi
  ( timeout 30 "$QEMU_RISCV64" "$TMP/p" >"$TMP/out" 2>/dev/null ); local rc=$?
  local aus; aus="$(tr '\n' '|' < "$TMP/out")"
  local fremd; fremd="$(timeout 30 "$QEMU_RISCV64" -strace "$TMP/p" 2>&1 >/dev/null | grep -oE 'write\([0-9]+' | grep -v 'write(1$' | sort -u | tr '\n' ' ')"
  if [ "$aus" != "$3" ] || [ "$rc" != "$4" ]; then nok "$1: [$aus] rc=$rc statt [$3] rc=$4"
  elif [ -n "$fremd" ]; then nok "$1: fremder Systemaufruf: $fremd"
  else ok "$1: [$aus] rc=$rc, kein fremder write"; fi
}

# Der Fall aus dem Issue: Ausgabe, danach malloc (align_to_8 teilt durch 8).
pruefe "PrintLn, dann malloc(166)" 'import std.io;
import std.alloc;
fn main(): int64 { var a: int64 := 12345; PrintLn(IntToStr(a)); var p: int64 := malloc(166); if (p == 0) { return 3; } PrintLn("ok"); return 0; }' "12345|ok|" 0

pruefe "Division 84/2" 'import std.io;
fn teile(a: int64, b: int64): int64 { return a / b; }
fn main(): int64 { PrintLn(IntToStr(teile(84, 2))); return 0; }' "42|" 0

pruefe "Division durch 0 bricht ab" 'import std.io;
fn teile(a: int64, b: int64): int64 { return a / b; }
fn main(): int64 { PrintLn("vor"); PrintLn(IntToStr(teile(1, 0))); PrintLn("nach"); return 0; }' "vor|" 1

pruefe "assertBounds im Bereich" 'import std.io;
fn pruefe(i: int64, n: int64): int64 { assertBounds(i, n); return i; }
fn main(): int64 { PrintLn("a"); PrintLn(IntToStr(pruefe(2, 3))); return 0; }' "a|2|" 0

pruefe "assertBounds ausserhalb bricht ab" 'import std.io;
fn pruefe(i: int64, n: int64): int64 { assertBounds(i, n); return i; }
fn main(): int64 { PrintLn("a"); PrintLn(IntToStr(pruefe(5, 3))); return 0; }' "a|" 1

# Die Wirkung im Umfeld von make: ein offener Pipe-Deskriptor, dessen Leser
# schon zu ist. Vorher SIGPIPE (rc 141), wenn der verirrte write ihn traf.
printf '%s\n' 'import std.io;
import std.alloc;
fn main(): int64 { PrintLn("x"); var p: int64 := malloc(3); PrintLn("y"); return 0; }' > "$TMP/fd.lyx"
if ( cd "$ROOT" && timeout 240 "$LYXC" --std-path="$ROOT" --target=riscv "$TMP/fd.lyx" -o "$TMP/fd" ) >/dev/null 2>&1; then
  # malloc(3): align_to_8 rechnet (3+7)/8 — a0 traegt vor dem Sprung den
  # Divisor-Rest; fd 3 wird hier als geschlossene Pipe vorgehalten.
  ( exec 3> >(true); sleep 0.2; timeout 30 "$QEMU_RISCV64" "$TMP/fd" >"$TMP/fd.out" 2>/dev/null ); rc=$?
  if [ "$rc" = "0" ] && [ "$(tr '\n' '|' < "$TMP/fd.out")" = "x|y|" ]; then ok "mit offener Pipe als fd 3: rc 0, x|y|"
  else nok "mit offener Pipe als fd 3: rc=$rc [$(tr '\n' '|' < "$TMP/fd.out")]"; fi
else
  nok "fd-Probe uebersetzt nicht"
fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
