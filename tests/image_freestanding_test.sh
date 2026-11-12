#!/usr/bin/env bash
# tests/image_freestanding_test.sh — #1954: PNG-Dekoder fuer freistehende Ziele.
#
# std.image.png liess sich unter --target=lyxos-kernel nicht einmal
# importieren (std.fs gilt dort als POSIX-Import), und unter --target=lyxos
# belegte es jeden Puffer mit alloc() — ein mmap-Syscall, den es im Kern nicht
# gibt. Neu: std.image.png_mem + std.inflate, beide ohne Speicherbelegung.
#
# Gemessen wird nicht "uebersetzt", sondern:
#   1. das Erzeugnis fuer lyxos-kernel ist ein ELF, fuer lyxos ein LBF, und es
#      enthaelt KEINEN syscall-Befehl mehr als ein leeres Programm — mit
#      Gegenprobe, dass dieselbe Zaehlung den Inflater aus std.zlib erkennt;
#   2. der WERT: jedes Pixelbyte echter PNGs (mit python3/zlib erzeugt,
#      Filter 0..4, mehrere IDAT-Chunks, stored/fixed/dynamic Huffman, 8 und
#      16 Bit, Grau/RGB/Grau+Alpha/RGBA) gegen die Rohdaten — auf x86_64 und,
#      weil der Weg zielunabhaengig ist, auf arm64 unter qemu;
#   3. die alte API (PngDecode) liefert fuer dieselben Dateien dieselben Bytes;
#   4. kaputte und abgeschnittene Dateien liefern einen negativen Fehlerwert.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
. "$(dirname "$0")/lib/qemu.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }
ulimit -c 0

# Uebersetzen aus dem Repo-Wurzelverzeichnis (der Resolver bevorzugt das CWD).
uebersetze() { # quelle ziel ausgabe
  (cd "$ROOT" && "$LYXC" --std-path="$ROOT" "$1" --target="$2" -o "$3" >"$3.log" 2>&1)
}
syscalls() { objdump -D -z --no-show-raw-insn -b binary -m i386:x86-64 "$1" | grep -cw syscall; }
magic() { od -An -tx1 -N4 "$1" | tr -d ' '; }

# ===========================================================================
# 1. Freistehend uebersetzbar, ohne Syscall
# ===========================================================================
cat > "$TMP/leer.lyx" <<'EOF'
fn main(): int64 { return 0; }
EOF
cat > "$TMP/frei.lyx" <<'EOF'
import std.image.png_mem;
fn main(): int64 {
    return PngDecodeFromMemory(4096, 64, 8192, 64, 12288, 64);
}
EOF
cat > "$TMP/zlib.lyx" <<'EOF'
import std.zlib;
fn main(): int64 {
    return InflateDEFLATEBounded(4096 as pchar, 4, 8192 as pchar, 4, 0);
}
EOF

uebersetze "$TMP/leer.lyx" lyxos-kernel "$TMP/leer.elf"
uebersetze "$TMP/frei.lyx" lyxos-kernel "$TMP/frei.elf"; rc=$?
if [ $rc -eq 0 ] && [ -s "$TMP/frei.elf" ] && [ "$(magic "$TMP/frei.elf")" = "7f454c46" ]; then
  ok "png_mem uebersetzt fuer lyxos-kernel (ELF, $(stat -c %s "$TMP/frei.elf") Byte)"
else
  no "png_mem uebersetzt fuer lyxos-kernel" "rc=$rc $(grep -i error "$TMP/frei.elf.log" | head -2 | tr '\n' ' ')"
fi
uebersetze "$TMP/frei.lyx" lyxos "$TMP/frei.lbf"; rc=$?
if [ $rc -eq 0 ] && [ -s "$TMP/frei.lbf" ] && [ "$(magic "$TMP/frei.lbf")" = "4c595821" ]; then
  ok "png_mem uebersetzt fuer lyxos (LBF, $(stat -c %s "$TMP/frei.lbf") Byte)"
else
  no "png_mem uebersetzt fuer lyxos" "rc=$rc"
fi

if [ -s "$TMP/leer.elf" ] && [ -s "$TMP/frei.elf" ]; then
  s0=$(syscalls "$TMP/leer.elf"); s1=$(syscalls "$TMP/frei.elf")
  if [ "$s1" -eq "$s0" ]; then ok "png_mem fuegt keinen syscall hinzu ($s1 == leer $s0)"
  else no "png_mem fuegt keinen syscall hinzu" "$s1 statt $s0"; fi
  # Gegenprobe: die Zaehlung sieht den mmap-gestuetzten Inflater aus std.zlib.
  uebersetze "$TMP/zlib.lyx" lyxos-kernel "$TMP/zlib.elf"
  if [ -s "$TMP/zlib.elf" ]; then
    s2=$(syscalls "$TMP/zlib.elf")
    if [ "$s2" -gt "$s0" ]; then ok "Gegenprobe: std.zlib-Inflater bringt syscalls mit ($s2 > $s0)"
    else no "Gegenprobe std.zlib" "$s2 nicht > $s0 — die Zaehlung waere blind"; fi
  else no "Gegenprobe std.zlib" "uebersetzt nicht"; fi
fi

# Die Linux-Fassung bleibt im Kernmodus gesperrt (std.fs) — die neue Unit
# darf das also nicht ueber einen Import von std.image.png umgehen.
printf 'import std.image.png_mem;\nimport std.inflate;\nfn main(): int64 { return 0; }\n' > "$TMP/imp.lyx"
uebersetze "$TMP/imp.lyx" lyxos-kernel "$TMP/imp.elf"
if grep -q "POSIX import" "$TMP/imp.elf.log"; then no "png_mem ohne POSIX-Import" "$(grep POSIX "$TMP/imp.elf.log")"
else ok "png_mem und std.inflate ohne POSIX-Import"; fi

# ===========================================================================
# 2.–4. Testbilder erzeugen
# ===========================================================================
# Je Fall: <name>.png, <name>.exp (erwartete RGBA8-Bytes, eine Zahl je Zeile,
# davor die Laenge) oder <name>.err (erwartet: negativer Wert).
python3 - "$TMP" <<'PY'
import sys, zlib, struct, os
out = sys.argv[1]

def chunk(t, d):
    return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)

def paeth(a, b, c):
    p = a + b - c; pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc: return a
    if pb <= pc: return b
    return c

def filt(rows, bpp, ftypes):
    res = b''; prior = bytes(len(rows[0]))
    for y, row in enumerate(rows):
        ft = ftypes[y % len(ftypes)]; o = bytearray([ft])
        for x in range(len(row)):
            a = row[x - bpp] if x >= bpp else 0
            b = prior[x]; c = prior[x - bpp] if x >= bpp else 0
            pr = [0, a, b, (a + b) // 2, paeth(a, b, c)][ft]
            o.append((row[x] - pr) & 255)
        res += bytes(o); prior = row
    return res

CH = {0: 1, 2: 3, 4: 2, 6: 4}
def rgba(samples, ctype, depth):
    bps = depth // 8; n = CH[ctype]; px = []
    for i in range(0, len(samples), n * bps):
        s = [samples[i + k * bps] for k in range(n)]   # hoeherwertiges Byte
        if ctype == 0: px += [s[0], s[0], s[0], 255]
        if ctype == 2: px += [s[0], s[1], s[2], 255]
        if ctype == 4: px += [s[0], s[0], s[0], s[1]]
        if ctype == 6: px += s
    return px

def make(name, w, h, ctype, depth, ftypes, level=9, nchunks=1, val=None):
    n = CH[ctype] * depth // 8
    if val is None:
        val = lambda x, y, k: (x * 37 + y * 101 + k * 59 + x * y * 13) & 255
    rows = [bytes(val(x, y, k) for x in range(w) for k in range(n)) for y in range(h)]
    raw = filt(rows, n, ftypes)
    z = zlib.compress(raw, level)
    ihdr = struct.pack('>IIBBBBB', w, h, depth, ctype, 0, 0, 0)
    idat = b''; step = (len(z) + nchunks - 1) // nchunks
    for i in range(0, len(z), step): idat += chunk(b'IDAT', z[i:i + step])
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr) + chunk(b'tEXt', b'k\x00v') + idat + chunk(b'IEND', b'')
    open(os.path.join(out, name + '.png'), 'wb').write(png)
    px = rgba(b''.join(rows), ctype, depth)
    open(os.path.join(out, name + '.exp'), 'w').write('\n'.join(map(str, [len(px)] + px)) + '\n')
    return png

# 3x2 RGB mit bekannten Werten, Filter 0 und 1
make('rgb3x2', 3, 2, 2, 8, [0, 1],
     val=lambda x, y, k: [[(255, 0, 0), (0, 255, 0), (0, 0, 255)],
                          [(10, 20, 30), (40, 50, 60), (200, 100, 7)]][y][x][k])
make('rgb_f04', 7, 5, 2, 8, [0, 1, 2, 3, 4])                    # alle Filter, fest/dyn.
make('rgba_chunks', 6, 5, 6, 8, [4, 3, 2, 1, 0], nchunks=4)     # 4 IDAT-Chunks
make('rgba_stored', 5, 4, 6, 8, [2, 4, 1, 3], level=0)          # stored-Bloecke
make('gray16', 4, 3, 0, 16, [4, 2, 0])                          # 16 Bit
make('graya', 5, 3, 4, 8, [3, 1, 4])                            # Grau+Alpha
big = make('rgb_big', 40, 30, 2, 8, [0, 1, 2, 3, 4],            # fest + lange Rueckverweise
           val=lambda x, y, k: ((x // 4) * 30 + (y // 3) * 17 + k * 80) & 255)
# Dynamisches Huffman (btype 2) braucht eine schiefe Verteilung; zlib waehlt
# bei den glatten Bildern oben feste Codes.
ALPH = [0, 17, 34, 51, 200, 255, 90, 7]
def lcg(x, y, k):
    s = (x * 3 + k + y * 1000) * 2654435761 + 12345
    return ALPH[(s >> 13) & 7]
dyn = make('rgb_dyn', 16, 16, 2, 8, [0, 4, 1, 2, 3], val=lcg)

def btype(png):
    i = 33
    while i < len(png):
        l = struct.unpack('>I', png[i:i + 4])[0]
        if png[i + 4:i + 8] == b'IDAT': return (png[i + 10] >> 1) & 3
        i += 12 + l
for nm, p, want in [('rgb_big', big, 1), ('rgb_dyn', dyn, 2)]:
    if btype(p) != want:
        sys.exit('Testbild %s: btype %d statt %d — Abdeckung stimmt nicht' % (nm, btype(p), want))
stored = open(os.path.join(out, 'rgba_stored.png'), 'rb').read()
if btype(stored) != 0: sys.exit('Testbild rgba_stored: kein stored-Block')

# --- Fehlerfaelle ------------------------------------------------------------
def err(name, data):
    open(os.path.join(out, name + '.png'), 'wb').write(data)
    open(os.path.join(out, name + '.err'), 'w').write('neg\n')
err('kaputt_halb', big[:len(big) // 2])                         # Datei abgeschnitten
# zlib-Strom abgeschnitten, Chunklaenge aber stimmig
def rebuild(name, zmod, ftypes=[0], w=8, h=8):
    rows = [bytes((x * 9 + y * 5 + k) & 255 for x in range(w) for k in range(3)) for y in range(h)]
    z = zmod(zlib.compress(filt(rows, 3, ftypes), 9))
    ihdr = struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr) + chunk(b'IDAT', z) + chunk(b'IEND', b'')
err('kaputt_zlibkurz', rebuild('x', lambda z: z[:len(z) // 2]))
err('kaputt_bitkipper', rebuild('x', lambda z: z[:6] + bytes([z[6] ^ 0x5a]) + z[7:]))
err('kaputt_adler', rebuild('x', lambda z: z[:-1] + bytes([z[-1] ^ 1])))
# Filterbyte 7 gibt es nicht
rows = [bytes(24) for _ in range(8)]
raw = bytearray(filt(rows, 3, [0])); raw[0] = 7
ihdr = struct.pack('>IIBBBBB', 8, 8, 8, 2, 0, 0, 0)
err('kaputt_filter', b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr) + chunk(b'IDAT', zlib.compress(bytes(raw))) + chunk(b'IEND', b''))
err('kaputt_signatur', b'\x88' + big[1:])
PY

# Lyx-Programm zu einer Datei: die Bytes stehen im Programm (poke8), damit
# derselbe Text auf jedem Ziel ohne Datei-I/O laeuft.
# modus mem: PngDecodeFromMemory, Puffergroessen aus PngMemInfo.
# modus alt: PngDecode (Linux-API).
# modus klein: Ausgabepuffer ein Byte zu klein -> PNGM_ERR_DST erwartet.
programm() { # png modus lyx
  python3 - "$1" "$2" > "$3" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read(); mode = sys.argv[2]
print('import std.alloc;\nimport std.io;')
print('import std.image.png_mem;' if mode != 'alt' else 'import std.image.core;\nimport std.image.png;')
print('fn main(): int64 {')
print('    var n: int64 := %d;' % len(d))
print('    var src: int64 := alloc(n + 8);')
# Je sieben Bytes ein poke64 (Wert < 2^56, also positiv); das achte, oberste
# Byte ist 0 und wird von der naechsten Gruppe ueberschrieben. Ein poke8 je
# Byte machte main auf arm64 so lang, dass das Programm abstuerzte, bevor es
# den Dekoder erreichte — ein Compilerdefekt, unabhaengig von dieser Unit
# (#2112).
for i in range(0, len(d), 7):
    v = int.from_bytes(d[i:i + 7], 'little')
    if v: print('    poke64(src + %d, %d);' % (i, v))
if mode == 'alt':
    print('''    var img: int64 := alloc(GRF_SIZE);
    var r: int64 := PngDecode(src, n, img);
    if (r != 1) { PrintLn(IntToStr(0 - 1)); return 0; }
    var len: int64 := peek64(img + GRF_OFF_PIXLEN);
    var px: int64 := peek64(img + GRF_OFF_PIXELS);''')
else:
    print('''    var info: int64 := alloc(PNGM_INFO_SIZE);
    var ri: int64 := PngMemInfo(src, n, info);
    var dl: int64 := 64;
    var wl: int64 := 65536;
    if (ri == 1) { dl := peek64(info + PNGM_INFO_DSTLEN); wl := peek64(info + PNGM_INFO_WORKLEN); }''')
    if mode == 'klein':
        print('    dl := dl - 1;')
    print('''    var px: int64 := alloc(dl + 16);
    var work: int64 := alloc(wl);
    var i0: int64 := 0;
    while (i0 < dl + 16) { poke8(px + i0, 0xEE); i0 := i0 + 1; }
    var len: int64 := PngDecodeFromMemory(src, n, px, dl, work, wl);
    if (len < 0) { PrintLn(IntToStr(len)); return 0; }
    if (peek8(px + dl) != 0xEE) { PrintLn("UEBERLAUF"c); return 0; }''')
print('''    PrintLn(IntToStr(len));
    var i: int64 := 0;
    while (i < len) { PrintLn(IntToStr(peek8(px + i))); i := i + 1; }
    return 0;
}''')
PY
}

laufe() { # ziel binary -> stdout
  if [ "$1" = arm64 ]; then timeout 30 "$QEMU_ARM64" "$2"; else timeout 30 "$2"; fi
}

pruefe() { # name ziel modus
  local name="$1" ziel="$2" modus="$3" tag="$1/$2/$3"
  programm "$TMP/$name.png" "$modus" "$TMP/p_${name}_$modus.lyx"
  uebersetze "$TMP/p_${name}_$modus.lyx" "$ziel" "$TMP/b_${name}_${ziel}_$modus"
  if [ ! -x "$TMP/b_${name}_${ziel}_$modus" ]; then no "$tag" "uebersetzt nicht"; return; fi
  laufe "$ziel" "$TMP/b_${name}_${ziel}_$modus" > "$TMP/o_${name}_${ziel}_$modus" 2>/dev/null
  local rc=$?
  if [ $rc -ge 124 ]; then no "$tag" "Lauf rc=$rc"; return; fi
  local first; first="$(head -1 "$TMP/o_${name}_${ziel}_$modus")"
  if [ "$modus" = klein ]; then
    if [ "$first" = "-3" ]; then ok "$tag: zu kleiner Ausgabepuffer -> -3"
    else no "$tag" "erwartet -3, bekam '$first'"; fi
    return
  fi
  if [ -f "$TMP/$name.err" ]; then
    case "$first" in
      -[0-9]*) ok "$tag: Fehlerwert $first" ;;
      *) no "$tag" "kaputte Datei lieferte '$first' statt eines negativen Werts" ;;
    esac
    return
  fi
  if cmp -s "$TMP/o_${name}_${ziel}_$modus" "$TMP/$name.exp"; then
    ok "$tag: $(head -1 "$TMP/$name.exp") Bytes stimmen"
  else
    local diff; diff="$(diff "$TMP/o_${name}_${ziel}_$modus" "$TMP/$name.exp" | head -3 | tr '\n' ' ')"
    no "$tag" "Pixelbytes weichen ab: $diff"
  fi
}

GUT="rgb3x2 rgb_f04 rgba_chunks rgba_stored gray16 graya rgb_big rgb_dyn"
KAPUTT="kaputt_halb kaputt_zlibkurz kaputt_bitkipper kaputt_adler kaputt_filter kaputt_signatur"

for n in $GUT $KAPUTT; do pruefe "$n" x86_64 mem; done
pruefe rgb_f04 x86_64 klein
# 3. die alte API sieht dieselben Bytes
for n in $GUT; do pruefe "$n" x86_64 alt; done

# Derselbe Weg auf arm64 — er ist zielunabhaengig.
if [ -n "${QEMU_ARM64:-}" ]; then
  for n in rgb3x2 rgb_f04 rgba_chunks rgba_stored gray16 graya rgb_big rgb_dyn kaputt_zlibkurz kaputt_adler kaputt_filter; do
    pruefe "$n" arm64 mem
  done
else
  echo "HINWEIS: kein qemu-aarch64 — arm64-Lauf entfaellt"
fi

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
