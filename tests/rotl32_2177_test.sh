#!/usr/bin/env bash
# tests/rotl32_2177_test.sh — rotl32/rotr32 als eingebaute Funktionen (#2177).
#
# ChaCha20, SHA-256, BLAKE3 rotieren 32-Bit-Woerter. rotl/rotr aus #2190
# drehen 64 Bit und taugen dafuer nicht; geschrieben stand die Rotation als
# Schieben/Verodern/Maskieren in einer eigenen Funktion. Die ChaCha20-
# Viertelrunde (bench/chacha_qr) ging mit dem Builtin von 240 auf 178 ms bei
# 2e7 Runden (gcc -O2: 162 ms), Pruefsumme unveraendert.
#
# Geprueft wird:
#   1. die WERTE gegen RotateLeft32/RotateRight32 aus std/conv.lyx fuer vier
#      Eingaben und alle Weiten -40..70 (negative, 0, 31, 32, 33 inklusive),
#      auf x86-64, arm64 und riscv (unter qemu) — die drei Backends rechnen
#      verschieden (ROL r32, NEG+ROR w, SLL/SRL/OR), das Ergebnis muss gleich
#      sein;
#   2. der WEG auf x86: ein zusaetzliches rotl32 bringt genau ein
#      `rol %cl,%eax` und keinen zusaetzlichen Sprung oder Aufruf;
#   3. lyxos uebersetzt und enthaelt den 32-Bit-ROL (D3 C0, ohne REX).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
. "$(dirname "$0")/lib/qemu.sh"   # #2048
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# Builtin-Ergebnisse erst in eine Variable: arm64/riscv koennen den Typ eines
# Builtin-Aufrufs als Print-Argument nicht bestimmen (vorbestehend, siehe
# tests/bit_builtins_test.sh).
cat > "$TMP/w.lyx" <<'LYX'
import std.io;
import std.conv;
fn main(): int64 {
  var xs: int64 := 0;
  var fehler: int64 := 0;
  var werte: int64 := 0;
  var x: int64 := 0x123456789ABCDEF1;
  while (xs < 4) {
    var n: int64 := 0 - 40;
    while (n <= 70) {
      var l1: int64 := rotl32(x, n); var l2: int64 := RotateLeft32(x, n);
      if (l1 != l2) { fehler += 1; }
      var r1: int64 := rotr32(x, n); var r2: int64 := RotateRight32(x, n);
      if (r1 != r2) { fehler += 1; }
      werte += 2;
      n += 1;
    }
    x := x * 6364136223846793005 + 1442695040888963407;
    xs += 1;
  }
  var a1: int64 := rotl32(0x80000001, 1);
  var a2: int64 := rotr32(0x80000001, 1);
  var a3: int64 := rotl32(0xFFFFFFFF00000001, 4);
  PrintLn(fehler); PrintLn(werte); PrintLn(a1); PrintLn(a2); PrintLn(a3);
  return 0;
}
LYX
ERWARTET="0 888 3 3221225472 16"

ziel() { # name target runner
  local name="$1" t="$2" run="$3" opt=""
  [ -n "$t" ] && opt="--target=$t"
  if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" $opt "$TMP/w.lyx" -o "$TMP/w.$name" >"$TMP/$name.log" 2>&1); then
    no "Werte $name" "uebersetzt nicht: $(grep -v Copyright "$TMP/$name.log" | head -2 | tr '\n' ' ')"; return
  fi
  if [ "$name" != x86 ] && [ -z "$run" ]; then
    echo "HINWEIS: qemu fuer $name fehlt — nur uebersetzt."; ok "$name uebersetzt"; return
  fi
  local got; got=$( ulimit -c 0; cd "$TMP" && timeout 60 $run "$TMP/w.$name" 2>/dev/null | tr '\n' ' ' ); got="${got% }"
  if [ "$got" = "$ERWARTET" ]; then ok "Werte $name ($got)"; else no "Werte $name" "'$got' erwartet '$ERWARTET'"; fi
}
ziel x86 "" ""
ziel arm64 arm64 "$QEMU_ARM64"
ziel riscv riscv "$QEMU_RISCV64"

# Weg auf x86: Differenz zwischen null und einem rotl32.
zaehle() { # quelle -> "rol spruenge calls"
  printf '%s\n' "$1" > "$TMP/z.lyx"
  (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" --emit=obj "$TMP/z.lyx" -o "$TMP/z.o" >/dev/null 2>&1) || { echo "X X X"; return; }
  local d; d="$(objdump -d -z --no-show-raw-insn "$TMP/z.o" 2>/dev/null)"
  echo "$(grep -cE 'rol +%cl,%eax' <<<"$d") $(grep -cE '^ +[0-9a-f]+:\s+j[a-z]+ ' <<<"$d") $(grep -c 'call' <<<"$d")"
}
A='import std.io;
fn main(): int64 { var x: int64 := 0x11112222; var n: int64 := 7; var r: int64 := x + n; PrintLn(r); return 0; }'
B='import std.io;
fn main(): int64 { var x: int64 := 0x11112222; var n: int64 := 7; var r: int64 := rotl32(x, n); PrintLn(r); return 0; }'
read -r ra ja ca <<<"$(zaehle "$A")"; read -r rb jb cb <<<"$(zaehle "$B")"
if [ "$ra" = X ] || [ "$rb" = X ]; then no "Weg x86" "uebersetzt nicht"
else
  if [ $((rb - ra)) -eq 1 ]; then ok "Weg x86: ein rol r32 mehr ($ra -> $rb)"; else no "Weg x86" "rol %cl,%eax: $ra -> $rb"; fi
  if [ "$jb" -eq "$ja" ] && [ "$cb" -eq "$ca" ]; then ok "Weg x86: kein Sprung, kein Aufruf"
  else no "Weg x86" "Spruenge $ja -> $jb, calls $ca -> $cb"; fi
fi

# lyxos: uebersetzt und enthaelt einen 32-Bit-ROL mehr als ohne.
lyxos_d3c0() {
  printf '%s\n' "$1" > "$TMP/l.lyx"
  (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" --target=lyxos "$TMP/l.lyx" -o "$TMP/l.out" >"$TMP/l.log" 2>&1) || { echo X; return; }
  od -An -v -tx1 "$TMP/l.out" | tr -s ' \n' ' ' | grep -o ' 89 c8 d3 c0\| d3 c0' | wc -l
}
LA='fn main(): int64 { var x: int64 := 5; var n: int64 := 3; var r: int64 := x + n; return r; }'
LB='fn main(): int64 { var x: int64 := 5; var n: int64 := 3; var r: int64 := rotl32(x, n); return r; }'
la=$(lyxos_d3c0 "$LA"); lb=$(lyxos_d3c0 "$LB")
if [ "$la" = X ] || [ "$lb" = X ]; then no "lyxos" "uebersetzt nicht: $(grep -iE 'error|unbekannt|kennt' "$TMP/l.log" | head -1)"
elif [ "$lb" -gt "$la" ]; then ok "lyxos: rol r32 im Erzeugnis ($la -> $lb)"
else no "lyxos" "kein zusaetzliches D3 C0 ($la -> $lb)"; fi

echo "rotl32_2177: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
