#!/usr/bin/env bash
# tests/so_reste_2135_test.sh — #2135: die Reste der x86-.so (#2124) und die
# fehlenden Basis-Relocations im PE und unter LyxOS.
#
#   1. .eh_frame: Bis 1.2.15A hatte die x86-64-.so keine Abwickelangaben. Ein
#      Abwickler (Absturzbericht, backtrace(), C++-Ausnahme) blieb an der
#      ersten Lyx-Funktion stehen. Gemessen wird die WIRKUNG: ein C-Host ruft
#      eine exportierte Funktion, die ueber drei Lyx-Rahmen (Funktion,
#      Methode, Funktion) in den Host zurueckruft; dort wickelt backtrace()
#      ab und muss ueber alle Lyx-Rahmen bis main des Hosts kommen. Dazu
#      Stichproben per SIGPROF mitten im Lyx-Code: JEDE muss bis main
#      abwickeln — auch die, die in Prolog und Epilog fallen; ein falscher
#      Eintrag dort fiele hier auf, nicht beim Rueckruf.
#   2. --debug mit --shared: DWARF fehlte still. Gemessen: die Rahmen aus 1.
#      werden ueber .debug_info (readelf, nicht der eigene Schreiber) auf die
#      richtigen Funktionsnamen abgebildet, in Aufrufreihenfolge. Nebenbei:
#      im statischen ELF lag jede DWARF-Adresse 56 Byte zu frueh (DwarfGen
#      nahm 120 statt CG_CODE_OFF) — an jeder Funktionsadresse muss jetzt der
#      Prolog stehen.
#   3. Bump-Allokator: acht Host-Threads belegen gleichzeitig Objekte (new)
#      und Zeichenketten (StrConcat) und pruefen danach jedes Byte ihrer
#      Kennung. Bis 1.2.15A ueberschrieben sie sich gegenseitig.
#   4. Ressourcentabelle und Scrub-Tabelle tragen absolute Adressen ohne
#      Basis-Relocation: PE (wine, auch mit erzwungener Verschiebung) und der
#      LyxOS-Vertrag (PT_LYXRELOC, *(basis+rva) += basis-0x400000, hier
#      nachgerechnet) muessen danach auf die richtigen Bytes zeigen.
#   5. JNI-Namen: '_' -> _1, '$' -> _00024, Nicht-ASCII -> _0xxxx. Gemessen
#      am Exportnamen UND am Aufruf ueber dlsym.
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
if ! command -v readelf > /dev/null 2>&1; then echo "FAIL readelf fehlt — NICHT gemessen"; exit 1; fi

baue() {  # quelle, ausgabe, weitere Schalter...
  local q="$1" a="$2"; shift 2
  ( cd "$ROOT" && ulimit -v 8000000 && timeout 240 "$LYXC" --std-path="$ROOT" "$q" "$@" -o "$a" ) >"$TMP/bl.log" 2>&1
}
fehlertext() { grep -m1 -iE 'error|fehler' "$TMP/bl.log"; }

mkdir -p "$TMP/w"

# ======================================================================
# 1 + 2: Abwickeln ueber Lyx-Rahmen, DWARF in der .so
# ======================================================================
cat > "$TMP/lib.lyx" <<'EOF'
@cap(system.exit)
extern fn hostcb(x: int64): int64 link "libhost.so";
type Rechner = class {
  basis: int64;
  fn Create(): void { self.basis := 1; }
  fn Schritt(x: int64): int64 { return tiefste(x) + self.basis; }
}
fn tiefste(x: int64): int64 { return hostcb(x) + 1; }
fn mitte(x: int64): int64 {
  var r: Rechner := new Rechner();
  return r.Schritt(x) + 1;
}
@export
fn eingang(x: int64): int64 { return mitte(x) + 1; }
fn blatt(a: int64): int64 { return a * 3 + 1; }
fn knoten(a: int64): int64 {
  var s: int64 := 0;
  var i: int64 := 0;
  while (i < 4) { s := s + blatt(a + i); i := i + 1; }
  return s;
}
@export
fn rechne(n: int64): int64 {
  var s: int64 := 0;
  var i: int64 := 0;
  while (i < n) { s := (s + knoten(i)) & 1048575; i := i + 1; }
  return s;
}
EOF
cat > "$TMP/libhost.c" <<'EOF'
#define _GNU_SOURCE
#include <dlfcn.h>
#include <execinfo.h>
#include <stdio.h>
#include <string.h>
void *sobasis;
char zeile[4096];
/* Rueckruf aus der .so: hier ueber die Lyx-Rahmen abwickeln. Ausgabe: die
   Rahmen in der .so als Offset (Ruecksprungadresse - 1), dann ob main
   erreicht wurde. */
long hostcb(long x) {
  void *pcs[64];
  int n = backtrace(pcs, 64), i, inso = 0, main_erreicht = 0;
  char *z = zeile;
  for (i = 1; i < n; i++) {
    Dl_info di;
    if (!dladdr(pcs[i], &di)) continue;
    if (di.dli_fbase == sobasis) {
      z += sprintf(z, "0x%lx ", (unsigned long)((char *)pcs[i] - (char *)sobasis - 1));
      inso++;
    } else if (di.dli_sname && strcmp(di.dli_sname, "main") == 0) { main_erreicht = 1; break; }
  }
  sprintf(z, "| so=%d main=%d", inso, main_erreicht);
  return x * 2;
}
EOF
cat > "$TMP/host.c" <<'EOF'
#define _GNU_SOURCE
#include <dlfcn.h>
#include <execinfo.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/time.h>
typedef long (*F1)(long);
extern void *sobasis;
extern char zeile[];
static volatile long bis_main, in_lyx;
static void prof(int s) {
  void *pcs[64]; int n, i, m = 0, l = 0;
  (void)s;
  n = backtrace(pcs, 64);
  for (i = 0; i < n; i++) {
    Dl_info di;
    if (!dladdr(pcs[i], &di)) continue;
    if (di.dli_fbase == sobasis) l = 1;
    if (di.dli_sname && strcmp(di.dli_sname, "main") == 0) { m = 1; break; }
  }
  if (l) { in_lyx++; if (m) bis_main++; }
}
int main(int c, char **v) {
  void *h = dlopen(v[1], RTLD_NOW); Dl_info di;
  (void)c;
  if (!h) { printf("dlopen: %s\n", dlerror()); return 2; }
  F1 ein = (F1)dlsym(h, "eingang"), re = (F1)dlsym(h, "rechne");
  if (!ein || !re) { printf("Symbol fehlt\n"); return 3; }
  dladdr((void *)ein, &di); sobasis = di.dli_fbase;
  long r = ein(5);
  printf("eingang=%ld\n%s\n", r, zeile);
  struct sigaction sa; memset(&sa, 0, sizeof sa); sa.sa_handler = prof; sigaction(SIGPROF, &sa, 0);
  struct itimerval it = {{0, 200}, {0, 200}}; setitimer(ITIMER_PROF, &it, 0);
  long s = re(20000000);
  struct itimerval aus = {{0, 0}, {0, 0}}; setitimer(ITIMER_PROF, &aus, 0);
  printf("rechne=%ld proben=%ld bis_main=%ld\n", s, in_lyx, bis_main);
  return 0;
}
EOF
if ! gcc -shared -fPIC -o "$TMP/w/libhost.so" "$TMP/libhost.c" > "$TMP/gcc.log" 2>&1 \
   || ! gcc -rdynamic -o "$TMP/w/host" "$TMP/host.c" -L"$TMP/w" -lhost -ldl >> "$TMP/gcc.log" 2>&1; then
  echo "FAIL Host baut nicht — NICHT gemessen: $(head -3 "$TMP/gcc.log" | tr '\n' ' ')"; exit 1
fi

# Funktionsname zu einem Offset aus .debug_info (readelf liest, nicht lyxc).
cat > "$TMP/dwname.py" <<'EOF'
import re, sys
txt = open(sys.argv[1]).read().split('\n')
fn, name, lo = [], None, None
for z in txt:
    m = re.search(r'DW_AT_name\s*:.*:\s*(\S+)\s*$', z)
    if m: name = m.group(1); continue
    m = re.search(r'DW_AT_low_pc\s*:\s*(0x[0-9a-f]+)', z)
    if m: lo = int(m.group(1), 16); continue
    m = re.search(r'DW_AT_high_pc\s*:\s*<?(0x[0-9a-f]+)', z)
    if m and name is not None and lo is not None:
        fn.append((lo, lo + int(m.group(1), 16), name)); name = lo = None
out = []
for a in sys.argv[2:]:
    v = int(a, 16)
    # Die Uebersetzungseinheit umfasst alles; gemeint ist der engste Bereich.
    t = sorted((hi - lo, n) for lo, hi, n in fn if lo <= v < hi)
    out.append(t[0][1] if t else '?')
print(' '.join(out))
EOF

if baue "$TMP/lib.lyx" "$TMP/w/lib.so" --target=x86_64 --shared --debug; then
  ph="$(readelf -lW "$TMP/w/lib.so" 2>&1)"
  if echo "$ph" | grep -q "GNU_EH_FRAME"; then ok "PT_GNU_EH_FRAME vorhanden"; else nok "PT_GNU_EH_FRAME fehlt"; fi
  fr="$(readelf --debug-dump=frames "$TMP/w/lib.so" 2>&1)"
  nfde=$(echo "$fr" | grep -c " FDE cie=")
  # Die Zahl der Eintraege direkt aus .eh_frame_hdr lesen, nicht aus der
  # readelf-Ausgabe: "Entries in search table" druckt erst ein neueres
  # binutils (lokal 2.46 ja, die CI mit Ubuntu-binutils nicht) — dort war die
  # Pruefung seit #2135 rot, obwohl die Datei stimmte.
  ntab=$(python3 - "$TMP/w/lib.so" <<'PY'
import sys, struct
d = open(sys.argv[1], 'rb').read()
shoff, = struct.unpack_from('<Q', d, 0x28)
shentsize, shnum, shstrndx = struct.unpack_from('<HHH', d, 0x3A)
def sh(i):
    return struct.unpack_from('<IIQQQQIIQQ', d, shoff + i * shentsize)
stroff = sh(shstrndx)[4]
for i in range(shnum):
    h = sh(i)
    nm = d[stroff + h[0]:d.index(b'\0', stroff + h[0])]
    if nm == b'.eh_frame_hdr':
        o = h[4]
        ver, pe, ce, te = d[o], d[o+1], d[o+2], d[o+3]
        groesse = {0x03: 4, 0x0b: 4, 0x04: 8, 0x0c: 8, 0x02: 2, 0x0a: 2}
        o += 4 + groesse[pe & 0x0f]
        n = int.from_bytes(d[o:o + groesse[ce & 0x0f]], 'little')
        print(n)
        break
PY
)
  if [ "$nfde" -ge 8 ] && [ $((ntab)) -eq "$nfde" ] && ! echo "$fr" | grep -qiE "warn|error|fehler"; then
    ok ".eh_frame lesbar: $nfde FDE, Suchtabelle $((ntab)) Eintraege, keine Warnung"
  else nok ".eh_frame: $nfde FDE, Suchtabelle '${ntab}', Warnungen: $(echo "$fr" | grep -ciE 'warn|error')"; fi
  aus="$(cd "$TMP/w" && LD_LIBRARY_PATH="$TMP/w" timeout 60 ./host "$TMP/w/lib.so" 2>&1)"; rc=$?
  # eingang(5): hostcb 10, tiefste 11, Schritt 12, mitte 13, eingang 14
  zeile="$(echo "$aus" | sed -n 2p)"
  if [ "$rc" = "0" ] && echo "$aus" | grep -q "^eingang=14$" && echo "$zeile" | grep -q "| so=5 main=1$"; then
    ok "Rueckruf: backtrace() wickelt ueber 5 Rahmen der .so bis main ab [$zeile]"
  else nok "Rueckruf: rc=$rc [$(echo "$aus" | tr '\n' ' ')] statt eingang=14 / so=5 main=1"; fi
  pr="$(echo "$aus" | sed -n 's/.*proben=\([0-9]*\) bis_main=\([0-9]*\).*/\1 \2/p')"
  p1="${pr% *}"; p2="${pr#* }"
  if [ -n "$pr" ] && [ "$p1" -ge 20 ] && [ "$p1" = "$p2" ]; then
    ok "Stichproben: alle $p1 Proben im Lyx-Code wickeln bis main ab"
  else nok "Stichproben: [$pr] (Proben im Lyx-Code / davon bis main)"; fi
  # 2: dieselben Rahmen ueber DWARF benannt
  if readelf -SW "$TMP/w/lib.so" | grep -q "\.debug_info"; then
    readelf --debug-dump=info "$TMP/w/lib.so" > "$TMP/info.txt" 2>&1
    offs="$(echo "$zeile" | sed 's/|.*//')"
    # shellcheck disable=SC2086
    namen="$(python3 -I "$TMP/dwname.py" "$TMP/info.txt" $offs)"
    # Der fuenfte Rahmen ist die SysV-Huelle des Exports (eigene Marke).
    soll="tiefste Rechner_Schritt mitte eingang __lyx_so_huelle_eingang"
    if [ "$namen" = "$soll" ]; then ok "--debug --shared: DWARF benennt die Rahmen [$namen]"
    else nok "--debug --shared: DWARF benennt die Rahmen [$namen] statt [$soll]"; fi
  else nok "--debug --shared: keine .debug_info in der .so"; fi
else nok "lib.so uebersetzt nicht ($(fehlertext))"; fi
# Gegenseite: ohne --debug keine DWARF-Abschnitte, .eh_frame trotzdem
if baue "$TMP/lib.lyx" "$TMP/w/nodbg.so" --target=x86_64 --shared; then
  s="$(readelf -SW "$TMP/w/nodbg.so")"
  if ! echo "$s" | grep -q "\.debug_" && echo "$s" | grep -q "\.eh_frame "; then ok "ohne --debug: kein DWARF, aber .eh_frame"
  else nok "ohne --debug: Abschnitte stimmen nicht"; fi
else nok "nodbg.so uebersetzt nicht ($(fehlertext))"; fi

# Statisches ELF: an jeder Funktionsadresse aus .debug_info steht der Prolog.
printf 'fn zwei(a: int64): int64 { return a * 2; }\nfn drei(a: int64): int64 { return zwei(a) + a; }\nfn main(): int64 { return drei(3); }\n' > "$TMP/st.lyx"
if baue "$TMP/st.lyx" "$TMP/st" --debug; then
  readelf --debug-dump=info "$TMP/st" > "$TMP/stinfo.txt" 2>&1
  r="$(python3 -I - "$TMP/st" "$TMP/stinfo.txt" <<'EOF'
import re, sys
d = open(sys.argv[1], 'rb').read()
t = open(sys.argv[2]).read()
gut = schlecht = 0
for name, lo in re.findall(r'DW_AT_name\s*:.*:\s*(zwei|drei)\s*\n\s*<[0-9a-f]+>\s*DW_AT_low_pc\s*:\s*(0x[0-9a-f]+)', t):
    o = int(lo, 16) - 0x400000
    if d[o:o + 4] == b'\x55\x48\x89\xe5': gut += 1
    else: schlecht += 1
print(gut, schlecht)
EOF
)"
  if [ "$r" = "2 0" ]; then ok "statisches ELF: DWARF-Adressen zeigen auf den Prolog (zwei, drei)"
  else nok "statisches ELF: DWARF-Adressen [gut schlecht] = [$r]"; fi
else nok "st --debug uebersetzt nicht ($(fehlertext))"; fi

# ======================================================================
# 3: parallele Belegung aus acht Host-Threads
# ======================================================================
cat > "$TMP/thr.lyx" <<'EOF'
type Knoten = class {
  wert: int64;
  kennung: int64;
  nxt: int64;
  txt: int64;
}
@export
fn arbeite(kennung: int64, n: int64, anhang: pchar): int64 {
  var kopf: int64 := 0;
  var i: int64 := 0;
  while (i < n) {
    var k: Knoten := new Knoten();
    k.wert := kennung * 1000000 + i;
    k.kennung := kennung;
    k.nxt := kopf;
    var s: pchar := StrConcat("0123456789"c, anhang);
    poke8(s as int64, 64 + kennung);
    k.txt := s as int64;
    kopf := k as int64;
    i := i + 1;
  }
  var fehler: int64 := 0;
  var j: int64 := n - 1;
  var p: int64 := kopf;
  while (p != 0 && j >= 0) {
    var q: Knoten := p as Knoten;
    if (q.wert != kennung * 1000000 + j) { fehler := fehler + 1; }
    if (q.kennung != kennung) { fehler := fehler + 1; }
    var t: int64 := q.txt;
    if (peek8(t) != 64 + kennung) { fehler := fehler + 1; }
    if (peek8(t + 15) != 102) { fehler := fehler + 1; }
    j := j - 1;
    p := q.nxt;
  }
  if (j != 0 - 1) { fehler := fehler + 1000; }
  return fehler;
}
EOF
cat > "$TMP/thr.c" <<'EOF'
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
typedef long (*FA)(long, long, const char *);
static FA arbeite;
static long erg[8];
static void *lauf(void *a) { long k = (long)a; erg[k] = arbeite(k + 1, 150000, "abcdef"); return 0; }
int main(int c, char **v) {
  void *h = dlopen(v[1], RTLD_NOW);
  (void)c;
  if (!h) { printf("dlopen: %s\n", dlerror()); return 2; }
  arbeite = (FA)dlsym(h, "arbeite");
  if (!arbeite) { printf("Symbol fehlt\n"); return 3; }
  long allein = arbeite(9, 1000, "abcdef");
  pthread_t t[8]; long i, summe = 0;
  for (i = 0; i < 8; i++) pthread_create(&t[i], 0, lauf, (void *)i);
  for (i = 0; i < 8; i++) pthread_join(t[i], 0);
  for (i = 0; i < 8; i++) summe += erg[i];
  printf("allein=%ld fehler=%ld\n", allein, summe);
  return 0;
}
EOF
if ! gcc -O1 -o "$TMP/w/thr" "$TMP/thr.c" -ldl -lpthread > "$TMP/gcc.log" 2>&1; then
  nok "Thread-Host baut nicht: $(head -2 "$TMP/gcc.log" | tr '\n' ' ')"
elif baue "$TMP/thr.lyx" "$TMP/w/thr.so" --target=x86_64 --shared; then
  gut=0; aus=""
  for lauf in 1 2 3; do
    aus="$(timeout 60 "$TMP/w/thr" "$TMP/w/thr.so" 2>&1)"; rc=$?
    if [ "$rc" = "0" ] && [ "$aus" = "allein=0 fehler=0" ]; then gut=$((gut+1)); else break; fi
  done
  if [ "$gut" = "3" ]; then ok "8 Threads x 150000 new + StrConcat: keine Ueberschneidung (3 Laeufe)"
  else nok "8 Threads: Lauf $((gut+1)) rc=$rc [$aus]"; fi
else nok "thr.so uebersetzt nicht ($(fehlertext))"; fi

# ======================================================================
# 4: Basis-Relocations fuer Ressourcen- und Scrub-Tabelle
# ======================================================================
printf 'Hallo Welt' > "$TMP/text.txt"
cat > "$TMP/res.lyx" <<EOF
import std.io;
import std.res;
@resource("vorlage", "$TMP/text.txt");
fn main(): int64 {
  var p: pchar := ResFind("vorlage");
  PrintLn("res=" + IntToStr(ResLen("vorlage") * 1000 + peek8(p as int64)));
  return 0;
}
EOF
cat > "$TMP/scrub.lyx" <<'EOF'
@integrity(mode: scrubbed, interval: 50)
fn Rechne(a: int64): int64 { return a * 3; }
fn main(): int64 { return Rechne(4); }
EOF
# LyxOS-Vertrag nachgerechnet: Abbild bei basis laden (rva == Dateioffset),
# jede Relocation *(basis+rva) += basis - 0x400000, dann den Zeigern folgen.
cat > "$TMP/lyxreloc.py" <<'EOF'
import struct, sys
d = bytearray(open(sys.argv[2], 'rb').read())
art = sys.argv[1]
B, E = 0x7f3200000000, 0x400000
phoff = struct.unpack_from('<Q', d, 32)[0]; phnum = struct.unpack_from('<H', d, 56)[0]
ph = [struct.unpack_from('<IIQQQQQQ', d, phoff + i * 56) for i in range(phnum)]
rl = [p for p in ph if p[0] == 0x6FFFAA00]
if not rl: print('kein PT_LYXRELOC'); sys.exit(0)
o = rl[0][2]; n = struct.unpack_from('<Q', d, o)[0]
rvas = set(struct.unpack_from('<%dQ' % n, d, o + 8))
for r in rvas:
    struct.pack_into('<Q', d, r, struct.unpack_from('<Q', d, r)[0] + B - E)
def lies(va, n): return bytes(d[va - B:va - B + n])
def q(va): return struct.unpack('<Q', lies(va, 8))[0]
loads = [p for p in ph if p[0] == 1]
if art == 'res':
    daten = [p for p in loads if p[1] & 2][0][2]
    tab = q(B + daten + 120)
    if not (B <= tab < B + len(d)): print('Tabellenzeiger %#x ausserhalb' % tab); sys.exit(0)
    anz = q(tab)
    name, nlen, byt, blen = [q(tab + 8 + k * 8) for k in range(4)]
    print('anz=%d name=%s bytes=%s' % (anz, lies(name, nlen).decode('latin1'), lies(byt, blen).decode('latin1')))
else:
    m = d.find(b'METASAF2')
    codeLen = struct.unpack_from('<Q', d, m + 16)[0]
    print('start=%#x ende=%#x' % (q(B + m + 24) - B, q(B + m + 32) - B - codeLen))
EOF
if baue "$TMP/res.lyx" "$TMP/res"; then
  r="$(timeout 10 "$TMP/res" 2>&1)"
  [ "$r" = "res=10072" ] && ok "Ressource unter Linux: [$r]" || nok "Ressource unter Linux: [$r]"
  r="$(python3 -I "$TMP/lyxreloc.py" res "$TMP/res" 2>&1)"
  if [ "$r" = "anz=1 name=vorlage bytes=Hallo Welt" ]; then ok "LyxOS-Vertrag (PT_LYXRELOC) nachgerechnet: Ressource bei fremder Basis [$r]"
  else nok "LyxOS-Vertrag Ressource: [$r]"; fi
else nok "res uebersetzt nicht ($(fehlertext))"; fi
if baue "$TMP/scrub.lyx" "$TMP/scrub"; then
  timeout 10 "$TMP/scrub" > /dev/null 2>&1; rc=$?
  [ "$rc" = "12" ] && ok "Scrub-Programm laeuft unter Linux (rc 12)" || nok "Scrub-Programm: rc $rc statt 12"
  r="$(python3 -I "$TMP/lyxreloc.py" scrub "$TMP/scrub" 2>&1)"
  if [ "$r" = "start=0xb0 ende=0xb0" ]; then ok "LyxOS-Vertrag: Scrub-Tabelle (+24/+32) bei fremder Basis [$r]"
  else nok "LyxOS-Vertrag Scrub-Tabelle: [$r] statt [start=0xb0 ende=0xb0]"; fi
else nok "scrub uebersetzt nicht ($(fehlertext))"; fi

# PE: Wunschbasis wie erzeugt und erzwungen verschoben (Abbild auf eine
# belegte Basis umgeschrieben, der Lader von wine muss neu verschieben).
cat > "$TMP/rebase.py" <<'EOF'
import struct, sys
d = bytearray(open(sys.argv[1], 'rb').read())
neu = int(sys.argv[3], 0)
pe = struct.unpack_from('<I', d, 0x3c)[0]
nsec = struct.unpack_from('<H', d, pe + 6)[0]
optsz = struct.unpack_from('<H', d, pe + 20)[0]
opt = pe + 24
alt = struct.unpack_from('<Q', d, opt + 24)[0]
relrva, relsz = struct.unpack_from('<II', d, opt + 112 + 5 * 8)
secs = []
for i in range(nsec):
    s = opt + optsz + i * 40
    vsz, va, rsz, roff = struct.unpack_from('<IIII', d, s + 8)
    secs.append((va, max(vsz, rsz), roff))
def r2o(rva):
    for va, sz, ro in secs:
        if va <= rva < va + sz: return rva - va + ro
    raise SystemExit('RVA %#x ausserhalb' % rva)
o = r2o(relrva); ende = o + relsz
while o < ende:
    page, bs = struct.unpack_from('<II', d, o)
    if bs == 0: break
    for k in range((bs - 8) // 2):
        e = struct.unpack_from('<H', d, o + 8 + 2 * k)[0]
        if e >> 12 == 10:
            fo = r2o(page + (e & 0xfff))
            struct.pack_into('<Q', d, fo, struct.unpack_from('<Q', d, fo)[0] - alt + neu)
    o += bs
struct.pack_into('<Q', d, opt + 24, neu)
open(sys.argv[2], 'wb').write(d)
EOF
if ! command -v wine > /dev/null 2>&1; then
  echo "HINWEIS: wine fehlt — PE-Laufzeitpruefung uebersprungen"
elif baue "$TMP/res.lyx" "$TMP/w/res.exe" --target=win64 --format=pe; then
  r="$(cd "$TMP/w" && timeout 90 wine ./res.exe 2>/dev/null | tr -d '\r')"
  [ "$r" = "res=10072" ] && ok "PE (wine, Wunschbasis): [$r]" || nok "PE (wine, Wunschbasis): [$r]"
  # 0x7ffe0000 ist unter wine belegt (KUSER_SHARED_DATA) — der Lader muss verschieben.
  python3 -I "$TMP/rebase.py" "$TMP/w/res.exe" "$TMP/w/resv.exe" 0x7ffe0000
  r="$(cd "$TMP/w" && timeout 90 wine ./resv.exe 2>/dev/null | tr -d '\r')"
  [ "$r" = "res=10072" ] && ok "PE (wine, erzwungen verschoben): [$r]" || nok "PE (wine, erzwungen verschoben): [$r]"
else nok "res.exe uebersetzt nicht ($(fehlertext))"; fi

# ======================================================================
# 5: JNI-Namen nach Spezifikation
# ======================================================================
cat > "$TMP/jni.lyx" <<'EOF'
@jni(class="org.ab_c.K$Innen", method="na_me")
fn f1(env: int64, thiz: int64, a: int64): int64 { return a + 1; }
@jni(class="t.Größe", method="m")
fn f2(env: int64, thiz: int64, a: int64): int64 { return a + 2; }
@jni(class="t.K", method="einfach")
fn f3(env: int64, thiz: int64, a: int64): int64 { return a + 3; }
EOF
cat > "$TMP/jni.c" <<'EOF'
#include <dlfcn.h>
#include <stdio.h>
typedef long (*J3)(long, long, long);
int main(int c, char **v) {
  void *h = dlopen(v[1], RTLD_NOW); int i; long s = 0;
  if (!h) { printf("dlopen: %s\n", dlerror()); return 2; }
  for (i = 2; i < c; i++) {
    J3 f = (J3)dlsym(h, v[i]);
    if (!f) { printf("fehlt:%s ", v[i]); continue; }
    s = s * 10 + f(0, 0, 0);
  }
  printf("%ld\n", s);
  return 0;
}
EOF
if ! gcc -o "$TMP/w/jni" "$TMP/jni.c" -ldl > "$TMP/gcc.log" 2>&1; then nok "JNI-Host baut nicht"
elif baue "$TMP/jni.lyx" "$TMP/w/jni.so" --target=x86_64 --shared; then
  # Erwartung von Hand nach der Spezifikation: '_'->_1, '$'->_00024,
  # 'ö'->_000f6, 'ß'->_000df, Paketpunkt->'_'.
  n1="Java_org_ab_1c_K_00024Innen_na_1me"; n2="Java_t_Gr_000f6_000dfe_m"; n3="Java_t_K_einfach"
  r="$(timeout 10 "$TMP/w/jni" "$TMP/w/jni.so" "$n1" "$n2" "$n3" 2>&1)"
  [ "$r" = "123" ] && ok "JNI-Namen maskiert und rufbar: $n1 $n2 $n3" || nok "JNI-Namen: [$r]"
  syms="$(readelf --dyn-syms -W "$TMP/w/jni.so" | awk '{print $8}' | grep '^Java_' | sort | tr '\n' ' ')"
  if ! echo "$syms" | grep -qE 'ab_c|\$|na_me'; then ok "keine unmaskierten Namen exportiert"
  else nok "unmaskierte Namen exportiert: $syms"; fi
else nok "jni.so uebersetzt nicht ($(fehlertext))"; fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
