#!/usr/bin/env bash
# tests/rumpfausrichtung_2339_test.sh — #2339: die Fuellung zur Ausrichtung
# eines Schleifenpaares gehoert VOR den Rumpf, nicht hinein.
#
# `cg_paarAusrichten` legt ein cmp/jcc-Paar nicht ueber eine 32-Byte-Grenze
# (JCC-Erratum, #2244). Das ist richtig und bleibt — gemessen am Kern
# int32_sum_L1 (4096 Elemente, 20000 Wiederholungen, i5-8250U, Median aus
# fuenf, Rumpf byteweise identisch, Vorlauf vor der Schleife):
#
#     Paar sauber                 41.828.337 Takte
#     cmp auf mod32 = 27         177.300.997 Takte   4,24x
#     cmp auf mod32 = 28          82.899.730 Takte   1,98x
#     cmp auf mod32 = 29..31      ~62.700.000 Takte   1,49x
#
# Die Fuellung landete aber bei `anfang`, und in einer Schleife ist das IM
# RUMPF: sie laeuft bei jedem Durchlauf mit und kostete dort 1,25x
# (int32_sum_L1 0,293 gegen 0,220 ns, Rauschboden des Geschirrs 6,4 %).
#
# `cg_rumpfAusrichten` verschiebt deshalb den GANZEN Rumpf und legt die
# Fuellung vor den Schleifenanfang — dort laeuft sie einmal je Eintritt.
#
# Geprueft wird am Erzeugnis, ueber viele Layouts:
#
#   1. In JEDER Variante muss das Paar sauber liegen (die Leistung von #2244
#      darf nicht verloren gehen) UND der Rumpf muss frei von Fuellung sein.
#   2. Mindestens eine Variante muss Fuellung VOR der Schleife haben. Ohne
#      diese Pruefung waere der Test auch von einem Compiler erfuellt, der
#      ueberhaupt nicht ausrichtet — und genau das waere der Rueckschritt,
#      den die Messung oben verbietet.
#
# Die Layouts entstehen, indem eine Funktion VOR der Schleife um je vier Byte
# waechst; damit wandert der Schleifenrumpf durch die Restklassen modulo 32.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ulimit -c 0
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

VARIANTEN=24

# Quelle je Variante: `vorlauf` waechst, die Reduktionsschleife bleibt gleich.
gen() {
  python3 -I - "$1" <<'PY'
import sys
k = int(sys.argv[1])
vor = "\n".join("  f := f + %d;" % (i + 1) for i in range(k))
print('''unit main;
import std.io;
import std.alloc;
fn vorlauf(f: int64): int64 {
%s
  return f;
}
fn red(a: int64, n: int64): int64 {
  var s: int64 := 0;
  var i: int64 := 0;
  while (i < n) { var o: int64 := i * 4; s := s + (peek32(a + o) & 0xFFFFFFFF); i += 1; }
  return s;
}
fn main(): int64 {
  var a: int64 := alloc(4096);
  var i: int64 := 0;
  while (i < 1024) { poke32(a + i * 4, i); i += 1; }
  PrintLn(IntToStr(red(a, 1024) + vorlauf(0)));
  return 0;
}''' % vor)
PY
}

# Liefert: "<mod32> <sauber|STRADDELT> <NOPs im Rumpf> <NOPs davor>"
pruef() {
  python3 -I - "$1" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
# Schleifenanfang der int32-Reduktion: movdqu (rdi,rax),xmm0 gefolgt von
# punpckldq xmm0,xmm2 innerhalb des Blocks.
for i in range(8, len(d) - 90):
    if d[i:i+5] == bytes([0xF3,0x0F,0x6F,0x04,0x07]) and bytes([0x66,0x0F,0x62,0xC2]) in d[i:i+16]:
        for j in range(i, i + 80):
            if d[j]==0x48 and d[j+1]==0x39 and d[j+2]==0xC8 and d[j+3]==0x7E:
                rumpf = d[i:j]
                nops  = sum(1 for b in rumpf if b == 0x90) + rumpf.count(bytes([0x0F,0x1F]))
                vor   = d[i-8:i]
                vn    = sum(1 for b in vor if b == 0x90) + vor.count(bytes([0x0F,0x1F]))
                # Dieselbe Bedingung wie im Codegen: Paar in einem Block und
                # nicht genau auf der Grenze endend.
                ok = (j >> 5) == ((j + 4) >> 5) and ((j + 5) & 31) != 0
                print("%d %s %d %d" % (j % 32, "sauber" if ok else "STRADDELT", nops, vn))
                sys.exit(0)
print("-1 KEINE-SCHLEIFE 0 0")
PY
}

imRumpf=0; davor=0; straddelt=0; fehlend=0; lagen=""
k=0
while [ "$k" -lt "$VARIANTEN" ]; do
  gen "$k" > "$TMP/p$k.lyx"
  if (cd "$TMP" && timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/p$k.lyx" -o "$TMP/b$k" >"$TMP/p$k.log" 2>&1); then
    set -- $(pruef "$TMP/b$k")
    if [ "$1" = "-1" ]; then
      fehlend=$((fehlend+1))
    else
      lagen="$lagen $1"
      [ "$2" = "STRADDELT" ] && straddelt=$((straddelt+1))
      imRumpf=$((imRumpf + $3))
      davor=$((davor + $4))
    fi
  else
    no "Variante $k uebersetzt nicht" "$(grep -v Copyright "$TMP/p$k.log" | grep -m1 -iE 'error|lyxc:')"
  fi
  k=$((k+1))
done

ANZ_LAGEN=$(printf '%s\n' $lagen | sort -un | wc -l)

if [ "$fehlend" -eq 0 ]; then
  ok "alle $VARIANTEN Varianten enthalten die Reduktionsschleife ($ANZ_LAGEN verschiedene Lagen modulo 32)"
else
  no "Schleife nicht gefunden" "$fehlend von $VARIANTEN Varianten ohne erkennbare Reduktionsschleife"
fi

if [ "$straddelt" -eq 0 ]; then
  ok "kein Paar ueber einer 32-Byte-Grenze (die Leistung von #2244 bleibt)"
else
  no "Paar straddelt" "$straddelt von $VARIANTEN — die Ausrichtung greift nicht mehr"
fi

if [ "$imRumpf" -eq 0 ]; then
  ok "keine Fuellung IM Schleifenrumpf (Summe ueber alle Varianten: 0)"
else
  no "Fuellung im Rumpf" "$imRumpf NOP-Stellen in Rumpfen — sie laufen je Durchlauf mit"
fi

# Die entscheidende Pruefung: der neue Weg muss ueberhaupt greifen. Ohne sie
# waere der Test auch von einem Compiler erfuellt, der nie ausrichtet.
if [ "$davor" -ge 1 ]; then
  ok "Fuellung VOR der Schleife vorhanden ($davor Varianten) — der Weg greift"
else
  no "Fuellung nirgends" "keine Variante richtet aus; der Test wuerde auch ohne jede Ausrichtung bestehen"
fi

echo "=== PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
