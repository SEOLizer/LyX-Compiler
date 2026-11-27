#!/usr/bin/env bash
# #2198: Laufzeitauswahl per @cpu(mehrere Stufen).
#
# Der Test prueft BEIDE Richtungen und messt die WIRKUNG, nicht das
# Vorhandensein:
#   * mit mehreren Stufen: Verteiler da, ZWEI VERSCHIEDENE Ziele, Ergebnis
#     richtig -- auch beim ZWEITEN Aufruf, wenn die Erkennung nicht mehr
#     laeuft;
#   * mit EINER Stufe: KEIN Verteiler und KEIN cpuid -- sonst zahlte jedes
#     Programm fuer eine Auswahl, die es nicht braucht.
#
# Warum die zweite Richtung mitgemessen wird: ein Test, der nur belegt, dass
# mehrere Stufen einen Verteiler erzeugen, waere auch von einer Fassung
# erfuellt, die IMMER einen erzeugt.
set -u
cd "$(dirname "$0")/.." || exit 1
LYXC="${LYXC:-./lyxc}"
P=0; F=0
pr() { if [ "$1" = ok ]; then P=$((P+1)); echo "PASS $2"; else F=$((F+1)); echo "FAIL $2"; fi; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# ---------------------------------------------------------------- 1) Wirkung
cat > "$T/a.lyx" <<'EOF'
import src.std.io
@cpu(avx2, baseline);
fn summe(a: int64, b: int64, c: int64, d: int64, e: int64, f: int64): int64 {
  return a + b * 2 + c * 3 + d * 4 + e * 5 + f * 6;
}
@cpu(baseline);
fn main(): int64 {
  PrintStr("r="c);  PrintInt(summe(1, 2, 3, 4, 5, 6)); PrintLn();
  PrintStr("r2="c); PrintInt(summe(1, 2, 3, 4, 5, 6)); PrintLn();
  return 0;
}
EOF
if $LYXC --std-path=. "$T/a.lyx" -o "$T/a" >"$T/a.log" 2>&1; then
  OUT=$("$T/a" 2>&1)
  # Sechs Argumente MUESSEN den Erkennungsaufruf ueberleben: er steht vor dem
  # Rumpf, die Argumente liegen noch in rdi/rsi/rdx/rcx/r8/r9, und cpuid
  # schreibt rax/rbx/rcx/rdx. Fehlt die Sicherung, ist der ERSTE Aufruf
  # falsch und jeder spaetere richtig.
  if [ "$OUT" = "r=91
r2=91" ]; then pr ok "beide Aufrufe 91 (Argumente ueberleben die Erkennung)"
  else pr no "Ergebnis: $(echo "$OUT" | tr '\n' ' ')"; fi
else
  pr no "uebersetzt nicht"; cat "$T/a.log" | head -3
fi

# ------------------------------------------------- 2) Verteiler am Erzeugnis
python3 - "$T/a" <<'PY'
import sys, struct, re
d = open(sys.argv[1], 'rb').read()
m = [h.start() for h in re.finditer(rb'\x48\x8b\x05....\x48\x85\xc0\x75\x05\xe8', d, re.S)]
def ok(c, t): print(("PASS " if c else "FAIL ") + t)
ok(len(m) == 1, "genau EIN Verteiler im Erzeugnis (gefunden: %d)" % len(m))
if len(m) == 1:
    o = m[0]
    s32 = lambda p: struct.unpack('<i', d[p:p+4])[0]
    p = o + 12 + 5
    ok(d[p:p+3] == b'\x48\x83\xf8', "Verteiler vergleicht rax gegen eine Schwelle")
    # Die Schwelle ist STUFE+1, nicht die Stufe: 0 heisst "noch nicht
    # erkannt". Waere hier die Stufe selbst, traefe `jge` auch den
    # unerkannten Zustand und sprang in die hohe Fassung -- auf einer CPU,
    # die sie nicht kann.
    ok(d[p+3] == 3, "Schwelle ist Stufe+1 = 3 fuer avx2 (gelesen: %d)" % d[p+3])
    p += 4
    ok(d[p:p+2] == b'\x0f\x8d', "bedingter Sprung in die hohe Fassung")
    t1 = p + 6 + s32(p + 2); p += 6
    ok(d[p:p+1] == b'\xe9', "UNBEDINGTER Sprung in die unterste Fassung")
    t2 = p + 5 + s32(p + 1)
    # Ohne den unbedingten Sprung fiele der Verteiler unterhalb aller
    # Schwellen in den naechsten Befehl -- den Rumpf der naechsten Funktion.
    ok(t1 != t2, "zwei VERSCHIEDENE Rumpfadressen (%s / %s)" % (hex(t1), hex(t2)))
PY
C=$(python3 -c "
d=open('$T/a','rb').read(); print(d.count(b'\x0f\xa2'), d.count(b'\x0f\x01\xd0'), d.count(b'\x41\xf7\xc3\x00\x00\x00\x08'))")
set -- $C
if [ "$1" = 2 ] && [ "$2" = 1 ]; then pr ok "Erkennung: cpuid Blatt 1 und 7, xgetbv einmal"
else pr no "cpuid=$1 xgetbv=$2 (erwartet 2 / 1)"; fi
# OSXSAVE-Pruefung (test r11d, 1<<27) ist PFLICHT: ohne sie ist `xgetbv` auf
# einer CPU ohne OSXSAVE ein ungueltiger Befehl und das Programm stirbt mit
# SIGILL -- nicht etwa mit einer 0.
if [ "$3" = 1 ]; then pr ok "OSXSAVE wird vor xgetbv geprueft"
else pr no "OSXSAVE-Pruefung fehlt ($3) -- xgetbv kann #UD werfen"; fi

# --------------------------------------- 3) Gegenrichtung: EINE Stufe
cat > "$T/b.lyx" <<'EOF'
import src.std.io
@cpu(avx2);
fn summe(a: int64, b: int64): int64 { return a + b * 2; }
@cpu(baseline);
fn main(): int64 { PrintInt(summe(3, 4)); PrintLn(); return 0; }
EOF
if $LYXC --std-path=. "$T/b.lyx" -o "$T/b" >/dev/null 2>&1; then
  [ "$("$T/b")" = "11" ] && pr ok "eine Stufe: Ergebnis richtig" || pr no "eine Stufe: falsch"
  N=$(python3 -c "
import re; d=open('$T/b','rb').read()
print(len([h for h in re.finditer(rb'\x48\x8b\x05....\x48\x85\xc0\x75\x05\xe8', d, re.S)]), d.count(b'\x0f\xa2'))")
  set -- $N
  if [ "$1" = 0 ]; then pr ok "eine Stufe: KEIN Verteiler"
  else pr no "eine Stufe: $1 Verteiler -- jedes Programm zahlt fuer nichts"; fi
  if [ "$2" = 0 ]; then pr ok "eine Stufe: KEIN cpuid im Erzeugnis"
  else pr no "eine Stufe: cpuid $2x -- Erkennungsblock ohne Verteiler"; fi
else pr no "eine Stufe uebersetzt nicht"; fi

# --------------------------------------- 4) Drei Stufen: zwei Schwellen
cat > "$T/c.lyx" <<'EOF'
import src.std.io
@cpu(avx512, avx2, baseline);
fn f(a: int64): int64 { return a * 7; }
@cpu(baseline);
fn main(): int64 { PrintInt(f(6)); PrintLn(); return 0; }
EOF
if $LYXC --std-path=. "$T/c.lyx" -o "$T/c" >/dev/null 2>&1; then
  [ "$("$T/c")" = "42" ] && pr ok "drei Stufen: Ergebnis richtig" || pr no "drei Stufen: falsch"
  S=$(python3 -c "
import re; d=open('$T/c','rb').read()
print(len([h for h in re.finditer(rb'\x48\x83\xf8[\x01-\x04]\x0f\x8d', d, re.S)]))")
  # Drei Fassungen = ZWEI Schwellen und ein unbedingter Sprung. Eine Schwelle
  # weniger hiesse, dass eine Fassung nie gewaehlt wird.
  [ "$S" -ge 2 ] && pr ok "drei Stufen: zwei Schwellen ($S)" || pr no "drei Stufen: nur $S Schwelle(n)"
else pr no "drei Stufen uebersetzt nicht"; fi

# --------------------------------------- 5) Dieselbe Stufe zweimal: laut
cat > "$T/d.lyx" <<'EOF'
@cpu(avx2, avx2);
fn f(a: int64): int64 { return a; }
fn main(): int64 { return f(0); }
EOF
if $LYXC --std-path=. "$T/d.lyx" -o "$T/d" >"$T/d.log" 2>&1; then
  pr no "doppelte Stufe wird still geschluckt"
else
  grep -q 'zweimal' "$T/d.log" && pr ok "doppelte Stufe wird laut abgewiesen" \
    || pr no "abgewiesen, aber ohne Grund: $(head -1 "$T/d.log")"
fi

# ------------------- 6) Der Erkennungsblock liegt im AUSFUEHRBAREN Segment
#
# Diese Pruefung ist aus einem echten Fehler entstanden: der Block stand
# hinter der Seitenauffuellung, lag damit im RW-Segment (NX), und der `call`
# aus dem Verteiler endete in SIGSEGV. Auffaellig wurde es nur bei
# Programmen, die gross genug waren -- bei kleinen fiel er noch in die
# letzte abgebildete Codeseite und lief. Eine Pruefung, die nur ein kleines
# Programm laufen laesst, haette das NICHT gefunden.
python3 - "$T/a" <<'PY2'
import sys, struct
d = open(sys.argv[1], 'rb').read()
def ok(c, t): print(("PASS " if c else "FAIL ") + t)
phoff  = struct.unpack('<Q', d[0x20:0x28])[0]
phnum  = struct.unpack('<H', d[0x38:0x3a])[0]
blk    = d.find(b'\x57\x56\x52\x51\x41\x50\x41\x51\x53')      # Erkennungsblock
ok(blk >= 0, "Erkennungsblock im Erzeugnis gefunden")
drin = 0
for i in range(phnum):
    ph = phoff + i * 56
    typ   = struct.unpack('<I', d[ph:ph+4])[0]
    flags = struct.unpack('<I', d[ph+4:ph+8])[0]
    off   = struct.unpack('<Q', d[ph+8:ph+16])[0]
    fsz   = struct.unpack('<Q', d[ph+32:ph+40])[0]
    # PT_LOAD mit X-Bit (1) -- nur dort darf ausgeführter Code liegen.
    if typ == 1 and (flags & 1) != 0 and off <= blk < off + fsz: drin = 1
ok(drin == 1, "Erkennungsblock liegt in einem AUSFUEHRBAREN PT_LOAD")
PY2

# ------------------- 7) Die Fassungen sind VERSCHIEDEN, und das Ergebnis stimmt
#
# Ohne diese Pruefung belegt der Test nur, dass verteilt wird -- nicht, dass
# es etwas bringt. Zwei identische Rumpfe waeren ein Verteiler ohne Zweck.
cat > "$T/e.lyx" <<'EOF'
import src.std.io
@cpu(avx2, baseline);
fn addiere(a: int64, b: int64, c: int64, n: int64) {
  var i: int64 := 0;
  while (i < n) { var o: int64 := i * 4; poke32(c + o, (peek32(a + o) + peek32(b + o)) & 0xFFFFFFFF); i += 1; }
}
@cpu(baseline);
fn main(): int64 {
  var n: int64 := 256;
  var a: int64 := alloc(n * 4); var b: int64 := alloc(n * 4); var c: int64 := alloc(n * 4);
  var i: int64 := 0;
  while (i < n) { var o: int64 := i * 4; poke32(a + o, i); poke32(b + o, i * 2); i += 1; }
  addiere(a, b, c, n);
  var s: int64 := 0; i := 0;
  while (i < n) { s := s + (peek32(c + i * 4) & 0xFFFFFFFF); i += 1; }
  PrintStr("s="c); PrintInt(s); PrintLn();
  return 0;
}
EOF
if $LYXC --std-path=. "$T/e.lyx" -o "$T/e" >/dev/null 2>&1; then
  # 3 * (0+1+...+255) = 3 * 32640
  [ "$("$T/e" 2>&1)" = "s=97920" ] && pr ok "vektorisierte Fassung rechnet richtig (97920)"     || pr no "vektorisiert falsch: $("$T/e" 2>&1)"
  python3 - "$T/e" <<'PY3'
import sys, struct, re
d = open(sys.argv[1], 'rb').read()
def ok(c, t): print(("PASS " if c else "FAIL ") + t)
m = [h.start() for h in re.finditer(rb'\x48\x8b\x05....\x48\x85\xc0\x75\x05\xe8', d, re.S)]
if len(m) != 1:
    ok(False, "ein Verteiler erwartet, %d gefunden" % len(m))
else:
    o = m[0]; s32 = lambda p: struct.unpack('<i', d[p:p+4])[0]
    p = o + 17; t1 = p + 10 + s32(p + 6); p += 10; t2 = p + 5 + s32(p + 1)
    hi, lo = min(t1, t2), max(t1, t2)
    rh = d[hi:lo]; rl = d[lo:lo + len(rh)]
    # vmovdqu ymm (c5 fe 6f) nur in der hohen Fassung: DAS ist der Unterschied,
    # um den es bei #2198 geht.
    ok(rh.count(b'\xc5\xfe\x6f') > 0, "hohe Fassung traegt ymm-Befehle (%d)" % rh.count(b'\xc5\xfe\x6f'))
    ok(rl.count(b'\xc5\xfe\x6f') == 0, "tiefe Fassung traegt KEINE ymm-Befehle")
    # #2404/#2671: EVEX darf in einer avx2-Fassung NICHT vorkommen -- auf einer
    # CPU ohne AVX-512 ist das SIGILL.
    ok(len([h for h in re.finditer(rb'\x62\xf1\xfe\x48', rh)]) == 0,
       "hohe Fassung traegt KEINEN EVEX-Befehl (avx2 verspricht kein AVX-512)")
PY3
else pr no "vektorisierte Fassung uebersetzt nicht"; fi

echo "PASS: $P  FAIL: $F"
[ "$F" -eq 0 ] || exit 1
