#!/usr/bin/env bash
# tests/ir_array_kopf_2262_test.sh — Arrays auf den IR-Zielen wie auf x86 (#2262, #2260).
#
# #2262: Auf x86 zeigt ein Array-Zeiger auf den {cap,len}-Kopf, die Elemente
# liegen ab +16. Die IR-Ziele (arm64, riscv, lyxos) liessen ihn bis 1.2.20H auf
# das ERSTE ELEMENT zeigen. Arrays, die der IR-Weg selbst anlegte, gingen in
# sich auf; jeder x86-artig angelegte Puffer (alloc + Kopf von Hand — so legt
# der Compiler selbst seine Tabellen an) wurde um zwei Elemente verschoben
# gelesen: `b[1]` lieferte 3 statt 22, `len(b)` faultete.
#
# #2260: `_exprTypeNode` kannte NK_INDEX nicht; `self.items[i].name` brach auf
# allen IR-Zielen mit #2134 ab. Struct-Elemente eines `Array<S>` liegen INLINE
# (x86 #1109) — `a[i]` ist dann die Elementadresse.
#
# Dazu lseek/pipe/truncate (IDs 228/231/232), die arm64 und riscv im
# Linux-Zweig fehlten (der Selbstbau liest seine Units mit lseek).
#
# Geprueft wird die WIRKUNG: jedes Programm liefert auf x86, arm64 und riscv
# dieselbe Ausgabe, und die Ausgabe ist die erwartete.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
. "$(dirname "$0")/lib/qemu.sh"   # #2048
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ulimit -c 0
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

ZIELE="x86"
[ -n "$QEMU_ARM64" ] && ZIELE="$ZIELE arm64" || echo "HINWEIS: Emulator fuer arm64 fehlt"
[ -n "$QEMU_RISCV64" ] && ZIELE="$ZIELE riscv" || echo "HINWEIS: Emulator fuer riscv fehlt"

printf 'abcdefgh' > "$TMP/stdin.dat"   # 8 Byte: lseek(0, 0, SEEK_END) == 8
fall() { # name erwartet [ziele]  (Quelle auf stdin)
  local name="$1" erw="$2" ziele="${3:-$ZIELE}"
  cat > "$TMP/$name.lyx"
  local z
  for z in $ziele; do
    local opt="" q=""
    [ "$z" = arm64 ] && { opt="--target=arm64"; q="$QEMU_ARM64"; }
    [ "$z" = riscv ] && { opt="--target=riscv"; q="$QEMU_RISCV64"; }
    if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" $opt "$TMP/$name.lyx" -o "$TMP/$name.$z" >"$TMP/$name.$z.log" 2>&1); then
      no "$name $z" "uebersetzt nicht: $(grep -m1 -iE 'error' "$TMP/$name.$z.log")"; continue
    fi
    local got
    got=$( cd "$TMP" && timeout 60 $q "$TMP/$name.$z" < "$TMP/stdin.dat" 2>&1 | tr '\n' ' ' ); got="${got% }"
    if [ "$got" = "$erw" ]; then ok "$name $z: $got"; else no "$name $z" "'$got' erwartet '$erw'"; fi
  done
}

# 1. Puffer x86-artig: Kopf {cap=8, len=3}, Elemente 11 22 33.
fall kopf_von_hand "22 3" <<'LYX'
import src.std.io;
import src.std.alloc;
fn main(): int64 {
  var p: int64 := alloc(64); poke64(p, 8); poke64(p+8, 3); poke64(p+16, 11); poke64(p+24, 22); poke64(p+32, 33);
  var b: Array<int64> := p;
  var x: int64 := b[1];
  PrintLn(x);
  var l: int64 := len(b);
  PrintLn(l);
  return 0;
}
LYX

# 2. Festes lokales Array, Literal, len, Index schreiben/lesen.
fall fest_und_literal "9 4 30 3 22" <<'LYX'
import src.std.io;
fn main(): int64 {
  var f: [4]int64;
  f[2] := 9;
  var a: int64 := f[2];
  PrintLn(a);
  var n: int64 := len(f);
  PrintLn(n);
  var l: Array<int64> := [10, 20, 30];
  var c: int64 := l[2];
  PrintLn(c);
  var m: int64 := len(l);
  PrintLn(m);
  l[1] := 22;
  var d: int64 := l[1];
  PrintLn(d);
  return 0;
}
LYX

# 3. Globales festes Array.
fall global_fest "5 7" <<'LYX'
import src.std.io;
var g: [6]int64;
fn main(): int64 {
  g[5] := 7;
  var n: int64 := len(g);
  var x: int64 := g[5];
  PrintLn(n - 1);
  PrintLn(x);
  return 0;
}
LYX

# 4. Tupel-Rueckgabe (Array-Literal als Zeiger).
fall tupel "6 42" <<'LYX'
import src.std.io;
fn zwei(a: int64): [int64, int64] { return (a * 2, 42); }
fn main(): int64 {
  var x, y := zwei(3);
  PrintLn(x);
  PrintLn(y);
  return 0;
}
LYX

# 5. #2260: Struct-Elemente inline — Local und Klassenfeld, lesen und schreiben.
fall struct_elemente "5 7 12" <<'LYX'
import src.std.io;
import src.std.alloc;
pub type Rec = struct {
  name: int64;
  age:  int64;
}
pub type Box = class {
  items: Array<Rec>;
  pub fn Setup() {
    var p: int64 := alloc(16 * 8 + 16);
    poke64(p, 8);
    poke64(p + 8, 2);
    self.items := p;
    self.items[0].name := 7;
    self.items[1].age := 12;
  }
  pub fn NameOf(i: int64): int64 { return self.items[i].name; }
  pub fn AgeOf(i: int64): int64 { return self.items[i].age; }
}
fn main(): int64 {
  var q: int64 := alloc(64); poke64(q, 2); poke64(q + 8, 1);
  var a: Array<Rec> := q;
  a[0].name := 5;
  var x: int64 := a[0].name;
  PrintLn(x);
  var g: Box := new Box();
  g.Setup();
  PrintLn(g.NameOf(0));
  PrintLn(g.AgeOf(1));
  return 0;
}
LYX

# 6. lseek (ID 228) auf allen Zielen — Wirkung: stdin ist eine 8-Byte-Datei,
#    lseek(0, 0, SEEK_END) liefert ihre Groesse.
fall lseek "8" <<'LYX'
import src.std.io;
fn main(): int64 {
  var s: int64 := lseek(0, 0, 2);
  PrintLn(s);
  return 0;
}
LYX

# 7. pipe/truncate (IDs 231/232) — die Namen ohne sys_-Praefix kennt nur der
#    IR-Weg (x86: sys_pipe/sys_truncate, die im IR-Weg auf die fest
#    geslotteten IDs 32/33 gehen, #2266). Wirkung: pipe liefert 0, lseek auf
#    der Pipe -ESPIPE (-29), truncate kuerzt eine echte Datei auf 3 Byte.
IRZ=""; for z in $ZIELE; do [ "$z" != x86 ] && IRZ="$IRZ $z"; done
if [ -n "$IRZ" ]; then
  printf 'abcdefgh' > "$TMP/kurz.dat"
  fall pipe_truncate "0 -29 0" "$IRZ" <<LYX
import src.std.io;
import src.std.alloc;
fn main(): int64 {
  var fds: int64 := alloc(16);
  var r: int64 := pipe(fds);
  PrintLn(r);
  var fd: int64 := peek32(fds);
  var s: int64 := lseek(fd, 0, 0);
  PrintLn(s);
  var t: int64 := truncate("$TMP/kurz.dat", 3);
  PrintLn(t);
  return 0;
}
LYX
  gr=$(stat -c %s "$TMP/kurz.dat")
  if [ "$gr" = 3 ]; then ok "truncate hat die Datei auf 3 Byte gekuerzt"; else no "truncate" "Datei hat $gr Byte"; fi
fi

echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
