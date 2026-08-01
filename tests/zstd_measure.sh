#!/usr/bin/env bash
# tests/zstd_measure.sh — misst den zstd-Decoder über einen GRÖSSENBEREICH
# (Issue #1027). Kein Pass/Fail-Test: ein Messwerkzeug für die Weiterarbeit.
#
# Die Lehre aus dem ersten Anlauf war, dass eine Einzelprobe „gefixt" suggeriert:
# damals brachte reine Härtung 6 → 5 stillschweigend falsche Ergebnisse, die
# Abstürze blieben bei 67 — sichtbar wurde das erst über viele Eingabegrößen.
#
# Gezählt werden VIER Ausgänge getrennt, denn sie sind unterschiedlich schlimm:
#   korrekt        — Inhalt stimmt
#   still-falsch   — plausibler Rückgabewert, falscher Inhalt, KEIN Fehlerflag
#   gemeldet       — sauber als Fehler zurückgewiesen
#   abgestürzt     — Signal
#
# Aufruf: bash tests/zstd_measure.sh   (braucht die zstd-CLI zum Erzeugen)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

command -v zstd >/dev/null 2>&1 || { echo "SKIP: zstd-CLI nicht vorhanden"; exit 0; }

TEXT="Lyx ist eine statisch typisierte Systemsprache mit eigenem Compiler. Der Compiler ist selbsthostend und uebersetzt sich selbst. "
python3 - "$TMP" "$TEXT" <<'PY'
import sys
tmp, text = sys.argv[1], sys.argv[2] * 8
for n in range(20, 117):
    open(f"{tmp}/in_{n:03d}.txt", "w").write(text[:n])
PY
for f in "$TMP"/in_*.txt; do zstd -1 -q -f "$f" -o "${f%.txt}.zst" 2>/dev/null; done

cat > "$TMP/probe.lyx" <<'EOF'
import std.io;
import std.alloc;
import std.fs;
import std.zstd;
pub fn main(argc: int64, argv: pchar): int64 {
  if (argc < 3) { return 2; }
  var path: pchar := ArgvGet(argv, 1);
  var want: int64 := StrToInt(ArgvGet(argv, 2));
  var sz: int64 := FileSize(path);
  if (sz <= 0) { return 3; }
  var buf: int64 := alloc(sz + 16);
  var fd: int64 := open(path, 0, 0);
  read(fd, buf as pchar, sz);
  close(fd);
  var out: int64 := alloc(8192);
  var n: int64 := ZstdDecompress(buf, sz, out, 8192);
  if (n < 0)     { return 10; }
  if (n != want) { return 11; }
  sys_write(1, out, n);
  return 0;
}
EOF
"$LYXC" --std-path="$ROOT" "$TMP/probe.lyx" -o "$TMP/probe" >/dev/null 2>&1 || {
  echo "FAIL: Sonde uebersetzt nicht"; exit 1; }

ok=0; wrong=0; err=0; crash=0
for f in "$TMP"/in_*.txt; do
  n=$(basename "$f" .txt); n=${n#in_}
  out=$(timeout 10 "$TMP/probe" "$TMP/in_$n.zst" "$(stat -c%s "$f")" 2>/dev/null); rc=$?
  if   [ "$rc" -ge 128 ]; then crash=$((crash+1))
  elif [ "$rc" -ne 0 ];   then err=$((err+1))
  elif [ "$out" = "$(cat "$f")" ]; then ok=$((ok+1))
  else wrong=$((wrong+1)); fi
done
echo "korrekt=$ok  still-falsch=$wrong  gemeldet=$err  abgestuerzt=$crash"
[ "$wrong" -eq 0 ] && [ "$crash" -eq 0 ]
