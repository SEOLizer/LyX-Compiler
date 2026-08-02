#!/usr/bin/env bash
# tests/deflate_single_source_test.sh — #1071: EINE DEFLATE-Kompression.
#
# Bis 1.0.11D lag der Encoder doppelt vor: std/zlib.lyx und
# std/pdf/compress.lyx, jeweils mit eigenem Bitschreiber, eigener
# Symbolemission und eigener Hashtabelle. Beide lösten dasselbe Problem mit
# denselben Parametern — und ein Fix in der einen erreichte die andere nicht.
#
# Genau das war passiert: die Fassung in std/zlib.lyx schrieb je 32768 Byte
# einen NEUEN Blockkopf, setzte das End-of-Block-Symbol aber nur EINMAL ganz
# am Schluss. Ab 32 kB Eingabe war der Strom damit ungültig, und gemeldet
# wurde nichts — die Funktion lieferte eine plausible Bytezahl. Betroffen
# waren std/gzip.lyx und der ZIP-Writer. Aufgefallen ist es erst, als beide
# Implementierungen auf dieselbe Eingabe geworfen und mit einem FREMDEN
# Inflater gegengelesen wurden.
#
# Der Test hält beides fest:
#
#   1. Die 32-kB-Grenze. Eingaben darüber müssen gültige Ströme ergeben —
#      das ist der Regressionswächter für den eigentlichen Defekt.
#   2. Beide öffentlichen Einstiege müssen BYTEGLEICHE Ausgaben liefern.
#      Weichen sie ab, gibt es wieder zwei Implementierungen.
#
# Gegengelesen wird mit python3 `zlib`, also einer fremden Implementierung.
# Der eigene Inflater allein belegt nichts: zwei zueinander passende Fehler
# heben sich gegenseitig auf — und genau dieser Fall lag hier vor, denn der
# eigene Inflater las die kaputten Ströme klaglos.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

python3 -c "import zlib" 2>/dev/null || { echo "SKIP: python3 zlib nicht vorhanden"; exit 0; }

python3 - "$TMP" <<'PY'
import sys, random
d = sys.argv[1]
T = b"Lyx ist eine statisch typisierte Systemsprache mit eigenem Compiler. " * 6000
# Die Größen sind so gewählt, dass die alte 32768er-Blockgrenze mehrfach
# überschritten wird.
for n in (1000, 20000, 33000, 40000, 100000, 300000):
    open(f"{d}/in_{n}.bin", "wb").write(T[:n])
random.seed(1071)
open(f"{d}/rand.bin", "wb").write(bytes(random.randrange(256) for _ in range(20000)))
PY

cat > "$TMP/c.lyx" <<'EOF'
import std.io;
import std.alloc;
import std.fs;
import std.zlib;
import std.pdf.compress;
// argv: <a|b> <pfad>   a = std.zlib ZlibCompress, b = std.pdf.compress zlibCompress
pub fn main(argc: int64, argv: pchar): int64 {
  if (argc < 3) { return 2; }
  var which: pchar := ArgvGet(argv, 1);
  var path: pchar := ArgvGet(argv, 2);
  var sz: int64 := FileSize(path);
  if (sz <= 0) { return 3; }
  var buf: int64 := alloc(sz + 16);
  var fd: int64 := open(path, 0, 0); read(fd, buf as pchar, sz); close(fd);
  var capc: int64 := ZlibCompressBound(sz) + 1024;
  var out: int64 := alloc(capc);
  var n: int64 := 0;
  if (StrCharAt(which, 0) == 97) { n := ZlibCompress(buf as pchar, sz, out as pchar, 6); }
  else { n := zlibCompress(buf, sz, out); }
  if (n <= 0) { return 10; }
  sys_write(1, out, n);
  return 0;
}
EOF
"$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1 || {
  echo "FAIL: Testprogramm uebersetzt nicht"; exit 1; }

check() { # datei
  local src="$1" name
  name="$(basename "$src" .bin)"
  for w in a b; do
    if ! timeout 120 "$TMP/c" "$w" "$src" > "$TMP/$name.$w.z" 2>/dev/null; then
      echo "FAIL $name ($w): Kompression meldet Fehler"; FAIL=$((FAIL+1)); return
    fi
  done
  # 1. Beide Ausgaben müssen von einem FREMDEN Inflater lesbar sein.
  for w in a b; do
    if ! python3 - "$TMP/$name.$w.z" "$src" <<'PY'
import sys, zlib
data = open(sys.argv[1], "rb").read()
src  = open(sys.argv[2], "rb").read()
try:
    out = zlib.decompress(data)
except Exception as e:
    print("   ", e, file=sys.stderr); sys.exit(1)
sys.exit(0 if out == src else 2)
PY
    then
      echo "FAIL $name ($w): fremder Inflater lehnt den Strom ab oder liefert anderen Inhalt"
      FAIL=$((FAIL+1)); return
    fi
  done
  # 2. Eine Quelle heißt: byteweise dasselbe Ergebnis.
  if ! cmp -s "$TMP/$name.a.z" "$TMP/$name.b.z"; then
    echo "FAIL $name: std.zlib und std.pdf.compress liefern verschiedene Ausgaben"
    FAIL=$((FAIL+1)); return
  fi
  echo "PASS $name ($(stat -c%s "$src") -> $(stat -c%s "$TMP/$name.a.z") Byte, beide Wege gleich)"
  PASS=$((PASS+1))
}

for f in "$TMP"/in_*.bin "$TMP/rand.bin"; do check "$f"; done

# --- Die betroffenen Aufrufer über der alten Blockgrenze -----------------
# gzip und der ZIP-Writer benutzen denselben Encoder. Ohne diese Fälle bliebe
# der Defekt in genau den Pfaden unbemerkt, in denen er sich auswirkte.
if command -v gzip >/dev/null 2>&1; then
  cat > "$TMP/g.lyx" <<'EOF'
import std.io;
import std.alloc;
import std.fs;
import std.gzip;
pub fn main(argc: int64, argv: pchar): int64 {
  if (argc < 2) { return 2; }
  var path: pchar := ArgvGet(argv, 1);
  var sz: int64 := FileSize(path);
  if (sz <= 0) { return 3; }
  var buf: int64 := alloc(sz + 16);
  var fd: int64 := open(path, 0, 0); read(fd, buf as pchar, sz); close(fd);
  var capc: int64 := GzipCompressBound(sz) + 1024;
  var out: int64 := alloc(capc);
  var n: int64 := GzipCompress(buf, sz, out, capc);
  if (n < 0) { return 10; }
  sys_write(1, out, n);
  return 0;
}
EOF
  if "$LYXC" --std-path="$ROOT" "$TMP/g.lyx" -o "$TMP/g" >/dev/null 2>&1; then
    if timeout 120 "$TMP/g" "$TMP/in_300000.bin" > "$TMP/big.gz" 2>/dev/null \
       && gzip -d -c "$TMP/big.gz" > "$TMP/big.back" 2>/dev/null \
       && cmp -s "$TMP/big.back" "$TMP/in_300000.bin"; then
      echo "PASS gzip ueber 32 kB (300000 -> $(stat -c%s "$TMP/big.gz") Byte, gzip-CLI liest)"
      PASS=$((PASS+1))
    else
      echo "FAIL gzip ueber 32 kB: gzip-CLI kann den Strom nicht lesen"; FAIL=$((FAIL+1))
    fi
  else
    echo "FAIL gzip-Testprogramm uebersetzt nicht"; FAIL=$((FAIL+1))
  fi
fi

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
