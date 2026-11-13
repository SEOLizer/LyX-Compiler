#!/bin/bash
# #2505: Die FFI-Aufrufstelle im Objektabbild nennt das RICHTIGE Symbol.
#
# Der Patch traegt einen INDEX, und es gibt ZWEI Tabellen: externDecls fuehrt
# die DEKLARIERTEN Bindungen, externSyms die BENUTZTEN (je eine ein GOT-Platz).
# Der Index zeigt in die zweite. Die erste Fassung las die erste -- bei
# std/x11.lyx stimmten die vorderen Namen zufaellig ueberein, XSetWindowTitle
# fiel ganz aus dem Abbild, und der Aufruf sprang ins Leere (SIGSEGV ohne
# Hinweis, waehrend derselbe Fehler aus der Quelle die Ladermeldung bringt).
#
# Gemessen wird am WERT und an der MELDUNG, nicht am Vorhandensein: ein Index,
# der in der falschen Tabelle noch GUELTIG ist, liefert einen anderen Namen --
# und bindet den Aufruf still an eine andere Funktion.
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
PASS=0; FAIL=0
pr() { if [ "$1" = ok ]; then PASS=$((PASS+1)); echo "PASS $2"; else FAIL=$((FAIL+1)); echo "FAIL $2"; fi; }

for w in readelf python3; do
  command -v "$w" >/dev/null 2>&1 || { echo "SKIP: $w fehlt"; echo "Ergebnis: 0 PASS, 0 FAIL"; exit 0; }
done

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/src/dv" "$T/nur/dv" "$T/leer"

# Die Tabellen laufen auseinander: memset wird DEKLARIERT und nicht benutzt,
# strlen wird benutzt. Deklarationsindex 0 = memset, Nutzungsindex 0 = strlen.
# Beide sind in der FFI-Klassifizierung als SAFE gefuehrt, der Fall braucht
# also keine @capabilities-Angabe (die wiederum Art 10 aussetzen wuerde).
cat > "$T/src/dv/mehr.lyx" <<'LYX'
unit dv.mehr;
extern fn memset(p: int64, c: int64, n: int64): int64 link "libc.so.6";
extern fn strlen(s: pchar): int64 link "libc.so.6";
pub fn Laenge(s: pchar): int64 { return strlen(s); }
LYX
"$LYXC" --std-path="$T/src" --with-objcode --compile-unit "$T/src/dv/mehr.lyx" \
    -o "$T/nur/dv/mehr.lyu" > "$T/bau.log" 2>&1 || {
  echo "FAIL Unit nicht uebersetzbar: $(grep -i error "$T/bau.log" | head -2)"
  echo "Ergebnis: 0 PASS, 1 FAIL"; exit 1; }

LEN="$("$LYXC" --unit-info "$T/nur/dv/mehr.lyu" 2>&1 | awk '/Objekt:/{print $2}')"
python3 -I -c "
d = open('$T/nur/dv/mehr.lyu','rb').read()
i = d.find(b'\x7fELF')
open('$T/mehr.o','wb').write(d[i:i+$LEN])
" 2>/dev/null
UND="$(readelf -sW "$T/mehr.o" 2>/dev/null | awk '$7=="UND" && $8!=""{print $8}')"

# 1) Das benutzte Symbol steht im Abbild.
if printf '%s\n' "$UND" | grep -qx strlen; then
  pr ok "das benutzte Symbol strlen steht im Abbild"
else
  pr no "strlen fehlt im Abbild: $(printf '%s' "$UND" | tr '\n' ' ')"
fi

# 2) Das nur DEKLARIERTE steht NICHT drin -- sonst wurde die andere Tabelle
#    gelesen. Das ist die eigentliche Aussage.
if printf '%s\n' "$UND" | grep -qx memset; then
  pr no "memset steht im Abbild -- der Index wurde in externDecls aufgeloest"
else
  pr ok "das nur deklarierte memset steht nicht im Abbild"
fi

# 3) WIRKUNG am WERT: Laenge("abcd") muss 4 ergeben. Waere der Aufruf an
#    memset gebunden, kaeme nicht 4 heraus (eine pchar als Zeiger, drei
#    Argumente gegen eines).
cat > "$T/p.lyx" <<'LYX'
import dv.mehr;
fn main(): int64 { return Laenge("abcd" as pchar); }
LYX
rm -f "$T/p"
( cd "$T/leer" && "$LYXC" --std-path="$T/nur" -I"$T/nur" "$T/p.lyx" -o "$T/p" ) > "$T/p.log" 2>&1
if [ -x "$T/p" ]; then
  "$T/p"; RC=$?
  if [ "$RC" -eq 4 ]; then
    pr ok "der gebundene Aufruf liefert 4 (strlen, nicht memset)"
  else
    pr no "Rueckgabe $RC statt 4 -- der Aufruf haengt an der falschen Funktion"
  fi
else
  pr no "uebersetzt nicht: $(grep -i error "$T/p.log" | head -2)"
fi

# 4) Der echte Fall am Bestand: std/x11.lyx deklariert XSetWindowTitle und
#    ruft es in XSetDisplayWindowTitle. Im Abbild fehlte das Symbol ganz.
if [ -f std/x11.lyx ]; then
  mkdir -p "$T/snur/std"
  if "$LYXC" --std-path=. --with-objcode --compile-unit std/x11.lyx \
         -o "$T/snur/std/x11.lyu" > "$T/x11.log" 2>&1; then
    XL="$("$LYXC" --unit-info "$T/snur/std/x11.lyu" 2>&1 | awk '/Objekt:/{print $2}')"
    python3 -I -c "
d = open('$T/snur/std/x11.lyu','rb').read()
i = d.find(b'\x7fELF')
open('$T/x11.o','wb').write(d[i:i+$XL])
" 2>/dev/null
    if readelf -sW "$T/x11.o" 2>/dev/null | awk '$7=="UND" && $8!=""{print $8}' \
         | grep -qx XSetWindowTitle; then
      pr ok "std.x11: XSetWindowTitle steht als UNDEF im Abbild"
    else
      pr no "std.x11: XSetWindowTitle fehlt im Abbild -- der Aufruf bleibt unvermerkt"
    fi
  else
    pr no "std/x11.lyx liefert kein Abbild: $(grep -i error "$T/x11.log" | head -2)"
  fi
else
  echo "SKIP 4: std/x11.lyx fehlt"
fi

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "OK: FFI-Aufrufstellen im Abbild nennen das richtige Symbol (#2505)"
