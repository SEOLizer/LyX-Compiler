#!/usr/bin/env bash
# tests/brotli_decode_test.sh — #1079: BrotliDecompress an echten Strömen.
#
# Der Dekodierer war als "vollständige RFC-7932-Implementierung" beschrieben
# und stürzte auf gültigen Strömen ab — auch auf denen der
# Referenzimplementierung. Der Grund, warum das jahrelang unbemerkt blieb,
# steht im Befund selbst: es gab keinen Brotli-Test und keinen Kompressor, an
# dem sich der Dekodierer hätte messen lassen.
#
# Ausgangslage über 36 Frames: 13 korrekt, 23 Abstürze.
#
# Gezählt werden VIER Ausgänge getrennt, weil sie unterschiedlich schlimm sind:
#   korrekt        — Inhalt stimmt
#   still-falsch   — plausible Rückgabe, falscher Inhalt, KEIN Fehlerflag
#   gemeldet       — sauber als Fehler zurückgewiesen
#   abgestürzt     — Signal
#
# Grün ist der Test nur, wenn nichts still falsch ist und nichts abstürzt.
# GEMELDETE Frames sind ausdrücklich erlaubt: das statische Wörterbuch
# (RFC 7932 §8) ist nicht umgesetzt, und ein Strom, der es braucht, MUSS als
# Fehler zurückkommen statt geraten zu werden. Die Zahl wird ausgegeben, damit
# sichtbar bleibt, wie groß diese Lücke ist.
#
# Dazu zwei Dinge, die der Frame-Zähler nicht abdeckt:
#   * die Rundreise durch die eigene Kette (komprimieren, dann auspacken) —
#     sie muss für jede Eingabe wörtlich zurückkommen;
#   * die CRC-32 der drei Kontext-Lookup-Tabellen aus §7.1. Der RFC gibt sie
#     an, und genau solche von Hand übernommenen Tabellen waren in diesem
#     Repo schon mehrfach falsch (zstd #1027, brotli #1075).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

python3 -c "import brotli" 2>/dev/null || { echo "SKIP: python3 brotli nicht vorhanden"; exit 0; }

python3 - "$TMP" <<'PY'
import sys, brotli, random
d = sys.argv[1]
T = (b"Lyx ist eine statisch typisierte Systemsprache mit eigenem Compiler. "
     b"Der Compiler ist selbsthostend und uebersetzt sich selbst. ") * 4000
random.seed(1079)
cases = {}
for n in (1, 20, 100, 1000, 20000, 200000):
    cases[f"text{n}"] = T[:n]
cases["rle"]     = b"A" * 50000
cases["rand"]    = bytes(random.randrange(256) for _ in range(20000))
cases["pattern"] = (b"abcdefgh" * 4) * 2000
# Nicht-Text mit Struktur: trifft die Kontextmodi UTF8 und Signed, die von
# reinem Text nicht erreicht werden.
cases["binary"]  = bytes((i * 7) % 251 for i in range(30000))
for name, data in cases.items():
    open(f"{d}/{name}.bin", "wb").write(data)
    for q in range(0, 12):          # alle Qualitätsstufen
        open(f"{d}/{name}_q{q}.br", "wb").write(brotli.compress(data, quality=q))
PY

cat > "$TMP/d.lyx" <<'EOF'
import std.io;
import std.alloc;
import std.fs;
import std.brotli;
pub fn main(argc: int64, argv: pchar): int64 {
  if (argc < 3) { return 2; }
  var path: pchar := ArgvGet(argv, 1);
  var cap:  int64 := StrToInt(ArgvGet(argv, 2));
  var sz: int64 := FileSize(path);
  if (sz <= 0) { return 3; }
  var buf: int64 := alloc(sz + 16);
  var fd: int64 := open(path, 0, 0); read(fd, buf as pchar, sz); close(fd);
  var out: int64 := alloc(cap + 16);
  var n: int64 := BrotliDecompress(buf, sz, out, cap);
  if (n < 0) { return 10; }
  sys_write(1, out, n);
  return 0;
}
EOF
cat > "$TMP/c.lyx" <<'EOF'
import std.io;
import std.alloc;
import std.fs;
import std.brotli;
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
"$LYXC" --std-path="$ROOT" "$TMP/d.lyx" -o "$TMP/d" >/dev/null 2>&1 || {
  echo "FAIL: Entpacker uebersetzt nicht"; exit 1; }
"$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1 || {
  echo "FAIL: Packer uebersetzt nicht"; exit 1; }

# --- Referenzströme: vier Ausgänge getrennt zählen ------------------------
ok=0; wrong=0; err=0; crash=0
for z in "$TMP"/*.br; do
  b="$(basename "$z" .br)"
  src="$TMP/$(echo "$b" | sed 's/_q[0-9]*$//').bin"
  timeout 60 "$TMP/d" "$z" 400000 > "$TMP/out.bin" 2>/dev/null; rc=$?
  if   [ "$rc" -ge 128 ]; then crash=$((crash+1)); echo "  ABSTURZ      $b (rc=$rc)"
  elif [ "$rc" -ne 0 ];   then err=$((err+1))
  elif cmp -s "$TMP/out.bin" "$src"; then ok=$((ok+1))
  else wrong=$((wrong+1));                         echo "  STILL FALSCH $b"; fi
done
echo "Referenzstroeme: korrekt=$ok  still-falsch=$wrong  gemeldet=$err  abgestuerzt=$crash"
echo "  (gemeldet = statisches Woerterbuch, RFC 7932 Abschnitt 8, nicht umgesetzt)"
if [ "$wrong" -eq 0 ] && [ "$crash" -eq 0 ]; then
  echo "PASS Referenzstroeme"; PASS=$((PASS+1))
else
  echo "FAIL Referenzstroeme"; FAIL=$((FAIL+1))
fi

# --- Rundreise durch die eigene Kette -------------------------------------
rtfail=0
for f in "$TMP"/*.bin; do
  sz=$(stat -c%s "$f"); [ "$sz" -eq 0 ] && continue
  if ! timeout 300 "$TMP/c" "$f" > "$TMP/rt.br" 2>/dev/null; then
    echo "  Rundreise $(basename "$f"): Kompression meldet Fehler"; rtfail=$((rtfail+1)); continue
  fi
  timeout 300 "$TMP/d" "$TMP/rt.br" $((sz + 4096)) > "$TMP/rt.bin" 2>/dev/null; rc=$?
  if [ "$rc" -ne 0 ] || ! cmp -s "$TMP/rt.bin" "$f"; then
    echo "  Rundreise $(basename "$f"): rc=$rc, Inhalt weicht ab"; rtfail=$((rtfail+1))
  fi
done
if [ "$rtfail" -eq 0 ]; then echo "PASS Rundreise"; PASS=$((PASS+1))
else echo "FAIL Rundreise ($rtfail Faelle)"; FAIL=$((FAIL+1)); fi

# --- CRC-32 der Kontexttabellen aus RFC 7932 Abschnitt 7.1 ---------------
# Die Tabellen stehen als Funktionen in std/brotli.lyx. Hier werden alle 256
# Werte abgefragt und gegen die im RFC angegebenen Pruefsummen gehalten.
cat > "$TMP/lut.lyx" <<'EOF'
import std.io;
import std.brotli;
pub fn main(): int64 {
  var i: int64 := 0;
  while (i < 256) { Print(BrLut0(i)); Print(" "); i := i + 1; }
  PrintLn("");
  i := 0;
  while (i < 256) { Print(BrLut1(i)); Print(" "); i := i + 1; }
  PrintLn("");
  i := 0;
  while (i < 256) { Print(BrLut2(i)); Print(" "); i := i + 1; }
  PrintLn("");
  return 0;
}
EOF
if "$LYXC" --std-path="$ROOT" "$TMP/lut.lyx" -o "$TMP/lut" >/dev/null 2>&1 \
   && timeout 60 "$TMP/lut" > "$TMP/lut.txt" 2>/dev/null; then
  if python3 - "$TMP/lut.txt" <<'PY'
import sys, zlib
rows = [l.split() for l in open(sys.argv[1]).read().strip().split("\n")]
want = (0x8e91efb7, 0xd01a32f4, 0x0dd7a0d6)
ok = True
for i, (row, w) in enumerate(zip(rows, want)):
    vals = [int(x) for x in row]
    got = zlib.crc32(bytes(vals))
    if len(vals) != 256 or got != w:
        print(f"  Lut{i}: len={len(vals)} crc={got:#x} erwartet={w:#x}")
        ok = False
sys.exit(0 if ok and len(rows) == 3 else 1)
PY
  then echo "PASS Kontexttabellen (CRC-32 laut RFC)"; PASS=$((PASS+1))
  else echo "FAIL Kontexttabellen: CRC-32 weicht ab"; FAIL=$((FAIL+1)); fi
else
  echo "FAIL Kontexttabellen: Pruefprogramm laeuft nicht"; FAIL=$((FAIL+1))
fi

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
