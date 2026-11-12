#!/usr/bin/env bash
# tests/ir_viele_argumente_test.sh — #2132: Aufrufe mit mehr als acht
# Argumenten und indirekte Aufrufe mit einem Aufruf als spaetem Argument auf
# den IR-Zielen (arm64, riscv, lyxos).
#
# Bis 1.2.15A:
#   (1) arm64/riscv verwarfen bei direkten und indirekten Aufrufen und im
#       Prolog still alles ab dem neunten Argument (`while ai < 8`); der
#       Aufgerufene las in seinem Slot fremden Stapel. Dazu reservierte jede
#       Aufrufstelle fest acht Slots als Argumentblock — ein neuntes Argument
#       landete auf einem Temp, das die Auswertung eines spaeteren Arguments
#       schon wieder belegte. Ein Lambda mit mehr als acht Parametern samt
#       Umgebung wurde (laut) abgewiesen.
#   (2) indirekte Aufrufe (lokaler/globaler Funktionszeiger, Funktionszeiger-
#       Feld, Methodenzeiger) legten jedes Argument sofort in Slot i des
#       Kratzstreifens; ein Aufruf in einem spaeteren Argument ueberschrieb die
#       frueheren: `f2(5, f2(6, 7))` lieferte 1207 statt 1107.
#
# Gemessen wird der WERT: jede Summe ist positionsgewichtet (r := r*31 + p),
# ein fehlendes, vertauschtes oder ueberschriebenes Argument aendert sie. Die
# Erwartungen sind unabhaengig nachgerechnet (Python, int64-Ueberlauf
# eingerechnet) und gelten fuer x86_64 (direkter Codegen), arm64 und riscv
# (qemu) gleichermassen. lyxos laeuft ueber den lokalen LBF-Lader — nur
# Ganzzahlfaelle ohne Allokation (LyxOS liefert Syscall-Ergebnisse in rdx).
#
# Der extern-Aufruf einer C-Funktion mit mehr als acht Argumenten ist hier
# nicht ausfuehrbar (kein aarch64-Sysroot fuer den dynamischen Lader unter
# qemu); er wird am ERZEUGNIS geprueft: die Stapelargumente stehen per STR an
# [sp] und [sp,#8], und unmittelbar nach dem BLR wird der Platz freigegeben.
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

pruefe() {  # name, datei, soll-ausgabe
  local t
  for t in linux arm64 riscv; do
    rm -f "$TMP/p"
    if ! ( cd "$ROOT" && timeout 240 "$LYXC" --std-path="$ROOT" --target=$t "$2" -o "$TMP/p" ) >"$TMP/bl.log" 2>&1; then
      nok "$1 [$t]: uebersetzt nicht ($(grep -m1 -iE 'error|lyxc:' "$TMP/bl.log"))"; continue
    fi
    local aus rc
    aus="$(lauf $t "$TMP/p" 2>/dev/null | tr '\n' '|')"; rc=${PIPESTATUS[0]}
    if [ "$aus" = "$3" ] && [ "$rc" = "0" ]; then ok "$1 [$t]: [$aus]"
    else nok "$1 [$t]: [$aus] rc=$rc statt [$3]"; fi
  done
}

# Gemeinsame Funktionen: s8 (Grenzfall), s9, s12, s16, gemischt int/f64, zwoelf f64.
cat > "$TMP/kopf.lyx" <<'EOF'
type F9 = fn(int64, int64, int64, int64, int64, int64, int64, int64, int64): int64;
type F12 = fn(int64, int64, int64, int64, int64, int64, int64, int64, int64, int64, int64, int64): int64;
type F2 = fn(int64, int64): int64;
type FM = fn(f64, int64, f64, f64, int64, f64, f64, f64, f64, int64, f64): int64;
fn s8(a: int64, b: int64, c: int64, d: int64, e: int64, f: int64, g: int64, h: int64): int64 {
  var r: int64 := a;
  r := r * 31 + b; r := r * 31 + c; r := r * 31 + d; r := r * 31 + e;
  r := r * 31 + f; r := r * 31 + g; r := r * 31 + h;
  return r;
}
fn s9(a: int64, b: int64, c: int64, d: int64, e: int64, f: int64, g: int64, h: int64, i: int64): int64 {
  var r: int64 := a;
  r := r * 31 + b; r := r * 31 + c; r := r * 31 + d; r := r * 31 + e;
  r := r * 31 + f; r := r * 31 + g; r := r * 31 + h; r := r * 31 + i;
  return r;
}
fn s12(a: int64, b: int64, c: int64, d: int64, e: int64, f: int64, g: int64, h: int64,
       i: int64, j: int64, k: int64, l: int64): int64 {
  var r: int64 := a;
  r := r * 31 + b; r := r * 31 + c; r := r * 31 + d; r := r * 31 + e;
  r := r * 31 + f; r := r * 31 + g; r := r * 31 + h; r := r * 31 + i;
  r := r * 31 + j; r := r * 31 + k; r := r * 31 + l;
  return r;
}
fn s16(a: int64, b: int64, c: int64, d: int64, e: int64, f: int64, g: int64, h: int64,
       i: int64, j: int64, k: int64, l: int64, m: int64, n: int64, o: int64, p: int64): int64 {
  var r: int64 := a;
  r := r * 31 + b; r := r * 31 + c; r := r * 31 + d; r := r * 31 + e;
  r := r * 31 + f; r := r * 31 + g; r := r * 31 + h; r := r * 31 + i;
  r := r * 31 + j; r := r * 31 + k; r := r * 31 + l; r := r * 31 + m;
  r := r * 31 + n; r := r * 31 + o; r := r * 31 + p;
  return r % 1000003;
}
fn mix(a: f64, b: int64, c: f64, d: f64, e: int64, f: f64, g: f64, h: f64, i: f64, j: int64, k: f64): int64 {
  var x: f64 := a * 1.0 + c * 2.0 + d * 4.0 + f * 8.0 + g * 16.0 + h * 32.0 + i * 64.0 + k * 128.0;
  return (x * 4.0) as int64 * 1000 + b * 100 + e * 10 + j;
}
fn f12(a: f64, b: f64, c: f64, d: f64, e: f64, f: f64, g: f64, h: f64, i: f64, j: f64, k: f64, l: f64): int64 {
  var r: f64 := a;
  r := r * 3.0 + b; r := r * 3.0 + c; r := r * 3.0 + d; r := r * 3.0 + e;
  r := r * 3.0 + f; r := r * 3.0 + g; r := r * 3.0 + h; r := r * 3.0 + i;
  r := r * 3.0 + j; r := r * 3.0 + k; r := r * 3.0 + l;
  return (r * 2.0) as int64;
}
fn add2(a: int64, b: int64): int64 { return a * 100 + b; }
EOF

echo "--- (1) direkte Aufrufe: 8 (Grenze), 9, 12, 16, gemischt int/f64, zwoelf f64, verschachtelt ---"
{ cat "$TMP/kopf.lyx"; cat <<'EOF'
fn main(): int64 {
  PrintInt(s8(1, 2, 3, 4, 5, 6, 7, 8)); PrintLn("");
  PrintInt(s9(1, 2, 3, 4, 5, 6, 7, 8, 9)); PrintLn("");
  PrintInt(s12(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12)); PrintLn("");
  PrintInt(s16(16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1)); PrintLn("");
  PrintInt(mix(0.25, 1, 0.5, 0.75, 2, 1.25, 1.5, 1.75, 2.0, 3, 2.25)); PrintLn("");
  PrintInt(f12(1.0, 2.0, 1.5, 0.5, 2.5, 1.0, 0.25, 3.0, 1.0, 0.5, 2.0, 1.5)); PrintLn("");
  PrintInt(s9(1, 2, 3, 4, 5, 6, 7, 8, s9(9, 8, 7, 6, 5, 4, 3, 2, 1) % 1000)); PrintLn("");
  PrintInt(s12(1, 2, 3, 4, 5, 6, 7, 8, 9, s9(1, 1, 1, 1, 1, 1, 1, 1, 1) % 97, 11, add2(3, 4))); PrintLn("");
  return 0;
}
EOF
} > "$TMP/direkt.lyx"
pruefe "direkt" "$TMP/direkt.lyx" "29377357956|910698096645|27130606997161158|85939|2041123|669178|910698096881|27130606997172982|"

echo "--- (1)+(2) Funktionszeiger: lokal, global; 2, 9, 11 (f64), 12, 16 Argumente, verschachtelt ---"
{ cat "$TMP/kopf.lyx"; cat <<'EOF'
type F16 = fn(int64, int64, int64, int64, int64, int64, int64, int64,
              int64, int64, int64, int64, int64, int64, int64, int64): int64;
var gF: F9;
var gF2: F2;
fn main(): int64 {
  var lf: F9 := s9;
  PrintInt(lf(9, 8, 7, 6, 5, 4, 3, 2, 1)); PrintLn("");
  PrintInt(lf(1, 2, 3, 4, 5, 6, 7, 8, lf(1, 1, 1, 1, 1, 1, 1, 1, 2) % 100)); PrintLn("");
  var lf2: F2 := add2;
  PrintInt(lf2(5, lf2(6, 7))); PrintLn("");
  var l12: F12 := s12;
  PrintInt(l12(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12)); PrintLn("");
  var l16: F16 := s16;
  PrintInt(l16(16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1)); PrintLn("");
  var lm: FM := mix;
  PrintInt(lm(0.25, 1, 0.5, 0.75, 2, 1.25, 1.5, 1.75, 2.0, 3, 2.25)); PrintLn("");
  gF := s9;
  PrintInt(gF(2, 3, 4, 5, 6, 7, 8, 9, 10)); PrintLn("");
  gF2 := add2;
  PrintInt(gF2(8, gF2(1, 2))); PrintLn("");
  return 0;
}
EOF
} > "$TMP/zeiger.lyx"
pruefe "Funktionszeiger" "$TMP/zeiger.lyx" "7902509290245|910698096726|1107|27130606997161158|85939|2041123|1792018835334|902|"

echo "--- (1)+(2) Funktionszeiger-Feld, Methode mit 10 Argumenten, Methodenzeiger (self gebunden) ---"
{ cat "$TMP/kopf.lyx"; cat <<'EOF'
type K = class {
  basis: int64;
  cb: F9;
  fn m10(a: int64, b: int64, c: int64, d: int64, e: int64, f: int64, g: int64, h: int64, i: int64, j: int64): int64 {
    return self.basis + s9(a, b, c, d, e, f, g, h, i) * 7 + j;
  }
};
type TM = method(int64, int64, int64, int64, int64, int64, int64, int64, int64): int64;
type H = class {
  tag: int64;
  fn Handle(a: int64, b: int64, c: int64, d: int64, e: int64, f: int64, g: int64, h: int64, i: int64): int64 {
    return self.tag * 1000000 + s9(a, b, c, d, e, f, g, h, i) % 1000000;
  }
};
type Knopf = class { klick: TM; };
fn main(): int64 {
  var k: K := new K();
  k.basis := 5;
  k.cb := s9;
  PrintInt(k.cb(3, 1, 4, 1, 5, 9, 2, 6, 5)); PrintLn("");
  PrintInt(k.cb(3, 1, 4, 1, 5, 9, 2, 6, k.cb(1, 2, 1, 2, 1, 2, 1, 2, 1) % 50)); PrintLn("");
  PrintInt(k.m10(1, 2, 3, 4, 5, 6, 7, 8, 9, 10)); PrintLn("");
  PrintInt(k.m10(1, 2, 3, 4, 5, 6, 7, 8, 9, k.m10(0, 0, 0, 0, 0, 0, 0, 0, 1, 2))); PrintLn("");
  var hh: H := new H();
  hh.tag := 4;
  var kn: Knopf := new Knopf();
  kn.klick := hh.Handle;
  PrintInt(kn.klick(1, 2, 3, 4, 5, 6, 7, 8, 9)); PrintLn("");
  PrintInt(kn.klick(1, 2, 3, 4, 5, 6, 7, 8, kn.klick(0, 0, 0, 0, 0, 0, 0, 0, 3) % 10)); PrintLn("");
  return 0;
}
EOF
} > "$TMP/objekt.lyx"
pruefe "Feld/Methode/Methodenzeiger" "$TMP/objekt.lyx" "2589769258146|2589769258164|6374886676530|6374886676534|4096645|4096639|"

echo "--- (1) Closure mit Erfassung: neun Parameter + Umgebung, verschachtelt ---"
{ cat "$TMP/kopf.lyx"; cat <<'EOF'
fn main(): int64 {
  var z: int64 := 1000;
  var cl := fn(a: int64, b: int64, c: int64, d: int64, e: int64, f: int64, g: int64, h: int64, i: int64): int64 {
    return z + s9(a, b, c, d, e, f, g, h, i) % 1000;
  };
  PrintInt(cl(1, 2, 3, 4, 5, 6, 7, 8, 9)); PrintLn("");
  PrintInt(cl(1, 2, 3, 4, 5, 6, 7, 8, cl(0, 0, 0, 0, 0, 0, 0, 0, 5) % 10)); PrintLn("");
  var c2 := fn(a: int64, b: int64): int64 { return z + a * 10 + b; };
  PrintInt(c2(3, c2(1, 2) % 100)); PrintLn("");
  return 0;
}
EOF
} > "$TMP/closure.lyx"
pruefe "Closure" "$TMP/closure.lyx" "1645|1641|1042|"

echo "--- lyxos (lokaler LBF-Lader, nur Ganzzahlen): direkt und ueber Zeiger ---"
lyxos() {  # name, main-rumpf, erwarteter Rueckgabewert
  { cat "$TMP/kopf.lyx"; printf 'var gF2: F2;\nfn main(): int64 { %s }\n' "$2"; } > "$TMP/l.lyx"
  if ! ( cd "$ROOT" && LYX_STD_PATH="$ROOT/std" timeout 200 "$LYXC" --target=lyxos "$TMP/l.lyx" -o "$TMP/l.lyxnative" ) >"$TMP/l.log" 2>&1; then
    nok "lyxos/$1: uebersetzt nicht: $(grep -im1 error "$TMP/l.log")"; return
  fi
  printf 'import src.tools.lbf.loader;\nfn main(): int64 { lbf_run("%s/l.lyxnative"c); return 111; }' "$TMP" > "$TMP/r.lyx"
  ( cd "$ROOT" && LYX_STD_PATH="$ROOT/std" timeout 200 "$LYXC" "$TMP/r.lyx" -o "$TMP/r" ) >/dev/null 2>&1
  timeout 10 "$TMP/r" >/dev/null 2>&1; local rc=$?
  if [ "$rc" -eq "$3" ]; then ok "lyxos/$1 (=$rc)"; else nok "lyxos/$1: exit=$rc erwartet $3"; fi
}
lyxos "s9 direkt"            'return s9(1, 2, 3, 4, 5, 6, 7, 8, 9) % 251;' 126
lyxos "s12 direkt"           'return s12(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12) % 251;' 135
lyxos "s16 direkt"           'return s16(16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1) % 251;' 97
lyxos "F9 lokal verschachtelt" 'var lf: F9 := s9; return lf(1, 2, 3, 4, 5, 6, 7, 8, lf(1, 1, 1, 1, 1, 1, 1, 1, 2) % 100) % 251;' 207
lyxos "F2 lokal verschachtelt" 'var f2: F2 := add2; return f2(5, f2(6, 7)) % 251;' 103
lyxos "F2 global verschachtelt" 'gF2 := add2; return gF2(8, gF2(1, 2)) % 251;' 149

echo "--- extern-Aufruf mit zehn Argumenten (arm64, am Erzeugnis) ---"
cat > "$TMP/ext.lyx" <<'EOF'
@capabilities([system.exit])
extern fn zehn(a: int64, b: int64, c: int64, d: int64, e: int64, f: int64, g: int64, h: int64, i: int64, j: int64): int64 link "libzehn.so";
fn main(): int64 { return zehn(1, 2, 3, 4, 5, 6, 7, 8, 9, 10); }
EOF
if ( cd "$ROOT" && timeout 240 "$LYXC" --std-path="$ROOT" --target=arm64 "$TMP/ext.lyx" -o "$TMP/ext" ) >"$TMP/ext.log" 2>&1; then
  # SUB sp,sp,#16 / STR x9,[sp] / STR x9,[sp,#8] vor dem BLR x9, ADD sp,sp,#16
  # unmittelbar danach. Die Wortfolge ist nur dann da, wenn das neunte und
  # zehnte Argument auf den Stapel gehen.
  if python3 - "$TMP/ext" <<'EOF'
import struct, sys
b = open(sys.argv[1], 'rb').read()
w = [struct.unpack_from('<I', b, i)[0] for i in range(0, len(b) - 3, 4)]
def finde(x, ab=0):
    for i in range(ab, len(w)):
        if w[i] == x: return i
    return -1
for i in range(len(w)):
    if w[i] == 0xD10043FF:                      # SUB sp, sp, #16
        a = finde(0xF90003E9, i); b2 = finde(0xF90007E9, i); c = finde(0xD63F0120, i)
        if 0 <= a < b2 < c and c - i < 40 and w[c + 1] == 0x910043FF:
            sys.exit(0)
sys.exit(1)
EOF
  then ok "extern zehn(...) [arm64]: Argumente 9 und 10 per STR an [sp]/[sp,#8], ADD sp nach dem BLR"
  else nok "extern zehn(...) [arm64]: keine Stapelargumente im Erzeugnis — das neunte und zehnte gingen verloren"; fi
else
  nok "extern zehn(...) [arm64]: uebersetzt nicht ($(grep -m1 -iE 'error|lyxc:' "$TMP/ext.log"))"
fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
