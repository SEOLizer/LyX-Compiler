#!/usr/bin/env bash
# tests/zstd_compress_test.sh — #1069: ZstdCompress komprimiert wirklich.
#
# Vorher erzeugte ZstdCompress gültige, aber unkomprimierte Frames: nur raw
# blocks, kein einziges gespartes Byte. Der Name sagte das nicht — ein
# Aufrufer, der „Compress" wählt, bekam schweigend eine Vergrößerung.
#
# Der Test prüft deshalb ZWEI Dinge, die einzeln beide wertlos wären:
#
#   1. Fremdlesbarkeit — die `zstd`-CLI muss unsere Frames auspacken können und
#      wörtlich das Original zurückgeben. Nur der eigene Decoder wäre kein
#      Beleg: zwei zueinander passende Fehler heben sich gegenseitig auf.
#   2. Ersparnis — auf komprimierbaren Eingaben muss die Ausgabe deutlich
#      KLEINER sein als die Eingabe. Ohne diese Schranke wäre die alte
#      Store-Fassung weiterhin grün.
#
# Dazu die Gegenprobe mit Zufallsdaten: dort DARF nicht komprimiert werden, die
# Ausgabe muss nahe an der Eingabe bleiben und trotzdem stimmen. Eine
# Implementierung, die Inkompressibles „schrumpfen" lässt, hat einen Fehler.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

command -v zstd >/dev/null 2>&1 || { echo "SKIP: zstd-CLI nicht vorhanden"; exit 0; }

python3 - "$TMP" <<'PY'
import sys, random
d = sys.argv[1]
T = ("Lyx ist eine statisch typisierte Systemsprache mit eigenem Compiler. "
     "Der Compiler ist selbsthostend und uebersetzt sich selbst. ")
big = (T * 8000).encode()
open(f"{d}/text.bin",    "wb").write(big[:20000])
open(f"{d}/multi.bin",   "wb").write(big[:300000])   # > 128 kB: mehrere Bloecke
open(f"{d}/rle.bin",     "wb").write(b"A" * 50000)
open(f"{d}/pattern.bin", "wb").write((b"abcdefgh" * 4) * 500)
random.seed(1069)
open(f"{d}/random.bin",  "wb").write(bytes(random.randrange(256) for _ in range(20000)))
open(f"{d}/empty.bin",   "wb").write(b"")
open(f"{d}/tiny.bin",    "wb").write(b"x")
PY

cat > "$TMP/pack.lyx" <<'EOF'
import std.io;
import std.alloc;
import std.fs;
import std.zstd;
// Komprimiert eine Datei und schreibt den Frame roh auf stdout.
pub fn main(argc: int64, argv: pchar): int64 {
  if (argc < 2) { return 2; }
  var path: pchar := ArgvGet(argv, 1);
  var sz: int64 := FileSize(path);
  if (sz < 0) { return 3; }
  var buf: int64 := alloc(sz + 16);
  if (sz > 0) {
    var fd: int64 := open(path, 0, 0);
    read(fd, buf as pchar, sz);
    close(fd);
  }
  var capc: int64 := sz + sz / 2 + 65536;
  var packed: int64 := alloc(capc);
  var pl: int64 := ZstdCompress(buf, sz, packed, capc);
  if (pl < 0) { return 10; }
  sys_write(1, packed, pl);
  return 0;
}
EOF
"$LYXC" --std-path="$ROOT" "$TMP/pack.lyx" -o "$TMP/pack" >/dev/null 2>&1 || {
  echo "FAIL: Packer uebersetzt nicht"; exit 1; }

# name, maximal erlaubte Ausgabegröße (0 = keine Schranke)
check() {
  local name="$1" limit="$2"
  local src="$TMP/$name.bin"
  if ! timeout 120 "$TMP/pack" "$src" > "$TMP/$name.zst" 2>/dev/null; then
    echo "FAIL $name: ZstdCompress meldet Fehler"; FAIL=$((FAIL+1)); return
  fi
  local insz outsz
  insz=$(stat -c%s "$src"); outsz=$(stat -c%s "$TMP/$name.zst")

  # Fremdlesbarkeit: die CLI muss den Frame verstehen.
  if ! zstd -d -c "$TMP/$name.zst" > "$TMP/$name.back" 2>/dev/null; then
    echo "FAIL $name: zstd-CLI kann den Frame nicht auspacken"; FAIL=$((FAIL+1)); return
  fi
  if ! cmp -s "$TMP/$name.back" "$src"; then
    echo "FAIL $name: CLI liefert anderen Inhalt"; FAIL=$((FAIL+1)); return
  fi
  if [ "$limit" -gt 0 ] && [ "$outsz" -gt "$limit" ]; then
    echo "FAIL $name: $insz -> $outsz Byte, erwartet hoechstens $limit"; FAIL=$((FAIL+1)); return
  fi
  echo "PASS $name ($insz -> $outsz Byte)"; PASS=$((PASS+1))
}

# Komprimierbares muss deutlich schrumpfen. Die Schranken liegen weit über dem
# gemessenen Wert, damit der Test nicht bei jeder Verbesserung des Matchers
# rot wird — aber weit unter der Eingabe, damit Store-Verhalten auffällt.
check text     2000       # gemessen 135
check multi    5000       # gemessen 385, mehrere Blöcke
check rle      100        # gemessen 17, RLE-Block
check pattern  200        # gemessen 33
# Zufallsdaten: keine Ersparnis möglich, aber auch keine Vergrößerung über den
# Rahmen hinaus. Mehr als 1 % Aufschlag hieße, dass etwas nicht stimmt.
check random   20200
# Randfälle: leer und ein einzelnes Byte müssen gültige Frames ergeben.
check empty    0
check tiny     0

# Gegenprobe: der eigene Decoder muss dasselbe liefern wie die CLI. Stimmen
# beide überein, ist ein zueinander passendes Fehlerpaar ausgeschlossen.
cat > "$TMP/rt.lyx" <<'EOF'
import std.io;
import std.alloc;
import std.fs;
import std.zstd;
pub fn main(argc: int64, argv: pchar): int64 {
  if (argc < 3) { return 2; }
  var path: pchar := ArgvGet(argv, 1);
  var cap:  int64 := StrToInt(ArgvGet(argv, 2));
  var sz: int64 := FileSize(path);
  if (sz <= 0) { return 3; }
  var buf: int64 := alloc(sz + 16);
  var fd: int64 := open(path, 0, 0);
  read(fd, buf as pchar, sz);
  close(fd);
  var out: int64 := alloc(cap + 16);
  var n: int64 := ZstdDecompress(buf, sz, out, cap);
  if (n < 0) { return 10; }
  sys_write(1, out, n);
  return 0;
}
EOF
"$LYXC" --std-path="$ROOT" "$TMP/rt.lyx" -o "$TMP/rt" >/dev/null 2>&1 || {
  echo "FAIL: Entpacker uebersetzt nicht"; exit 1; }

for name in text multi rle pattern random tiny; do
  [ -f "$TMP/$name.zst" ] || continue
  cap=$(( $(stat -c%s "$TMP/$name.bin") + 4096 ))
  if timeout 120 "$TMP/rt" "$TMP/$name.zst" "$cap" > "$TMP/$name.own" 2>/dev/null \
     && cmp -s "$TMP/$name.own" "$TMP/$name.bin"; then
    echo "PASS $name eigener Decoder"; PASS=$((PASS+1))
  else
    echo "FAIL $name: eigener Decoder liefert etwas anderes als die CLI"; FAIL=$((FAIL+1))
  fi
done

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
