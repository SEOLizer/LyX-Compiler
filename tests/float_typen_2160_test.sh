#!/usr/bin/env bash
# tests/float_typen_2160_test.sh — #2160, #2161: f32 und Typaliasse auf Gleitkomma.
#
# Bis 1.2.17A:
#   #2161 x86: `type Meter = f64` galt als Ganzzahl (cg_isFloatTypeName kannte
#       keinen Alias) — Literal und Arithmetik liefen auf dem IEEE-Bitmuster,
#       eine .so-Exportfunktion mit Meter-Parameter bekam das Argument aus rdi.
#       Der IR-Weg rechnete nur richtig, solange ein f64-Literal im Ausdruck
#       stand (`m * 2` ging schief).
#   #2160 IR-Weg (arm64/riscv): `x as f64` und `x as int64` mit `x: f32`
#       nahmen das Bitmuster als Ganzzahl; eine Ganzzahl in ein
#       Gleitkommaziel (`var x: f64 := 3`, `x := 4`, `p.v := 2`, `return 2500`)
#       lag als Bitmuster im Slot. x86 wandelte nur die Deklaration, nicht die
#       Zuweisung.
#   f32-Felder (alle Ziele, auch x86): das Feld hat vier Byte, im Register
#       liegt ein double — geschrieben wurden dessen untere vier Byte
#       (0.25 -> 0). Jetzt cvtsd2ss/cvtss2sd bzw. IRO_F64_ZU_F32/F32_ZU_F64.
#
# Gemessen werden WERTE auf x86_64, arm64 und riscv; sie muessen gleich sein.
# Bei den f32-Feldern zusaetzlich die Nachbarn (int32 davor und dahinter) und
# die Groesse. Fuer lyxos (laeuft lokal nicht) die Wandelbefehle am Erzeugnis,
# fuer die .so-Huelle auf x86 der Aufruf ueber ctypes.
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

lauf() {
  case "$1" in
    linux) ( cd "$TMP" && timeout 30 "$2" ) ;;
    arm64) ( cd "$TMP" && timeout 30 "$QEMU_ARM64" "$2" ) ;;
    riscv64) ( cd "$TMP" && timeout 30 "$QEMU_RISCV64" "$2" ) ;;
  esac
}
baue() {  # ziel, datei, ausgabe [verzeichnis] [optionen]
  local t="$1" f="$2" o="$3" d="${4:-$ROOT}"; shift 4 2>/dev/null || shift 3
  ( cd "$d" && timeout 240 "$LYXC" --std-path="$ROOT" --target=$t "$@" "$f" -o "$o" ) >"$o.log" 2>&1
}
pruefe() {  # name datei soll [verzeichnis]
  local t
  for t in linux arm64 riscv64; do
    rm -f "$TMP/p"
    if ! baue $t "$2" "$TMP/p" "${4:-$ROOT}"; then
      nok "$1 [$t]: uebersetzt nicht ($(grep -m1 -iE 'error|fehler' "$TMP/p.log"))"; continue
    fi
    local aus rc
    aus="$(lauf $t "$TMP/p" 2>&1 | tr '\n' '|')"; rc=${PIPESTATUS[0]}
    if [ "$aus" = "$3" ] && [ "$rc" = 0 ]; then ok "$1 [$t]: [$aus]"
    else nok "$1 [$t]: [$aus] rc=$rc statt [$3]"; fi
  done
}

# --- #2161: Alias auf f64 (Repro woertlich) --------------------------------------
cat > "$TMP/alias.lyx" <<'EOF'
type Meter = f64;
fn f(y: Meter): f64 { return y + 1.0; }
fn main(): int64 { var m: Meter := 2.5; var r: f64 := f(m); PrintInt((r * 10.0) as int64); Print(" "); var q: f64 := m * 2.0; PrintInt((q*10.0) as int64); Print("\n"); return 0; }
EOF
pruefe "Alias auf f64 (Repro #2161)" "$TMP/alias.lyx" "35 50|"

# Alias auf Alias, Rueckgabetyp, Feld, Modulvariable, importierter Alias,
# Ganzzahl in ein Alias-Ziel, Arithmetik ohne f64-Literal.
mkdir -p "$TMP/imp/lib"
cat > "$TMP/imp/lib/masse.lyx" <<'EOF'
pub type Kilo = f64;
pub type Last = Kilo;
pub fn Doppelt(k: Kilo): Kilo { return k * 2.0; }
EOF
cat > "$TMP/imp/haupt.lyx" <<'EOF'
import lib.masse;
type Meter = f64;
type Strecke = Meter;
type P = struct { a: Meter; n: int64; };
var gm: Meter := 1.25;
fn halb(s: Strecke): Strecke { return s / 2.0; }
fn main(): int64 {
  var s: Strecke := 7.0;
  var h: Strecke := halb(s);
  PrintInt((h * 10.0) as int64); Print(" ");
  var p: P; p.a := 3.5; p.n := 2;
  var t: f64 := p.a * 2.0;
  PrintInt((t * 10.0) as int64); Print(" ");
  PrintInt((gm * 100.0) as int64); Print(" ");
  var k: Last := 1.5;
  var d: Kilo := Doppelt(k);
  PrintInt((d * 10.0) as int64); Print(" ");
  var mix: Meter := 3;
  mix := mix * 2;
  PrintInt((mix * 10.0) as int64); Print(" ");
  if (s > 6.5) { Print("t"); } else { Print("f"); }
  Print("\n");
  return 0;
}
EOF
pruefe "Alias: Kette, Rueckgabe, Feld, global, importiert" "haupt.lyx" "35 70 125 30 60 t|" "$TMP/imp"

# --- #2160: f32 auf dem IR-Weg (Repro woertlich) ---------------------------------
cat > "$TMP/f32.lyx" <<'EOF'
fn mischen(n: int64, x: f32, y: f64, m: int64): f64 { return (x as f64) + y + ((n * 10 + m) as f64); }
fn main(): int64 { var x: f32 := 0.5; var r: f64 := mischen(4, x, 10.25, 2); PrintInt((r * 100.0) as int64); Print(" "); var r2: f64 := (x as f64) + 1.0; PrintInt((r2*100.0) as int64); Print("\n"); return 0; }
EOF
pruefe "f32-Cast (Repro #2160)" "$TMP/f32.lyx" "5275 150|"

cat > "$TMP/f32b.lyx" <<'EOF'
fn main(): int64 {
  var x: f32 := 0.5;
  var a: f64 := x * 4.0;
  PrintInt((a * 10.0) as int64); Print(" ");
  var b: f64 := x as f64;
  PrintInt((b * 10.0) as int64); Print(" ");
  var c: int64 := x as int64;
  PrintInt(c); Print(" ");
  var y: f32 := 2.75;
  PrintInt(y as int64); Print("\n");
  return 0;
}
EOF
pruefe "f32: as f64, as int64" "$TMP/f32b.lyx" "20 5 0 2|"

# --- #2160: Ganzzahl in ein Gleitkommaziel ----------------------------------------
cat > "$TMP/ganz.lyx" <<'EOF'
type Meter = f64;
type P = struct { v: f64; n: int64; };
var gf: f64 := 0.0;
fn h(): f64 { return 2500; }
fn hm(): Meter { return 12 * 2; }
fn main(): int64 {
  var a: f64 := 3;
  var b: f64 := 2.0;
  b := 4;
  var m: Meter := 3;
  PrintInt((a * 10.0) as int64); Print(" "); PrintInt((b * 10.0) as int64); Print(" ");
  PrintInt((m * 10.0) as int64); Print("|");
  var p: P; p.v := 2; p.n := 7;
  PrintInt((p.v * 10.0) as int64); Print(" "); PrintInt(p.n); Print("|");
  gf := 6;
  PrintInt((gf * 10.0) as int64); Print(" ");
  PrintInt((h() * 1.0) as int64); Print(" "); PrintInt((hm() * 1.0) as int64); Print("\n");
  return 0;
}
EOF
pruefe "Ganzzahl in Gleitkommaziel" "$TMP/ganz.lyx" "30 40 30|20 7|60 2500 24|"

# Gegenseite: eine Gleitkommaquelle, die die Typbestimmung NICHT kennt, darf
# nicht gewandelt werden — der erste Anlauf machte aus m(4.0) (Lambda ohne
# Typangabe), fFloor und peek32f ein zweites Mal Gleitkomma (Bitmuster als
# Ganzzahl gelesen).
cat > "$TMP/gegen.lyx" <<'EOF'
fn main(): int64 {
  var x: f64 := 1.5;
  var m := fn(y: f64): f64 { return x * y; };
  var r: f64 := m(4.0);
  r := m(2.0);
  var y: f64 := 2.7;
  var f: f64 := fFloor(y);
  var g: f64 := 0.0;
  g := fRound(y);
  PrintInt((r * 10.0) as int64); Print(" "); PrintInt((f * 10.0) as int64); Print(" "); PrintInt((g * 10.0) as int64); Print("\n");
  return 0;
}
EOF
pruefe "Gegenseite: Lambda, fFloor, fRound" "$TMP/gegen.lyx" "30 20 30|"

# --- f32-Felder: Wert, Nachbarn, Groesse, Klasse, Parameter -------------------------
cat > "$TMP/feld.lyx" <<'EOF'
type Q = struct { a: int32; w: f32; b: int32; };
type K = class { w: f32; n: int64; };
fn halb(x: f32): f32 { return x / 2.0; }
fn main(): int64 {
  var q: Q; q.a := 0 - 1; q.w := 0 - 1.5; q.b := 77;
  PrintInt(q.a); Print(" "); PrintInt((q.w * 10.0) as int64); Print(" "); PrintInt(q.b); Print(" ");
  PrintInt(sizeof(Q)); Print("|");
  var k: K := new K(); k.w := 2.75; k.n := 5;
  k.w := k.w + 1.0;
  PrintInt((k.w * 100.0) as int64); Print(" "); PrintInt(k.n); Print("|");
  var h: f32 := halb(5.0);
  PrintInt((h * 10.0) as int64); Print(" ");
  var t: f32 := 0.1;
  q.w := t;
  var r: f64 := q.w;
  // single-Genauigkeit: 0.1f = 0.100000001490116...
  PrintInt((r * 1000000000.0) as int64); Print("\n");
  return 0;
}
EOF
pruefe "f32-Felder" "$TMP/feld.lyx" "-1 -15 77 12|375 5|25 100000001|"

# --- lyxos: die Wandelbefehle am Erzeugnis -----------------------------------------
cat > "$TMP/lx.lyx" <<'EOF'
type Q = struct { a: int32; w: f32; };
fn main(): int64 { var q: Q; q.w := 0.25; var r: f64 := q.w; return (r * 100.0) as int64; }
EOF
if baue lyxos "$TMP/lx.lyx" "$TMP/lx.lbf"; then
  zahl="$(python3 -I - "$TMP/lx.lbf" <<'PY'
import sys
b = open(sys.argv[1], 'rb').read()
print(b.count(bytes.fromhex('f20f5ac0660f7ec0')), b.count(bytes.fromhex('660f6ec0f30f5ac0')))
PY
)"
  # cvtsd2ss+movd (Schreiben) und movd+cvtss2sd (Lesen), je einmal
  if [ "$zahl" = "1 1" ]; then ok "lyxos: f32-Feld schreibt/liest mit Wandlung [$zahl]"
  else nok "lyxos: Wandelbefehle [$zahl] statt [1 1]"; fi
else nok "lyxos: uebersetzt nicht ($(grep -m1 -i error "$TMP/lx.lbf.log"))"; fi

# --- x86 .so: Alias und f32 an der C-Schnittstelle (ctypes) -----------------------
mkdir -p "$TMP/so"
cat > "$TMP/so/lib.lyx" <<'EOF'
type Meter = f64;
@export
fn dop(m: Meter): Meter { return m * 2.0; }
@export
fn viertel(x: f32): f32 { return x / 4.0; }
EOF
if baue linux lib.lyx "$TMP/so/lib.so" "$TMP/so" --shared; then
  aus="$(python3 -I - "$TMP/so/lib.so" <<'PY'
import ctypes, sys
l = ctypes.CDLL(sys.argv[1])
l.dop.restype = ctypes.c_double; l.dop.argtypes = [ctypes.c_double]
l.viertel.restype = ctypes.c_float; l.viertel.argtypes = [ctypes.c_float]
print(l.dop(2.5), l.viertel(5.0))
PY
)"
  if [ "$aus" = "5.0 1.25" ]; then ok "x86 .so: Alias-Parameter und f32 [$aus]"
  else nok "x86 .so: [$aus] statt [5.0 1.25]"; fi
else nok "x86 .so: uebersetzt nicht ($(grep -m1 -i error "$TMP/so/lib.so.log"))"; fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
