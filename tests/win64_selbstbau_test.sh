#!/usr/bin/env bash
# tests/win64_selbstbau_test.sh
#
# #2264: lyxc nach win64 uebersetzen und das Erzeugnis ARBEITEN lassen.
#
# Bis 1.2.20F baute `--target=win64` den Compiler fehlerfrei zu einer PE-Datei,
# aber lyxc.exe stuerzte ab, sobald es einen Uebersetzungsauftrag begann:
# lyx_getEnvVar rechnete envp hinter argv (SysV) und las dort die ersten acht
# Bytes von argv[0] als Zeiger. `--version` und `--help` liefen, weil sie
# davor zurueckkommen — ein Test, der nur den Start prueft, waere gruen
# gewesen. Gemessen wird deshalb das ERZEUGNIS, das lyxc.exe selbst schreibt.
#
# Laufzeit: ein win64-Bau des Compilers plus ein Lauf unter wine (~2 min).
set -uo pipefail
ulimit -c 0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

cat > "$TMP/hallo.lyx" <<'LYX'
import src.std.io;
fn main(): int64 { PrintLn(42); return 0; }
LYX

# 1) lyxc selbst nach win64 uebersetzen
if ! ( cd "$ROOT" && timeout 900 "$LYXC" --std-path="$ROOT" --target=win64 --format=pe \
         src/lyxc.lyx -o "$TMP/lyxc.exe" ) >"$TMP/bau.log" 2>&1; then
  nok "lyxc nach win64 uebersetzen: $(grep -m1 -i error "$TMP/bau.log")"
  echo; echo "Ergebnis: $PASS PASS, $FAIL FAIL"; exit 1
fi
ok "lyxc nach win64 uebersetzt"

# Erzeugnis ist eine PE-Datei mit dem Eintritt im .text (MZ + PE\0\0)
if python3 - "$TMP/lyxc.exe" <<'PY'
import struct, sys
d = open(sys.argv[1], 'rb').read()
if d[:2] != b'MZ': sys.exit(1)
pe = struct.unpack_from('<I', d, 0x3c)[0]
if d[pe:pe+4] != b'PE\0\0': sys.exit(1)
if struct.unpack_from('<H', d, pe + 24)[0] != 0x20b: sys.exit(1)   # PE32+
sys.exit(0)
PY
then ok "Erzeugnis ist PE32+"; else nok "Erzeugnis ist kein PE32+"; fi

if ! command -v wine >/dev/null 2>&1; then
  echo "SKIP wine nicht vorhanden — die Wirkung ist ohne Windows nicht messbar"
  echo; echo "Ergebnis: $PASS PASS, $FAIL FAIL"; [ "$FAIL" -eq 0 ]; exit $?
fi

# 2) lyxc.exe uebersetzen lassen — der Auftrag, an dem es vor #2264 fiel
cp "$TMP/lyxc.exe" "$ROOT/lyxc_selbstbau_test.exe"
trap 'rm -rf "$TMP"; rm -f "$ROOT/lyxc_selbstbau_test.exe"' EXIT
( cd "$ROOT" && WINEDEBUG=-all timeout 900 wine lyxc_selbstbau_test.exe \
    --std-path=. "$TMP/hallo.lyx" -o "$TMP/hallo_win" ) >"$TMP/wine.log" 2>&1
if [ ! -s "$TMP/hallo_win" ]; then
  nok "lyxc.exe schreibt kein Erzeugnis: $(grep -m1 -iE 'exception|page fault|error' "$TMP/wine.log")"
else
  ok "lyxc.exe uebersetzt eine Datei"
  chmod +x "$TMP/hallo_win"
  aus="$(timeout 60 "$TMP/hallo_win" 2>/dev/null)"
  if [ "$aus" = "42" ]; then ok "dessen Erzeugnis gibt 42 aus"; else nok "Erzeugnis gab [$aus] statt 42"; fi

  # 3) Gegenprobe: bytegleich mit dem, was der Linux-Compiler schreibt
  if ( cd "$ROOT" && timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/hallo.lyx" \
         -o "$TMP/hallo_lin" ) >"$TMP/lin.log" 2>&1; then
    a="$(sha256sum "$TMP/hallo_win" | cut -d' ' -f1)"
    b="$(sha256sum "$TMP/hallo_lin" | cut -d' ' -f1)"
    if [ "$a" = "$b" ]; then ok "bytegleich mit dem Linux-Erzeugnis"
    else nok "Erzeugnisse unterscheiden sich ($a != $b)"; fi
  else
    nok "Linux-Gegenprobe uebersetzt nicht"
  fi
fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
