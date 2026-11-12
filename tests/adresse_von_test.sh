#!/usr/bin/env bash
# tests/adresse_von_test.sh — #2116: `@x` liefert die ADRESSE auf allen Zielen.
#
# Bis 1.2.14B:
#   - arm64/riscv kannten IRO_LOAD_LOCAL_ADDR (Opcode 63) nicht — `@v` auf ein
#     skalares Local brach laut ab, jeder Out-Parameter war unbaubar.
#   - `@g` auf eine Modulvariable: x86 lud 0 (Schreiben darueber -> SIGSEGV),
#     der IR-Weg gab einen UNBESCHRIEBENEN Temp zurueck — uebersetzt fehlerfrei,
#     Schreibzugriff an eine zufaellige Adresse.
#   - `@` auf etwas anderes als einen Namen: still 0 bzw. Zufallswert.
#
# Gemessen wird der WERT, den der Schreibzugriff ueber die Adresse hinterlaesst,
# auf x86_64, arm64, android-arm64 und riscv; dazu ein Rahmen mit 700 Slots
# (Slotadresse jenseits von simm9/zwoelf Bit) und die Gegenseite: `@f()` wird
# laut abgewiesen statt still uebersetzt.
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
    arm64|android-arm64) timeout 30 "$QEMU_ARM64" "$2" ;;
    riscv) timeout 30 "$QEMU_RISCV64" "$2" ;;
  esac
}

pruefe() {  # name, datei, soll-ausgabe
  local t
  for t in linux arm64 android-arm64 riscv; do
    rm -f "$TMP/p"
    if ! ( cd "$ROOT" && timeout 240 "$LYXC" --std-path="$ROOT" --target=$t "$2" -o "$TMP/p" ) >"$TMP/bl.log" 2>&1; then
      nok "$1 [$t]: uebersetzt nicht ($(grep -m1 -iE 'error' "$TMP/bl.log"))"; continue
    fi
    local aus rc
    aus="$(lauf $t "$TMP/p" 2>/dev/null | tr '\n' '|')"; rc=${PIPESTATUS[0]}
    if [ "$aus" = "$3" ] && [ "$rc" = "0" ]; then ok "$1 [$t]: [$aus]"
    else nok "$1 [$t]: [$aus] rc=$rc statt [$3]"; fi
  done
}

# Der Fall aus dem Issue, woertlich.
cat > "$TMP/issue.lyx" <<'EOF'
fn setv(p: int64) { poke64(p, 42); }
fn main(): int64 {
  var v: int64 := 0;
  setv(@v);
  PrintInt(v); Print("\n");
  return 0;
}
EOF
pruefe "Issue: setv(@v)" "$TMP/issue.lyx" "42|"

# Modulvariablen, Out-Parameter in einer Schleife neben vielen Locals,
# Adresse eines Parameters.
cat > "$TMP/mix.lyx" <<'EOF'
var g: int64 := 5;
var h: int64 := 7;
fn setv(p: int64, w: int64) { poke64(p, w); }
fn inc(p: int64) { poke64(p, peek64(p) + 1); }
fn viele(n: int64): int64 {
  var a0: int64 := 1; var a1: int64 := 2; var a2: int64 := 3; var a3: int64 := 4;
  var a4: int64 := 5; var a5: int64 := 6; var a6: int64 := 7; var a7: int64 := 8;
  var z: int64 := 0;
  var i: int64 := 0;
  while (i < n) { inc(@z); i := i + 1; }
  return z * 100 + a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7;
}
fn par(x: int64): int64 { setv(@x, x * 2); return x; }
fn main(): int64 {
  setv(@g, 42); setv(@h, 43);
  PrintInt(g); Print(" "); PrintInt(h); Print(" ");
  PrintInt(viele(10)); Print(" ");
  PrintInt(par(21)); Print("\n");
  return 0;
}
EOF
pruefe "Modulvariable, Schleife, Parameter" "$TMP/mix.lyx" "42 43 1036 42|"

# 700 Slots: die Adresse von v699 liegt weit jenseits von simm9 (arm64) bzw.
# zwoelf Bit (riscv).
python3 - "$TMP/gross.lyx" <<'EOF'
import sys
L = ['fn setv(p: int64) { poke64(p, 42); }', 'fn main(): int64 {']
for i in range(700): L.append('  var v%d: int64 := %d;' % (i, i))
L += ['  setv(@v699); setv(@v0);', '  PrintInt(v699 + v0 + v350); Print("\\n");', '  return 0;', '}']
open(sys.argv[1], 'w').write('\n'.join(L) + '\n')
EOF
pruefe "700 Slots, fernes @v699" "$TMP/gross.lyx" "434|"

# Gegenseite: `@` auf einen Aufruf hat keine Adresse — laut abweisen, auf
# beiden Codegen-Wegen (x86 direkt, arm64 ueber ir_lower).
cat > "$TMP/kein.lyx" <<'EOF'
fn f(): int64 { return 3; }
fn main(): int64 {
  var x: int64 := @f();
  PrintInt(x); return 0;
}
EOF
for t in linux arm64; do
  ( cd "$ROOT" && timeout 240 "$LYXC" --std-path="$ROOT" --target=$t "$TMP/kein.lyx" -o "$TMP/k" ) >"$TMP/k.log" 2>&1; rc=$?
  if [ "$rc" != "0" ] && grep -q "Adresse-von" "$TMP/k.log"; then ok "@f() [$t]: laut abgewiesen"
  else nok "@f() [$t]: rc=$rc, keine Meldung zur Adresse-von"; fi
done

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
