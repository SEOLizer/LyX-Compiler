#!/bin/bash
# #2499: Vorkompilate liegen je Architektur (`units/<arch>/std/io.lyu`).
#
# Der PFAD ordnet, der KOPF entscheidet: gesucht wird zuerst in der
# Architekturebene, der flache Pfad bleibt als Rueckfall gueltig (eine .lyu
# ohne Objektabschnitt ist architekturunabhaengig) -- und ob ein ABBILD
# benutzbar ist, sagt die Architektur im Kopf der Datei, nicht das
# Verzeichnis, in dem sie liegt.
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
_pp="$(dirname "$0")/lib/paket_pfad.sh"; [ -f "$_pp" ] || _pp="$(dirname "$0")/../lib/paket_pfad.sh"; . "$_pp"   # #2499
PASS=0; FAIL=0
pr() { if [ "$1" = ok ]; then PASS=$((PASS+1)); echo "PASS $2"; else FAIL=$((FAIL+1)); echo "FAIL $2"; fi; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 fehlt"; echo "Ergebnis: 0 PASS, 0 FAIL"; exit 0; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/leer" "$T/src/m"

# 1) Der Name der Architekturebene steht in LyuArchName und wird vom Makefile
#    uebernommen. Zwei Quellen fuer denselben Namen hiessen: eine Datei liegt
#    da, wo niemand sucht.
if grep -q "return \"$PKG_ARCH\"c;" src/lyu_reader.lyx; then
  pr ok "LYU_ARCH=$PKG_ARCH kommt aus LyuArchName (src/lyu_reader.lyx)"
else
  pr no "LYU_ARCH=$PKG_ARCH ist in LyuArchName unbekannt -- Makefile und Resolver driften"
fi

# 2) Der Paketbaum traegt die Architekturebene.
if [ -d "$PKG_UNITS/std" ] && [ "$(basename "$PKG_UNITS")" = "$PKG_ARCH" ]; then
  pr ok "Paketbaum liegt unter units/$PKG_ARCH/ ($(find "$PKG_UNITS" -name '*.lyu' | wc -l) Vorkompilate)"
else
  pr no "Paketbaum ohne Architekturebene: $PKG_UNITS"
fi

# --- Zwei Baeume mit UNTERSCHIEDLICHEM Inhalt, damit sichtbar wird, welcher
#     gewonnen hat. Eine Pruefung "es uebersetzt" waere von beiden erfuellt.
cat > "$T/src/m/basis.lyx" <<'LYX'
unit m.basis;
pub fn Wert(): int64 { return 42; }
LYX
mkdir -p "$T/baum/$PKG_ARCH/m"
"$LYXC" --std-path="$T/src" --compile-unit --with-objcode "$T/src/m/basis.lyx" \
    -o "$T/baum/$PKG_ARCH/m/basis.lyu" > "$T/b1.log" 2>&1 || {
  echo "FAIL Abbild fuer $PKG_ARCH nicht baubar: $(grep -i error "$T/b1.log" | head -2)"
  echo "Ergebnis: 0 PASS, 1 FAIL"; exit 1; }

cat > "$T/src/m/basis.lyx" <<'LYX'
unit m.basis;
pub fn Wert(): int64 { return 7; }
LYX
mkdir -p "$T/baum/m"
"$LYXC" --std-path="$T/src" --compile-unit --with-objcode "$T/src/m/basis.lyx" \
    -o "$T/baum/m/basis.lyu" > "$T/b2.log" 2>&1 || {
  echo "FAIL flaches Abbild nicht baubar"; echo "Ergebnis: 0 PASS, 1 FAIL"; exit 1; }

cat > "$T/p.lyx" <<'LYX'
import m.basis;
fn main(): int64 { return Wert(); }
LYX
lauf() {  # $1 = Baumwurzel -> rc des Programms
  rm -f "$T/p"
  ( cd "$T/leer" && "$LYXC" --std-path="$1" -I"$1" "$T/p.lyx" -o "$T/p" ) > "$T/l.log" 2>&1 || return 255
  [ -x "$T/p" ] || return 255
  "$T/p"; return $?
}

# 3) Die Architekturebene gewinnt -- nachgewiesen am WERT, nicht am Gelingen.
lauf "$T/baum"; RC=$?
if [ "$RC" -eq 42 ]; then
  pr ok "units/$PKG_ARCH/ wird vor dem flachen Pfad genommen (42, nicht 7)"
elif [ "$RC" -eq 7 ]; then
  pr no "der flache Pfad gewinnt -- die Architekturebene wird nicht zuerst gesucht"
else
  pr no "kein Erzeugnis (rc=$RC): $(grep -i error "$T/l.log" | head -2)"
fi

# 4) Rueckfall: ohne Architekturebene gilt der flache Pfad weiter. Bestehende
#    Baeume und selbst gebaute .lyu liegen dort.
mkdir -p "$T/nurflach/m"
cp "$T/baum/m/basis.lyu" "$T/nurflach/m/basis.lyu"
lauf "$T/nurflach"; RC=$?
if [ "$RC" -eq 7 ]; then
  pr ok "ohne Architekturebene greift der flache Pfad (7)"
else
  pr no "Rueckfall auf den flachen Pfad scheitert (rc=$RC)"
fi

# 5) Der KOPF entscheidet: ein Abbild fuer ein anderes Ziel wird nicht
#    stillschweigend genommen, und die Meldung nennt beide Architekturen.
#    Das Kopfbyte 6 traegt die Architektur (#1982) und wird hier verbogen --
#    ein arm64-Abbild laesst sich mit --with-objcode nicht erzeugen.
mkdir -p "$T/fremd/$PKG_ARCH/m"
cp "$T/baum/$PKG_ARCH/m/basis.lyu" "$T/fremd/$PKG_ARCH/m/basis.lyu"
python3 -I -c "
p = '$T/fremd/$PKG_ARCH/m/basis.lyu'
d = bytearray(open(p,'rb').read())
d[6] = 1   # arm64
open(p,'wb').write(d)
"
rm -f "$T/pf"
( cd "$T/leer" && "$LYXC" --std-path="$T/fremd" -I"$T/fremd" "$T/p.lyx" -o "$T/pf" ) > "$T/f.log" 2>&1
if [ -x "$T/pf" ]; then
  pr no "ein Abbild fuer eine andere Architektur wurde gebunden"
elif grep -q "ANDERES ZIEL" "$T/f.log" && grep -q "arm64" "$T/f.log" && grep -q "$PKG_ARCH" "$T/f.log"; then
  pr ok "fremdes Abbild wird abgewiesen und die Meldung nennt arm64 und $PKG_ARCH"
else
  pr no "abgewiesen, aber ohne den Grund zu nennen: $(grep -i error "$T/f.log" | head -2)"
fi

# 6) Die Meldung "ohne Objektcode" bleibt fuer den anderen Fall erhalten:
#    eine .lyu, die ueberhaupt kein Abbild traegt. Sonst schickt die neue
#    Meldung in die falsche Abhilfe.
mkdir -p "$T/ohne/$PKG_ARCH/m"
"$LYXC" --std-path="$T/src" --compile-unit "$T/src/m/basis.lyx" \
    -o "$T/ohne/$PKG_ARCH/m/basis.lyu" > "$T/b3.log" 2>&1
rm -f "$T/po"
( cd "$T/leer" && "$LYXC" --std-path="$T/ohne" -I"$T/ohne" "$T/p.lyx" -o "$T/po" ) > "$T/o.log" 2>&1
if [ ! -x "$T/po" ] && grep -q "ohne Objektcode" "$T/o.log"; then
  pr ok "eine .lyu ohne Abbild meldet weiter 'ohne Objektcode'"
else
  pr no "falsche Meldung fuer eine .lyu ohne Abbild: $(grep -i error "$T/o.log" | head -2)"
fi

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "OK: Vorkompilate liegen je Architektur, der Kopf entscheidet (#2499)"
