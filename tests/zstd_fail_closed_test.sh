#!/usr/bin/env bash
# tests/zstd_fail_closed_test.sh — #1027: ZstdDecompress muss melden statt raten.
#
# Der Decoder fuer Compressed Blocks (Huffman/FSE) ist defekt: ueber 97 Frames
# derselben Textquelle in aufsteigender Groesse stuerzte er 67-mal ab und lieferte
# 5-mal stillschweigend falschen Inhalt. Solange er nicht repariert ist, muss
# ZSTD_ERR zurueckkommen — ein Aufrufer kann Muell nicht von echten Daten
# unterscheiden.
#
# Geprueft wird deshalb dreierlei: Raw Blocks und der eigene Store-Modus liefern
# weiterhin korrekte Daten, und ein Compressed Block wird gemeldet statt geraten
# oder abgestuerzt.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; LYXC="$ROOT/lyxc"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

command -v zstd >/dev/null 2>&1 || { echo "SKIP: zstd-CLI nicht vorhanden"; exit 0; }

# inkompressibel -> Raw Blocks; komprimierbar -> Compressed Blocks
head -c 200 /dev/urandom > "$TMP/raw.bin"
zstd -1 -f -q "$TMP/raw.bin" -o "$TMP/raw.zst"
printf 'hello world, hello world, hello world!\n%.0s' 1 2 3 > "$TMP/comp.bin"
zstd -1 -f -q "$TMP/comp.bin" -o "$TMP/comp.zst"

cat > "$TMP/t.lyx" <<EOF
import std.zstd;
import std.alloc;
import src.std.io;
fn load(path: pchar, lenOut: int64): int64 {
  var fd: int64 := open(path, 0, 0);
  if (fd < 0) { poke64(lenOut, 0); return 0; }
  var b: int64 := alloc(262144);
  var n: int64 := read(fd, b, 262144);
  close(fd);
  poke64(lenOut, n);
  return b;
}
fn main(): int64 {
  var lo: int64 := alloc(8);
  var rc: int64 := 0;

  // 1. Raw Block: muss byteweise stimmen
  var z: int64 := load("$TMP/raw.zst"c, lo);
  var zn: int64 := peek64(lo);
  var o: int64 := load("$TMP/raw.bin"c, lo);
  var on: int64 := peek64(lo);
  var out: int64 := alloc(262144);
  var r: int64 := ZstdDecompress(z, zn, out, 262144);
  if (r != on) { PrintStrLn("FAIL raw_block: Laenge"); rc := 1; }
  else {
    var i: int64 := 0; var bad: int64 := 0;
    while (i < on) { if (peek8(out + i) != peek8(o + i)) { bad := bad + 1; } i := i + 1; }
    if (bad != 0) { PrintStrLn("FAIL raw_block: Inhalt"); rc := 1; }
    else { PrintStrLn("PASS raw_block"); }
  }

  // 2. Compressed Block: muss ZSTD_ERR liefern, nicht raten und nicht abstuerzen
  var z2: int64 := load("$TMP/comp.zst"c, lo);
  var zn2: int64 := peek64(lo);
  var out2: int64 := alloc(262144);
  var r2: int64 := ZstdDecompress(z2, zn2, out2, 262144);
  if (r2 != ZSTD_ERR) { PrintStrLn("FAIL compressed_block: kein ZSTD_ERR"); rc := 1; }
  else { PrintStrLn("PASS compressed_block (gemeldet)"); }

  // 3. Eigener Store-Modus: round-trip
  var src2: int64 := alloc(8192);
  var i2: int64 := 0;
  while (i2 < 3000) { poke8(src2 + i2, 65 + (i2 % 26)); i2 := i2 + 1; }
  var packed: int64 := alloc(16384);
  var pl: int64 := ZstdCompress(src2, 3000, packed, 16384);
  var un: int64 := alloc(16384);
  var ul: int64 := ZstdDecompress(packed, pl, un, 16384);
  var bad2: int64 := 0; i2 := 0;
  while (i2 < 3000) { if (peek8(un + i2) != peek8(src2 + i2)) { bad2 := bad2 + 1; } i2 := i2 + 1; }
  if ((ul != 3000) | (bad2 != 0)) { PrintStrLn("FAIL store_roundtrip"); rc := 1; }
  else { PrintStrLn("PASS store_roundtrip"); }

  return rc;
}
EOF

if ! "$LYXC" --std-path="$ROOT" "$TMP/t.lyx" -o "$TMP/t" >/dev/null 2>&1; then
  echo "FAIL: Testprogramm uebersetzt nicht"; exit 1
fi
timeout 30 "$TMP/t"; rc=$?
if [ "$rc" -ge 128 ]; then echo "FAIL: Absturz (rc=$rc)"; exit 1; fi
exit "$rc"
