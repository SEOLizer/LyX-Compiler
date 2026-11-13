#!/bin/bash
# #2146 Stufe C2c: GLOBALE Variablen binden im Objektabbild ueber ihren NAMEN,
# nicht als Abstand in den mitgelieferten Datenblock.
#
# Warum nur die Globalen: der Datenbereich geht weiter vollstaendig mit, weil
# die eigenen Daten NICHT zusammenhaengend sind (gemessen an std/string.lyx:
# [152,319) und [459,607), fremde dazwischen) -- ein Datenschnitt braeuchte
# eine Umrechnung aller Datenoffsets. Zeichenketten und Tabellen duerfen
# doppelt vorkommen, sie sind unveraenderlich: eine zweite Kopie ist Platz,
# kein zweiter Zustand. Eine globale Variable braucht dagegen GENAU EINEN
# Slot, sonst zaehlen Wirt und Abbild getrennt.
#
# Die Zuordnung Datenoffset -> Globale ist exakt, weil cg_addGlobal je
# Variable genau acht Byte reserviert.
cd "$(dirname "$0")/.." || exit 1
LYXC="${LYXC:-./lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
PASS=0; FAIL=0
pr() { if [ "$1" = ok ]; then PASS=$((PASS+1)); echo "PASS $2"; else FAIL=$((FAIL+1)); echo "FAIL $2"; fi; }

for w in readelf python3 gcc; do
  command -v "$w" >/dev/null 2>&1 || { echo "SKIP: $w fehlt"; echo "Ergebnis: 0 PASS, 0 FAIL"; exit 0; }
done

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/u/glob"
cat > "$T/u/glob/zaehler.lyx" <<'LYX'
unit glob.zaehler;
pub var Stand: int64;
pub fn Hoch(): int64 { Stand := Stand + 1; return Stand; }
LYX
cat > "$T/u/glob/nutzer.lyx" <<'LYX'
unit glob.nutzer;
import glob.zaehler;
pub var Eigen: int64;
pub fn Zweimal(): int64 { Hoch(); Hoch(); Eigen := Eigen + 1; return Stand + Eigen; }
LYX

hol() {
  "$LYXC" --std-path="$T/u" --compile-unit --with-objcode "$T/u/glob/$1.lyx" \
      -o "$T/$1.lyu" > "$T/$1.log" 2>&1 || return 1
  local l; l="$("$LYXC" --unit-info "$T/$1.lyu" 2>&1 | awk '/Objekt:/{print $2}')"
  [ -n "$l" ] || return 1
  python3 -I -c "
d = open('$T/$1.lyu','rb').read()
i = d.find(b'\x7fELF')
open('$T/$1.o','wb').write(d[i:i+$l])
" || return 1
}
hol zaehler || { echo "FAIL zaehler: $(grep -i error "$T/zaehler.log" | head -2)"; echo "Ergebnis: 0 PASS, 1 FAIL"; exit 1; }
hol nutzer  || { echo "FAIL nutzer: $(grep -i error "$T/nutzer.log" | head -2)";  echo "Ergebnis: 0 PASS, 1 FAIL"; exit 1; }

# 1) Die eigene Globale wird DEFINIERT, mit Groesse.
Z="$(readelf -sW "$T/zaehler.o" 2>/dev/null)"
if printf '%s' "$Z" | awk '$4=="OBJECT" && $7=="1" && $8=="_lyxg_Stand"{f=1} END{exit !f}'; then
  pr ok "zaehler definiert _lyxg_Stand als OBJECT in .ltext"
else
  pr no "zaehler definiert _lyxg_Stand nicht: $(printf '%s' "$Z" | grep _lyxg_ | head -2)"
fi

# 2) Die FREMDE Globale bleibt UNDEF -- das ist die eigentliche Aussage. Ein
#    Abbild, das sie selbst definierte, fuehrte einen zweiten Zaehler.
N="$(readelf -sW "$T/nutzer.o" 2>/dev/null)"
if printf '%s' "$N" | awk '$7=="UND" && $8=="_lyxg_Stand"{f=1} END{exit !f}'; then
  pr ok "nutzer laesst die fremde _lyxg_Stand UNDEF"
else
  pr no "nutzer definiert die fremde Globale selbst: $(printf '%s' "$N" | grep _lyxg_Stand | head -2)"
fi
if printf '%s' "$N" | awk '$4=="OBJECT" && $7=="1" && $8=="_lyxg_Eigen"{f=1} END{exit !f}'; then
  pr ok "nutzer definiert seine eigene _lyxg_Eigen"
else
  pr no "nutzer definiert _lyxg_Eigen nicht"
fi

# 3) Zugriffe sind Relokationen, keine gebackenen Abstaende.
if readelf -rW "$T/nutzer.o" 2>/dev/null | grep -q "R_X86_64_PC32.*_lyxg_Stand"; then
  pr ok "Zugriff auf die fremde Globale ist eine PC32-Relokation"
else
  pr no "kein Relokationseintrag fuer _lyxg_Stand"
fi

# 4) WIRKUNG, beide Seiten: C setzt die Variable, die Abbilder rechnen darauf
#    weiter, und am Ende liest C denselben Slot. Ein zweiter Slot faellt hier
#    auf -- mit getrennten Zustaenden kaeme 1 und 40 heraus.
cat > "$T/m.c" <<'C'
#include <stdio.h>
extern long Zweimal(void);
extern long _lyxg_Stand;
long _lyxh_strlen_simd(const char *s) { const char *p = s; while (*p) p++; return p - s; }
int main(void) {
  _lyxg_Stand = 40;
  long a = Zweimal();
  printf("%ld %ld\n", a, _lyxg_Stand);
  return 0;
}
C
if gcc -c "$T/m.c" -o "$T/m.o" > "$T/cc.log" 2>&1 \
   && gcc "$T/m.o" "$T/nutzer.o" "$T/zaehler.o" -o "$T/prog" > "$T/ld.log" 2>&1; then
  AUS="$("$T/prog" 2>&1)"
  if [ "$AUS" = "43 42" ]; then
    pr ok "ein Slot: C setzt 40, Zweimal() ergibt 43, danach steht 42"
  else
    pr no "falsches Ergebnis '$AUS' statt '43 42' -- Wirt und Abbild zaehlen getrennt"
  fi
else
  pr no "ld bindet die Abbilder nicht: $(grep -iE 'error|undefined' "$T/ld.log" | head -3)"
fi

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "OK: globale Variablen binden ueber den Namen (#2146 Stufe C2c)"
