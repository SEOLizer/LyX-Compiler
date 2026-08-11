#!/usr/bin/env bash
# tests/gzip_test.sh — #1070: gzip-Container (RFC 1952).
#
# DEFLATE und die reflektierte CRC-32 lagen schon da; es fehlte nur der Rahmen.
# Der Aufwand steckt entsprechend nicht im Codec, sondern in den Fällen, die
# man beim Rahmen leicht übersieht — genau die prüft dieser Test:
#
#   * die OPTIONALEN Kopffelder (FNAME, FEXTRA, FCOMMENT, FHCRC). Wer sie nicht
#     überspringt, setzt den DEFLATE-Strom an der falschen Stelle an.
#   * MEHRERE Member (`cat a.gz b.gz`) — sonst wird der erste ausgepackt und
#     der Rest still verschluckt.
#   * der Trailer wird GEPRÜFT, nicht nur gelesen: falsche CRC, falsche ISIZE
#     und abgeschnittene Ströme müssen gemeldet werden.
#
# Gegengelesen wird in beide Richtungen mit der `gzip`-CLI. Nur gegen sich
# selbst zu prüfen belegt nichts: zwei zueinander passende Fehler heben sich
# gegenseitig auf.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

command -v gzip >/dev/null 2>&1 || { echo "SKIP: gzip-CLI nicht vorhanden"; exit 0; }

python3 - "$TMP" <<'PY'
import sys, random
d = sys.argv[1]
T = b"Lyx ist eine statisch typisierte Systemsprache mit eigenem Compiler. " * 300
open(f"{d}/text.bin",  "wb").write(T)
open(f"{d}/small.bin", "wb").write(b"hallo hallo hallo")
open(f"{d}/empty.bin", "wb").write(b"")
random.seed(1070)
open(f"{d}/rand.bin",  "wb").write(bytes(random.randrange(256) for _ in range(5000)))
PY

cat > "$TMP/gz.lyx" <<'EOF'
import std.io;
import std.alloc;
import std.fs;
import std.gzip;
// argv: <d|c> <pfad> <cap>  — schreibt das Ergebnis roh auf stdout.
pub fn main(argc: int64, argv: pchar): int64 {
  if (argc < 4) { return 2; }
  var mode: pchar := ArgvGet(argv, 1);
  var path: pchar := ArgvGet(argv, 2);
  var cap:  int64 := StrToInt(ArgvGet(argv, 3));
  var sz: int64 := FileSize(path);
  if (sz < 0) { return 3; }
  var buf: int64 := alloc(sz + 16);
  if (sz > 0) { var fd: int64 := open(path, 0, 0); read(fd, buf as pchar, sz); close(fd); }
  var out: int64 := alloc(cap + 16);
  var n: int64 := 0;
  if (StrCharAt(mode, 0) == 100) { n := GzipDecompress(buf, sz, out, cap); }
  else { n := GzipCompress(buf, sz, out, cap); }
  // Fehlercodes werden ueber den Exit-Code unterscheidbar gemacht:
  // 11 = GZIP_ERR, 12 = GZIP_OVERFLOW.
  if (n == GZIP_ERR)      { return 11; }
  if (n == GZIP_OVERFLOW) { return 12; }
  if (n < 0)              { return 13; }
  sys_write(1, out, n);
  return 0;
}
EOF
"$LYXC" --std-path="$ROOT" "$TMP/gz.lyx" -o "$TMP/gz" >/dev/null 2>&1 || {
  echo "FAIL: Testprogramm uebersetzt nicht"; exit 1; }

# --- Lesen: von der gzip-CLI erzeugte Ströme ------------------------------
gzip -c -n "$TMP/text.bin"  > "$TMP/plain.gz"      # ohne FNAME/MTIME
gzip -c    "$TMP/text.bin"  > "$TMP/withname.gz"   # mit FNAME und MTIME
gzip -c -9 "$TMP/text.bin"  > "$TMP/best.gz"
gzip -c -1 "$TMP/rand.bin"  > "$TMP/rand.gz"
gzip -c -n "$TMP/empty.bin" > "$TMP/empty.gz"
cat "$TMP/plain.gz" "$TMP/withname.gz" > "$TMP/two.gz"
cp "$TMP/plain.gz" "$TMP/pad.gz"; head -c 512 /dev/zero >> "$TMP/pad.gz"

read_ok() { # name, erwartete Datei
  if ! timeout 60 "$TMP/gz" d "$TMP/$1.gz" 4000000 > "$TMP/$1.out" 2>/dev/null; then
    echo "FAIL lesen $1: rc=$?"; FAIL=$((FAIL+1)); return
  fi
  if cmp -s "$TMP/$1.out" "$2"; then echo "PASS lesen $1"; PASS=$((PASS+1))
  else echo "FAIL lesen $1: anderer Inhalt"; FAIL=$((FAIL+1)); fi
}
read_ok plain    "$TMP/text.bin"
read_ok withname "$TMP/text.bin"
read_ok best     "$TMP/text.bin"
read_ok rand     "$TMP/rand.bin"
read_ok empty    "$TMP/empty.bin"
read_ok pad      "$TMP/text.bin"
cat "$TMP/text.bin" "$TMP/text.bin" > "$TMP/twice.bin"
read_ok two      "$TMP/twice.bin"

# FEXTRA kommt von der CLI nicht ohne Weiteres — deshalb von Hand einsetzen.
python3 - "$TMP" <<'PY'
import sys
d = sys.argv[1]
b = bytearray(open(f"{d}/plain.gz", "rb").read())
extra = b"XX\x04\x00abcd"                 # SI1 SI2 LEN(2) + 4 Byte Daten
b[3] |= 0x04                              # FEXTRA setzen
out = b[:10] + bytearray(len(extra).to_bytes(2, "little")) + extra + b[10:]
open(f"{d}/extra.gz", "wb").write(bytes(out))
PY
read_ok extra "$TMP/text.bin"

# FHCRC setzt die gzip-CLI nie (laut RFC selbst: bis gzip 1.2.4 nie gesetzt),
# also auch von Hand. Geprüft wird beides: eine richtige Kopfprüfsumme muss
# durchgehen, eine falsche muss auffallen. Der RFC erlaubt, das Feld nur zu
# überspringen — eine mitgeführte und nicht geprüfte Prüfsumme erweckt aber
# den Eindruck, der Kopf sei abgesichert.
python3 - "$TMP" <<'PYFH'
import sys, zlib
d = sys.argv[1]
b = bytearray(open(f"{d}/plain.gz", "rb").read())
b[3] |= 0x02                                   # FHCRC setzen
hdr = bytes(b[:10])
crc16 = zlib.crc32(hdr) & 0xFFFF
open(f"{d}/fhcrc.gz", "wb").write(hdr + crc16.to_bytes(2, "little") + bytes(b[10:]))
open(f"{d}/fhcrcbad.gz", "wb").write(hdr + (crc16 ^ 0xFFFF).to_bytes(2, "little") + bytes(b[10:]))
PYFH
read_ok fhcrc "$TMP/text.bin"

# --- Schreiben: die gzip-CLI muss unsere Ströme lesen ---------------------
write_ok() { # name
  local src="$TMP/$1.bin"
  if ! timeout 60 "$TMP/gz" c "$src" 4000000 > "$TMP/$1.mygz" 2>/dev/null; then
    echo "FAIL schreiben $1: rc=$?"; FAIL=$((FAIL+1)); return
  fi
  if ! gzip -d -c "$TMP/$1.mygz" > "$TMP/$1.back" 2>/dev/null; then
    echo "FAIL schreiben $1: gzip-CLI kann den Strom nicht lesen"; FAIL=$((FAIL+1)); return
  fi
  if cmp -s "$TMP/$1.back" "$src"; then
    echo "PASS schreiben $1 ($(stat -c%s "$src") -> $(stat -c%s "$TMP/$1.mygz") Byte)"
    PASS=$((PASS+1))
  else
    echo "FAIL schreiben $1: CLI liefert anderen Inhalt"; FAIL=$((FAIL+1))
  fi
}
write_ok text
write_ok small
write_ok rand
write_ok empty

# Komprimierbares muss auch wirklich schrumpfen, sonst wäre ein
# Store-Verhalten unbemerkt.
tsz=$(stat -c%s "$TMP/text.bin"); gsz=$(stat -c%s "$TMP/text.mygz")
if [ "$gsz" -lt $((tsz / 4)) ]; then echo "PASS Ersparnis ($tsz -> $gsz)"; PASS=$((PASS+1))
else echo "FAIL Ersparnis: $tsz -> $gsz Byte"; FAIL=$((FAIL+1)); fi

# Round-Trip durch die eigene Implementierung.
if timeout 60 "$TMP/gz" d "$TMP/text.mygz" 4000000 > "$TMP/rt.out" 2>/dev/null \
   && cmp -s "$TMP/rt.out" "$TMP/text.bin"; then
  echo "PASS Round-Trip"; PASS=$((PASS+1))
else
  echo "FAIL Round-Trip"; FAIL=$((FAIL+1))
fi

# --- Negativfälle: jeder muss gemeldet werden ----------------------------
python3 - "$TMP" <<'PY'
import sys
d = sys.argv[1]
b = bytes(open(f"{d}/plain.gz", "rb").read())
def w(name, data): open(f"{d}/{name}.gz", "wb").write(bytes(data))
c = bytearray(b); c[-8] ^= 0xFF; w("badcrc", c)        # CRC verfälscht
c = bytearray(b); c[-4] ^= 0xFF; w("badsize", c)       # ISIZE verfälscht
w("trunc", b[:len(b) // 2])                            # abgeschnitten
c = bytearray(b); c[len(b) // 2] ^= 0x55; w("corrupt", c)
c = bytearray(b); c[3] |= 0x20; w("reserved", c)       # reserviertes Flag-Bit
c = bytearray(b); c[2] = 9;     w("badcm", c)          # unbekanntes Verfahren
w("notgz", b"\x00\x01\x02\x03" + b"x" * 64)
PY

neg() { # name, erwarteter exit
  timeout 60 "$TMP/gz" d "$TMP/$1.gz" 4000000 > /dev/null 2>&1; local rc=$?
  if [ "$rc" -ge 128 ]; then echo "FAIL $1: Absturz (rc=$rc)"; FAIL=$((FAIL+1)); return; fi
  if [ "$rc" -eq "$2" ]; then echo "PASS $1 (gemeldet)"; PASS=$((PASS+1))
  else echo "FAIL $1: exit=$rc erwartet $2"; FAIL=$((FAIL+1)); fi
}
neg badcrc   11
neg badsize  11
neg trunc    11
neg corrupt  11
neg reserved 11
neg badcm    11
neg notgz    11
neg fhcrcbad 11

# Zu kleiner Ausgabepuffer ist KEIN Datenverfall und muss unterscheidbar
# gemeldet werden — sonst meldet der Aufrufer einem zu kleinen Puffer einen
# kaputten Strom.
timeout 60 "$TMP/gz" d "$TMP/plain.gz" 100 > /dev/null 2>&1; rc=$?
if [ "$rc" -eq 12 ]; then echo "PASS zu kleiner Puffer (GZIP_OVERFLOW)"; PASS=$((PASS+1))
else echo "FAIL zu kleiner Puffer: exit=$rc erwartet 12"; FAIL=$((FAIL+1)); fi

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
