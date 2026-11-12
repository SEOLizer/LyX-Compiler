#!/usr/bin/env bash
# tests/x86_aufrufe_test.sh — vier Defekte im x86-Codegen, alle still:
#
#   #2079  `f as int64` wurde 0, wenn die Datei vorher eine noch nicht
#          uebersetzte Unit importierte: cg_processImport stellte
#          topLevelHead nach dem rekursiven Import nicht wieder her.
#   #2084  Indirekte Aufrufe (fn-Zeiger lokal/global, Closure, Methoden-
#          zeigerfeld, fn-Zeigerfeld, berechneter Zeiger) kannten nur
#          Registerargumente. Ab dem siebten meldeten zwei Wege falsch
#          "Struct-Rueckgabe", die anderen verloren Argumente still. Der
#          Closure-RUMPF legte ausserdem nur fuenf Parameter an — der sechste
#          war im Rumpf still 0, auch ohne Umgebung.
#   #2081  rbx ist nach SysV vom Gerufenen zu erhalten; der Codegen benutzt es
#          in jeder Binaeroperation und stellte es nie wieder her. Eine
#          Lyx-Funktion als C-Callback (qsort) zerstoerte den Aufrufer.
#   #2078  push/pop auf ein globales `array<T>` schrieb nach [rbp+0];
#          len/Index lasen den Slot selbst.
#
# Jede Pruefung misst den WERT. Die Argumente tragen eindeutige Ziffern, die
# Ausgabe zeigt also auch die REIHENFOLGE.
set -uo pipefail
ulimit -c 0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

liefert() {  # name, datei (in $TMP/m), soll mit |
  rm -f "$TMP/m/b"
  if ! ( cd "$TMP/m" && timeout 120 "$LYXC" --std-path="$ROOT" "$2" -o b ) >"$TMP/log" 2>&1; then
    nok "$1: uebersetzt nicht ($(grep -m1 -iE 'error' "$TMP/log"))"; return
  fi
  local ist; ist="$( (cd "$TMP/m" && timeout 20 ./b 2>&1; echo "rc=$?") | tr '\n' '|')"
  if [ "$ist" = "$3" ]; then ok "$1 = $3"; else nok "$1: [$ist] statt [$3]"; fi
}
mkdir -p "$TMP/m/p"

echo "--- #2079: Funktionsadresse nach dem Import einer neuen Unit ---"
printf 'unit p.fresh;\n\npub con FRESH_C: int64 := 7;\n' > "$TMP/m/p/fresh.lyx"
cat > "$TMP/m/adr.lyx" <<'EOF'
unit main;

@capabilities([system.unsafe.ffi])
extern fn sqrt(x: f64): f64 link "libm.so.6";

import p.fresh;

type F = fn(x: int64): int64;
fn twice(x: int64): int64 { return x * 2; }
fn rufe(f: F, v: int64): int64 { return f(v); }

fn main(): int64 {
  var p: int64 := twice as int64;
  if (p == 0) { PrintStr("adresse 0\n"); } else { PrintStr("adresse ok\n"); }
  var g: F := twice;
  PrintInt(g(21)); PrintStr("\n");
  PrintInt(rufe(twice, FRESH_C)); PrintStr("\n");
  return 0;
}
EOF
liefert "twice as int64 != 0, g(21), rufe(twice, FRESH_C)" adr.lyx "adresse ok|42|14|rc=0|"

echo
echo "--- #2084: indirekte Aufrufe mit 6, 7 und 8 Argumenten ---"
cat > "$TMP/m/ind.lyx" <<'EOF'
unit main;
import std.io;
type F7 = fn(int64, int64, int64, int64, int64, int64, int64): int64;
type F8 = fn(int64, int64, int64, int64, int64, int64, int64, int64): int64;
type M7 = method(int64, int64, int64, int64, int64, int64, int64): int64;
type P = struct { x: int64; y: int64; };
type FS = fn(int64, int64, int64, int64, int64, int64, int64): P;
fn f7(a0: int64, a1: int64, a2: int64, a3: int64, a4: int64, a5: int64, a6: int64): int64 {
  return a0*1000000 + a1*100000 + a2*10000 + a3*1000 + a4*100 + a5*10 + a6;
}
fn f8(a0: int64, a1: int64, a2: int64, a3: int64, a4: int64, a5: int64, a6: int64, a7: int64): int64 {
  return a0*10000000 + a1*1000000 + a2*100000 + a3*10000 + a4*1000 + a5*100 + a6*10 + a7;
}
fn mk(a0: int64, a1: int64, a2: int64, a3: int64, a4: int64, a5: int64, a6: int64): P {
  var p: P; p.x := a0*1000 + a1*100 + a2*10 + a3; p.y := a4*100 + a5*10 + a6; return p;
}
type H = class { tag: int64;
  fn M(a0: int64, a1: int64, a2: int64, a3: int64, a4: int64, a5: int64, a6: int64): int64 {
    return self.tag + a0*1000000 + a1*100000 + a2*10000 + a3*1000 + a4*100 + a5*10 + a6; } };
type B = class { cb: F7; on: M7; };
var gp: F7;
var gs: FS;
fn main(): int64 {
  gp := f7;
  PrintLn(IntToStr(gp(1, 2, 3, 4, 5, 6, 7)));
  var g: F7 := f7;
  PrintLn(IntToStr(g(1, 2, 3, 4, 5, 6, 7)));
  var g8: F8 := f8;
  PrintLn(IntToStr(g8(1, 2, 3, 4, 5, 6, 7, 8)));
  var k: int64 := 90000000;
  var c := fn(a0: int64, a1: int64, a2: int64, a3: int64, a4: int64, a5: int64, a6: int64): int64 {
    return k + a0*1000000 + a1*100000 + a2*10000 + a3*1000 + a4*100 + a5*10 + a6; };
  PrintLn(IntToStr(c(1, 2, 3, 4, 5, 6, 7)));
  var c6 := fn(a0: int64, a1: int64, a2: int64, a3: int64, a4: int64, a5: int64): int64 {
    return k + a0*100000 + a1*10000 + a2*1000 + a3*100 + a4*10 + a5; };
  PrintLn(IntToStr(c6(1, 2, 3, 4, 5, 6)));
  var u6 := fn(a0: int64, a1: int64, a2: int64, a3: int64, a4: int64, a5: int64): int64 {
    return a0*100000 + a1*10000 + a2*1000 + a3*100 + a4*10 + a5; };
  PrintLn(IntToStr(u6(1, 2, 3, 4, 5, 6)));
  var h: H := new H(); h.tag := 80000000;
  var b: B := new B(); b.cb := f7; b.on := h.M;
  PrintLn(IntToStr(b.cb(1, 2, 3, 4, 5, 6, 7)));
  PrintLn(IntToStr(b.on(1, 2, 3, 4, 5, 6, 7)));
  var d: [2]F7 := [f7, f7];
  PrintLn(IntToStr(d[1](1, 2, 3, 4, 5, 6, 7)));
  var fs: FS := mk;
  var p: P := fs(1, 2, 3, 4, 5, 6, 7);
  PrintLn(IntToStr(p.x)); PrintLn(IntToStr(p.y));
  gs := mk;
  var q: P := gs(7, 6, 5, 4, 3, 2, 1);
  PrintLn(IntToStr(q.x)); PrintLn(IntToStr(q.y));
  // Stapel nach dem Aufruf wieder sauber: indirekter Aufruf als Argument.
  PrintLn(IntToStr(f8(gp(1, 2, 3, 4, 5, 6, 7), 0, 0, 0, 0, 0, 0, 9)));
  return 0;
}
EOF
liefert "global, lokal, F8, Closure 7/6, Lambda 6, Feld, Methodenfeld, Index, Struct-Rueckgabe lokal/global, verschachtelt" ind.lyx \
  "1234567|1234567|12345678|91234567|90123456|123456|1234567|81234567|1234567|1234|567|7654|321|12345670000009|rc=0|"

echo
echo "--- #2081: Lyx-Funktion als C-Callback (qsort) ---"
cat > "$TMP/m/cb.lyx" <<'EOF'
@cap(memory.mmap)
extern fn qsort(base: int64, n: int64, size: int64, cmp: int64) link "libc.so.6";
fn vergleiche(a: int64, b: int64): int64 {
    var x: int64 := peek64(a); var y: int64 := peek64(b);
    if (x < y) { return 0 - 1; } if (x > y) { return 1; } return 0;
}
fn main(): int64 {
    var a: int64 := mmap(0, 800, 3, 34, 0 - 1, 0);
    var i: int64 := 0;
    while (i < 100) { poke64(a + i * 8, ((i * 37) % 100) + 1); i := i + 1; }
    qsort(a, 100, 8, vergleiche as int64);
    var sortiert: int64 := 1;
    i := 0;
    while (i < 100) { if (peek64(a + i * 8) != i + 1) { sortiert := 0; } i := i + 1; }
    PrintInt(peek64(a)); PrintStr(" "); PrintInt(peek64(a + 99 * 8)); PrintStr(" "); PrintInt(sortiert); PrintStr("\n");
    return 0;
}
EOF
liefert "qsort mit Lyx-Vergleich: 1..100 sortiert" cb.lyx "1 100 1|rc=0|"

echo
echo "--- #2078: globales dynamisches Array ---"
cat > "$TMP/m/ga.lyx" <<'EOF'
unit main;
type F = fn(x: int64): int64;
fn f1(x: int64): int64 { return x + 1; }
var g: array<int64>;
var t: array<F>;
fn fill(n: int64): void { var i: int64 := 0; while (i < n) { push(g, i * 3); i := i + 1; } }
fn main(): int64 {
  PrintLn("leer=" + IntToStr(len(g)));
  push(g, 7); push(g, 8);
  PrintLn("len=" + IntToStr(len(g)) + " g0=" + IntToStr(g[0]) + " g1=" + IntToStr(g[1]));
  fill(3000);
  g[5] := 99;
  var p: int64 := pop(g);
  PrintLn("len=" + IntToStr(len(g)) + " g5=" + IntToStr(g[5]) + " letztes=" + IntToStr(g[3000]) + " pop=" + IntToStr(p));
  push(t, f1);
  var h: F := t[0];
  PrintLn("t=" + IntToStr(len(t)) + " h=" + IntToStr(h(41)));
  return 0;
}
EOF
# fill(3000) haengt 0,3,...,8997 an die zwei Elemente: 3002 Stueck; pop nimmt
# 8997, g[3000] ist 2998*3 = 8994. Das Wachsen ueber 1024 hinaus laeuft dabei
# zweimal durch munmap des alten Blocks.
liefert "push in main/Hilfsfunktion, Index lesen/schreiben, pop, Wachsen, array<F>" ga.lyx \
  "leer=0|len=2 g0=7 g1=8|len=3001 g5=99 letztes=8994 pop=8997|t=1 h=42|rc=0|"

cat > "$TMP/m/gf.lyx" <<'EOF'
unit main;
var fest: int64[3];
fn main(): int64 { push(fest, 1); return 0; }
EOF
if ( cd "$TMP/m" && timeout 120 "$LYXC" --std-path="$ROOT" gf.lyx -o bf ) >"$TMP/log" 2>&1; then
  nok "push auf globales [3]int64 uebersetzt (wuerde beim Wachsen den Datenbereich freigeben)"
elif grep -q "push/pop auf ein Array fester Groesse" "$TMP/log"; then ok "push auf globales [3]int64 abgewiesen"
else nok "push auf globales [3]int64: falsche Meldung: $(grep -m1 -i error "$TMP/log")"; fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
