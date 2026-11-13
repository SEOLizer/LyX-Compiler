#!/usr/bin/env bash
# tests/lyu_objabbild_2146_test.sh — #2146 Stufe B: die .lyu traegt das
# relozierbare Objektabbild (Deklarationsart 9).
#
# WARUM ART 9 UND NICHT 6: der Issue-Text von #2146 (2026-10-20) nennt "Art 6".
# Die ist seit #2488 die f64-Konstante. Belegt sind 2..8.
#
# KEINE EIGENE ARCHITEKTURANGABE im Eintrag: die Architektur steht im KOPF der
# .lyu. Zwei Wahrheiten fuer dieselbe Tatsache liefen irgendwann auseinander.
#
# DAS ARCHITEKTUR-TOR sitzt in LyrObjAbbild(wantArch, ...) -- also in der
# Funktion, die das Abbild herausgibt, nicht beim Aufrufer. Ein Abbild ist
# Maschinencode; es auf der falschen Architektur zu benutzen waere kein
# Fehlschlag, sondern ein Absturz an beliebiger Stelle.
#
# DIE LEHRE, DIE DIESEN TEST GEFORMT HAT: die erste Fassung liess --unit-info
# mit `self.arch` fragen -- die Datei pruefte sich selbst, das Tor konnte nie
# auslaesen, und eine auf arm64 verbogene x86-Datei wurde als arm64-Abbild
# ausgegeben. Deshalb prueft Schritt 4 GENAU DAS: Kopf verbiegen, Eintrag
# bleibt, Tor muss verweigern. Eine Pruefung, deren Soll- und Istwert aus
# derselben Quelle kommen, prueft nichts.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

for w in nm file python3; do
  command -v "$w" >/dev/null 2>&1 || { echo "SKIP: $w fehlt"; exit 0; }
done

mkdir -p "$TMP/u/probe"
cat > "$TMP/u/probe/kern.lyx" <<'EOF'
unit probe.kern;
pub fn Verdopple(x: int64): int64 { return x * 2; }
pub fn Plus(a: int64, b: int64): int64 { return a + b; }
EOF

if ! "$LYXC" --std-path="$TMP/u" --compile-unit --with-objcode "$TMP/u/probe/kern.lyx" \
     -o "$TMP/k.lyu" >"$TMP/cu.log" 2>&1; then
  echo "FAIL --compile-unit scheitert:"
  grep -iE "error" "$TMP/cu.log" | head -3 | sed 's/^/    /'
  echo "Ergebnis: 0 PASS, 1 FAIL"; exit 1
fi

info="$("$LYXC" --unit-info "$TMP/k.lyu" 2>&1)"

echo "-- 1. die .lyu meldet ein Abbild und haelt es fuer nutzbar --"
laenge="$(printf '%s' "$info" | awk '/Objekt:/{print $2}')"
if printf '%s' "$info" | grep -q "nutzbar fuer x86_64: ja" && [ -n "$laenge" ] && [ "$laenge" -gt 1000 ]; then
  echo "PASS Abbild $laenge Byte, nutzbar fuer x86_64"
  PASS=$((PASS+1))
else
  echo "FAIL unit-info ohne brauchbare Objektzeile:"
  printf '%s\n' "$info" | grep -iE "objekt|nutzbar" | sed 's/^/    /'
  FAIL=$((FAIL+1))
fi

echo "-- 2. das Abbild ist ein gueltiges ELF-Objekt mit den Symbolen --"
# Das Abbild liegt am Stueck in der Datei; die Laenge sagt unit-info.
python3 -I -c "
import sys
d = open('$TMP/k.lyu','rb').read()
i = d.find(b'\x7fELF')
if i < 0: sys.exit(2)
open('$TMP/aus.o','wb').write(d[i:i+$laenge])
" 2>/dev/null
if [ -s "$TMP/aus.o" ] && file "$TMP/aus.o" | grep -q "ELF 64-bit LSB relocatable"; then
  fehlt=""
  for sym in Verdopple Plus; do
    nm "$TMP/aus.o" 2>/dev/null | grep -qE "^[0-9a-f]+ T $sym\$" || fehlt="$fehlt $sym"
  done
  if [ -z "$fehlt" ]; then
    echo "PASS relozierbares ELF mit Verdopple und Plus (#2146 Stufe A)"
    PASS=$((PASS+1))
  else
    echo "FAIL Symbole fehlen im Abbild:$fehlt"
    FAIL=$((FAIL+1))
  fi
else
  echo "FAIL kein gueltiges ELF-Objekt extrahierbar"
  FAIL=$((FAIL+1))
fi

echo "-- 3. Gegenseite: ein IR-Ziel bekommt KEIN Abbild --"
# Ein x86-Abbild in einer arm64-.lyu waere schlimmer als keines: es wuerde
# auf dem Geraet abstuerzen statt beim Uebersetzen zu scheitern.
if "$LYXC" --std-path="$TMP/u" --target=arm64 --compile-unit --with-objcode \
   "$TMP/u/probe/kern.lyx" -o "$TMP/a.lyu" >"$TMP/arm.log" 2>&1; then
  ai="$("$LYXC" --unit-info "$TMP/a.lyu" 2>&1)"
  if printf '%s' "$ai" | grep -q "Objekt:  keines" && printf '%s' "$ai" | grep -q "Target:  arm64"; then
    echo "PASS arm64-.lyu ohne Abbild"
    PASS=$((PASS+1))
  else
    echo "FAIL arm64-.lyu traegt ein Abbild:"
    printf '%s\n' "$ai" | grep -iE "target|objekt" | sed 's/^/    /'
    FAIL=$((FAIL+1))
  fi
else
  echo "FAIL --compile-unit --target=arm64 scheitert:"
  grep -iE "error" "$TMP/arm.log" | head -2 | sed 's/^/    /'
  FAIL=$((FAIL+1))
fi

echo "-- 4. das Architektur-Tor verweigert bei fremder Architektur --"
cp "$TMP/k.lyu" "$TMP/f.lyu"
# Byte 6 des Kopfes ist die Architektur (0 = x86_64, 1 = arm64). Der Art-9-
# Eintrag bleibt dabei unveraendert in der Datei -- genau das ist der Punkt.
python3 -I -c "
d = bytearray(open('$TMP/f.lyu','rb').read())
d[6] = 1
open('$TMP/f.lyu','wb').write(d)
"
fi2="$("$LYXC" --unit-info "$TMP/f.lyu" 2>&1)"
if printf '%s' "$fi2" | grep -q "nutzbar fuer x86_64: nein" \
   && printf '%s' "$fi2" | grep -qE "Objekt:  [0-9]+ Byte"; then
  echo "PASS Eintrag bleibt lesbar, Tor verweigert ihn fuer x86_64"
  PASS=$((PASS+1))
else
  echo "FAIL Tor greift nicht (oder der Eintrag ist verschwunden):"
  printf '%s\n' "$fi2" | grep -iE "target|objekt|nutzbar" | sed 's/^/    /'
  FAIL=$((FAIL+1))
fi

echo "-- 5. ohne --with-objcode entsteht KEIN Abbild --"
# Die Voreinstellung ist AUS, und das aus gemessenen Gruenden: mit Abbild
# waechst der versionierte Paketbaum von 1,1 MB auf 101 MB, und das Abbild
# traegt auch allen importierten Code mit (der Codegen uebersetzt den ganzen
# AST). Beides ist vor Stufe C zu loesen, nicht durch eine Voreinstellung zu
# verdecken.
if "$LYXC" --std-path="$TMP/u" --compile-unit "$TMP/u/probe/kern.lyx" \
   -o "$TMP/o.lyu" >"$TMP/o.log" 2>&1; then
  oi="$("$LYXC" --unit-info "$TMP/o.lyu" 2>&1)"
  gross="$(stat -c%s "$TMP/o.lyu")"
  if printf '%s' "$oi" | grep -q "Objekt:  keines" && [ "$gross" -lt 1000 ]; then
    echo "PASS ohne Schalter kein Abbild (.lyu $gross Byte)"
    PASS=$((PASS+1))
  else
    echo "FAIL ohne Schalter entstand ein Abbild (.lyu $gross Byte):"
    printf '%s\n' "$oi" | grep -iE "objekt" | sed 's/^/    /'
    FAIL=$((FAIL+1))
  fi
else
  echo "FAIL --compile-unit ohne Schalter scheitert"
  FAIL=$((FAIL+1))
fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" = "0" ] || exit 1
echo "OK: die .lyu traegt das Objektabbild, architekturgebunden (#2146 Stufe B)"
exit 0
