#!/usr/bin/env bash
# tests/android_shared_lib_test.sh — #2117, #2118, #2119: eine .so fuer
# android-arm64, die bionic laedt, und laute Ablehnung, wo es keine gibt.
#
# Bis 1.2.14B war keine von lyxc erzeugte Android-.so ladbar:
#   - keine Section-Header (bionic: "has no section headers", immer fatal);
#   - Adressplaetze fuer Modulvariablen und externe Aufrufe IM CODE, per
#     Relocation umgeschrieben (Text-Relocation ohne DT_TEXTREL — bionic
#     lehnt sie ab API 23 ab); der Schreibzugriff trug dazu den INDEX der
#     Variable als Addend, schrieb also in den ELF-Kopf;
#   - die Exportwerte zeigten 0x1000 zu tief (in den ELF-Kopf);
#   - `extern fn` stand als Export in der Tabelle, `@export` fehlte ganz,
#     und mit einem extern davor rutschten alle Adressen eine Funktion weiter;
#   - Segmente auf 4 KiB, ohne PT_GNU_STACK und PT_GNU_RELRO (#2119);
#   - android-x86_64 und x86-64 --shared schrieben still ein Platzhalter-
#     programm (main -> 42) bei rc 0 (#2118).
#   - #2123: eine Modulvariable mit Anfangswert zur Laufzeit (Aufruf,
#     Zeichenkette) blieb 0 — in einer .so gibt es kein main, das sie setzt.
#     Jetzt ruft der Lader __lyx_modinit ueber DT_INIT_ARRAY; der Eintrag
#     traegt eine R_AARCH64_RELATIVE und liegt unter RELRO.
#
# Gemessen wird zweierlei: die Ladebedingungen von bionic (linker_phdr.cpp)
# am ERZEUGNIS, und die WIRKUNG — ein kleiner Lader (Lyx, arm64, qemu) bildet
# die .so ab, loest die GOT-Eintraege auf und ruft die Exporte; geprueft
# werden die Werte, die dabei durch Modulvariablen, `@x` und einen externen
# Aufruf laufen.
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

if [ -z "$QEMU_ARM64" ]; then echo "FAIL qemu fuer arm64 fehlt — NICHT gemessen"; exit 1; fi

baue() {  # quelle, ziel, ausgabe, [extra]
  ( cd "$ROOT" && timeout 240 "$LYXC" --std-path="$ROOT" "$1" --target="$2" ${4:-} -o "$3" ) >"$TMP/bl.log" 2>&1
}

# Ladebedingungen am Erzeugnis. Ausgabe: eine Zeile je Verstoss, sonst nichts.
cat > "$TMP/pruef.py" <<'EOF'
import struct, sys
d = open(sys.argv[1], 'rb').read()
want = sys.argv[2:]
err = []
if d[:4] != b'\x7fELF' or d[4] != 2: print('kein ELF64'); sys.exit(0)
e_type, e_machine = struct.unpack_from('<HH', d, 16)
e_phoff, e_shoff = struct.unpack_from('<QQ', d, 32)
phent, phnum, shent, shnum, shstrndx = struct.unpack_from('<HHHHH', d, 54)
if e_type != 3: err.append('e_type %d statt ET_DYN' % e_type)
if e_machine != 183: err.append('e_machine %d statt 183' % e_machine)
ph = [struct.unpack_from('<IIQQQQQQ', d, e_phoff + i * phent) for i in range(phnum)]
loads = [p for p in ph if p[0] == 1]
dyn = [p for p in ph if p[0] == 2]
if shnum == 0: err.append('keine Section-Header')
if shent != 64: err.append('e_shentsize %d' % shent)
if shstrndx == 0 or shstrndx >= max(shnum, 1): err.append('e_shstrndx %d' % shstrndx)
sh = [struct.unpack_from('<IIQQQQIIQQ', d, e_shoff + i * 64) for i in range(shnum)] if shent == 64 else []
if sh and sh[shstrndx][1] != 3: err.append('e_shstrndx zeigt nicht auf SHT_STRTAB')
ds = [s for s in sh if s[1] == 6]
if not ds: err.append('keine SHT_DYNAMIC')
elif not dyn or ds[0][4] != dyn[0][2] or ds[0][5] != dyn[0][5]: err.append('SHT_DYNAMIC != PT_DYNAMIC')
elif sh[ds[0][6]][1] != 3: err.append('SHT_DYNAMIC.sh_link nicht SHT_STRTAB')
for p in loads:
    if p[7] < 0x4000: err.append('LOAD p_align %#x < 16 KiB' % p[7])
    if p[2] % p[7] != p[3] % p[7]: err.append('LOAD offset/vaddr nicht kongruent')
gs = [p for p in ph if p[0] == 0x6474E551]
if not gs: err.append('kein PT_GNU_STACK')
elif gs[0][1] & 1: err.append('PT_GNU_STACK ausfuehrbar')
rr = [p for p in ph if p[0] == 0x6474E552]
if not rr: err.append('kein PT_GNU_RELRO')
elif dyn and not (rr[0][3] <= dyn[0][3] and dyn[0][3] + dyn[0][5] <= rr[0][3] + rr[0][5]): err.append('RELRO deckt .dynamic nicht')
def v2o(v):
    for p in loads:
        if p[3] <= v < p[3] + p[5]: return v - p[3] + p[2]
    return None
tags = {}; o = dyn[0][2] if dyn else None
while o is not None:
    t, v = struct.unpack_from('<qQ', d, o); o += 16
    if t == 0: break
    tags.setdefault(t, []).append(v)
if 22 in tags: err.append('DT_TEXTREL')
xl = [p for p in loads if p[1] & 1]
if 7 in tags:
    ra, rs = v2o(tags[7][0]), tags[8][0]
    for i in range(0, rs, 24):
        off, = struct.unpack_from('<Q', d, ra + i)
        if any(p[3] <= off < p[3] + p[5] for p in xl): err.append('Text-Relocation bei %#x' % off)
text = [s for s in sh if s[1] == 1 and s[2] & 4]
exp = {}
if 4 in tags and 5 in tags and 6 in tags:
    n = struct.unpack_from('<I', d, v2o(tags[4][0]) + 4)[0]
    so, st = v2o(tags[6][0]), v2o(tags[5][0])
    for i in range(1, n):
        nm, info, _, shx, val, _ = struct.unpack_from('<IBBHQQ', d, so + i * 24)
        if shx != 0:
            name = d[st + nm:d.index(b'\0', st + nm)].decode()
            exp[name] = val
            if not text or not (text[0][3] <= val < text[0][3] + text[0][5]): err.append('Export %s ausserhalb .text (%#x)' % (name, val))
else: err.append('DT_HASH/STRTAB/SYMTAB fehlt')
# #2123: .init_array — geprueft, wo es eins gibt; ob es eins geben MUSS,
# sagt der Aufrufer ('+init').
if 25 in tags:
    ia, isz = tags[25][0], (tags.get(27) or [0])[0]
    if isz == 0 or isz % 8: err.append('DT_INIT_ARRAYSZ %d' % isz)
    rw = [p for p in loads if p[1] & 2]
    if not any(p[3] <= ia and ia + isz <= p[3] + p[5] for p in rw): err.append('.init_array nicht im RW-Segment')
    if not rr or not (rr[0][3] <= ia and ia + isz <= rr[0][3] + rr[0][5]): err.append('.init_array nicht unter RELRO')
    if not [s for s in sh if s[1] == 14 and s[3] == ia and s[5] == isz]: err.append('keine SHT_INIT_ARRAY auf DT_INIT_ARRAY')
    rel = {}
    if 7 in tags:
        ra, rs = v2o(tags[7][0]), tags[8][0]
        for i in range(0, rs, 24):
            off, info, add = struct.unpack_from('<QQq', d, ra + i)
            rel[off] = (info, add)
    for k in range(0, isz, 8):
        r = rel.get(ia + k)
        if r is None or r[0] != 1027: err.append('Eintrag %#x ohne R_AARCH64_RELATIVE' % (ia + k))
        elif not text or not (text[0][3] <= r[1] < text[0][3] + text[0][5]): err.append('INIT_ARRAY-Ziel ausserhalb .text (%#x)' % r[1])
elif '+init' in want: err.append('kein DT_INIT_ARRAY')
for w in want:
    if w == '+init': continue
    if w.startswith('-'):
        if w[1:] in exp: err.append('%s darf nicht exportiert sein' % w[1:])
    elif w not in exp: err.append('Export fehlt: %s' % w)
if len(set(exp.values())) != len(exp): err.append('zwei Exporte auf derselben Adresse')
for e in err: print(e)
EOF
pruefe_so() {  # name, so, symbole...
  local n="$1" so="$2"; shift 2
  local v; v="$(python3 -I "$TMP/pruef.py" "$so" "$@" 2>&1)"
  if [ -z "$v" ]; then ok "$n: Ladebedingungen erfuellt"
  else nok "$n: $(echo "$v" | tr '\n' ';')"; fi
}

# --- 1. Das Beispiel aus den Issues ---
if baue "$ROOT/examples/android/jni_native_add.lyx" android-arm64 "$TMP/add.so" --shared; then
  pruefe_so "jni_native_add" "$TMP/add.so" Java_com_example_MyClass_nativeAdd Java_com_example_MyClass_nativeMul Java_com_example_MyClass_nativeDouble
else nok "jni_native_add uebersetzt nicht ($(grep -m1 -i error "$TMP/bl.log"))"; fi

# --- 2. Modulvariablen, @x, extern, @export; geladen und gerufen ---
cat > "$TMP/lib.lyx" <<'EOF'
@cap(system.exit)
extern fn hostcb(x: int64): int64 link "libhost.so";
var zaehler: int64 := 40;
var zweite: int64 := 7;
fn setz(p: int64, w: int64) { poke64(p, w); }
@jni(class="t.K", method="inc")
fn inc(env: int64, thiz: int64, a: int64): int64 {
  zaehler := zaehler + a;
  return zaehler * 100 + zweite;
}
@jni(class="t.K", method="rueck")
fn rueck(env: int64, thiz: int64, a: int64): int64 {
  return hostcb(a) + 1;
}
@export
fn adresse(a: int64, b: int64, c: int64): int64 {
  var v: int64 := 0;
  setz(@v, c);
  setz(@zweite, c + 1);
  return v + zweite;
}
// #2123: Anfangswerte zur Laufzeit — ein Aufruf und eine Zeichenkette.
fn basis(): int64 { return 30; }
var lauf: int64 := basis() + 12;
var txt: pchar := "hallo";
@export
fn wert(a: int64, b: int64, c: int64): int64 {
  if ((txt as int64) == 0) { return lauf * 1000; }
  return lauf * 1000 + peek8((txt as int64) + 1);
}
EOF
cat > "$TMP/lader.lyx" <<'EOF'
import std.io;
type J3 = fn(int64, int64, int64): int64;
type J0 = fn(): int64;
var hostGerufen: int64 := 0;
fn hostcb(x: int64): int64 { hostGerufen := hostGerufen + 1; return x * 3; }
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
  // RWX: der Lader schreibt die Segmente selbst hinein (#2122: mmap traegt
  // seit 1.2.14C alle sechs Argumente).
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
  var rela: int64 := 0; var relasz: int64 := 0; var hash: int64 := 0;
  var initArr: int64 := 0; var initSz: int64 := 0;
  var d: int64 := gBase + dynVA;
  while (peek64(d) != 0) {
    var tag: int64 := peek64(d); var val: int64 := peek64(d + 8);
    if (tag == 4) { hash := gBase + val; }
    if (tag == 5) { gStr := gBase + val; }
    if (tag == 6) { gSym := gBase + val; }
    if (tag == 7) { rela := gBase + val; }
    if (tag == 8) { relasz := val; }
    if (tag == 25) { initArr := gBase + val; }
    if (tag == 27) { initSz := val; }
    d := d + 16;
  }
  gN := le32(hash + 4);
  var k: int64 := 0;
  while (k < relasz) {
    var re: int64 := rela + k;
    var info: int64 := peek64(re + 8);
    if ((info & 0xFFFFFFFF) == 1027) {
      // #2123: R_AARCH64_RELATIVE — Ladebasis + Addend, ohne Symbol.
      poke64(gBase + peek64(re), gBase + peek64(re + 16));
    } else {
      if ((info & 0xFFFFFFFF) != 1025) { PrintLn("fremder Relocation-Typ"); return 3; }
      if (nameIst(gStr + le32(gSym + (info >> 32) * 24), "hostcb"c) == 0) { PrintLn("fremdes Symbol"); return 4; }
      poke64(gBase + peek64(re), hostcb as int64);
    }
    k := k + 24;
  }
  // #2123: DT_INIT_ARRAY wie bionic (call_array): nach dem Relozieren, in
  // Reihenfolge. Gezaehlt, damit ein fehlender Eintrag sichtbar wird.
  var nInit: int64 := 0;
  k := 0;
  while (k < initSz) {
    var fI: J0 := peek64(initArr + k) as J0;
    // Ergebnis zuweisen: als blosse Anweisung entfaellt der Aufruf eines
    // lokalen Funktionszeigers auf dem IR-Weg (eigener Defekt, gefunden bei
    // #2123) — dieser Lader laeuft selbst auf arm64.
    var rI: int64 := fI();
    nInit := nInit + 1;
    k := k + 8;
  }
  var fInc: J3 := suche("Java_t_K_inc"c) as J3;
  var fRueck: J3 := suche("Java_t_K_rueck"c) as J3;
  var fAdr: J3 := suche("adresse"c) as J3;
  var fWert: J3 := suche("wert"c) as J3;
  if ((fInc as int64) == 0 || (fRueck as int64) == 0 || (fAdr as int64) == 0 || (fWert as int64) == 0) { PrintLn("Symbol fehlt"); return 5; }
  PrintLn(IntToStr(fInc(0, 0, 2)));
  PrintLn(IntToStr(fInc(0, 0, 3)));
  PrintLn(IntToStr(fRueck(0, 0, 14)));
  PrintLn(IntToStr(hostGerufen));
  PrintLn(IntToStr(fAdr(0, 0, 20)));
  PrintLn(IntToStr(fInc(0, 0, 0)));
  PrintLn(IntToStr(nInit));
  PrintLn(IntToStr(fWert(0, 0, 0)));
  return 0;
}
EOF
mkdir -p "$TMP/w"
if baue "$TMP/lib.lyx" android-arm64 "$TMP/w/lib.so" --shared; then
  pruefe_so "Modulvariablen/extern/@export" "$TMP/w/lib.so" Java_t_K_inc Java_t_K_rueck adresse wert -hostcb -__lyx_modinit -basis +init
  if baue "$TMP/lader.lyx" arm64 "$TMP/w/lader"; then
    aus="$( (cd "$TMP/w" && timeout 30 "$QEMU_ARM64" ./lader 2>&1) | tr '\n' '|')"
    # inc(2): 42*100+7; inc(3): 45*100+7; rueck(14): hostcb(14)+1 = 43, einmal
    # gerufen; adresse(20): v=20 ueber @v, zweite=21 ueber @zweite -> 41;
    # inc(0): der Schreibzugriff auf `zweite` muss angekommen sein -> 4521.
    # #2123: genau ein INIT_ARRAY-Eintrag; wert(): lauf = basis()+12 = 42,
    # txt[1] = 'a' (97) -> 42097. Ohne Anfangswerte stuende hier 0.
    if [ "$aus" = "4207|4507|43|1|41|4521|1|42097|" ]; then ok "geladen und gerufen: [$aus]"
    else nok "geladen und gerufen: [$aus] statt [4207|4507|43|1|41|4521|1|42097|]"; fi
  else nok "Lader uebersetzt nicht ($(grep -m1 -iE '^lyxc:|error' "$TMP/bl.log"))"; fi
else nok "lib.lyx uebersetzt nicht ($(grep -m1 -i error "$TMP/bl.log"))"; fi

# --- 3. arm64-Linux --shared geht durch denselben Writer ---
if baue "$ROOT/examples/android/jni_native_add.lyx" arm64 "$TMP/add64.so" --shared; then
  pruefe_so "arm64 --shared" "$TMP/add64.so" Java_com_example_MyClass_nativeAdd
else nok "arm64 --shared uebersetzt nicht"; fi

# --- 4. #2118: wo es keinen Codegen gibt, laut ---
for z in "android-x86_64 --shared" "x86_64 --shared" "android-x86_64"; do
  set -- $z
  rm -f "$TMP/x.out"
  baue "$ROOT/examples/android/jni_native_add.lyx" "$1" "$TMP/x.out" "${2:-}"; rc=$?
  if [ "$rc" != "0" ] && grep -q "#2118" "$TMP/bl.log"; then ok "$z: laut abgewiesen (rc $rc)"
  else nok "$z: rc=$rc, keine Meldung — still eine Datei erzeugt?"; fi
done

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
