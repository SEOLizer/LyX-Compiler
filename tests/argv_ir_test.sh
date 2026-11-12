#!/usr/bin/env bash
# tests/argv_ir_test.sh — #2110: Programmargumente auf allen drei Zielen.
#
# GetArgC (ID 17), GetArgV (ID 18) und ArgvGet (ID 235) waren auf arm64 und
# riscv unuebersetzbar ("Builtin-ID 17 wird nicht behandelt") — jedes
# Programm, das seine Argumente liest. Jetzt: arm64 sichert argv am Eingang
# von main in x28, riscv im Startrumpf in s10; GetArgC zaehlt bis zum NULL.
#
# Gemessen werden die WERTE gegen x86: Anzahl, jedes Argument (auch eines mit
# Leerzeichen), ArgvGet im Bereich und ausserhalb (0), und GetArgC nach 20
# verschachtelten Aufrufen — x28/s10 muessen jeden Rahmen ueberleben.
# Nicht gemessen: der dynamische arm64-Weg ueber __libc_start_main (braucht
# eine aarch64-Sysroot fuer qemu); er uebergibt argv ebenfalls in x1 an main.
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

cat > "$TMP/a.lyx" <<'LYX'
import std.io;
fn tief(n: int64): int64 { if (n == 0) { return GetArgC(); } return tief(n - 1); }
fn main(): int64 {
  var n: int64 := GetArgC();
  PrintLn(IntToStr(n));
  var i: int64 := 1;
  while (i < n) { var a: pchar := GetArg(i); PrintLn(a); i := i + 1; }
  var v: int64 := GetArgV();
  var b: pchar := ArgvGet(v as pchar, 2);
  PrintLn(b);
  var z: int64 := ArgvGet(v as pchar, 7) as int64;
  PrintLn(IntToStr(z));
  PrintLn(IntToStr(tief(20)));
  return 0;
}
LYX
for ziel in x86_64 arm64 riscv; do
  pre=""
  case "$ziel" in arm64) pre="$QEMU_ARM64" ;; riscv) pre="$QEMU_RISCV64" ;; esac
  if ! ( cd "$ROOT" && timeout 240 "$LYXC" --std-path="$ROOT" --target="$ziel" "$TMP/a.lyx" -o "$TMP/a_$ziel" ) >"$TMP/bl.log" 2>&1; then
    nok "[$ziel] uebersetzt nicht ($(grep -m1 -iE 'error' "$TMP/bl.log"))"; continue
  fi
  if [ "$ziel" != "x86_64" ] && [ -z "$pre" ]; then nok "[$ziel] qemu fehlt — NICHT gemessen"; continue; fi
  ist="$( (timeout 30 $pre "$TMP/a_$ziel" eins "zwei drei" vier 2>&1) | tr '\n' '|')"
  soll="4|eins|zwei drei|vier|zwei drei|0|4|"
  if [ "$ist" = "$soll" ]; then ok "[$ziel] argc 4, Argumente, ArgvGet im/ausser Bereich, nach 20 Aufrufen = $soll"
  else nok "[$ziel] [$ist] statt [$soll]"; fi
  ist0="$( (timeout 30 $pre "$TMP/a_$ziel" 2>&1) | tr '\n' '|')"
  if [ "${ist0%%|*}" = "1" ]; then ok "[$ziel] ohne Argumente: argc 1"
  else nok "[$ziel] ohne Argumente: [$ist0]"; fi
done

# #2271: `main(argc, argv)` als Parameter. riscv setzte a0/a1 im Startrumpf
# nicht — argc kam als 0 an, der riscv-Selbstbau zeigte deshalb nur die Hilfe.
# GetArgC oben ging ueber s10 und war davon nicht betroffen.
cat > "$TMP/p.lyx" <<'LYX'
import std.io;
pub fn main(argc: int64, argv: pchar): int64 {
  PrintLn(IntToStr(argc));
  var i: int64 := 1;
  while (i < argc) { var a: pchar := ArgvGet(argv, i); PrintLn(a); i := i + 1; }
  return 0;
}
LYX
for ziel in x86_64 arm64 riscv; do
  pre=""
  case "$ziel" in arm64) pre="$QEMU_ARM64" ;; riscv) pre="$QEMU_RISCV64" ;; esac
  if ! ( cd "$ROOT" && timeout 240 "$LYXC" --std-path="$ROOT" --target="$ziel" "$TMP/p.lyx" -o "$TMP/p_$ziel" ) >"$TMP/bl.log" 2>&1; then
    nok "[$ziel] main(argc, argv) uebersetzt nicht ($(grep -m1 -iE 'error' "$TMP/bl.log"))"; continue
  fi
  if [ "$ziel" != "x86_64" ] && [ -z "$pre" ]; then nok "[$ziel] qemu fehlt — NICHT gemessen"; continue; fi
  ist="$( (timeout 30 $pre "$TMP/p_$ziel" eins "zwei drei" 2>&1) | tr '\n' '|')"
  soll="3|eins|zwei drei|"
  if [ "$ist" = "$soll" ]; then ok "[$ziel] main(argc, argv): $soll"
  else nok "[$ziel] main(argc, argv): [$ist] statt [$soll]"; fi
done

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
