#!/usr/bin/env bash
# tests/x86_shared_lib_test.sh — #2124: `--shared` fuer x86-64 und
# android-x86_64 erzeugt eine echte .so.
#
# Bis 1.2.14B schrieben beide still ein Platzhalterprogramm (main -> 42) bei
# rc 0; seit #2118 brachen sie laut ab. Jetzt laufen sie ueber den x86-
# Schnellweg (codegen_x86) mit eigenem ET_DYN-Schreiber (cg_writeELFShared).
#
# Gemessen wird zweierlei:
#   1. die Ladebedingungen am ERZEUGNIS — dieselben Regeln wie fuer
#      android-arm64 (tests/android_shared_lib_test.sh, bionic linker_phdr.cpp),
#      mit e_machine 62, ohne Text-Relocation und ohne DT_TEXTREL, beide Seiten
#      der Exportliste (was exportiert sein muss UND was nicht);
#   2. die WIRKUNG — ein C-Programm laedt die .so mit dem glibc-Lader
#      (dlopen/dlsym) und ruft die Exporte wie ART: JNI-Form (env=0, thiz=0)
#      und @export. Geprueft werden die WERTE, die dabei durch Modulvariablen,
#      `@x`, eine Zeichenkette (Basis-Relocation), eine Klasse samt VMT und
#      `is`, einen globalen Funktionszeiger, eine Ressource, einen externen
#      Aufruf in eine zweite Bibliothek, f64-Argumente (SysV: xmm), acht
#      Argumente (zwei ueber den Stapel) und argc aus DT_INIT_ARRAY laufen;
#      dazu, dass rbx/rbp/r12-r15 den Aufruf ueberleben (kleiner Assembler-
#      Pruefer im Host) und mehrere Aufrufe hintereinander.
# Beide Ziele, x86_64 --shared und android-x86_64 --shared. Gegenseite: was
# eine Bibliothek nicht leisten kann (@capabilities), wird laut abgewiesen.
set -uo pipefail
ulimit -c 0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

if ! command -v gcc > /dev/null 2>&1; then echo "FAIL gcc fehlt — NICHT gemessen"; exit 1; fi

baue() {  # quelle, ziel, ausgabe, [extra]
  ( cd "$ROOT" && timeout 240 "$LYXC" --std-path="$ROOT" "$1" --target="$2" ${4:-} -o "$3" ) >"$TMP/bl.log" 2>&1
}

# Ladebedingungen am Erzeugnis. Ausgabe: eine Zeile je Verstoss, sonst nichts.
# Argumente: datei, note(0/1), dann Exporte (mit '-' davor: darf NICHT da sein).
cat > "$TMP/pruef.py" <<'EOF'
import struct, sys
d = open(sys.argv[1], 'rb').read()
note = sys.argv[2] == '1'
want = sys.argv[3:]
err = []
if d[:4] != b'\x7fELF' or d[4] != 2: print('kein ELF64'); sys.exit(0)
e_type, e_machine = struct.unpack_from('<HH', d, 16)
e_phoff, e_shoff = struct.unpack_from('<QQ', d, 32)
phent, phnum, shent, shnum, shstrndx = struct.unpack_from('<HHHHH', d, 54)
if e_type != 3: err.append('e_type %d statt ET_DYN' % e_type)
if e_machine != 62: err.append('e_machine %d statt 62' % e_machine)
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
# Kein 16-KiB-Rahmen darf zu zwei LOAD-Segmenten gehoeren (16-KiB-Geraete).
seiten = {}
for i, p in enumerate(loads):
    for s in range(p[3] // 0x4000, (p[3] + p[5] + 0x3fff) // 0x4000):
        if s in seiten and seiten[s] != i: err.append('16-KiB-Seite %#x in zwei LOAD-Segmenten' % (s * 0x4000))
        seiten[s] = i
gs = [p for p in ph if p[0] == 0x6474E551]
if not gs: err.append('kein PT_GNU_STACK')
elif gs[0][1] & 1: err.append('PT_GNU_STACK ausfuehrbar')
rr = [p for p in ph if p[0] == 0x6474E552]
if not rr: err.append('kein PT_GNU_RELRO')
elif dyn and not (rr[0][3] <= dyn[0][3] and dyn[0][3] + dyn[0][5] <= rr[0][3] + rr[0][5]): err.append('RELRO deckt .dynamic nicht')
nt = [p for p in ph if p[0] == 4]
if note and not nt: err.append('keine Android-Notiz')
if not note and nt: err.append('Android-Notiz auf Linux-Ziel')
if note and nt and d[nt[0][2] + 12:nt[0][2] + 19] != b'Android': err.append('Notiz nicht "Android"')
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
if 30 in tags and tags[30][0] & 4: err.append('DF_TEXTREL')
if 25 not in tags: err.append('kein DT_INIT_ARRAY')
xl = [p for p in loads if p[1] & 1]
if 7 in tags:
    ra, rs = v2o(tags[7][0]), tags[8][0]
    for i in range(0, rs, 24):
        off, info = struct.unpack_from('<QQ', d, ra + i)
        if any(p[3] <= off < p[3] + p[5] for p in xl): err.append('Text-Relocation bei %#x' % off)
        if info & 0xffffffff not in (6, 8): err.append('Relocation-Typ %d' % (info & 0xffffffff))
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
for w in want:
    if w.startswith('-'):
        if w[1:] in exp: err.append('%s darf nicht exportiert sein' % w[1:])
    elif w not in exp: err.append('Export fehlt: %s' % w)
if len(set(exp.values())) != len(exp): err.append('zwei Exporte auf derselben Adresse')
for e in err: print(e)
EOF
pruefe_so() {  # name, so, note, symbole...
  local n="$1" so="$2" nt="$3"; shift 3
  local v; v="$(python3 -I "$TMP/pruef.py" "$so" "$nt" "$@" 2>&1)"
  if [ -z "$v" ]; then ok "$n: Ladebedingungen erfuellt"
  else nok "$n: $(echo "$v" | tr '\n' ';')"; fi
}

# --- Die Bibliothek ---
printf 'Hallo Welt' > "$TMP/text.txt"
cat > "$TMP/lib.lyx" <<'EOF'
import std.res;
@resource("vorlage", "text.txt");
@cap(system.exit)
extern fn hostcb(x: int64): int64 link "libhost.so";
type Tier = class {
  beine: int64;
  fn Create(): void { self.beine := 4; }
  virtual fn Laut(): int64 { return 1; }
}
type Vogel = class extends Tier {
  fn Create(): void { self.beine := 2; }
  override fn Laut(): int64 { return 2; }
}
var zaehler: int64 := 40;
var zweite: int64 := 7;
var gruss: pchar := "hallo";
fn dopp(x: int64): int64 { return x * 2; }
var gFn: fn(int64): int64 := dopp;
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
@export
fn laenge(): int64 { return StrLen(gruss); }
@export
fn tierart(welche: int64): int64 {
  var t: Tier := new Tier();
  if (welche == 1) { t := new Vogel(); }
  var r: int64 := t.Laut() * 10 + t.beine;
  if (t is Vogel) { r := r + 100; }
  return r;
}
@export
fn zeiger(x: int64): int64 { return gFn(x); }
@export
fn ressource(): int64 {
  var p: pchar := ResFind("vorlage");
  return ResLen("vorlage") * 1000 + peek8(p as int64);
}
@export
fn misch(a: int64, x: f64, b: int64, y: f64): f64 {
  return (a as f64) * x + (b as f64) * y;
}
@export
fn acht(a: int64, b: int64, c: int64, d: int64, e: int64, f: int64, g: int64, h: int64): int64 {
  return a + b * 2 + c * 3 + d * 4 + e * 5 + f * 6 + g * 7 + h * 8;
}
@export
fn argc(): int64 { return GetArgC(); }
EOF

# --- Der Host: glibc-Lader, Aufrufe wie aus ART ---
printf 'static long n; long gerufen(void){return n;} long hostcb(long x){n++; return x*3;}\n' > "$TMP/libhost.c"
cat > "$TMP/host.c" <<'EOF'
#include <dlfcn.h>
#include <stdio.h>
typedef long (*J3)(long,long,long);
typedef long (*J1)(long);
typedef long (*J0)(void);
typedef double (*JM)(long,double,long,double);
typedef long (*J8)(long,long,long,long,long,long,long,long);
long pruef_call(void *fn, long a, long b, long c, long *ok);
#define S(t, n, h, s) t n = (t)dlsym(h, s); if (!n) { printf("Symbol fehlt: %s\n", s); return 3; }
int main(int c, char **v) {
  void *h = dlopen(v[1], RTLD_NOW); if (!h) { printf("dlopen: %s\n", dlerror()); return 2; }
  void *hh = dlopen("libhost.so", RTLD_NOW); if (!hh) { printf("dlopen host: %s\n", dlerror()); return 2; }
  S(J0, gerufen, hh, "gerufen")
  S(J3, inc, h, "Java_t_K_inc") S(J3, rueck, h, "Java_t_K_rueck") S(J3, adr, h, "adresse")
  S(J0, len, h, "laenge") S(J1, tier, h, "tierart") S(J1, zeiger, h, "zeiger")
  S(J0, res, h, "ressource") S(JM, misch, h, "misch") S(J8, acht, h, "acht") S(J0, ac, h, "argc")
  long r1 = inc(0, 0, 2), r2 = inc(0, 0, 3), r3 = rueck(0, 0, 14), r4 = gerufen();
  long r5 = adr(0, 0, 20), r6 = inc(0, 0, 0);
  printf("%ld|%ld|%ld|%ld|%ld|%ld|", r1, r2, r3, r4, r5, r6);
  printf("%ld|%ld|%ld|%ld|%ld|", len(), tier(0), tier(1), zeiger(21), res());
  printf("%.2f|%ld|%ld|", misch(3, 1.5, 4, 0.25), acht(1, 2, 3, 4, 5, 6, 7, 8), ac());
  long ok = 0, rr = pruef_call((void *)inc, 0, 0, 5, &ok);
  printf("%ld:%ld|", rr, ok);
  ok = 0; rr = pruef_call((void *)tier, 1, 0, 0, &ok);
  printf("%ld:%ld\n", rr, ok);
  return 0;
}
EOF
# pruef_call(fn, a, b, c, &ok): ruft fn(a, b, c) mit bekannten Werten in
# rbx, rbp, r12-r15 und setzt ok = 1, wenn alle sechs danach unveraendert sind.
cat > "$TMP/pruef.S" <<'EOF'
        .intel_syntax noprefix
        .text
        .globl pruef_call
pruef_call:
        push rbx
        push rbp
        push r12
        push r13
        push r14
        push r15
        push r8
        mov rax, rdi
        mov rdi, rsi
        mov rsi, rdx
        mov rdx, rcx
        movabs rbx, 0x1111111111111111
        movabs rbp, 0x2222222222222222
        movabs r12, 0x3333333333333333
        movabs r13, 0x4444444444444444
        movabs r14, 0x5555555555555555
        movabs r15, 0x6666666666666666
        call rax
        pop r8
        mov qword ptr [r8], 0
        movabs rcx, 0x1111111111111111
        cmp rbx, rcx
        jne 1f
        movabs rcx, 0x2222222222222222
        cmp rbp, rcx
        jne 1f
        movabs rcx, 0x3333333333333333
        cmp r12, rcx
        jne 1f
        movabs rcx, 0x4444444444444444
        cmp r13, rcx
        jne 1f
        movabs rcx, 0x5555555555555555
        cmp r14, rcx
        jne 1f
        movabs rcx, 0x6666666666666666
        cmp r15, rcx
        jne 1f
        mov qword ptr [r8], 1
1:
        pop r15
        pop r14
        pop r13
        pop r12
        pop rbp
        pop rbx
        ret
        .section .note.GNU-stack,"",@progbits
EOF
mkdir -p "$TMP/w"
if ! gcc -shared -fPIC -o "$TMP/w/libhost.so" "$TMP/libhost.c" > "$TMP/gcc.log" 2>&1 \
   || ! gcc -o "$TMP/w/host" "$TMP/host.c" "$TMP/pruef.S" -ldl >> "$TMP/gcc.log" 2>&1; then
  echo "FAIL Host baut nicht — NICHT gemessen: $(head -3 "$TMP/gcc.log" | tr '\n' ' ')"; exit 1
fi

# inc(2): 42*100+7; inc(3): 45*100+7; rueck(14): hostcb(14)+1 = 43, einmal
# gerufen; adresse(20): v=20 ueber @v, zweite=21 ueber @zweite -> 41; inc(0):
# der Schreibzugriff auf `zweite` ist angekommen -> 4521. laenge: "hallo" = 5;
# tierart(0): Tier 1*10+4 = 14; tierart(1): Vogel 2*10+2, `is Vogel` +100 =
# 122; zeiger(21) = dopp(21) = 42; ressource: 10 Byte, 'H' = 72 -> 10072;
# misch(3, 1.5, 4, 0.25) = 5.50; acht = 1+4+9+16+25+36+49+64 = 204; argc: der
# Host laeuft als `host lib.so a b` -> 4, gesetzt von __lyx_so_init. Ueber den
# Pruefer: inc(5) = 50*100+21 = 5021 und tierart(1) = 122, beide Male mit
# erhaltenen Registern (:1).
SOLL="4207|4507|43|1|41|4521|5|14|122|42|10072|5.50|204|4|5021:1|122:1|"
for z in x86_64 android-x86_64; do
  nt=0; [ "$z" = "android-x86_64" ] && nt=1
  rm -f "$TMP/w/lib.so"
  if baue "$TMP/lib.lyx" "$z" "$TMP/w/lib.so" --shared; then
    pruefe_so "$z --shared" "$TMP/w/lib.so" "$nt" Java_t_K_inc Java_t_K_rueck adresse laenge tierart zeiger ressource misch acht argc -hostcb -setz -dopp -main
    aus="$( (cd "$TMP/w" && LD_LIBRARY_PATH="$TMP/w" timeout 30 ./host "$TMP/w/lib.so" a b 2>&1) | tr '\n' '|')"
    if [ "$aus" = "$SOLL" ]; then ok "$z: geladen (dlopen) und gerufen: [$aus]"
    else nok "$z: geladen und gerufen: [$aus] statt [$SOLL]"; fi
  else nok "$z --shared uebersetzt nicht ($(grep -m1 -iE 'error|fehler' "$TMP/bl.log"))"; fi
done

# --- Das Beispiel aus den Issues, ohne Klassen und externs ---
if baue "$ROOT/examples/android/jni_native_add.lyx" android-x86_64 "$TMP/add.so" --shared; then
  pruefe_so "jni_native_add (android-x86_64)" "$TMP/add.so" 1 Java_com_example_MyClass_nativeAdd Java_com_example_MyClass_nativeMul Java_com_example_MyClass_nativeDouble
else nok "jni_native_add uebersetzt nicht ($(grep -m1 -iE 'error|fehler' "$TMP/bl.log"))"; fi

# --- Gegenseite: was eine Bibliothek nicht kann, laut ---
# @capabilities installiert seccomp/Landlock am PROZESS — in einer .so traefe
# das den Host. Still weglassen waere ein Versprechen ohne Wirkung.
cat > "$TMP/cap.lyx" <<'EOF'
@capabilities([fs.read])
@export
fn f(a: int64): int64 { return a + 1; }
EOF
rm -f "$TMP/cap.so"
baue "$TMP/cap.lyx" x86_64 "$TMP/cap.so" --shared; rc=$?
if [ "$rc" != "0" ] && grep -q "#2124" "$TMP/bl.log" && [ ! -e "$TMP/cap.so" ]; then ok "@capabilities in einer .so: laut abgewiesen (rc $rc)"
else nok "@capabilities in einer .so: rc=$rc, Datei: $([ -e "$TMP/cap.so" ] && echo ja || echo nein)"; fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
