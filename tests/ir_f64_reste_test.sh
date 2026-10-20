#!/usr/bin/env bash
# tests/ir_f64_reste_test.sh — #2139: drei Luecken des IR-Wegs (arm64, riscv,
# lyxos — alle Backends hinter src/ir_lower.lyx).
#
# Bis 1.2.16A:
#   (1) Eine f64-Modulkonstante/-variable mit AUSDRUCK als Startwert
#       (`con E: f64 := 0.0 - 1.5`, `2.0 * 3.5`, `A + B`) war still 0.0 — der
#       Vorpass kannte nur das Literal. x86 faltet seit #1853 (cg_faltF64).
#       Nicht faltbare (Cast, Konstante einer anderen Unit) blieben ebenfalls 0.
#   (2) _isF64Expr kannte Feld und Aufrufergebnis nicht: `b.v + b.v` mit
#       `v: f64` rechnete ganzzahlig auf den IEEE-Bits (9223372036854775807),
#       ebenso `f() + f()`, Methoden, importierte Funktionen, Box<f64>.
#   (3) Der IR-Weg kuerzte NIRGENDS auf schmale Ganzzahltypen: weder der
#       Laufzeit-Startwert einer Modulvariablen (`var e8: int8 := f() * 60`
#       -> 300 statt 44) noch ein Local, eine Zuweisung, `as int8`, ein
#       Parameter oder eine Rueckgabe. x86 kuerzt seit #1151 an allen Stellen.
#
# Gemessen wird der WERT (x1000 als Ganzzahl) auf x86_64, arm64 und riscv —
# alle drei muessen dem Sollwert entsprechen. Gegenseite: Ganzzahlfelder und
# -aufrufe bleiben ganzzahlig, int64 wird nicht gekuerzt, Werte im
# Wertebereich bleiben stehen. lyxos: Rueckgabewert ueber den lokalen
# LBF-Lader (nur Ganzzahl, nicht allokierend, siehe CLAUDE.md "Messsonden").
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

# pruefe <name> <datei> <soll> [verzeichnis] [ziele]
pruefe() {
  local t
  for t in ${5:-linux arm64 riscv}; do
    rm -f "$TMP/p"
    if ! ( cd "${4:-$ROOT}" && timeout 240 "$LYXC" --std-path="$ROOT" --target=$t "$2" -o "$TMP/p" ) >"$TMP/bl.log" 2>&1; then
      nok "$1 [$t]: uebersetzt nicht ($(grep -m1 -iE 'error' "$TMP/bl.log"))"; continue
    fi
    local aus rc
    aus="$(lauf $t "$TMP/p" 2>/dev/null | tr '\n' '|')"; rc=${PIPESTATUS[0]}
    if [ "$aus" = "$3" ] && [ "$rc" = "0" ]; then ok "$1 [$t]: [$aus]"
    else nok "$1 [$t]: [$aus] rc=$rc statt [$3]"; fi
  done
}

# --- (1) f64-Startwert mit Ausdruck ------------------------------------------
# Der Fall aus dem Issue woertlich, dazu Produkt, Verweis auf andere
# f64-Konstanten, Negation einer Konstanten, Modulvariable. `C` steht als
# Bezug: das Literal ging schon vorher.
cat > "$TMP/con.lyx" <<'EOF'
con E: f64 := 0.0 - 1.5;
con P: f64 := 2.0 * 3.5;
con S: f64 := E + P;
con N: f64 := -E;
con Q: f64 := S / 4.0;
con C: f64 := 0.25;
var v1: f64 := 0.0 - 1.5;
var v2: f64 := S * 2.0;
fn p(x: f64) { PrintInt((x * 1000.0) as int64); Print(" "); }
fn main(): int64 {
  p(E); p(P); p(S); p(N); p(Q); p(C); p(v1); p(v2);
  Print("\n");
  return 0;
}
EOF
pruefe "f64-con/var mit Ausdruck" "$TMP/con.lyx" "-1500 7000 5500 1500 1375 250 -1500 11000 |"

# Nicht faltbar: Cast im Startwert. Der IR-Weg legt den Wert zur LAUFZEIT ab
# (#2123) statt 0. Nur IR-Ziele: x86 liefert hier selbst 0 (eigener Befund,
# cg_evalConExpr wertet `(3 as f64)` ganzzahlig aus — nicht Gegenstand).
cat > "$TMP/cast.lyx" <<'EOF'
con W: f64 := (3 as f64) * 0.5;
var v3: f64 := (10 as f64) / 4.0;
fn main(): int64 {
  PrintInt((W * 1000.0) as int64); Print(" ");
  PrintInt((v3 * 1000.0) as int64); Print("\n");
  return 0;
}
EOF
pruefe "f64-con mit Cast zur Laufzeit" "$TMP/cast.lyx" "1500 2500|" "" "arm64 riscv"

# --- (2) Feld und Aufrufergebnis ------------------------------------------
# Struktfeld, Klassenfeld, geerbtes Feld, Methode (auch geerbt), freie
# Funktion, eingebaute Quelle, Funktionszeiger, Box<f64>; Gegenseite: das
# Ganzzahlfeld und die Ganzzahlfunktion bleiben ganzzahlig, der Vergleich
# zweier f64-Felder liefert 0/1.
cat > "$TMP/feld.lyx" <<'EOF'
type B = struct { v: f64; n: int64; }
type K = class { w: f64; fn get(): f64 { return self.w; } }
type Abl = class extends K { z: int64; };
type Box<T> = class {
  v: T;
  fn Get(): T { return self.v; }
};
fn mk(): f64 { return 1.25; }
fn ganz(): int64 { return 7; }
fn fx(x: f64): f64 { return x; }
fn p(x: f64) { PrintInt((x * 1000.0) as int64); Print(" "); }
fn main(): int64 {
  var b: B; b.v := 2.25; b.n := 3;
  p(b.v + b.v);
  p(mk() + mk());
  var k: K := new K(); k.w := 0.75;
  p(k.w + k.w);
  p(k.get() + k.get());
  var a: Abl := new Abl(); a.w := 3.0;
  p(a.w + a.w);
  p(a.get() + a.get());
  var x: Box<f64> := new Box<f64>(); x.v := 1.25;
  p(x.v + x.v);
  p(x.Get() + x.Get());
  p(fAdd(0.5, 0.25) + fAdd(0.5, 0.25));
  var fp: fn(f64): f64 := fx;
  p(fp(0.5) + fp(0.5));
  PrintInt(((b.v + b.v) as int64) * 1000); Print(" ");
  PrintInt(b.n + b.n); Print(" ");
  PrintInt(ganz() + ganz()); Print(" ");
  if (k.w < a.w) { Print("lt"); } else { Print("ge"); }
  Print("\n");
  return 0;
}
EOF
pruefe "f64 aus Feld/Methode/Aufruf/Box<f64>/fn-Zeiger" "$TMP/feld.lyx" "4500 2500 1500 1500 6000 6000 2500 2500 1500 1000 4000 6 14 lt|"

# Unit-uebergreifend: Konstanten, Klasse, Methode, Funktion einer anderen
# Unit; MA verweist auf eine IMPORTIERTE Konstante (nicht faltbar -> Laufzeit).
mkdir -p "$TMP/xm"
cat > "$TMP/xm/gu.lyx" <<'EOF'
unit gu;
pub con GA: f64 := 0.0 - 2.5;
pub con GB: f64 := GA * 2.0;
pub var gv: f64 := GB + 0.5;
pub var g8: int8 := 200;
pub type Pkt = class {
  x: f64;
  fn Dop(): f64 { return self.x + self.x; }
};
pub type Pkt2 = class extends Pkt { n: int64; };
pub fn hol(): f64 { return 0.75; }
pub fn neu(a: f64): Pkt { var p: Pkt := new Pkt(); p.x := a; return p; }
pub fn schmal(x: int8): int64 { return x as int64; }
pub fn rueck(x: int64): uint8 { return x; }
EOF
cat > "$TMP/xm/main.lyx" <<'EOF'
import gu;
con MA: f64 := GA + 1.0;
fn p(x: f64) { PrintInt((x * 1000.0) as int64); Print(" "); }
fn main(): int64 {
  p(GA); p(GB); p(gv); p(MA);
  PrintInt(g8 as int64); Print(" ");
  var q: Pkt := neu(1.5);
  p(q.x + q.x);
  p(q.Dop() + q.Dop());
  p(hol() + hol());
  var q2: Pkt2 := new Pkt2(); q2.x := 4.0;
  p(q2.x + q2.x);
  p(q2.Dop() + q2.Dop());
  PrintInt(schmal(300)); Print(" ");
  PrintInt(rueck(300)); Print("\n");
  return 0;
}
EOF
pruefe "Unit-uebergreifend: con, Feld, Methode, Funktion, schmal" main.lyx "-2500 -5000 -4500 -1500 -56 3000 6000 1500 8000 16000 44 44|" "$TMP/xm"

# Feld am Ergebnis einer IMPORTIERTEN Funktion — bis 1.2.16A auf dem IR-Weg
# "Feld nicht aufloesbar" (_instanceFieldOffset kannte nur die eigene Unit).
cat > "$TMP/xm/neu.lyx" <<'EOF'
import gu;
fn main(): int64 {
  PrintInt(((neu(0.25).x + neu(0.25).x) * 1000.0) as int64); Print("\n");
  return 0;
}
EOF
pruefe "Feld am Ergebnis einer importierten Funktion" neu.lyx "500|" "$TMP/xm"

# --- (3) schmale Ganzzahltypen -----------------------------------------------
# Der Fall aus dem Issue woertlich, dazu alle sechs Breiten als Modulvariable
# mit Laufzeit-Startwert und mit faltbarem Startwert, Local, Zuweisung,
# zusammengesetzte Zuweisung, Cast, Parameter, Rueckgabe, Modulvariable per
# Zuweisung. Gegenseite: Werte im Bereich bleiben, int64 wird nicht gekuerzt.
cat > "$TMP/schmal.lyx" <<'EOF'
fn f(): int64 { return 5; }
var e8: int8 := f() * 60;
var w8: uint8 := f() * 60;
var e16: int16 := f() * 7000;
var w16: uint16 := f() * 14000;
var e32: int32 := f() * 500000000;
var w32: uint32 := f() * 1000000000;
var k8: int8 := 200;
var k16: uint16 := 70000;
var g8: int8;
var g64: int64 := f() * 1000000000000;
fn par(x: int8): int64 { return x as int64; }
fn rue(x: int64): int8 { return x; }
fn main(): int64 {
  PrintInt(e8 as int64); Print(" "); PrintInt(w8 as int64); Print(" ");
  PrintInt(e16 as int64); Print(" "); PrintInt(w16 as int64); Print(" ");
  PrintInt(e32 as int64); Print(" "); PrintInt(w32 as int64); Print(" ");
  PrintInt(k8 as int64); Print(" "); PrintInt(k16 as int64); Print(" ");
  var x: int8 := f() * 60;
  PrintInt(x as int64); Print(" ");
  x := f() * 61;
  PrintInt(x as int64); Print(" ");
  var a: int8 := 100;
  a += 100;
  PrintInt(a as int64); Print(" ");
  var y: int64 := f() * 60;
  PrintInt((y as int8) as int64); Print(" ");
  PrintInt((y as uint8) as int64); Print(" ");
  PrintInt(par(f() * 60)); Print(" ");
  PrintInt(rue(f() * 60) as int64); Print(" ");
  g8 := f() * 60;
  PrintInt(g8 as int64); Print(" ");
  var n: int8 := 0 - 5;
  var u: uint8 := 255;
  var m: int16 := 0 - 32768;
  PrintInt(n as int64); Print(" "); PrintInt(u as int64); Print(" "); PrintInt(m as int64); Print(" ");
  PrintInt(g64); Print(" ");
  PrintInt(y * 1000000000000); Print("\n");
  return 0;
}
EOF
pruefe "schmale Typen: Modulvariable, Local, Zuweisung, Cast, Parameter, Rueckgabe" "$TMP/schmal.lyx" \
  "44 44 -30536 4464 -1794967296 705032704 -56 4464 44 49 -56 44 44 44 44 44 -5 255 -32768 5000000000000 300000000000000|"

# --- lyxos: Rueckgabewert ueber den lokalen LBF-Lader -----------------------
lyxos_rc() {  # quelle -> Exit-Code von main
  rm -f "$TMP/e.lyxnative" "$TMP/er"
  ( cd "$ROOT" && timeout 240 "$LYXC" --std-path="$ROOT" --target=lyxos "$1" -o "$TMP/e.lyxnative" ) >/dev/null 2>&1 || { echo "UEBERSETZT-NICHT"; return; }
  printf 'import src.tools.lbf.loader;\nfn main(): int64 { lbf_run("%s/e.lyxnative"c); return 111; }' "$TMP" > "$TMP/er.lyx"
  ( cd "$ROOT" && timeout 240 "$LYXC" "$TMP/er.lyx" -o "$TMP/er" ) >/dev/null 2>&1 || { echo "LADER-UEBERSETZT-NICHT"; return; }
  ( ulimit -v 4000000; timeout 10 "$TMP/er" >/dev/null 2>&1 ); echo $?
}
# (1) B = (0.0 - 1.5) * 2.0 = -3.0 -> -30 + 100 = 70; mit 0.0 waeren es 100.
cat > "$TMP/lx1.lyx" <<'EOF'
con A: f64 := 0.0 - 1.5;
con B: f64 := A * 2.0;
fn main(): int64 { return ((B * 10.0) as int64) + 100; }
EOF
# (2) mk() + mk() = 2.5 -> 25; ganzzahlig auf den Bits kaeme Unsinn heraus.
cat > "$TMP/lx2.lyx" <<'EOF'
fn mk(): f64 { return 1.25; }
fn main(): int64 { return ((mk() + mk()) * 10.0) as int64; }
EOF
# (3) Das Vorzeichen zeigt die Kuerzung: der Exit-Code allein (mod 256) waere
# fuer 200 und -56 derselbe.
cat > "$TMP/lx3.lyx" <<'EOF'
fn f(): int64 { return 5; }
var e8: int8 := f() * 40;
fn main(): int64 { if (e8 < 0) { return 7; } return 9; }
EOF
r="$(lyxos_rc "$TMP/lx1.lyx")"; [ "$r" = "70" ] && ok "lyxos f64-con mit Ausdruck [$r]" || nok "lyxos f64-con mit Ausdruck: [$r] statt [70]"
r="$(lyxos_rc "$TMP/lx2.lyx")"; [ "$r" = "25" ] && ok "lyxos f64-Aufrufergebnis [$r]" || nok "lyxos f64-Aufrufergebnis: [$r] statt [25]"
r="$(lyxos_rc "$TMP/lx3.lyx")"; [ "$r" = "7" ] && ok "lyxos int8-Modulvariable [$r]" || nok "lyxos int8-Modulvariable: [$r] statt [7]"

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
