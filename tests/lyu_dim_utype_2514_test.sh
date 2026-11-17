#!/bin/bash
# #2514: `pub dim` und `pub utype` in der .lyu.
#
# std/units.lyx war die letzte quellpflichtige Unit des Pakets: ihre 17
# Dimensionen und 66 Einheitentypen standen als Symbole in der .lyu, aber
# nicht als Deklaration ("Nicht beschrieben: Length").
#
# WAS DIESER TEST MISST, und warum nicht weniger:
#
# BEIDE SEITEN (#1823). Dass die passende Addition uebersetzt, waere auch
# erfuellt, wenn die Dimensionspruefung ueber die .lyu-Grenze GAR NICHT mehr
# greift -- dann ist `3 m + 4 s` ebenso typrichtig. Darum wird zusaetzlich
# gemessen, dass der unpassende Fall LAUT scheitert.
#
# AM ERZEUGNIS, nicht an der Meldung. Geprueft wird, dass eine Datei
# entsteht bzw. keine entsteht, plus der Wortlaut im Fehlerfall.
#
# NUR AUS DER .lyu: der Baum enthaelt units.lyu und KEINE units.lyx. Ohne
# diese Vorbedingung messe man den Quellweg und merke es nicht.
set -u
cd "$(dirname "$0")/.." || exit 1
LYXC="${LYXC:-./lyxc}"
# Der Wrapper des Guards ruft LYXC mit genau diesem Pfad auf. Dieser Test
# wechselt zum Uebersetzen das Verzeichnis, also muss der Pfad ABSOLUT sein,
# bevor der Guard ihn einbackt -- sonst scheitert jeder Aufruf mit
# "timeout: failed to execute process".
case "$LYXC" in /*) ;; *) LYXC="$PWD/${LYXC#./}";; esac
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
[ -x "$LYXC" ] || { echo "SKIP: ./lyxc fehlt"; exit 0; }
PASS=0; FAIL=0
ok()   { echo "PASS: $1"; PASS=$((PASS+1)); }
nok()  { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/baum/x86_64/std" "$T/arb"

# --- units.lyu erzeugen -----------------------------------------------------
if ! "$LYXC" --std-path=. --with-objcode --compile-unit std/units.lyx \
     -o "$T/baum/x86_64/std/units.lyu" > "$T/cu.log" 2>&1; then
  nok "std/units.lyx liess sich nicht zu .lyu uebersetzen"
  sed -n '1,5p' "$T/cu.log"
  echo "RESULT: $PASS PASS, $FAIL FAIL"; exit 1
fi
ok "std/units.lyx zu .lyu uebersetzt"

# Vorbedingung: im Baum liegt KEINE Quelle.
if [ -e "$T/baum/x86_64/std/units.lyx" ]; then
  nok "Vorbedingung verletzt: units.lyx liegt im Baum, der Test misst den Quellweg"
else
  ok "Vorbedingung: nur units.lyu im Baum, keine Quelle"
fi

# --- Der Abschnitt traegt die Dimensionen ----------------------------------
# Namen UND die Ausdrucksform. `(1 / Time)` ist der Kehrwertfall: beim ersten
# Wurf stand dort `( / Time)`, weil ein Ganzzahlliteral seinen Wert in iVal
# traegt und nicht als Quelltext -- der lesende Parser meldete dann
# "expected expression". Ein Test nur auf den NAMEN haette das nicht gesehen.
for muster in Length Time Frequency Resistance; do
  if grep -qa "$muster" "$T/baum/x86_64/std/units.lyu"; then
    ok "Dimension im .lyu beschrieben: $muster"
  else
    nok "Dimension fehlt im .lyu: $muster"
  fi
done

# --- Programm, das nur aus der .lyu uebersetzt -----------------------------
cat > "$T/arb/ok.lyx" <<'EOF'
unit main;
import std.units;
fn main(): int64 {
  var a: m := 3.0;
  var b: m := 4.0;
  var c: m := a + b;
  return 0;
}
EOF
sed 's/var b: m/var b: s/' "$T/arb/ok.lyx" > "$T/arb/bad.lyx"
# Kehrwertdimension: Hz entsteht aus `dim Frequency = 1 / Time`.
cat > "$T/arb/hz.lyx" <<'EOF'
unit main;
import std.units;
fn main(): int64 {
  var f: Hz := 50.0;
  var g: Hz := 60.0;
  var h: Hz := f + g;
  return 0;
}
EOF
sed 's/var g: Hz/var g: s/' "$T/arb/hz.lyx" > "$T/arb/hzbad.lyx"

LYXC_ABS="$LYXC"   # oben absolut gemacht, ggf. der Guard-Wrapper
BAUM="$T/baum"

lauf() {   # lauf <datei> -> setzt RC und ERZ
  ( cd "$T/arb" && "$LYXC_ABS" --units-install-dir="$BAUM" "$1.lyx" -o "$1.out" \
      > "$1.log" 2>&1 )
  RC=$?
  if [ -s "$T/arb/$1.out" ]; then ERZ=ja; else ERZ=nein; fi
}

# Seite 1: passend -> muss uebersetzen UND ein Erzeugnis liefern.
lauf ok
if [ "$RC" = "0" ] && [ "$ERZ" = "ja" ]; then
  ok "passende Addition uebersetzt nur aus der .lyu (Erzeugnis entsteht)"
else
  nok "passende Addition scheitert (rc=$RC, Erzeugnis=$ERZ)"
  grep -m3 -iE "error|Nicht beschrieben|parse" "$T/arb/ok.log" | sed 's/^/    /'
fi

lauf hz
if [ "$RC" = "0" ] && [ "$ERZ" = "ja" ]; then
  ok "Kehrwertdimension Hz uebersetzt nur aus der .lyu"
else
  nok "Hz scheitert (rc=$RC, Erzeugnis=$ERZ)"
  grep -m3 -iE "error|parse" "$T/arb/hz.log" | sed 's/^/    /'
fi

# Seite 2: unpassend -> muss LAUT scheitern, ohne Erzeugnis.
for f in bad hzbad; do
  lauf "$f"
  if [ "$RC" != "0" ] && [ "$ERZ" = "nein" ]; then
    ok "unpassende Dimension ($f) scheitert ohne Erzeugnis"
  else
    nok "unpassende Dimension ($f) ging durch (rc=$RC, Erzeugnis=$ERZ)"
  fi
  if grep -q "verschiedener Dimension" "$T/arb/$f.log"; then
    ok "Meldung nennt die Dimension ($f)"
  else
    nok "Meldung nennt die Dimension nicht ($f)"
    grep -m2 -iE "error" "$T/arb/$f.log" | sed 's/^/    /'
  fi
done

# --- std.units ist nicht mehr quellpflichtig -------------------------------
# Die Meldung des Codegens ist der eigentliche Gegenstand des Issues.
if grep -q "Quelle der importierten Unit nicht lesbar" "$T/arb/ok.log" 2>/dev/null; then
  nok "std.units gilt weiter als quellpflichtig"
else
  ok "std.units ist nicht mehr quellpflichtig"
fi

echo "RESULT: $PASS PASS, $FAIL FAIL"
[ "$FAIL" = "0" ] || exit 1
