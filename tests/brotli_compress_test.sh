#!/usr/bin/env bash
# tests/brotli_compress_test.sh — #1075: BrotliCompress komprimiert wirklich.
#
# Vorher erzeugte BrotliCompress gültige, aber unkomprimierte Ströme: nur
# ISUNCOMPRESSED-Meta-Blöcke, kein einziges gespartes Byte. Jetzt echte
# komprimierte Meta-Blöcke — Huffman-codierte Literale, Insert-and-Copy-Codes
# und Distanzcodes.
#
# Geprüft wird ausschließlich gegen die REFERENZIMPLEMENTIERUNG (python3
# `brotli`), nicht gegen den eigenen Dekodierer. Das ist hier keine
# Vorsichtsmaßnahme, sondern zwingend: der eigene Dekodierer stürzt auf
# gültigen Brotli-Strömen ab — auch auf denen der Referenz. Siehe das eigene
# Issue dazu; bis das behoben ist, wäre er als Prüfinstanz wertlos.
#
# Der Test hält drei Dinge fest:
#
#   1. Fremdlesbarkeit — die Referenz muss unsere Ströme wörtlich auspacken.
#   2. Ersparnis — komprimierbare Eingaben müssen deutlich kleiner werden.
#      Ohne diese Schranke wäre die alte Store-Fassung weiterhin grün.
#   3. Zufallsdaten dürfen NICHT schrumpfen und müssen trotzdem stimmen: der
#      Rückfall auf den unkomprimierten Meta-Block muss funktionieren.
#
# Die Größen sind so gewählt, dass sie die MNIBBLES-Grenzen des Meta-Block-
# Kopfes überschreiten (4, 5 und 6 Nibbles für MLEN).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

python3 -c "import brotli" 2>/dev/null || { echo "SKIP: python3 brotli nicht vorhanden"; exit 0; }

python3 - "$TMP" <<'PY'
import sys, random
d = sys.argv[1]
T = (b"Lyx ist eine statisch typisierte Systemsprache mit eigenem Compiler. "
     b"Der Compiler ist selbsthostend und uebersetzt sich selbst. ") * 20000
# 100 kreuzt den Fall "Kopie endet punktgenau auf MLEN", 70000 und 300000 die
# MNIBBLES-Grenzen 16 und 20 Bit.
for n in (0, 1, 16, 100, 1000, 65536, 70000, 300000):
    open(f"{d}/s{n}.bin", "wb").write(T[:n])
open(f"{d}/rle.bin", "wb").write(b"A" * 50000)
random.seed(1075)
open(f"{d}/rand.bin", "wb").write(bytes(random.randrange(256) for _ in range(20000)))
PY

cat > "$TMP/c.lyx" <<'EOF'
import std.io;
import std.alloc;
import std.fs;
import std.brotli;
// Komprimiert eine Datei und schreibt den Strom roh auf stdout.
pub fn main(argc: int64, argv: pchar): int64 {
  if (argc < 2) { return 2; }
  var path: pchar := ArgvGet(argv, 1);
  var sz: int64 := FileSize(path);
  if (sz < 0) { return 3; }
  var buf: int64 := alloc(sz + 16);
  if (sz > 0) { var fd: int64 := open(path, 0, 0); read(fd, buf as pchar, sz); close(fd); }
  var capc: int64 := sz + sz / 2 + 65536;
  var out: int64 := alloc(capc);
  var n: int64 := BrotliCompress(buf, sz, out, capc);
  if (n < 0) { return 10; }
  sys_write(1, out, n);
  return 0;
}
EOF
"$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1 || {
  echo "FAIL: Packer uebersetzt nicht"; exit 1; }

check() { # name, maximal erlaubte Ausgabegröße (0 = keine Schranke)
  local name="$1" limit="$2" src="$TMP/$1.bin"
  if ! timeout 300 "$TMP/c" "$src" > "$TMP/$1.br" 2>/dev/null; then
    echo "FAIL $name: BrotliCompress meldet Fehler"; FAIL=$((FAIL+1)); return
  fi
  local insz outsz
  insz=$(stat -c%s "$src"); outsz=$(stat -c%s "$TMP/$1.br")
  if ! python3 - "$TMP/$1.br" "$src" <<'PY'
import sys, brotli
data = open(sys.argv[1], "rb").read()
src  = open(sys.argv[2], "rb").read()
try:
    out = brotli.decompress(data)
except Exception as e:
    print("   ", e, file=sys.stderr); sys.exit(1)
sys.exit(0 if out == src else 2)
PY
  then
    echo "FAIL $name: Referenzimplementierung lehnt den Strom ab oder liefert anderen Inhalt"
    FAIL=$((FAIL+1)); return
  fi
  if [ "$limit" -gt 0 ] && [ "$outsz" -gt "$limit" ]; then
    echo "FAIL $name: $insz -> $outsz Byte, erwartet hoechstens $limit"; FAIL=$((FAIL+1)); return
  fi
  echo "PASS $name ($insz -> $outsz Byte)"; PASS=$((PASS+1))
}

# Randfälle: müssen gültige Ströme ergeben.
check s0      0
check s1      0
check s16     0
check s100    0
# Komprimierbares muss deutlich schrumpfen. Die Schranken liegen weit über den
# gemessenen Werten, damit der Test nicht bei jeder Verbesserung des Matchers
# rot wird — aber weit unter der Eingabe, damit Store-Verhalten auffällt.
check s1000   200      # gemessen 69
check s65536  500      # gemessen 71
check s70000  500      # gemessen 71
check s300000 500      # gemessen 71
check rle     100      # gemessen 12
# Gegenprobe: Zufallsdaten dürfen nicht schrumpfen, müssen aber stimmen.
check rand    20200

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
