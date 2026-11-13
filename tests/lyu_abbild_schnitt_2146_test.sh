#!/bin/bash
# #2146 Stufe C2b: das Objektabbild in der .lyu traegt nur den Code der Unit
# selbst; alles, was der Schnitt zurueckliess, steht als Relokation drin.
#
# Der Schnitt traegt eine Eigenschaft: werden vorne `anf` Bytes entfernt,
# verschiebt sich JEDER Offset um dasselbe Delta (Daten liegen in beiden
# Fassungen hinter dem Code). Interne Abstaende bleiben damit gueltig, und neu
# zu beschreiben sind nur Bezuege, die VOR den Schnitt zeigen: Helfer des
# Wirts und Funktionen importierter Units.
#
# DIE AUSSAGEKRAEFTIGSTE PRUEFUNG IST DIE LETZTE: ld bindet das Abbild gegen
# eine C-Gegenstelle und das Programm rechnet. Alles davor kann ein Abbild
# erfuellen, das plausibel aussieht und falsch bindet.
cd "$(dirname "$0")/.." || exit 1
LYXC="${LYXC:-./lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
PASS=0; FAIL=0
pr() { if [ "$1" = ok ]; then PASS=$((PASS+1)); echo "PASS $2"; else FAIL=$((FAIL+1)); echo "FAIL $2"; fi; }

for w in readelf python3 gcc; do
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
cat > "$T/u/probe/mithelfer.lyx" <<'LYX'
unit probe.mithelfer;
pub fn Laenge(s: pchar): int64 { return StrLen(s); }
LYX

hol() {  # $1 = Unitname -> $T/$1.o
  "$LYXC" --std-path="$T/u" --compile-unit --with-objcode "$T/u/probe/$1.lyx" \
      -o "$T/$1.lyu" > "$T/$1.log" 2>&1 || return 1
  local l; l="$("$LYXC" --unit-info "$T/$1.lyu" 2>&1 | awk '/Objekt:/{print $2}')"
  [ -n "$l" ] || return 1
  python3 -I -c "
d = open('$T/$1.lyu','rb').read()
i = d.find(b'\x7fELF')
open('$T/$1.o','wb').write(d[i:i+$l])
" || return 1
  echo "$l"
}

GL="$(hol gross)" || { echo "FAIL gross: $(grep -i error "$T/gross.log" | head -2)"; echo "Ergebnis: 0 PASS, 1 FAIL"; exit 1; }
HL="$(hol mithelfer)" || { echo "FAIL mithelfer: $(grep -i error "$T/mithelfer.log" | head -2)"; echo "Ergebnis: 0 PASS, 1 FAIL"; exit 1; }

SYM="$(readelf -sW "$T/gross.o" 2>/dev/null)"
REL="$(readelf -rW "$T/gross.o" 2>/dev/null)"

# 1) die eigene Funktion liegt am Anfang des Abbilds
if printf '%s' "$SYM" | awk '$4=="FUNC" && $8=="GrossDrei"{print $2}' | grep -qx "0000000000000000"; then
  pr ok "GrossDrei liegt auf .ltext:0 -- der Schnitt beginnt an der eigenen Funktion"
else
  pr no "GrossDrei nicht auf Offset 0: $(printf '%s' "$SYM" | awk '$8=="GrossDrei"{print $2}')"
fi

# 2) kein _start mehr: an Offset 0 liegt jetzt die erste Unit-Funktion, ein
#    _start mit st_value 0 waere ein falscher Einsprungpunkt.
if printf '%s' "$SYM" | awk '{print $8}' | grep -qx "_start"; then
  pr no "_start steht noch im geschnittenen Abbild und zeigt auf .ltext:0"
else
  pr ok "kein _start im geschnittenen Abbild"
fi

# 3) importierte Aufrufe sind UNDEF samt Relokation -- und NICHT definiert
fehlt=""
for s in KleinEins KleinZwei; do
  printf '%s' "$SYM" | awk '$5=="GLOBAL" && $7=="UND"{print $8}' | grep -qx "$s" || fehlt="$fehlt $s"
  printf '%s' "$REL" | grep -q "R_X86_64_PC32.*$s" || fehlt="$fehlt $s/reloc"
done
if [ -z "$fehlt" ]; then
  pr ok "KleinEins und KleinZwei sind UNDEF mit PC32-Relokation"
else
  pr no "fehlende UNDEF-Symbole oder Relokationen:$fehlt"
fi
if printf '%s' "$SYM" | awk '$4=="FUNC" && $7=="1"{print $8}' | grep -qxE "KleinEins|KleinZwei"; then
  pr no "importierte Funktion ist im Abbild DEFINIERT -- der Schnitt hat sie nicht entfernt"
else
  pr ok "keine importierte Funktion im Abbild definiert"
fi

# 4) Helferreferenz wird zum UNDEF-Symbol des Wirts
if readelf -rW "$T/mithelfer.o" 2>/dev/null | grep -q "R_X86_64_PC32.*_lyxh_strlen_simd"; then
  pr ok "StrLen wird zur Relokation gegen _lyxh_strlen_simd (Helferblock des Wirts)"
else
  pr no "keine Helfer-Relokation im Abbild: $(readelf -rW "$T/mithelfer.o" 2>/dev/null | grep R_X86_64 | head -3)"
fi

# 5) ELF ohne Beanstandung: sh_info muss den ersten GLOBAL-Index nennen,
#    sonst darf ld die Datei zurueckweisen.
W="$(readelf -sW "$T/gross.o" 2>&1 >/dev/null)"
if [ -z "$W" ]; then
  pr ok "readelf beanstandet die Symboltabelle nicht"
else
  pr no "readelf warnt: $(printf '%s' "$W" | head -2)"
fi

# 6) WIRKUNG: ld bindet das Abbild, das Programm rechnet.
cat > "$T/stub.c" <<'C'
#include <stdio.h>
long KleinEins(long a) { return a + 1; }
long KleinZwei(long a) { return a + 2; }
long GrossDrei(long a);
int main(void) { printf("%ld\n", GrossDrei(10)); return 0; }
C
if gcc -c "$T/stub.c" -o "$T/stub.o" > "$T/cc.log" 2>&1 \
   && gcc "$T/stub.o" "$T/gross.o" -o "$T/prog" > "$T/ld.log" 2>&1; then
  AUS="$("$T/prog" 2>&1)"
  if [ "$AUS" = "23" ]; then
    pr ok "ld bindet das Abbild, GrossDrei(10) ergibt 23"
  else
    pr no "gebunden, aber falsches Ergebnis: '$AUS' statt 23"
  fi
else
  pr no "ld bindet das Abbild nicht: $(grep -iE 'error|undefined' "$T/ld.log" | head -3)"
fi

# 7) Der schwierige Fall, am ECHTEN Bestand: eine Klasse erbt eine Methode aus
#    einer importierten Unit. Der VMT-Eintrag traegt dann eine absolute Adresse
#    auf Code VOR dem Schnitt -- gegen .ltext waere das ein negativer Offset.
#    Aus der Adresse muss wieder ein NAME werden (R_X86_64_64 gegen das
#    Symbol). Gemessen: ohne diese Behandlung erzeugten 16 von 489
#    stdlib-Units kein Abbild, alle unter std/lyxvision.
#
#    Nachgebaut wurde der Fall nicht: eine Minimalklasse bekam einen direkten
#    Aufruf (PC32) statt eines VMT-Eintrags, haette also etwas anderes
#    gemessen. std/lyxvision/button.lyx loest ihn wirklich aus.
if [ -f std/lyxvision/button.lyx ]; then
  if "$LYXC" --std-path=. --compile-unit --with-objcode std/lyxvision/button.lyx \
       -o "$T/btn.lyu" > "$T/btn.log" 2>&1; then
    BL="$("$LYXC" --unit-info "$T/btn.lyu" 2>&1 | awk '/Objekt:/{print $2}')"
    python3 -I -c "
d = open('$T/btn.lyu','rb').read()
i = d.find(b'\x7fELF')
open('$T/btn.o','wb').write(d[i:i+$BL])
" 2>/dev/null
    NAM="$(readelf -rW "$T/btn.o" 2>/dev/null | awk '/R_X86_64_64/ && $5!=".ltext" && $5!=""{print $5}' | sort -u | tr '\n' ' ')"
    if [ -n "$NAM" ]; then
      pr ok "geerbte Methode im VMT wird zur Namensrelokation: $NAM"
    else
      pr no "kein Namenssymbol fuer geerbten Code -- der VMT-Eintrag zeigt in das Erzeugnis des Erzeugers"
    fi
  else
    pr no "std/lyxvision/button.lyx erzeugt kein Abbild: $(grep -i error "$T/btn.log" | head -2)"
  fi
else
  echo "SKIP 7: std/lyxvision/button.lyx fehlt"
fi

# 8) Das Abbild ist kleiner als das ungeschnittene -- die Zahl steht hier als
#    Messgroesse, nicht als Aussage ueber Richtigkeit.
if [ "$GL" -lt 3000 ]; then
  pr ok "geschnittenes Abbild $GL Byte (ungeschnitten waren es 4832)"
else
  pr no "Abbild $GL Byte -- nicht geschnitten"
fi

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "OK: das Abbild ist auf den eigenen Code geschnitten und bindet (#2146 Stufe C2b)"
