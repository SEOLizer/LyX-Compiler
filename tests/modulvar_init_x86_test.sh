#!/usr/bin/env bash
# tests/modulvar_init_x86_test.sh — #2136: Anfangswerte von Modulvariablen zur
# LAUFZEIT auf x86 und in vorkompilierten Units (--compile-unit).
#
# Bis 1.2.15A:
#   - x86 (codegen_x86, CGN_VAR_DECL) wies jeden Anfangswert ab, der sich nicht
#     in den Datenbereich legen liess: `var g := f() + 1`, `var b := a + 1`,
#     ein Laufzeit-Element in einem Array-Literal ("Startwert ist zur
#     Uebersetzungszeit nicht bekannt"). Der IR-Weg kann es seit #2123 — die
#     Ziele waren ungleich maechtig.
#   - `--compile-unit` fuer ein IR-Ziel wies eine Unit mit solchem Anfangswert
#     ab (#2123), z.B. std/lfd_parser.lyx.
#   - Dabei gefunden: das Uebernehmen einer .lyu legte ihre Modulvariablen auf
#     dieselben Plaetze wie die des Programms — schrieb das Programm seine
#     Variable, aenderte sich die der Unit (auch ohne Laufzeit-Anfangswert).
#
# Gemessen wird der WERT, und die REIHENFOLGE am Weg: jeder Anfangswert haengt
# eine Ziffer an einen Zaehler, 123 heisst "einmal, und in dieser Folge".
# x86 == arm64 == riscv == Sollwert. Dazu die Bibliothek (C-Host laedt die
# x86-.so mit dlopen, der Wert kommt ueber einen Export), --compile-unit auf
# arm64 und x86 und die Gegenseite: ein Programm ohne Laufzeit-Anfangswert
# bleibt Byte fuer Byte, wie es mit 1.2.15A war (kein Aufruf, keine Funktion).
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
if ! command -v gcc > /dev/null 2>&1; then echo "FAIL gcc fehlt — NICHT gemessen"; exit 1; fi

# Uebersetzen im Verzeichnis der Quelle (Importe loesen relativ dazu auf).
baue() {  # quelle, ziel, ausgabe, [extra]
  ( cd "$(dirname "$1")" && timeout 240 "$LYXC" --std-path="$ROOT" --target="$2" ${4:-} "$1" -o "$3" ) >"$TMP/bl.log" 2>&1
}
lauf() {  # ziel, binary
  case "$1" in
    x86_64) ( ulimit -v 4000000; timeout 30 "$2" ) ;;
    arm64)  ( ulimit -v 4000000; timeout 30 "$QEMU_ARM64" "$2" ) ;;
    riscv)  ( ulimit -v 4000000; timeout 30 "$QEMU_RISCV64" "$2" ) ;;
  esac
}
messe() {  # quelle, ziel -> Ausgabe auf stdout
  rm -f "$TMP/p"
  if ! baue "$1" "$2" "$TMP/p"; then
    echo "UEBERSETZT-NICHT: $(grep -v Copyright "$TMP/bl.log" | grep -m1 -iE 'error|lyxc:')"; return
  fi
  local aus rc
  aus="$(cd "$TMP" && lauf "$2" "$TMP/p" 2>/dev/null | tr '\n' '|')"; rc=${PIPESTATUS[0]}
  echo "$aus rc=$rc"
}
alle() {  # name, quelle, soll — x86 == arm64 == riscv == soll
  local t ist x86
  x86="$(messe "$2" x86_64)"
  for t in x86_64 arm64 riscv; do
    if [ "$t" = x86_64 ]; then ist="$x86"; else ist="$(messe "$2" "$t")"; fi
    if [ "$ist" = "$3" ]; then ok "$1 [$t]: [$ist]"
    else nok "$1 [$t]: [$ist] statt [$3] (x86: [$x86])"; fi
  done
}

# --- 1. Die Faelle aus tests/ir_modulvar_init_test.sh, jetzt auch auf x86 ----
# Der Fall aus dem Issue, woertlich.
cat > "$TMP/issue.lyx" <<'EOF'
fn f(): int64 { return 41; }
var g: int64 := f() + 1;
var s: pchar := "abc";
fn main(): int64 { PrintInt(g); Print(" "); PrintInt(StrLen(s)); Print("\n"); return 0; }
EOF
alle "Issue woertlich" "$TMP/issue.lyx" "42 3| rc=0"

# Aus einer anderen Modulvariablen (gefaltet UND zur Laufzeit), f64 aus einem
# Aufruf.
cat > "$TMP/kette.lyx" <<'EOF'
fn half(): f64 { return 0.5; }
fn sieben(): int64 { return 7; }
var a: int64 := 7;
var b: int64 := a + 1;
var c: int64 := sieben();
var d: int64 := c * 10 + b;
var hf: f64 := half() * 3.0;
fn main(): int64 {
  PrintInt(b); Print(" "); PrintInt(d); Print(" "); PrintInt((hf * 10.0) as int64); Print("\n");
  return 0;
}
EOF
alle "Modulvariable/Aufruf/f64" "$TMP/kette.lyx" "8 78 15| rc=0"

# Reihenfolge ueber drei Units: haupt importiert ub VOR ua, ub importiert ua.
# Erwartet: basis (keine), ua, ub, haupt — gSeq = 123, jede Unit genau einmal;
# dazu eine PRIVATE Modulvariable (Zeichenkette) in ua.
mkdir -p "$TMP/mi"
cat > "$TMP/mi/basis.lyx" <<'EOF'
unit mi.basis;
pub var gSeq: int64 := 0;
pub fn Mark(k: int64): int64 { gSeq := gSeq * 10 + k; return gSeq; }
EOF
cat > "$TMP/mi/ua.lyx" <<'EOF'
unit mi.ua;
import mi.basis;
fn seed(): int64 { return 20; }
pub var aOrd: int64 := Mark(1);
pub var aBase: int64 := seed() * 2;
var aPriv: pchar := "ua";
pub fn APrivLen(): int64 { return StrLen(aPriv); }
EOF
cat > "$TMP/mi/ub.lyx" <<'EOF'
unit mi.ub;
import mi.basis;
import mi.ua;
pub var bOrd: int64 := Mark(2);
pub var bVal: int64 := aBase + 2;
EOF
cat > "$TMP/haupt.lyx" <<'EOF'
import mi.ub;
import mi.ua;
import mi.basis;
var mOrd: int64 := Mark(3);
var mVal: int64 := bVal * 10;
fn main(): int64 {
  PrintInt(gSeq); Print(" ");
  PrintInt(aOrd); Print(" "); PrintInt(bOrd); Print(" "); PrintInt(mOrd); Print(" ");
  PrintInt(mVal); Print(" "); PrintInt(APrivLen()); Print("\n");
  return 0;
}
EOF
alle "Drei Units, Reihenfolge" "$TMP/haupt.lyx" "123 1 12 123 420 2| rc=0"

# Array-Literal mit einem Laufzeit-Element, eine Struktur aus einem Aufruf
# (Wert, nicht Zeiger in den Rahmen der Init-Funktion), eine Deklaration
# HINTER main (main ruft trotzdem), Deklarationsreihenfolge: `nachher` liest
# `spaeter`, das erst danach entsteht — also 0 + 1.
cat > "$TMP/misch.lyx" <<'EOF'
type TP = struct { x: int64; y: int64; };
fn MkP(a: int64): TP { var p: TP; p.x := a; p.y := a * 2; return p; }
fn f(): int64 { return 5; }
var arr: [3]int64 := [1, f(), 3];
var pt: TP := MkP(21);
var nachher: int64 := spaeter + 1;
fn main(): int64 {
  PrintInt(arr[0]); Print(" "); PrintInt(arr[1]); Print(" "); PrintInt(arr[2]); Print(" ");
  PrintInt(pt.x); Print(" "); PrintInt(pt.y); Print(" ");
  PrintInt(nachher); Print(" "); PrintInt(spaeter); Print("\n");
  return 0;
}
var spaeter: int64 := f() * 2;
EOF
alle "Array-Element/Struktur/hinter main" "$TMP/misch.lyx" "1 5 3 21 42 1 10| rc=0"

# --- 2. Gegenseite: ohne Laufzeit-Anfangswert unveraendert ------------------
# Ohne Bedarf entsteht weder die Funktion noch der Aufruf in main — gemessen
# an der Symbolkarte (--map-file) zweier Programme, die sich NUR in einem
# Anfangswert unterscheiden; beide muessen dasselbe ausgeben.
cat > "$TMP/konst.lyx" <<'EOF'
var a: int64 := 7;
var s: pchar := "x";
fn f(): int64 { return 7; }
fn main(): int64 { PrintInt(a); Print(s); Print("\n"); return 0; }
EOF
sed 's/var a: int64 := 7;/var a: int64 := f();/' "$TMP/konst.lyx" > "$TMP/lauf.lyx"
if baue "$TMP/konst.lyx" x86_64 "$TMP/k1" --map-file && baue "$TMP/lauf.lyx" x86_64 "$TMP/k2" --map-file; then
  a1="$(lauf x86_64 "$TMP/k1")"; a2="$(lauf x86_64 "$TMP/k2")"
  m1="$(grep -c '__lyx_modinit' "$TMP/k1.map")"; m2="$(grep -c '__lyx_modinit' "$TMP/k2.map")"
  if [ "$a1" = "7x" ] && [ "$a2" = "7x" ] && [ "$m1" = "0" ] && [ "$m2" = "2" ]; then
    ok "Init-Funktion nur mit Bedarf (Symbole: $m1 ohne, $m2 mit; beide 7x)"
  else nok "konstant/Laufzeit: [$a1]/[$a2], __lyx_modinit-Symbole $m1/$m2 statt 0/2"; fi
else nok "konstant/Laufzeit uebersetzt nicht ($(grep -v Copyright "$TMP/bl.log" | grep -m1 -iE 'error|lyxc:'))"; fi

# --- 2b. Derselbe Codegen, andere Einsprungpunkte ---------------------------
# windows-x86_64 (PE) ruft main aus seinem eigenen Eintritt; gemessen unter
# wine, wo es eins gibt. lyxos-kernel laeuft hier nicht (cli/hlt nach main) —
# dort am Erzeugnis: Unit-Funktion und Sammelfunktion stehen in der Karte.
if command -v wine > /dev/null 2>&1; then
  rm -f "$TMP/h.exe"
  if baue "$TMP/haupt.lyx" windows-x86_64 "$TMP/h.exe"; then
    ist="$( (ulimit -v 8000000; WINEDEBUG=-all timeout 120 wine "$TMP/h.exe") 2>/dev/null | tr -d '\r')"
    [ "$ist" = "123 1 12 123 420 2" ] && ok "windows-x86_64 (wine): [$ist]" || nok "windows-x86_64 (wine): [$ist] statt [123 1 12 123 420 2]"
  else nok "windows-x86_64 uebersetzt nicht ($(grep -v Copyright "$TMP/bl.log" | grep -m1 -iE 'error|lyxc:'))"; fi
else echo "HINWEIS wine fehlt — windows-x86_64 nicht ausgefuehrt"; fi
rm -f "$TMP/krn" "$TMP/krn.map"
if baue "$TMP/issue.lyx" lyxos-kernel "$TMP/krn" --map-file; then
  m="$(grep -cE '__lyx_modinit(_0)?$' "$TMP/krn.map")"
  [ "$m" = "2" ] && ok "lyxos-kernel: __lyx_modinit_0 und __lyx_modinit im Erzeugnis" || nok "lyxos-kernel: $m von 2 Init-Symbolen"
else nok "lyxos-kernel uebersetzt nicht ($(grep -v Copyright "$TMP/bl.log" | grep -m1 -iE 'error|lyxc:'))"; fi

# --- 3. Bibliothek: x86-64 --shared, Anfangswerte ueber DT_INIT_ARRAY -------
# Der Host laedt die .so mit dem glibc-Lader und liest die Werte ueber Exporte.
# wert(): basis() + 12 = 42, doppelt(): wert * 2 = 84 (zweite Variable aus der
# ersten), text(): StrLen einer zur Laufzeit gewaehlten Zeichenkette = 5,
# folge(): die Reihenfolge 12 (erst a, dann b).
mkdir -p "$TMP/so"
cat > "$TMP/so/lib.lyx" <<'EOF'
var seq: int64 := 0;
fn mark(k: int64): int64 { seq := seq * 10 + k; return seq; }
fn basis(): int64 { return 30; }
fn wahl(): pchar { return "hallo"; }
var lauf: int64 := basis() + 12;
var o1: int64 := mark(1);
var dopp: int64 := lauf * 2;
var o2: int64 := mark(2);
var t: pchar := wahl();
@export
fn wert(): int64 { return lauf; }
@export
fn doppelt(): int64 { return dopp; }
@export
fn text(): int64 { return StrLen(t); }
@export
fn folge(): int64 { return seq; }
EOF
cat > "$TMP/so/host.c" <<'EOF'
#include <dlfcn.h>
#include <stdio.h>
typedef long (*J0)(void);
int main(int c, char **v) {
  void *h = dlopen(v[1], RTLD_NOW); if (!h) { printf("dlopen: %s\n", dlerror()); return 2; }
  J0 w = (J0)dlsym(h, "wert"), d = (J0)dlsym(h, "doppelt"), t = (J0)dlsym(h, "text"), f = (J0)dlsym(h, "folge");
  if (!w || !d || !t || !f) { printf("Symbol fehlt\n"); return 3; }
  printf("%ld %ld %ld %ld\n", w(), d(), t(), f());
  return 0;
}
EOF
if gcc -o "$TMP/so/host" "$TMP/so/host.c" -ldl > "$TMP/gcc.log" 2>&1; then
  rm -f "$TMP/so/lib.so"
  if baue "$TMP/so/lib.lyx" x86_64 "$TMP/so/lib.so" --shared; then
    aus="$( (ulimit -v 4000000; timeout 30 "$TMP/so/host" "$TMP/so/lib.so") 2>&1)"
    if [ "$aus" = "42 84 5 12" ]; then ok "x86-64 .so: dlopen, Werte ueber Exporte [$aus]"
    else nok "x86-64 .so: [$aus] statt [42 84 5 12]"; fi
  else nok "x86-64 .so uebersetzt nicht ($(grep -v Copyright "$TMP/bl.log" | grep -m1 -iE 'error|lyxc:'))"; fi
else nok "Host baut nicht — NICHT gemessen: $(head -2 "$TMP/gcc.log" | tr '\n' ' ')"; fi

# --- 4. --compile-unit: Unit mit Laufzeit-Anfangswert als .lyu --------------
# arm64: die .lyu traegt das IR samt `__lyx_modinit@...`; das Programm findet
# die Unit NUR als .lyu (keine Quelle im Suchpfad) und haengt ihre Funktion in
# seine Sammelfunktion. Das Programm hat selbst Modulvariablen — eine davon
# rechnet aus der Unit (h = G() * 2), eine wird in main geschrieben: die
# Plaetze duerfen sich mit denen der .lyu nicht ueberschneiden.
mkdir -p "$TMP/cu/src" "$TMP/cu/inc/demo"
cat > "$TMP/cu/src/cu_u.lyx" <<'EOF'
unit demo.cu;
fn basis(): int64 { return 30; }
var s: pchar := "abc";
var g: int64 := basis() + 9;
pub fn G(): int64 { return StrLen(s) + g; }
EOF
cat > "$TMP/cu/p.lyx" <<'EOF'
import demo.cu;
var h: int64 := G() * 2;
var k: int64 := 5;
fn main(): int64 {
  k := 100;
  PrintInt(G()); Print(" "); PrintInt(h); Print(" "); PrintInt(k); Print("\n");
  return 0;
}
EOF
SOLLCU="42 84 100"
if ( cd "$ROOT" && timeout 240 "$LYXC" --compile-unit --target=arm64 --std-path="$ROOT" "$TMP/cu/src/cu_u.lyx" -o "$TMP/cu/inc/demo/cu.lyu" ) >"$TMP/cu.log" 2>&1; then
  if ( cd / && timeout 240 "$LYXC" --target=arm64 --std-path="$ROOT" -I "$TMP/cu/inc" "$TMP/cu/p.lyx" -o "$TMP/cu/p" ) >"$TMP/cub.log" 2>&1; then
    ist="$(lauf arm64 "$TMP/cu/p" 2>/dev/null)"
    [ "$ist" = "$SOLLCU" ] && ok "--compile-unit arm64: Wert kommt an ($ist)" || nok "--compile-unit arm64: [$ist] statt [$SOLLCU]"
  else nok "--compile-unit arm64: Programm uebersetzt nicht ($(grep -v Copyright "$TMP/cub.log" | grep -m1 -iE 'error|lyxc:'))"; fi
else nok "--compile-unit arm64: abgewiesen ($(grep -v Copyright "$TMP/cu.log" | grep -m1 -iE 'error|lyxc:'))"; fi

# Eine .lyu OHNE Laufzeit-Anfangswert (alte Form, keine Init-Funktion) wird
# weiter gelesen; ihre Modulvariable liegt neben der des Programms.
mkdir -p "$TMP/cu2/src" "$TMP/cu2/inc/demo"
printf 'unit demo.cu;\nvar g: int64 := 39;\npub fn G(): int64 { return g + 3; }\n' > "$TMP/cu2/src/cu_u.lyx"
printf 'import demo.cu;\nvar k: int64 := 5;\nfn main(): int64 { k := 100; PrintInt(G()); Print(" "); PrintInt(k); Print("\\n"); return 0; }\n' > "$TMP/cu2/p.lyx"
if ( cd "$ROOT" && timeout 240 "$LYXC" --compile-unit --target=arm64 --std-path="$ROOT" "$TMP/cu2/src/cu_u.lyx" -o "$TMP/cu2/inc/demo/cu.lyu" ) >"$TMP/cu.log" 2>&1 \
   && ( cd / && timeout 240 "$LYXC" --target=arm64 --std-path="$ROOT" -I "$TMP/cu2/inc" "$TMP/cu2/p.lyx" -o "$TMP/cu2/p" ) >"$TMP/cub.log" 2>&1; then
  ist="$(lauf arm64 "$TMP/cu2/p" 2>/dev/null)"
  [ "$ist" = "42 100" ] && ok ".lyu ohne Init: Modulvariablen getrennt ($ist)" || nok ".lyu ohne Init: [$ist] statt [42 100]"
else nok ".lyu ohne Init uebersetzt nicht ($(grep -v Copyright "$TMP/cu.log" "$TMP/cub.log" | grep -m1 -iE 'error|lyxc:'))"; fi

# x86: --compile-unit laesst den x86-Codegen als Pruefung mitlaufen — der wies
# bis 1.2.15A ab. Die x86-.lyu traegt keinen Code; das Programm nimmt die
# Quelle daneben, der Wert muss stimmen.
mkdir -p "$TMP/cx/demo"
cp "$TMP/cu/src/cu_u.lyx" "$TMP/cx/demo/cu.lyx"
if ( cd "$ROOT" && timeout 240 "$LYXC" --compile-unit --std-path="$ROOT" "$TMP/cx/demo/cu.lyx" -o "$TMP/cx/demo/cu.lyu" ) >"$TMP/cx.log" 2>&1 && [ -s "$TMP/cx/demo/cu.lyu" ]; then
  ok "--compile-unit x86: .lyu geschrieben"
  if ( cd / && timeout 240 "$LYXC" --std-path="$ROOT" -I "$TMP/cx" "$TMP/cu/p.lyx" -o "$TMP/cx/p" ) >"$TMP/cxb.log" 2>&1; then
    ist="$(lauf x86_64 "$TMP/cx/p" 2>/dev/null)"
    [ "$ist" = "$SOLLCU" ] && ok "--compile-unit x86: Wert kommt an ($ist)" || nok "--compile-unit x86: [$ist] statt [$SOLLCU]"
  else nok "--compile-unit x86: Programm uebersetzt nicht ($(grep -v Copyright "$TMP/cxb.log" | grep -m1 -iE 'error|lyxc:'))"; fi
else nok "--compile-unit x86: abgewiesen ($(grep -v Copyright "$TMP/cx.log" | grep -m1 -iE 'error|lyxc:'))"; fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
