#!/bin/bash
# #2499: Die Vorkompilate des Pakets tragen das Objektabbild (#2146) -- erst
# damit traegt sich das Paket selbst.
#
# Vorher scheiterte ein Programm, das NUR gegen den Paketbaum uebersetzt, an
# "stammt aus einer .lyu ohne Objektcode" und brauchte die Quellen aus dem
# LPM-Paket std. Geprueft wird deshalb nicht das Vorhandensein eines
# Abschnitts, sondern die WIRKUNG: uebersetzen und rechnen, ohne eine einzige
# .lyx in Reichweite.
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
_pp="$(dirname "$0")/lib/paket_pfad.sh"; [ -f "$_pp" ] || _pp="$(dirname "$0")/../lib/paket_pfad.sh"; . "$_pp"   # #2499
PASS=0; FAIL=0
pr() { if [ "$1" = ok ]; then PASS=$((PASS+1)); echo "PASS $2"; else FAIL=$((FAIL+1)); echo "FAIL $2"; fi; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/leer"

# 1) Das Makefile baut mit Abbild. Ohne diese Zeile ist alles Weitere zufaellig.
if [ -n "$PKG_OBJCODE" ]; then
  pr ok "Makefile baut die Vorkompilate mit '$PKG_OBJCODE'"
else
  pr no "LYU_OBJCODE ist leer -- das Paket traegt keine Abbilder"
fi

# 2) Eine gepackte .lyu traegt wirklich ein Abbild (Deklarationsart 9).
#    Gefragt wird die Datei, nicht das Makefile.
LYU="$PKG_UNITS/std/string.lyu"
if [ -f "$LYU" ]; then
  INFO="$("$LYXC" --unit-info "$LYU" 2>&1)"
  LEN="$(printf '%s' "$INFO" | awk '/Objekt:/{print $2}')"
  case "$LEN" in
    ''|*[!0-9]*) pr no "std/string.lyu meldet kein Abbild: $(printf '%s' "$INFO" | grep -i objekt)" ;;
    *) if [ "$LEN" -gt 1000 ]; then
         pr ok "gepackte std/string.lyu traegt ein Abbild ($LEN Byte)"
       else
         pr no "Abbild in std/string.lyu nur $LEN Byte"
       fi ;;
  esac
else
  pr no "$LYU fehlt -- 'make precompile-units' fahren"
fi

# 3) WIRKUNG: ein Programm uebersetzen, das NUR den Paketbaum sieht. Das
#    Arbeitsverzeichnis ist leer, weil der Import-Resolver es vor --std-path
#    bevorzugt: im Repo faende er std/*.lyx und der Test waere gruen, ohne das
#    Paket geprueft zu haben.
cat > "$T/p.lyx" <<'LYX'
import std.io;
import std.string;
fn main(): int64 {
  PrintStrLn(StrConcat("Paket", "-Lauf"));
  return StrLen("abcde");
}
LYX
rm -f "$T/p"
( cd "$T/leer" && "$LYXC" --std-path="$PKG_UNITS" -I"$PKG_UNITS" "$T/p.lyx" -o "$T/p" ) > "$T/l.log" 2>&1
if [ -x "$T/p" ]; then
  AUS="$("$T/p" 2>&1)"; RC=$?
  if [ "$AUS" = "Paket-Lauf" ] && [ "$RC" -eq 5 ]; then
    pr ok "Programm uebersetzt und rechnet nur mit dem Paketbaum (Paket-Lauf, rc=5)"
  else
    pr no "laeuft, aber falsch: '$AUS' rc=$RC"
  fi
else
  pr no "uebersetzt nicht nur mit dem Paketbaum: $(grep -i error "$T/l.log" | head -2)"
fi

# 4) Gegenprobe, dass Pruefung 3 etwas misst: dieselbe Uebersetzung gegen
#    einen Baum OHNE Abbilder muss scheitern, und zwar mit dem bekannten
#    Grund. Sonst waere 3 auch von einem Paket erfuellt, das die Quellen
#    heimlich doch findet.
mkdir -p "$T/ohne/std"
for u in io string alloc; do
  [ -f "std/$u.lyx" ] || continue
  "$LYXC" --std-path=. --compile-unit "std/$u.lyx" -o "$T/ohne/std/$u.lyu" >/dev/null 2>&1
done
rm -f "$T/po"
( cd "$T/leer" && "$LYXC" --std-path="$T/ohne" -I"$T/ohne" "$T/p.lyx" -o "$T/po" ) > "$T/o.log" 2>&1
if [ ! -x "$T/po" ] && grep -q "ohne Objektcode" "$T/o.log"; then
  pr ok "ohne Abbilder scheitert dieselbe Uebersetzung mit 'ohne Objektcode'"
else
  pr no "ein Baum ohne Abbilder uebersetzt trotzdem -- Pruefung 3 misst nichts"
fi

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "OK: das Paket traegt sich selbst (#2499)"
