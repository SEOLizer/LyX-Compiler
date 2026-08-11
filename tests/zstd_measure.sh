#!/usr/bin/env bash
# tests/zstd_measure.sh — misst den zstd-Decoder über eine MATRIX aus
# Eingabeart, Größe und Kompressionsstufe (Issues #1027, #1072).
#
# Die Lehre aus dem ersten Anlauf war, dass eine Einzelprobe „gefixt"
# suggeriert: damals brachte reine Härtung 6 → 5 stillschweigend falsche
# Ergebnisse, die Abstürze blieben bei 67 — sichtbar wurde das erst über viele
# Eingabegrößen. Die Lehre aus dem zweiten Anlauf (#1072) war, dass auch ein
# Größenbereich zu wenig ist, wenn alle Frames DENSELBEN Weg nehmen: 97 von 97
# Frames waren grün, während Wiederholoffsets, Mehrblock-Frames und drei der
# vier Literal-Größenformate nie ausgeführt wurden.
#
# Deshalb variiert diese Messung bewusst das, was im Decoder verschiedene
# Zweige trifft:
#
#   Eingabeart   text (gemischt) | rle (ein Byte) | pattern (Wiederholoffsets)
#                | random (inkompressibel → raw blocks)
#   Größe        20 B .. 400 kB — über 128 kB erzwingt MEHRERE Blöcke
#   Stufe        -1 -3 -9 -19 — höhere Stufen wählen eigene FSE-Tabellen,
#                RLE- und Repeat-Tabellenmodi und andere Literalformate
#   Prüfsumme    --check
#
# Gezählt werden VIER Ausgänge getrennt, denn sie sind unterschiedlich schlimm:
#   korrekt        — Inhalt stimmt
#   still-falsch   — plausibler Rückgabewert, falscher Inhalt, KEIN Fehlerflag
#   gemeldet       — sauber als Fehler zurückgewiesen
#   abgestürzt     — Signal
#
# Verglichen wird mit `cmp` gegen die Originaldatei, nicht über eine
# Shell-Substitution: die verschluckt Nullbytes und nachlaufende Zeilenenden
# und hätte bei den Zufallsdaten falsche Treffer gemeldet.
#
# Dazu ein NEGATIVTEIL: verfälschte, abgeschnittene und Wörterbuch-Frames
# MÜSSEN gemeldet werden. Ohne ihn misst der Positivteil nur, dass der Decoder
# gutmütig ist.
#
# Aufruf: bash tests/zstd_measure.sh   (braucht die zstd-CLI zum Erzeugen)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

command -v zstd >/dev/null 2>&1 || { echo "SKIP: zstd-CLI nicht vorhanden"; exit 0; }

mkdir -p "$TMP/in" "$TMP/f" "$TMP/neg"

python3 - "$TMP" <<'PY'
import sys, os, random
d = sys.argv[1]
T = ("Lyx ist eine statisch typisierte Systemsprache mit eigenem Compiler. "
     "Der Compiler ist selbsthostend und uebersetzt sich selbst. ")
big = (T * 20000).encode()

def w(name, b): open(f"{d}/in/{name}", "wb").write(b)

# Mischtext. Ab 131072 Byte (Blockmaximum) entstehen mehrere Bloecke.
for n in (20, 60, 116, 1000, 5000, 131072, 200000, 400000):
    w(f"text_{n:07d}", big[:n])

# Lange Einzelbyte-Wiederholung: RLE-Literale und RLE-Tabellenmodus.
for n in (1000, 70000, 300000):
    w(f"rle_{n:07d}", b"A" * n)

# Regelmaessiges Muster: erzwingt Wiederholoffsets (offset_value 1..3).
pat = b"abcdefgh" * 4
for n in (4096, 150000):
    w(f"pattern_{n:07d}", (pat * (n // len(pat) + 1))[:n])

# Zufallsdaten: inkompressibel, der Kompressor faellt auf raw blocks zurueck.
random.seed(1027)
for n in (4096, 200000):
    w(f"random_{n:07d}", bytes(random.randrange(256) for _ in range(n)))
PY

for f in "$TMP"/in/*; do
  b="$(basename "$f")"
  for L in 1 3 9 19; do zstd -q -f "-$L" "$f" -o "$TMP/f/${b}_L$L.zst" 2>/dev/null; done
  zstd -q -f -3 --check "$f" -o "$TMP/f/${b}_chk.zst" 2>/dev/null
done

# Negativfaelle: jeder MUSS gemeldet werden.
python3 - "$TMP" <<'PY'
import sys
d = sys.argv[1]
for src, dst in (("text_0005000_chk", "corrupt_chk"), ("text_0005000_L3", "corrupt_nochk")):
    b = bytearray(open(f"{d}/f/{src}.zst", "rb").read())
    b[len(b) // 2] ^= 0x55            # ein Bitmuster mitten im Frame kippen
    open(f"{d}/neg/{dst}.zst", "wb").write(bytes(b))
b = open(f"{d}/f/text_0005000_L3.zst", "rb").read()
open(f"{d}/neg/truncated.zst", "wb").write(b[:len(b) // 2])
open(f"{d}/neg/notzstd.zst", "wb").write(b"\x00\x01\x02\x03" + b"x" * 64)
PY
# Woerterbuch-Frame: braucht das Woerterbuch und muss ohne es abgewiesen werden.
head -c 4096 "$TMP/in/text_0005000" > "$TMP/neg/dict.bin"
zstd -q -f -D "$TMP/neg/dict.bin" "$TMP/in/text_0005000" -o "$TMP/neg/dictframe.zst" 2>/dev/null

cat > "$TMP/probe.lyx" <<'EOF'
import std.io;
import std.alloc;
import std.fs;
import std.zstd;
// Schreibt den dekodierten Inhalt ROH auf stdout; der Vergleich passiert in
// der Huelle mit cmp, damit er binaersicher ist.
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
"$LYXC" --std-path="$ROOT" "$TMP/probe.lyx" -o "$TMP/probe" >/dev/null 2>&1 || {
  echo "FAIL: Sonde uebersetzt nicht"; exit 1; }

ok=0; wrong=0; err=0; crash=0
for z in "$TMP"/f/*.zst; do
  b="$(basename "$z" .zst)"
  src="$TMP/in/$(echo "$b" | sed 's/_L[0-9]*$//; s/_chk$//')"
  cap=$(( $(stat -c%s "$src") + 4096 ))
  timeout 60 "$TMP/probe" "$z" "$cap" > "$TMP/out.bin" 2>/dev/null; rc=$?
  if   [ "$rc" -ge 128 ]; then crash=$((crash+1)); echo "  ABSTURZ      $b (rc=$rc)"
  elif [ "$rc" -ne 0 ];   then err=$((err+1));     echo "  gemeldet     $b"
  elif cmp -s "$TMP/out.bin" "$src"; then ok=$((ok+1))
  else wrong=$((wrong+1));                         echo "  STILL FALSCH $b"; fi
done
echo "korrekt=$ok  still-falsch=$wrong  gemeldet=$err  abgestuerzt=$crash"

# --- Negativteil -----------------------------------------------------------
# Ein Frame, den der Decoder nicht richtig dekodieren KANN, muss als Fehler
# zurueckkommen. Ein Erfolg ist hier ein Fehlschlag des Tests.
negfail=0
for n in corrupt_chk corrupt_nochk truncated notzstd dictframe; do
  [ -f "$TMP/neg/$n.zst" ] || continue
  timeout 60 "$TMP/probe" "$TMP/neg/$n.zst" 500000 > /dev/null 2>&1; rc=$?
  if   [ "$rc" -ge 128 ]; then echo "  ABSTURZ bei $n (rc=$rc)"; negfail=$((negfail+1))
  elif [ "$rc" -eq 0 ];   then echo "  NICHT GEMELDET: $n"; negfail=$((negfail+1))
  fi
done
echo "Negativfaelle: $negfail nicht gemeldet"

# Grün nur, wenn NICHTS still falsch ist, nichts abstürzt, im Positivteil
# nichts gemeldet wird und jeder Negativfall gemeldet wurde.
[ "$wrong" -eq 0 ] && [ "$crash" -eq 0 ] && [ "$err" -eq 0 ] && [ "$negfail" -eq 0 ]
