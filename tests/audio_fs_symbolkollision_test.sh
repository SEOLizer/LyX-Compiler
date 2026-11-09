#!/usr/bin/env bash
# #2441: std.audio und std.fs waren nicht gemeinsam importierbar.
#
# std/audio.lyx deklarierte SEEK_SET/SEEK_CUR/SEEK_END und
# O_RDONLY/O_WRONLY/O_RDWR/O_CREAT/O_TRUNC ein zweites Mal — mit denselben
# Werten wie std/fs.lyx. sema weist mehrdeutige Exporte ab, also scheiterte
# JEDES Programm, das beide Units auch nur transitiv importierte
# (std.audio.playback importiert std.audio). Von aussen war das nicht
# aufloesbar. Aufgeloest, indem std.audio die Deklarationen aus std.fs
# importiert statt sie zu wiederholen.
#
# Gemessen wird die WIRKUNG in beide Richtungen, nicht das Vorhandensein:
#   1. beide Units zusammen muessen uebersetzen,
#   2. Verbraucher, die SEEK_*/O_* aus std.audio beziehen, muessen weiter
#      uebersetzen UND die richtigen WERTE sehen (sonst waere Teil 1 auch von
#      einem stillen Weglassen erfuellt),
#   3. kein Name darf von std/audio.lyx und std/fs.lyx beide als `pub`
#      exportiert werden — sonst kommt die Klasse an einem anderen Namen
#      zurueck.
#
# Alle Laeufe unter `ulimit -v`.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

echo "--- #2441: std.audio + std.fs gemeinsam importierbar ---"

cd "$ROOT" || exit 1

# --- Teil 1: Repro aus dem Issue, woertlich -----------------------------------
cat > "$TMP/beide.lyx" <<'LYX'
import std.io;
import std.fs;
import std.audio.playback;

fn main(): int64 {
  Print("hi\n"c);
  return 0;
}
LYX
if (ulimit -v 4000000; "$LYXC" "$TMP/beide.lyx" -o "$TMP/beide" --std-path=. > "$TMP/beide.log" 2>&1); then
  ok "std.fs + std.audio.playback uebersetzen gemeinsam"
else
  nok "std.fs + std.audio.playback: $(grep -m3 'sema error' "$TMP/beide.log" | tr '\n' ' ')"
fi

# --- Teil 2: Werte, bezogen ueber den Import von std.audio --------------------
# Diese Richtung faellt um, wenn die Konstanten nur geloescht wurden.
cat > "$TMP/werte.lyx" <<'LYX'
import std.io;
import std.audio;

fn main(): int64 {
  PrintInt(SEEK_SET); Print(" "c);
  PrintInt(SEEK_CUR); Print(" "c);
  PrintInt(SEEK_END); Print(" "c);
  PrintInt(O_RDONLY); Print(" "c);
  PrintInt(O_WRONLY); Print(" "c);
  PrintInt(O_RDWR); Print(" "c);
  PrintInt(O_CREAT); Print(" "c);
  PrintInt(O_TRUNC); Print("\n"c);
  return 0;
}
LYX
if (ulimit -v 4000000; "$LYXC" "$TMP/werte.lyx" -o "$TMP/werte" --std-path=. > "$TMP/werte.log" 2>&1); then
  gemessen="$( (ulimit -v 4000000; "$TMP/werte") 2>/dev/null | tail -1)"
  erwartet="0 1 2 0 1 2 64 512"
  if [ "$gemessen" = "$erwartet" ]; then
    ok "SEEK_*/O_* ueber std.audio sichtbar und richtig ($gemessen)"
  else
    nok "SEEK_*/O_* ueber std.audio: gemessen [$gemessen], erwartet [$erwartet]"
  fi
else
  nok "Verbraucher von SEEK_*/O_* aus std.audio uebersetzt nicht: $(grep -m3 'error' "$TMP/werte.log" | tr '\n' ' ')"
fi

# --- Teil 3: kein doppelter pub-Export zwischen den beiden Units --------------
doppelt="$(python3 - "$ROOT" <<'PY'
import os, re, sys
root = sys.argv[1]
def exports(p):
    txt = open(os.path.join(root, p), encoding="utf-8").read()
    return set(re.findall(r'^\s*pub\s+(?:fn|con|type|var)\s+(\w+)', txt, re.M))
print(" ".join(sorted(exports("std/audio.lyx") & exports("std/fs.lyx"))))
PY
)"
if [ -z "$doppelt" ]; then
  ok "std/audio.lyx und std/fs.lyx exportieren keinen gemeinsamen Namen"
else
  nok "doppelt exportiert von std/audio.lyx und std/fs.lyx: $doppelt"
fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
