#!/usr/bin/env bash
# tests/arm64_abi_reste_test.sh — #2149 und #2157: ABI-Reste der IR-Backends.
#
# Bis 1.2.16E:
#   (1) arm64: der Gleitkomma-Formatierer benutzte x19..x24 ohne sie zu
#       retten, main ueberschrieb x28 (argv, #2110) — beides callee-saved.
#   (2) arm64 --shared: exportierte Funktionen mit f64 hatten keine Huelle;
#       C uebergibt Gleitkomma in d0..d7, Lyx las x0..x7 — still falsch.
#   (3) android-arm64 mit extern fn verlangte /lib/ld-linux-aarch64.so.1 und
#       den glibc-Startweg (__libc_start_main, libc.so.6).
#   (4) Die Gleitkommamaske von `extern fn` kannte nur die Woerter f64/f32;
#       ein Alias (`type GLfloat = f32`) oder eine Einheit lief als Ganzzahl.
#   (6) xtensa: RRI8-Direktwerte > 255 wurden still gekuerzt, Konstanten
#       ausserhalb von 20 Bit still 0, Feldversaetze ueber 1020 Byte lasen 0.
#   #2157: Struct-Locals/-Kopien und feste Arrays auf dem IR-Weg holten je
#       Belegung ein eigenes mmap (eine Seite) und gaben es nie zurueck.
#       Dazu liegen die arm64-Modulvariablen jetzt auf einer eigenen Seite —
#       auf der letzten Codeseite kostete jeder Schreibzugriff unter qemu
#       ~55 µs.
#
# Die C-Seite wird ohne C-Compiler nachgestellt: ein Lader in Lyx (arm64,
# qemu) bildet die .so ab, und kleine Maschinencode-Thunks rufen die Exporte
# mit der AAPCS64-Konvention (Gleitkomma in d-Registern, Ergebnis aus d0,
# vorher gesetzte x19..x24/x28 werden danach verglichen).
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

baue() {  # ziel datei ausgabe [optionen]
  local t="$1" f="$2" o="$3"; shift 3
  ( cd "$ROOT" && timeout 240 "$LYXC" --std-path="$ROOT" --target=$t "$@" "$f" -o "$o" ) >"$o.log" 2>&1
}

# --- (1)(2) .so-Huelle und gerettete Register --------------------------------
mkdir -p "$TMP/w"
cat > "$TMP/lib.lyx" <<'LYX'
type Meter = f64;
@export
fn rechne(a: f64, b: int64): f64 { return a * 2.0 + (b as f64); }
@export
fn mischen(n: int64, x: f64, y: Meter, m: int64): f64 { return x + y + ((n * 10 + m) as f64); }
@export
fn ganz(a: int64, b: int64): int64 { return a * 10 + b; }
@export
fn fmt(a: f64): int64 { var s: pchar := FloatToStr(a); return StrLen(s); }
LYX
cat > "$TMP/lader.lyx" <<'LYX'
import std.alloc;
type T3 = fn(int64, int64, int64): int64;
type T5 = fn(int64, int64, int64, int64, int64): int64;
fn nameIst(p: int64, s: pchar): int64 {
  var i: int64 := 0;
  while (StrCharAt(s, i) != 0) {
    if (peek8(p + i) != StrCharAt(s, i)) { return 0; }
    i := i + 1;
  }
  if (peek8(p + i) != 0) { return 0; }
  return 1;
}
fn le16(p: int64): int64 { return peek8(p) + peek8(p + 1) * 256; }
fn le32(p: int64): int64 { return peek32(p) & 0xFFFFFFFF; }
var gBase: int64 := 0;
var gStr: int64 := 0;
var gSym: int64 := 0;
var gN: int64 := 0;
fn suche(name: pchar): int64 {
  var i: int64 := 1;
  while (i < gN) {
    var s: int64 := gSym + i * 24;
    if (le16(s + 6) != 0) {
      if (nameIst(gStr + le32(s), name) != 0) { return gBase + peek64(s + 8); }
    }
    i := i + 1;
  }
  return 0;
}
fn main(): int64 {
  var cap: int64 := 1048576;
  var f: int64 := alloc(cap);
  var fd: int64 := open("lib.so"c, 0, 0);
  if (fd < 0) { PrintLn("open"); return 2; }
  var n: int64 := 0;
  var r: int64 := read(fd, f, cap);
  while (r > 0) { n := n + r; r := read(fd, f + n, cap - n); }
  close(fd);
  var phoff: int64 := peek64(f + 32);
  var phnum: int64 := le16(f + 56);
  var span: int64 := 0;
  var dynVA: int64 := 0 - 1;
  var i: int64 := 0;
  while (i < phnum) {
    var ph: int64 := f + phoff + i * 56;
    var t: int64 := le32(ph);
    if (t == 1) { var e: int64 := peek64(ph + 16) + peek64(ph + 40); if (e > span) { span := e; } }
    if (t == 2) { dynVA := peek64(ph + 16); }
    i := i + 1;
  }
  gBase := mmap(0, span, 7, 34, 0 - 1, 0);
  i := 0;
  while (i < phnum) {
    var ph2: int64 := f + phoff + i * 56;
    if (le32(ph2) == 1) {
      var off: int64 := peek64(ph2 + 8);
      var va: int64 := peek64(ph2 + 16);
      var fs: int64 := peek64(ph2 + 32);
      var j: int64 := 0;
      while (j < fs) { poke8(gBase + va + j, peek8(f + off + j)); j := j + 1; }
    }
    i := i + 1;
  }
  var hash: int64 := 0;
  var d: int64 := gBase + dynVA;
  while (peek64(d) != 0) {
    var tag: int64 := peek64(d); var val: int64 := peek64(d + 8);
    if (tag == 4) { hash := gBase + val; }
    if (tag == 5) { gStr := gBase + val; }
    if (tag == 6) { gSym := gBase + val; }
    d := d + 16;
  }
  gN := le32(hash + 4);
  // C-Aufrufer als Maschinencode: Gleitkomma in d/s-Registern, Ergebnis aus d0.
  var th: int64 := mmap(0, 4096, 7, 34, 0 - 1, 0);
  // thunk1(abits, b, fn): d0 = a, x0 = b, blr fn, x0 = d0
  poke32(th + 0,  0xA9BF7BFD); poke32(th + 4,  0x910003FD);
  poke32(th + 8,  0x9E670000); poke32(th + 12, 0xAA0103E0);
  poke32(th + 16, 0xD63F0040); poke32(th + 20, 0xD2800000);
  poke32(th + 24, 0x9E660000); poke32(th + 28, 0xA8C17BFD);
  poke32(th + 32, 0xD65F03C0);
  // thunk2(n, m, xbits, ybits, fn): x0 = n, x1 = m, s0 = (f32) x, d1 = y, blr fn, x0 = d0
  var t2: int64 := th + 64;
  poke32(t2 + 0,  0xA9BF7BFD); poke32(t2 + 4,  0x910003FD);
  poke32(t2 + 8,  0x9E670040); poke32(t2 + 12, 0xD503201F);
  poke32(t2 + 16, 0x9E670061); poke32(t2 + 20, 0xD63F0080);
  poke32(t2 + 24, 0xD2800000); poke32(t2 + 28, 0x9E660000);
  poke32(t2 + 32, 0xA8C17BFD); poke32(t2 + 36, 0xD65F03C0);
  // thunk3(abits, fn, 0): setzt x19..x24/x28, ruft fn(d0 = a), liefert 0,
  // wenn alle sieben danach noch ihren Wert tragen (sonst die Abweichung).
  var t3: int64 := th + 128;
  poke32(t3 + 0, 0xA9BF7BFD);
  poke32(t3 + 4, 0x910003FD);
  poke32(t3 + 8, 0xA9BC53F3);
  poke32(t3 + 12, 0xA9015BF5);
  poke32(t3 + 16, 0xA90263F7);
  poke32(t3 + 20, 0xF9001BFC);
  poke32(t3 + 24, 0xD2822333);
  poke32(t3 + 28, 0xD2844414);
  poke32(t3 + 32, 0xD2866635);
  poke32(t3 + 36, 0xD2888856);
  poke32(t3 + 40, 0xD28AAA77);
  poke32(t3 + 44, 0xD28CCC98);
  poke32(t3 + 48, 0xD285051C);
  poke32(t3 + 52, 0x9E670000);
  poke32(t3 + 56, 0xD63F0020);
  poke32(t3 + 60, 0xD2800000);
  poke32(t3 + 64, 0xD2822329);
  poke32(t3 + 68, 0xCA09026A);
  poke32(t3 + 72, 0xAA0A0000);
  poke32(t3 + 76, 0xD2844409);
  poke32(t3 + 80, 0xCA09028A);
  poke32(t3 + 84, 0xAA0A0000);
  poke32(t3 + 88, 0xD2866629);
  poke32(t3 + 92, 0xCA0902AA);
  poke32(t3 + 96, 0xAA0A0000);
  poke32(t3 + 100, 0xD2888849);
  poke32(t3 + 104, 0xCA0902CA);
  poke32(t3 + 108, 0xAA0A0000);
  poke32(t3 + 112, 0xD28AAA69);
  poke32(t3 + 116, 0xCA0902EA);
  poke32(t3 + 120, 0xAA0A0000);
  poke32(t3 + 124, 0xD28CCC89);
  poke32(t3 + 128, 0xCA09030A);
  poke32(t3 + 132, 0xAA0A0000);
  poke32(t3 + 136, 0xD2850509);
  poke32(t3 + 140, 0xCA09038A);
  poke32(t3 + 144, 0xAA0A0000);
  poke32(t3 + 148, 0xF9401BFC);
  poke32(t3 + 152, 0xA94263F7);
  poke32(t3 + 156, 0xA9415BF5);
  poke32(t3 + 160, 0xA8C453F3);
  poke32(t3 + 164, 0xA8C17BFD);
  poke32(t3 + 168, 0xD65F03C0);

  var k3: T3 := t3 as T3;
  var k1: T3 := th as T3;
  var k2: T5 := t2 as T5;
  var fR: int64 := suche("rechne"c);
  var fM: int64 := suche("mischen"c);
  var fG: T3 := suche("ganz"c) as T3;
  if (fR == 0 || fM == 0) { PrintLn("Symbol fehlt"); return 5; }
  var e1: int64 := k1(0x3FF8000000000000, 3, fR);
  var e2: int64 := k2(4, 2, 0x3FE0000000000000, 0x4024800000000000, fM);
  var e3: int64 := fG(4, 2, 0);
  var fF: int64 := suche("fmt"c);
  var e4: int64 := k3(0x4004000000000000, fF, 0);
  // 1.5 * 2 + 3 = 6.0; 0.5 + 10.25 + 42 = 52.75 — als IEEE-Bits verglichen
  if (e1 == 0x4018000000000000) { Print("6.0 "); } else { Print("e1="); PrintInt(e1); Print(" "); }
  if (e2 == 0x404A600000000000) { Print("52.75 "); } else { Print("e2="); PrintInt(e2); Print(" "); }
  PrintInt(e3); Print(" ");
  if (e4 == 0) { Print("gerettet"); } else { Print("x19-x28 veraendert"); }
  Print("\n");
  return 0;
}
LYX
if baue arm64 "$TMP/lib.lyx" "$TMP/w/lib.so" --shared && baue arm64 "$TMP/lader.lyx" "$TMP/w/lader"; then
  aus="$( (cd "$TMP/w" && timeout 60 "$QEMU_ARM64" ./lader 2>&1) | tr '\n' '|')"
  # rechne(1.5, 3) = 6.0; mischen(4, 0.5, 10.25, 2) = 52.75 (Ganzzahl und
  # Gleitkomma verschraenkt, y ueber einen Alias); ganz ohne Huelle;
  # fmt formatiert und muss x19..x24 zuruecklassen.
  if [ "$aus" = "6.0 52.75 42 gerettet|" ]; then ok "arm64 .so: Huelle und gerettete Register [$aus]"
  else nok "arm64 .so: [$aus] statt [6.0 52.75 42 gerettet|]"; fi
else nok "arm64 .so/Lader uebersetzt nicht: $(grep -m1 -iE 'error|lyxc:' "$TMP/w/lib.so.log" "$TMP/w/lader.log")"; fi

# f32 an der Schnittstelle: laut abgewiesen (#2160)
printf 'type F = f32;\n@export\nfn g(a: F): int64 { return 1; }\n' > "$TMP/f32.lyx"
if baue arm64 "$TMP/f32.lyx" "$TMP/f32.so" --shared; then nok "arm64 .so mit f32: uebersetzt"
elif grep -q "f32 an der C-Schnittstelle" "$TMP/f32.so.log"; then ok "arm64 .so mit f32: laut abgewiesen"
else nok "arm64 .so mit f32: $(grep -m1 -i error "$TMP/f32.so.log")"; fi

# main rettet x28 im Rahmen: STUR x28, [x29, #…] unmittelbar vor MOV x28, x1
printf 'fn main(): int64 { return GetArgC() - 1; }\n' > "$TMP/m.lyx"
if baue arm64 "$TMP/m.lyx" "$TMP/m"; then
  if python3 - "$TMP/m" <<'PY'
import sys, struct
d = open(sys.argv[1], 'rb').read()
w = [struct.unpack_from('<I', d, i)[0] for i in range(0, len(d) - 3, 4)]
for i in range(1, len(w)):
    if w[i] == 0xAA0103FC:
        p = w[i - 1]
        if (p & 0xFFE00C00) == 0xF8000000 and (p & 31) == 28 and ((p >> 5) & 31) == 29:
            sys.exit(0)
sys.exit(1)
PY
  then ok "arm64 main: x28 vor dem Setzen gerettet"; else nok "arm64 main: keine Sicherung von x28"; fi
  if (cd "$TMP" && timeout 30 "$QEMU_ARM64" ./m a b >/dev/null 2>&1; [ $? -eq 2 ]); then ok "arm64 main: GetArgC weiter richtig"; else nok "arm64 main: GetArgC falsch"; fi
else nok "arm64 main uebersetzt nicht"; fi

# --- (3) android-arm64 mit extern fn: Bionic-Lader -------------------------------
printf '@cap(system.ffi)\nextern fn getpid(): int32 link "libc.so";\nfn main(): int64 { var p: int64 := getpid(); return 0; }\n' > "$TMP/and.lyx"
if baue android-arm64 "$TMP/and.lyx" "$TMP/and"; then
  interp="$(readelf -lW "$TMP/and" 2>/dev/null | grep -o '\[Requesting program interpreter: [^]]*\]')"
  need="$(readelf -dW "$TMP/and" 2>/dev/null | grep NEEDED | tr -s ' ' | tr '\n' ';')"
  syms="$(readelf --dyn-syms -W "$TMP/and" 2>/dev/null | grep -c __libc_start_main)"
  if echo "$interp" | grep -q "/system/bin/linker64" && ! echo "$need" | grep -q "libc.so.6" && [ "$syms" = 0 ]; then
    ok "android-arm64: linker64, kein libc.so.6, kein __libc_start_main"
  else nok "android-arm64: interp=[$interp] needed=[$need] __libc_start_main=$syms"; fi
else nok "android-arm64 uebersetzt nicht: $(grep -m1 -iE 'error' "$TMP/and.log")"; fi
# Gegenseite: arm64-Linux behaelt den glibc-Lader
if baue arm64 "$TMP/and.lyx" "$TMP/lin"; then
  if readelf -lW "$TMP/lin" 2>/dev/null | grep -q "ld-linux-aarch64.so.1"; then ok "arm64-Linux: weiter ld-linux-aarch64"
  else nok "arm64-Linux: Lader geaendert"; fi
else nok "arm64-Linux uebersetzt nicht"; fi

# --- (4) Gleitkommamaske ueber Alias und Einheit (x86, libm) ------------------
cat > "$TMP/alias.lyx" <<'LYX'
type D = f64;
type E = D;
@cap(system.ffi)
extern fn sqrt(x: E): E link "libm.so.6";
@cap(system.ffi)
extern fn pow(x: f64, y: D): f64 link "libm.so.6";
fn main(): int64 {
  var w: f64 := sqrt(2.25);
  var p: f64 := pow(2.0, 10.0);
  PrintInt((w * 100.0) as int64); Print(" "); PrintInt(p as int64); Print("\n");
  return 0;
}
LYX
if baue linux "$TMP/alias.lyx" "$TMP/alias"; then
  aus="$(cd "$TMP" && timeout 30 ./alias 2>&1 | tr '\n' '|')"
  if [ "$aus" = "150 1024|" ]; then ok "extern fn mit Gleitkomma-Alias: [$aus]"; else nok "extern fn mit Gleitkomma-Alias: [$aus] statt [150 1024|]"; fi
else nok "alias.lyx uebersetzt nicht: $(grep -m1 -i error "$TMP/alias.log")"; fi

# --- (6) xtensa: grosse Konstanten und ferne Felder ------------------------------
# Bis 1.2.16E wurde eine Konstante ausserhalb von 20 Bit still 0. Gemessen am
# Rueckgabewert unter qemu-xtensa (Huelle aus tests/lib/xtensa_huelle.py).
if [ -n "${QEMU_XTENSA:-}" ]; then
  xt() {  # name quelle soll-rc
    printf '%s\n' "$2" > "$TMP/xt.lyx"; rm -f "$TMP/xt.elf" "$TMP/xt.run"
    if ! baue esp32 "$TMP/xt.lyx" "$TMP/xt.elf"; then nok "xtensa $1: uebersetzt nicht ($(grep -m1 -i error "$TMP/xt.elf.log"))"; return; fi
    if ! python3 "$ROOT/tests/lib/xtensa_huelle.py" "$TMP/xt.elf" "$TMP/xt.run" >/dev/null 2>&1; then nok "xtensa $1: Huelle"; return; fi
    timeout 60 "$QEMU_XTENSA" "$TMP/xt.run" >/dev/null 2>&1; local rc=$?
    [ "$rc" = "$3" ] && ok "xtensa $1: rc=$rc" || nok "xtensa $1: rc=$rc statt $3"
  }
  xt "Konstante 1193046" 'fn main(): int64 { var x: int64 := 1193046; return x - 1193000; }' 46
  xt "Konstante -1193046" 'fn main(): int64 { var x: int64 := 0 - 1193046; return x + 1193100; }' 54
  xt "Konstante 0x12345678" 'fn main(): int64 { var x: int64 := 0x12345678; return (x >> 24) & 255; }' 18
  # Gegenseite: kleine Konstante wie gehabt
  xt "Konstante 2000" 'fn main(): int64 { var x: int64 := 2000; return x - 1958; }' 42
else
  nok "Emulator fuer xtensa fehlt — xtensa NICHT gemessen"
fi
# Ferner Feldversatz (> 1020 Byte): bis 1.2.16E las er still 0, der Store
# entfiel. Hier am Uebersetzen gemessen — ein freistehendes Ziel hat kein
# alloc, die Struktur kommt per `ref`.
cat > "$TMP/x2.lyx" <<'LYX'
type Gross = struct { a: [200]int64; z: int64; };
fn setz(ref g: Gross) { g.z := 7; }
fn hol(ref g: Gross): int64 { return g.z; }
fn main(): int64 { return 0; }
LYX
if baue esp32 "$TMP/x2.lyx" "$TMP/x2"; then ok "xtensa: Feld ueber 1020 Byte uebersetzt"
else nok "xtensa: Feld ueber 1020 Byte: $(grep -m1 -i error "$TMP/x2.log")"; fi

# --- #2157: Arena statt mmap je Belegung -------------------------------------------
cat > "$TMP/arena.lyx" <<'LYX'
type Pt = struct { x: int64; y: int64; };
fn summe(p: Pt): int64 { var q: Pt; q.x := p.x; q.y := p.y + 1; var a: [4]int64; a[0] := q.y; return q.x + a[0]; }
fn main(): int64 {
  var p: Pt; p.x := 1; p.y := 2;
  var s: int64 := 0;
  var i: int64 := 0;
  while (i < 1000000) { s := s + summe(p); i := i + 1; }
  PrintInt(s); Print(" "); PrintInt(p.y); Print("\n");
  return 0;
}
LYX
for t in arm64 riscv; do
  if baue $t "$TMP/arena.lyx" "$TMP/ar_$t"; then
    q="$QEMU_ARM64"; [ $t = riscv ] && q="$QEMU_RISCV64"
    # drei Belegungen je Aufruf (Kopie, q, a): mit mmap je Belegung waeren
    # das 12 GB, unter dem Deckel von 1,5 GB scheitert es.
    aus="$( (cd "$TMP" && ulimit -v 1500000; timeout 60 "$q" ./ar_$t) 2>&1 | tr '\n' '|')"
    if [ "$aus" = "4000000 2|" ]; then ok "#2157 Arena [$t]: [$aus]"; else nok "#2157 Arena [$t]: [$aus] statt [4000000 2|]"; fi
  else nok "#2157 [$t] uebersetzt nicht"; fi
done

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
