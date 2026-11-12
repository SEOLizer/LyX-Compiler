#!/usr/bin/env bash
# #2353 — memcpy ueber alle Laengen, die die Wege von _lyx_memcpy trennen.
#
# Angelegt beim Nachmessen von #2353 (dessen Praemisse sich als falsch
# erwies: AVX2 schlaegt ERMSB oberhalb von ~12 KB nicht, und unterhalb
# frisst der Aufrufweg den Kerngewinn). Der Test selbst prueft nicht die
# AVX2-Fassung, sondern den BESTAND — `memcpy` hat 393 Aufrufstellen und
# hatte bisher keinen Test, der die Wegegrenzen des Helfers einzeln trifft.
#
# Geprueft wird die WIRKUNG, nicht eine Invariante:
#
#   1. JEDES einzelne Byte gegen ein laengenabhaengiges Muster — ein Test,
#      der nur das erste Byte oder nur die Laenge prueft, waere auch von
#      einer Kopie erfuellt, die in der Mitte Muell schreibt.
#   2. 16 WAECHTERBYTES vor und hinter dem Ziel. Der Helfer kopiert seinen
#      Schwanz ueber `[rdi+rdx-32]`, also genau bis an das Ende; ein
#      Offsetfehler dort schreibt DAHINTER, und nur ein Waechter findet das.
#   3. Die Rueckgabe ist der Zielzeiger (C-Semantik, #1842).
#
# Die Laengen treffen die Wegegrenzen des Helfers (16, 32, 64, 512) einzeln,
# jeweils davor, darauf und dahinter: lueckenlos 0..600, dann grob bis 13000.
#
# BEIDE Fassungen: ohne und mit --target-cpu=avx2. Ein Test, der nur die
# Standardfassung prueft, waere von einer kaputten avx2-Emission erfuellt.
set -u
cd "$(dirname "$0")/.."
LYXC=${LYXC:-./lyxc}
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

pruefe_fassung() {
  nam="$1"; shift
  if "$LYXC" --std-path=. "$@" tests/memcpy_2353/laengen.lyx -o "$TMP/m_$nam" >"$TMP/b_$nam.log" 2>&1; then
    ok "${nam}_uebersetzt"
  else
    bad "${nam}_uebersetzt"; tail -5 "$TMP/b_$nam.log"; return
  fi
  if out=$("$TMP/m_$nam" 2>&1); then
    n=$(echo "$out" | sed -n 's/^geprueft: \([0-9]*\) Laengen.*/\1/p')
    f=$(echo "$out" | sed -n 's/.*Fehler: \([0-9]*\)$/\1/p')
    if [ "${f:-1}" = "0" ] && [ "${n:-0}" -ge 900 ] && echo "$out" | grep -q '^ALL PASS$'; then
      ok "${nam}_${n}_laengen_fehlerfrei"
    else
      bad "$nam (Laengen=${n:-?}, Fehler=${f:-?})"; echo "$out" | grep -v '^geprueft' | head -8
    fi
  else
    bad "${nam}_laeuft"; echo "$out" | head -10
  fi
}

pruefe_fassung baseline
pruefe_fassung avx2 --target-cpu=avx2

echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
