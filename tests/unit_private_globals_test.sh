#!/usr/bin/env bash
# tests/unit_private_globals_test.sh — #2097, #2099, #2102: Modulvariablen und
# Konstanten zweier Units.
#
#   #2097  Zwei Units mit je einer PRIVATEN `var gX` teilten still denselben
#          Speicher (x86: cg_addGlobal gab fuer einen bekannten Namen den
#          vorhandenen Platz zurueck; IR: die Suche nahm den ersten Treffer).
#   #2099  Zwei private `con X`: welcher Wert galt, hing an der
#          Importreihenfolge des PROGRAMMS (x86: zuletzt eingetragen, IR:
#          zuerst eingetragen).
#   #2102  `pub con B_SIZE := A_SIZE;` aus einer Unit, die rp.a importiert:
#          importierte das Programm rp.a nicht selbst, war B_SIZE still -1.
#
# Jeder Fall in BEIDEN Importreihenfolgen — der Fehler hing genau daran.
# Private Funktionen derselben Art misst tests/unit_private_namen_test.sh.
set -uo pipefail
ulimit -c 0   # ein Absturz unter qemu legt sonst eine .core-Datei ins Repo
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
. "$(dirname "$0")/lib/qemu.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

ziele() {  # $1 Beschreibung, $2 Datei (in $TMP/m), $3 Soll mit |, $4 Ziele
  local was="$1" src="$2" erw="$3" zl="$4"
  for ziel in $zl; do
    local bin="$TMP/b_$ziel" pre=""
    case "$ziel" in arm64) pre="$QEMU_ARM64" ;; riscv) pre="$QEMU_RISCV64" ;; esac
    if ! ( cd "$TMP/m" && timeout 240 "$LYXC" --std-path="$ROOT" --target="$ziel" "$src" -o "$bin" ) >"$TMP/bl.log" 2>&1; then
      nok "$was [$ziel]: uebersetzt nicht ($(grep -m1 -iE '^lyxc:|error' "$TMP/bl.log"))"; continue
    fi
    if [ "$ziel" != "x86_64" ] && [ -z "$pre" ]; then nok "$was [$ziel]: qemu fehlt — NICHT gemessen"; continue; fi
    local ist; ist="$( (cd "$TMP/m" && timeout 60 $pre "$bin" 2>&1) | tr '\n' '|')"
    if [ "$ist" = "$erw" ]; then ok "$was [$ziel] = $erw"
    else nok "$was [$ziel]: [$ist] statt [$erw]"; fi
  done
}
ALLE="x86_64 arm64 riscv"
mkdir -p "$TMP/m/ua" "$TMP/m/u" "$TMP/m/rp"

echo "--- #2097: private var zweier Units ---"
cat > "$TMP/m/ua/one.lyx" <<'EOF'
unit ua.one;
var gX: int64 := 0;
pub fn OneSet(v: int64) { gX := v; }
pub fn OneGet(): int64 { return gX; }
EOF
cat > "$TMP/m/ua/two.lyx" <<'EOF'
unit ua.two;
var gX: int64 := 0;
pub fn TwoSet(v: int64) { gX := v; }
pub fn TwoGet(): int64 { return gX; }
EOF
for reihe in "one two" "two one"; do
  set -- $reihe
  cat > "$TMP/m/v_$1.lyx" <<EOF
import std.io;
import ua.$1;
import ua.$2;
var gX: int64 := 5;
fn main(): int64 {
  OneSet(111); TwoSet(222); gX := 333;
  PrintLn(IntToStr(OneGet())); PrintLn(IntToStr(TwoGet())); PrintLn(IntToStr(gX));
  return 0;
}
EOF
  ziele "Import ua.$1 vor ua.$2: one 111, two 222, eigenes gX 333" "v_$1.lyx" "111|222|333|" "$ALLE"
done

echo
echo "--- #2099: private con zweier Units ---"
cat > "$TMP/m/u/ua.lyx" <<'EOF'
unit u.ua;
con X: int64 := 111;
pub fn WertA(): int64 { return X; }
EOF
cat > "$TMP/m/u/ub.lyx" <<'EOF'
unit u.ub;
import u.ua;
con X: int64 := 222;
pub fn WertB(): int64 { return X; }
EOF
for reihe in "ub ua" "ua ub"; do
  set -- $reihe
  cat > "$TMP/m/c_$1.lyx" <<EOF
import std.io;
import u.$1;
import u.$2;
fn main(): int64 { PrintLn(IntToStr(WertA())); PrintLn(IntToStr(WertB())); return 0; }
EOF
  ziele "Import u.$1 vor u.$2: WertA 111, WertB 222" "c_$1.lyx" "111|222|" "$ALLE"
done

echo
echo "--- #2102: con aus einer Unit, die das Programm nicht selbst importiert ---"
cat > "$TMP/m/rp/a.lyx" <<'EOF'
unit rp.a;
pub con A_SIZE: int64 := 24 + 16 * 32;
EOF
cat > "$TMP/m/rp/b.lyx" <<'EOF'
unit rp.b;
import rp.a;
pub con B_SIZE: int64 := A_SIZE;
pub fn BSize(): int64 { return B_SIZE; }
EOF
cat > "$TMP/m/r.lyx" <<'EOF'
import std.io;
import rp.b;
fn main(): int64 { PrintLn(IntToStr(B_SIZE)); PrintLn(IntToStr(BSize())); return 0; }
EOF
# #2107: seit 1.2.14B auch auf dem IR-Weg (vorher dort mit #1798 abgewiesen).
ziele "B_SIZE = A_SIZE = 536, auch in rp.b" "r.lyx" "536|536|" "$ALLE"

# Kette ueber zwei Units (rp.c nennt B_SIZE, das A_SIZE nennt) und eine
# Konstante des HAUPTMODULS aus einer importierten.
cat > "$TMP/m/rp/c.lyx" <<'EOF'
unit rp.c;
import rp.b;
pub con C_SIZE: int64 := B_SIZE + 4;
pub fn CSize(): int64 { return C_SIZE; }
EOF
cat > "$TMP/m/k.lyx" <<'EOF'
import std.io;
import rp.c;
import rp.a;
con M_SIZE: int64 := A_SIZE * 2 + 1;
fn main(): int64 { PrintLn(IntToStr(CSize())); PrintLn(IntToStr(C_SIZE)); PrintLn(IntToStr(M_SIZE)); return 0; }
EOF
ziele "Kette C_SIZE = B_SIZE + 4 = 540, M_SIZE im Hauptmodul = 1073" "k.lyx" "540|540|1073|" "$ALLE"

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
