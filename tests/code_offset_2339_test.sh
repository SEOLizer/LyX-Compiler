#!/usr/bin/env bash
# tests/code_offset_2339_test.sh — #2339: --code-offset verschiebt den
# erzeugten Code als Ganzes, fuer Layout-Messungen.
#
# WOZU. Die Lage einer heissen Schleife entscheidet messbar ueber die
# Laufzeit. Gemessen am 2026-10-31 mit genau diesem Schalter (i5-8250U,
# cycles:u, Median aus drei, Offsets 0/1/2/3/5/7/32/64/96/128):
#
#     int8_add_L1    Spanne 15,6 %  (N=1 ist +15 % langsamer)
#     int16_mul_L1   Spanne 10,8 %  (N=32 und N=96 sind ~10 % schneller)
#     int32_sum_L1   Spanne  0,5 %  (flach)
#
# Der Rauschboden desselben Geschirrs liegt bei 6,4 %. Eine Einzelmessung an
# einem kurzen L1-Kern ist also ohne Layoutangabe nicht belastbar — und genau
# deshalb musste in #2335 eine veroeffentlichte Zahl zurueckgenommen werden.
#
# WARUM EIN COMPILERSCHALTER UND NICHT QUELLTEXT. Drei naheliegende Wege sind
# gemessen falsch:
#
#   * Zuweisungen auf einen Parameter werden wegoptimiert — die Erzeugnisse
#     bleiben BYTEWEISE gleich, obwohl der Quelltext waechst.
#   * Eine eigene Funktion davor wirkt nicht: die Emissionsreihenfolge ist
#     nicht die Deklarationsreihenfolge, die Fuellung landet hinter den
#     Kernen. (Die NOP-Bytes erscheinen im Erzeugnis, die Schleifenadresse
#     bleibt.)
#   * Ein `asm`-Block im Rumpf verschiebt, kostet die Funktion aber die
#     Registerzuteilung aus #2114: cg_rlLauf setzt bei CGN_ASM das
#     Ausschlussbit, weil asm r12..r15 ueberschreiben kann. Gemessen wurde
#     `int32_mul` dadurch 3,1x LANGSAMER (0,08 s -> 0,25 s) — was wie ein
#     Layout-Effekt aussah und keiner war.
#
# Der Schalter legt die Fuellung deshalb ZWISCHEN Helferblock und ersten
# Nutzercode: kein Funktionsrumpf, keine Optimierungsentscheidung, nie
# ausgefuehrt.
#
# Geprueft wird:
#   1. OHNE Schalter und mit `--code-offset=0` ist das Erzeugnis BITGLEICH.
#      Das ist das Sicherheitsnetz der ganzen Aenderung.
#   2. Der Schalter wirkt: ueber die geprueften Offsets entstehen mehrere
#      verschiedene Lagen. Ohne diese Pruefung waere der Test auch von einem
#      Schalter erfuellt, der nichts tut.
#   3. Die Rechnung bleibt gleich — bei jedem Offset dieselbe Ausgabe.
#   4. Ein unsinniger Wert wird LAUT abgewiesen, nicht still gekappt.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ulimit -c 0
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

cat > "$TMP/p.lyx" <<'EOF'
unit main;
import std.io;
import std.alloc;
fn sum32(a: int64, n: int64): int64 {
  var s: int64 := 0;
  var i: int64 := 0;
  while (i < n) { var o: int64 := i * 4; s := s + (peek32(a + o) & 0xFFFFFFFF); i += 1; }
  return s;
}
fn main(): int64 {
  var n: int64 := 1024;
  var a: int64 := alloc(n * 4);
  var i: int64 := 0;
  while (i < n) { poke32(a + i * 4, i * 3 + 1); i += 1; }
  PrintLn(IntToStr(sum32(a, n)));
  return 0;
}
EOF

baue() {  # ziel [schalter...]
  local z="$1"; shift
  (cd "$TMP" && timeout 200 "$LYXC" --std-path="$ROOT" "$@" "$TMP/p.lyx" -o "$TMP/$z" >"$TMP/$z.log" 2>&1)
}

# Lage der Vektorschleife (movdqu (rdi,rax),xmm0) als Kennzeichen des Layouts.
lage() {
  python3 -I - "$1" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
for i in range(len(d) - 5):
    if d[i:i+5] == bytes([0xF3, 0x0F, 0x6F, 0x04, 0x07]):
        print(i); sys.exit(0)
print(-1)
PY
}

# ---------------------------------------------------------------- 1
if baue ohne && baue null --code-offset=0; then
  if cmp -s "$TMP/ohne" "$TMP/null"; then
    ok "ohne Schalter und --code-offset=0 bitgleich"
  else
    no "Vorgabe" "--code-offset=0 aendert das Erzeugnis — der Schalter wirkt ungewollt"
  fi
else
  no "Vorgabe" "uebersetzt nicht: $(grep -v Copyright "$TMP/ohne.log" | grep -m1 -iE 'error|lyxc:')"
fi

# ---------------------------------------------------------------- 2 + 3
LAGEN=""; AUSGABEN=""; FEHLT=0
for n in 0 1 2 3 7 16 32 64 96; do
  if baue "o$n" "--code-offset=$n"; then
    LAGEN="$LAGEN $(lage "$TMP/o$n")"
    AUSGABEN="$AUSGABEN $( (cd "$TMP" && timeout 60 "./o$n" 2>&1) )"
  else
    FEHLT=$((FEHLT+1))
  fi
done
VERSCH=$(printf '%s\n' $LAGEN | sort -u | wc -l)
EINDEUTIG=$(printf '%s\n' $AUSGABEN | sort -u | wc -l)

if [ "$FEHLT" -eq 0 ]; then ok "alle neun Offsets uebersetzen"
else no "Offsets" "$FEHLT von neun uebersetzen nicht"; fi

if [ "$VERSCH" -ge 2 ]; then
  ok "Schalter wirkt: $VERSCH verschiedene Lagen der Vektorschleife"
else
  no "Schalter wirkungslos" "alle Offsets liefern dieselbe Lage — der Test wuerde auch ohne Wirkung bestehen"
fi

if [ "$EINDEUTIG" -eq 1 ] && [ -n "$AUSGABEN" ]; then
  ok "Rechnung unveraendert bei jedem Offset ($(printf '%s\n' $AUSGABEN | sort -u))"
else
  no "Rechnung" "$EINDEUTIG verschiedene Ergebnisse: $(printf '%s\n' $AUSGABEN | sort -u | tr '\n' ' ')"
fi

# ---------------------------------------------------------------- 4
if baue zuviel --code-offset=5000; then
  no "Obergrenze" "--code-offset=5000 wurde angenommen — ein stiller Default blaeht den Code beliebig auf"
else
  # Die Meldung muss den BEREICH nennen. Nur auf "code-offset" zu pruefen
  # waere eine Zusicherung, die aus dem falschen Grund gruen ist: ein
  # Compiler, der den Schalter gar nicht kennt, lehnt ihn als unbekannte
  # Option ab und haette den Test ebenfalls bestanden.
  if grep -qE "0\.\.4096" "$TMP/zuviel.log"; then
    ok "--code-offset=5000 laut abgewiesen, mit Bereichsangabe 0..4096"
  else
    no "Obergrenze" "abgewiesen, aber ohne Bereichsangabe: $(grep -v Copyright "$TMP/zuviel.log" | head -2)"
  fi
fi

echo "=== PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
