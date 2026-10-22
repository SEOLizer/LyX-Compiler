#!/usr/bin/env bash
# tests/x86_register_locals_2114_test.sh — #2114: x86-64-Codegen.
#
# Bis 1.2.17D lag jedes Local im Rahmen, jede Operation lief ueber
# push/pop und `movabs`. Eine Rechenschleife war damit an die
# Store->Load-Weiterleitung gebunden (ChaCha20-Viertelrunde ~30 ns, gcc -O2
# ~6 ns). Jetzt:
#   A  Ganzzahl OP Konstante als Direktoperand (`and rax, imm`, `shl rax, 16`,
#      `& 0xFFFFFFFF` als `mov eax, eax`), ein einfaches Local rechts als
#      Speicher- bzw. Registeroperand — kein push/pop.
#   B  bis zu vier skalare int64-Locals je Funktion in r12..r15 (Gewicht nach
#      Schleifentiefe, deterministisch), im Prolog gesichert, im Epilog
#      zurueck. Ausgeschlossen: try, defer, Lambdas/innere Funktionen, asm,
#      `@x`, Debug-Information.
#
# Gemessen werden WERTE (auch die der ausgeschlossenen Faelle, deren
# Speichersemantik erhalten bleiben muss), der WEG (die Schleife greift nicht
# mehr auf ihre Rahmenslots zu) und die ABI (ein C-Aufrufer findet r12..r15
# unveraendert vor). Keine Zeitmessung — die ist auf belasteten Maschinen
# nicht stabil genug fuer einen Test.
set -uo pipefail
ulimit -c 0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
LYXCA="$(readlink -f "$LYXC")"   # absolut — die Tests wechseln das Verzeichnis
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

baue() {  # quelle ausgabe [optionen]
  local f="$1" o="$2"; shift 2
  ( cd "$ROOT" && timeout 240 "$LYXCA" --std-path="$ROOT" "$@" "$f" -o "$o" ) >"$o.log" 2>&1
}
pruefe() {  # name quelle soll [optionen]
  local n="$1" f="$2" soll="$3"; shift 3
  if ! baue "$f" "$TMP/p" "$@"; then nok "$n: uebersetzt nicht ($(grep -m1 -iE 'error|interner' "$TMP/p.log"))"; return; fi
  local aus rc
  aus="$(cd "$TMP" && timeout 30 ./p 2>&1 | tr '\n' '|')"; rc=${PIPESTATUS[0]}
  if [ "$aus" = "$soll" ] && [ "$rc" = 0 ]; then ok "$n: [$aus]"
  else nok "$n: [$aus] rc=$rc statt [$soll]"; fi
}

# --- Viertelrunde (Repro aus #2114, ohne Zeitmessung) ------------------------
cat > "$TMP/qr.lyx" <<'EOF'
con M32: int64 := 4294967295;
fn main(): int64 {
  var a: int64 := 1; var b: int64 := 2; var c: int64 := 3; var d: int64 := 4;
  var i: int64 := 0;
  while (i < 1000000) {
    a := (a + b) & M32; d := d ^ a; d := ((d << 16) | (d >> 16)) & M32;
    c := (c + d) & M32; b := b ^ c; b := ((b << 12) | (b >> 20)) & M32;
    a := (a + b) & M32; d := d ^ a; d := ((d << 8) | (d >> 24)) & M32;
    c := (c + d) & M32; b := b ^ c; b := ((b << 7) | (b >> 25)) & M32;
    i := i + 1;
  }
  PrintInt(a); Print(" "); PrintInt(b); Print(" "); PrintInt(c); Print(" "); PrintInt(d); Print("\n");
  return 0;
}
EOF
# Sollwert aus derselben Rechnung in C (gcc), sonst fest.
soll="1606624893 1349306049 2659432367 4157484571|"
if command -v gcc >/dev/null 2>&1; then
  cat > "$TMP/qr.c" <<'EOF'
#include <stdio.h>
#include <stdint.h>
int main(void){ uint64_t a=1,b=2,c=3,d=4; const uint64_t M=0xffffffffu;
for(long i=0;i<1000000;i++){ a=(a+b)&M; d^=a; d=((d<<16)|(d>>16))&M; c=(c+d)&M; b^=c; b=((b<<12)|(b>>20))&M;
a=(a+b)&M; d^=a; d=((d<<8)|(d>>24))&M; c=(c+d)&M; b^=c; b=((b<<7)|(b>>25))&M; }
printf("%lu %lu %lu %lu\n",a,b,c,d); return 0; }
EOF
  gcc -O0 "$TMP/qr.c" -o "$TMP/qrc" 2>/dev/null && soll="$("$TMP/qrc" | tr '\n' '|')"
fi
pruefe "Viertelrunde: Werte" "$TMP/qr.lyx" "$soll"
pruefe "Viertelrunde: Werte -O0" "$TMP/qr.lyx" "$soll" -O0

# Der Weg: zwischen der Schleifenschranke (1000000 = 0x0F4240) und dem
# Ruecksprung stehen keine Rahmenzugriffe [rbp-..] mehr fuer a, b, c, d —
# dafuer Registerzugriffe auf r12..r15.
if baue "$TMP/qr.lyx" "$TMP/qrw"; then
  weg="$(python3 -I - "$TMP/qrw" <<'PY'
import sys
b = open(sys.argv[1], 'rb').read()
s = b.find(bytes.fromhex('40420f00'))          # Schleifenschranke als imm32
e = b.find(b'\xe9', s)                          # erster jmp rel32 dahinter (Ruecksprung)
k = b[s:e]
slots = set()
for i in range(len(k) - 3):                     # mov/op mit [rbp+disp8]
    if k[i] == 0x48 and k[i+1] in (0x8b, 0x89, 0x03, 0x2b, 0x23, 0x0b, 0x33, 0x3b) and k[i+2] == 0x45:
        slots.add(k[i+3])
reg = sum(k.count(bytes([0x4c, 0x89, m])) for m in (0xe0, 0xe8, 0xf0, 0xf8)) \
    + sum(k.count(bytes([0x49, 0x89, m])) for m in (0xc4, 0xc5, 0xc6, 0xc7))
print(len(slots), 'slots', reg, 'reg')
PY
)"
  set -- $weg
  # Fuenf Kandidaten, vier Register: hoechstens EIN Local (die Zaehlvariable)
  # darf noch ueber den Rahmen laufen; bis 1.2.17D waren es alle fuenf und
  # kein einziger Registerzugriff.
  if [ "${1:-99}" -le 1 ] && [ "${3:-0}" -ge 30 ]; then ok "Weg: Schleife im Register [$weg]"
  else nok "Weg: [$weg] — erwartet <=1 Rahmenslot, >=30 Registerzugriffe"; fi
else nok "Weg: uebersetzt nicht"; fi

# --- Register ueber Aufrufe, Rekursion, vorzeitige Rueckkehr ---------------
cat > "$TMP/ruf.lyx" <<'EOF'
fn g(n: int64): int64 {
  var x: int64 := n; var y: int64 := 3; var z: int64 := 7; var w: int64 := 0;
  var k: int64 := 0;
  while (k < 10) { w := w + x * y - z; x := x + 1; k := k + 1; }
  return w;
}
fn fib(n: int64): int64 {
  var a: int64 := 0; var b: int64 := 1; var t: int64 := 0; var i: int64 := 0;
  if (n < 2) { return n; }
  while (i < n) { t := a + b; a := b; b := t; i := i + 1; if (i == 40) { return a; } }
  return a;
}
fn rek(n: int64): int64 {
  var s: int64 := n; var q: int64 := n * 2;
  if (n == 0) { return 0; }
  var r: int64 := rek(n - 1);
  return s + q + r;
}
fn main(): int64 {
  var p: int64 := 5; var q: int64 := 6; var r: int64 := 0; var j: int64 := 0;
  while (j < 3) { r := r + g(p) + q; p := p + 1; j := j + 1; }
  PrintInt(r); Print(" "); PrintInt(fib(30)); Print(" "); PrintInt(fib(50)); Print(" "); PrintInt(rek(20)); Print("\n");
  return 0;
}
EOF
# g(5)=10*15... gerechnet: w = sum_{x=n}^{n+9} (3x - 7) = 3*(10n+45) - 70
# g(5)=215, g(6)=245, g(7)=275 -> r = 735 + 18 = 753; fib(30)=832040;
# fib(50) bricht bei i==40 mit a=fib(40)=102334155 ab; rek(20)=3*210=630.
pruefe "Aufrufe, Rekursion, vorzeitige Rueckkehr" "$TMP/ruf.lyx" "753 832040 102334155 630|"

# --- Ausgeschlossene Faelle behalten die Speichersemantik --------------------
cat > "$TMP/aus.lyx" <<'EOF'
fn mitTry(): int64 {
  var x: int64 := 1; var y: int64 := 2;
  try {
    x := 10; y := 20;
    throw 5;
  } catch (e) {
    return x + y;
  }
  return 0;
}
fn mitAdresse(): int64 {
  var x: int64 := 1; var y: int64 := 2;
  var p: int64 := @x;
  poke64(p, 40);
  return x + y;
}
fn mitLambda(): int64 {
  var x: int64 := 3; var y: int64 := 4;
  var f := fn(): int64 { return x * 10; };
  return f() + y;
}
fn main(): int64 {
  PrintInt(mitTry()); Print(" "); PrintInt(mitAdresse()); Print(" "); PrintInt(mitLambda()); Print("\n");
  return 0;
}
EOF
pruefe "try/@x/Lambda behalten Speichersemantik" "$TMP/aus.lyx" "30 42 34|"

# --- ausgerollte, verschachtelte Schleifen mit Deklaration im Rumpf ----------
cat > "$TMP/roll.lyx" <<'EOF'
fn main(): int64 {
  var s: int64 := 0; var i: int64 := 0;
  while (i < 20) {
    var j: int64 := 0;
    while (j < 20) {
      var t: int64 := i * j;
      var u: int64 := t + 1;
      s := s + u;
      j := j + 1;
    }
    i := i + 1;
  }
  PrintInt(s); Print("\n");
  return 0;
}
EOF
# s = sum_{i,j<20} (i*j + 1) = 190*190 + 400 = 36500
pruefe "verschachtelt, ausgerollt (-O3)" "$TMP/roll.lyx" "36500|" -O3
pruefe "verschachtelt (-O0)" "$TMP/roll.lyx" "36500|" -O0

# --- ein int64-Local als Array (push/pop): Feldbasis aus dem Register ------
# Der erste Anlauf meldete hier laut "interner Fehler" (cg_arrPtrNachRcx las
# den Slot) — gefunden an tests/demo_s3_list.lyx in test-external.
cat > "$TMP/arr.lyx" <<'EOF'
fn main(): int64 {
  var a: int64 := 0; var i: int64 := 0; var s: int64 := 0;
  while (i < 5) { push(a, i * 3); i := i + 1; }
  while (i > 0) { s := s * 10 + pop(a); i := i - 1; }
  PrintInt(s); Print("\n");
  return 0;
}
EOF
pruefe "int64-Local als Array (push/pop)" "$TMP/arr.lyx" "129630|"

# --- ABI: ein C-Aufrufer findet r12..r15 unveraendert ------------------------
if command -v gcc >/dev/null 2>&1; then
  mkdir -p "$TMP/so"
  cat > "$TMP/so/lib.lyx" <<'EOF'
@export
fn summe(n: int64): int64 {
  var a: int64 := 0; var b: int64 := 1; var c: int64 := 2; var d: int64 := 3; var i: int64 := 0;
  while (i < n) { a := a + b; b := b + c; c := c + d; d := d + 1; i := i + 1; }
  return a + b + c + d;
}
EOF
  cat > "$TMP/so/ruf.c" <<'EOF'
#include <stdio.h>
#include <dlfcn.h>
long summe_pruefen(long (*f)(long), long n, long *verloren);
__asm__(".globl summe_pruefen\nsumme_pruefen:\n"
  " push %rbx\n push %r12\n push %r13\n push %r14\n push %r15\n"
  " mov %rdx, %rbx\n"
  " mov $0x1111, %r12\n mov $0x2222, %r13\n mov $0x3333, %r14\n mov $0x4444, %r15\n"
  " mov %rdi, %rax\n mov %rsi, %rdi\n call *%rax\n"
  " xor %rcx, %rcx\n"
  " cmp $0x1111, %r12\n je 1f\n or $1, %rcx\n1:\n"
  " cmp $0x2222, %r13\n je 2f\n or $2, %rcx\n2:\n"
  " cmp $0x3333, %r14\n je 3f\n or $4, %rcx\n3:\n"
  " cmp $0x4444, %r15\n je 4f\n or $8, %rcx\n4:\n"
  " mov %rcx, (%rbx)\n"
  " pop %r15\n pop %r14\n pop %r13\n pop %r12\n pop %rbx\n ret\n");
int main(int argc, char **argv) {
  void *h = dlopen(argv[1], RTLD_NOW);
  if (!h) { printf("dlopen: %s\n", dlerror()); return 1; }
  long (*f)(long) = (long (*)(long))dlsym(h, "summe");
  if (!f) { printf("dlsym\n"); return 1; }
  long verloren = -1;
  long r = summe_pruefen(f, 100, &verloren);
  printf("%ld verloren=%lx\n", r, verloren);
  return 0;
}
EOF
  if ( cd "$TMP/so" && timeout 240 "$LYXCA" --std-path="$ROOT" --shared lib.lyx -o lib.so ) >"$TMP/so/lib.log" 2>&1 \
     && gcc -O1 "$TMP/so/ruf.c" -o "$TMP/so/ruf" -ldl 2>"$TMP/so/cc.log"; then
    aus="$(timeout 30 "$TMP/so/ruf" "$TMP/so/lib.so" 2>&1)"
    # a = sum b, b = 1+2k..., gerechnet in C: siehe unten
    soll="$(python3 -c "
a,b,c,d=0,1,2,3
for i in range(100): a,b,c,d=a+b,b+c,c+d,d+1
print(a+b+c+d)") verloren=0"
    if [ "$aus" = "$soll" ]; then ok "C-Aufrufer: r12..r15 erhalten [$aus]"
    else nok "C-Aufrufer: [$aus] statt [$soll]"; fi
  else nok "C-Aufrufer: Bau scheitert ($(head -1 "$TMP/so/lib.log" "$TMP/so/cc.log" | grep -iE 'error' | head -1))"; fi
else
  echo "HINWEIS kein gcc — ABI-Pruefung gegen einen C-Aufrufer uebersprungen"
fi

# --- Stufe 2: Parameter im Register, auch Stapelparameter ---------------------
cat > "$TMP/par.lyx" <<'EOF'
fn mix(a: int64, b: int64, c: int64, d: int64, e: int64, f: int64, g: int64, h: int64): int64 {
  var i: int64 := 0;
  while (i < 50) { a := a + b * 2; h := h ^ a; g := g + h; i := i + 1; }
  return a + b + c + d + e + f + g + h;
}
fn tief(n: int64, acc: int64): int64 {
  if (n == 0) { return acc; }
  return tief(n - 1, acc + n);
}
fn main(): int64 {
  PrintInt(mix(1, 2, 3, 4, 5, 6, 7, 8)); Print(" "); PrintInt(tief(100, 0)); Print("\n");
  return 0;
}
EOF
# Sollwert in Python gerechnet (dieselbe Schleife)
psoll="$(python3 -c "
a,b,c,d,e,f,g,h=1,2,3,4,5,6,7,8
for i in range(50):
  a=a+b*2; h=h^a; g=g+h
print(a+b+c+d+e+f+g+h, 5050)" | tr ' ' ' ')|"
pruefe "Parameter im Register (8 Parameter, Rekursion)" "$TMP/par.lyx" "$psoll"
# Weg: in der Schleife von mix (Schranke 50 = cmp rax, 0x32) liegen die vier
# meistgenutzten Werte a, h, i, g in Registern — darunter die Parameter a
# (aus rdi) und g, h (Stapelparameter 7 und 8). Nur b laeuft noch ueber den
# Rahmen; bis Stufe 1 waren es alle vier Parameter.
if baue "$TMP/par.lyx" "$TMP/parw"; then
  pw="$(python3 -I - "$TMP/parw" <<'PY'
import sys
b = open(sys.argv[1], 'rb').read()
s = b.find(bytes.fromhex('4883f832'))
e = b.find(b'\xe9', s)
k = b[s:e]
slots = set()
for i in range(len(k) - 3):
    if k[i] == 0x48 and k[i+1] in (0x8b, 0x89, 0x03, 0x2b, 0x23, 0x0b, 0x33, 0x3b, 0x0f) and k[i+2] == 0x45:
        slots.add(k[i+3])
print(len(slots))
PY
)"
  [ "${pw:-9}" -le 1 ] && ok "Weg: Parameter im Register [$pw Rahmenslot(s) in der Schleife]" \
    || nok "Weg: Parameter — $pw Rahmenslots in der Schleife statt hoechstens 1"
else nok "Weg (Parameter): uebersetzt nicht"; fi

# --- Stufe 2: verschmolzene Bedingungen (alle Vergleiche, vorzeichenlos) ----
cat > "$TMP/cmp.lyx" <<'EOF'
fn zaehle(lo: int64, hi: int64): int64 {
  var n: int64 := 0; var i: int64 := lo;
  while (i < hi) { if (i == 3) { n := n + 100; } if (i != 4) { n := n + 1; } i := i + 1; }
  var j: int64 := 0;
  while (j <= 5) { if (j > 2) { n := n + 10; } if (j >= 5) { n := n + 1000; } j := j + 1; }
  return n;
}
fn main(): int64 {
  var u: uint64 := 0 - 1;           // 2^64-1: vorzeichenlos gross, vorzeichenbehaftet -1
  var z: uint64 := 5;
  var s: int64 := 0 - 1;
  if (u > z) { Print("u>z "); } else { Print("u<=z "); }
  if (s > 5) { Print("s>5 "); } else { Print("s<=5 "); }
  PrintInt(zaehle(0, 8)); Print("\n");
  return 0;
}
EOF
# zaehle: i=0..7: +1 ausser i==4 (7), +100 bei i==3 -> 107; j=0..5: j>2 -> 3*10, j>=5 -> 1000 -> 1137
pruefe "Bedingungen verschmolzen (signed/unsigned)" "$TMP/cmp.lyx" "u>z s<=5 1137|"

# --- Stufe 2: linker Operand in r11, Rueckfall bei Aufruf rechts ------------
cat > "$TMP/r11.lyx" <<'EOF'
fn f(x: int64): int64 { var q: int64 := x * 3; return q + 1; }
fn main(): int64 {
  var a: int64 := 7; var b: int64 := 5; var c: int64 := 3;
  var t: int64 := ((a << 4) | (b >> 1)) + ((a - b) * (c + 2)) - ((a ^ c) & (b | 8));
  var v: int64 := (a * 10) + f(b) * (c + f(a));
  PrintInt(t); Print(" "); PrintInt(v); Print("\n");
  return 0;
}
EOF
# t = (112|2) + 2*5 - (4 & 13) = 114 + 10 - 4 = 120; v = 70 + 16*(3+22) = 470
pruefe "linker Operand in r11, Aufruf rechts" "$TMP/r11.lyx" "120 470|"

# Weg: die Schleifenbedingung `i < 1000000` endet in einem jge (0F 8D) direkt
# hinter dem cmp, ohne setcc/movzx/test.
if baue "$TMP/qr.lyx" "$TMP/qrj"; then
  jw="$(python3 -I - "$TMP/qrj" <<'PY'
import sys
b = open(sys.argv[1], 'rb').read()
s = b.find(bytes.fromhex('40420f00'))
print('jcc' if b[s+4:s+6] == bytes.fromhex('0f8d') else 'setcc' if b[s+4] == 0x0f and (b[s+5] & 0xf0) == 0x90 else 'anders')
PY
)"
  [ "$jw" = jcc ] && ok "Weg: Bedingung als cmp; jge" || nok "Weg: Bedingung [$jw] statt jcc"
else nok "Weg (Bedingung): uebersetzt nicht"; fi

# --- Determinismus: zweimal uebersetzt, dasselbe Erzeugnis -------------------
if baue "$TMP/qr.lyx" "$TMP/d1" && baue "$TMP/qr.lyx" "$TMP/d2" && cmp -s "$TMP/d1" "$TMP/d2"; then
  ok "Determinismus: zwei Uebersetzungen bitgleich"
else nok "Determinismus: Erzeugnisse verschieden"; fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
