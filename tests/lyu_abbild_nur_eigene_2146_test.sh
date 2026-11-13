#!/bin/bash
# #2146 Stufe C: das Objektabbild in der .lyu exportiert NUR die Funktionen der
# Unit selbst.
#
# Warum: die Uebersetzung einer Unit erzeugt auch den Code ihrer Importe
# (cg_processImport tauscht pSrc/pNodes). Gemessen an einer Unit mit einem
# einzigen std-Import trug das Abbild 71 Funktionssymbole, davon 1 eigenes --
# beim Einbinden zweier solcher Abbilder waere dieselbe Funktion mehrfach als
# GLOBAL-Symbol definiert.
#
# ZWEI SEITEN: dass das eigene Symbol da ist, erfuellt auch ein Abbild, das
# alles exportiert. Der Test muss zusaetzlich zeigen, dass die fremden NICHT
# drin sind.
cd "$(dirname "$0")/.." || exit 1
LYXC="${LYXC:-./lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294: Ressourcengrenze um jeden lyxc-Aufruf
PASS=0; FAIL=0
pr() { if [ "$1" = ok ]; then PASS=$((PASS+1)); echo "PASS $2"; else FAIL=$((FAIL+1)); echo "FAIL $2"; fi; }

for w in nm python3; do
  command -v "$w" >/dev/null 2>&1 || { echo "SKIP: $w fehlt"; echo "Ergebnis: 0 PASS, 0 FAIL"; exit 0; }
done

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/u/probe"
cat > "$T/u/probe/klein.lyx" <<'LYX'
unit probe.klein;
pub fn KleinEins(a: int64): int64 { return a + 1; }
pub fn KleinZwei(a: int64): int64 { return a + 2; }
LYX
cat > "$T/u/probe/gross.lyx" <<'LYX'
unit probe.gross;
import probe.klein;
pub fn GrossDrei(a: int64): int64 { return KleinEins(a) + KleinZwei(a); }
LYX

if ! "$LYXC" --std-path="$T/u" --compile-unit --with-objcode "$T/u/probe/gross.lyx" \
     -o "$T/g.lyu" > "$T/cu.log" 2>&1; then
  echo "FAIL --compile-unit scheitert: $(grep -iE 'error' "$T/cu.log" | head -2)"
  echo "Ergebnis: 0 PASS, 1 FAIL"; exit 1
fi
L="$("$LYXC" --unit-info "$T/g.lyu" 2>&1 | awk '/Objekt:/{print $2}')"
if [ -z "$L" ] || [ "$L" -lt 100 ]; then
  echo "FAIL kein Abbild in der .lyu (Laenge '$L')"
  echo "Ergebnis: 0 PASS, 1 FAIL"; exit 1
fi
python3 -I -c "
d = open('$T/g.lyu','rb').read()
i = d.find(b'\x7fELF')
open('$T/g.o','wb').write(d[i:i+$L])
" 2>/dev/null

SYMS="$(nm "$T/g.o" 2>/dev/null | awk '$2=="T"{print $3}')"

# 1) eigene Funktion da
if printf '%s\n' "$SYMS" | grep -qx "GrossDrei"; then
  pr ok "eigene Funktion GrossDrei steht im Abbild"
else
  pr no "eigene Funktion GrossDrei fehlt im Abbild: $(printf '%s' "$SYMS" | tr '\n' ' ')"
fi

# 2) fremde Funktionen NICHT da — die eigentliche Aussage
FREMD=""
for s in KleinEins KleinZwei; do
  printf '%s\n' "$SYMS" | grep -qx "$s" && FREMD="$FREMD $s"
done
if [ -z "$FREMD" ]; then
  pr ok "keine Funktion der importierten Unit im Abbild"
else
  pr no "importierte Funktionen im Abbild:$FREMD"
fi

# 3) Das Abbild traegt den eigenen Code -- keine leere Huelle. Die Frage, was
#    GESCHNITTEN wird, gehoert seit 1.2.38D nach
#    tests/lyu_abbild_schnitt_2146_test.sh; bis dahin stand hier die
#    Erwartung, dass der mituebersetzte Code noch drin ist. Eine solche
#    Erwartung wird rot, sobald die Luecke zugeht -- deshalb prueft sie jetzt
#    nur noch, dass ueberhaupt Code da ist.
GROESSE=$(stat -c %s "$T/g.o")
if [ "$GROESSE" -gt 500 ]; then
  pr ok "Abbild traegt Code ($GROESSE Byte)"
else
  pr no "Abbild ist mit $GROESSE Byte eine leere Huelle"
fi

# 4) --emit=obj bleibt vollstaendig: ein eigenstaendiges Objekt soll alles
#    anbieten, was in ihm steht (Stufe A). Zwei Wege, zwei Antworten.
cat > "$T/p.lyx" <<'LYX'
import probe.klein;
fn main(): int64 { return KleinEins(1); }
LYX
if "$LYXC" --std-path="$T/u" -I"$T/u" --emit=obj "$T/p.lyx" -o "$T/p.o" > "$T/eo.log" 2>&1; then
  if nm "$T/p.o" 2>/dev/null | awk '$2=="T"{print $3}' | grep -qx "KleinEins"; then
    pr ok "--emit=obj exportiert importierte Funktionen weiter (Stufe A unveraendert)"
  else
    pr no "--emit=obj exportiert KleinEins nicht mehr -- Stufe A eingeschraenkt"
  fi
else
  pr no "--emit=obj scheitert: $(grep -iE 'error' "$T/eo.log" | head -2)"
fi

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "OK: das Abbild exportiert nur die eigenen Funktionen (#2146 Stufe C)"
