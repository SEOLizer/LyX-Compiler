#!/bin/bash
# #2502: Eine .lyu beschreibt `extern fn` (Deklarationsart 10). Damit ist eine
# Unit mit FFI aus der .lyu allein nutzbar.
#
# Vorher zaehlte der Codegen den Namen als verloren ("Nicht beschrieben:
# XOpenDisplay") und verlangte die .lyx der ganzen Unit -- 11 von 40
# Beispielen scheiterten daran, alle ueber std.x11/std.qt5_app/std.qt5_egl.
#
# GEPRUEFT WIRD DIE KETTE BIS ZUM AUFRUF, nicht die Beschreibung: das Abbild
# traegt die FFI-Aufrufstellen als Relokation gegen den Namen, der Wirt legt
# daraus einen GOT-Platz an (cg_addExtern), und das Erzeugnis bekommt
# DT_NEEDED. "Uebersetzt" allein waere auch von einem Erzeugnis erfuellt, das
# beim ersten Aufruf ins Leere springt -- genau das war der Zwischenstand.
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
PASS=0; FAIL=0
pr() { if [ "$1" = ok ]; then PASS=$((PASS+1)); echo "PASS $2"; else FAIL=$((FAIL+1)); echo "FAIL $2"; fi; }

command -v readelf >/dev/null 2>&1 || { echo "SKIP: readelf fehlt"; echo "Ergebnis: 0 PASS, 0 FAIL"; exit 0; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/src/ff" "$T/nur/ff" "$T/leer"

cat > "$T/src/ff/zahl.lyx" <<'LYX'
unit ff.zahl;
extern fn atoi(s: pchar): int64 link "libc.so.6";
pub fn Zahl(s: pchar): int64 { return atoi(s); }
LYX
cat > "$T/src/ff/mitcap.lyx" <<'LYX'
unit ff.mitcap;
@capabilities([system.exit])
extern fn atol(s: pchar): int64 link "libc.so.6";
pub fn Lang(s: pchar): int64 { return atol(s); }
LYX

"$LYXC" --std-path="$T/src" --with-objcode --compile-unit "$T/src/ff/zahl.lyx" \
    -o "$T/nur/ff/zahl.lyu" > "$T/bau.log" 2>&1 || {
  echo "FAIL Unit mit FFI liefert keine .lyu: $(grep -i error "$T/bau.log" | head -2)"
  echo "Ergebnis: 0 PASS, 1 FAIL"; exit 1; }

# 1) Die .lyu beschreibt die Bindung samt Bibliothek.
INFO="$("$LYXC" --unit-info "$T/nur/ff/zahl.lyu" 2>&1)"
if printf '%s' "$INFO" | grep -q 'extern fn atoi() link "libc.so.6";'; then
  pr ok "die .lyu beschreibt 'extern fn atoi() link \"libc.so.6\"'"
else
  pr no "keine extern-Beschreibung: $(printf '%s' "$INFO" | grep -i extern | head -2)"
fi

# 2) WIRKUNG, und zwar am WERT: atoi("41") muss 41 ergeben. Ein Erzeugnis, das
#    den Aufruf ins Leere schickt, faellt hier auf (es starb mit SIGSEGV).
cat > "$T/p.lyx" <<'LYX'
import ff.zahl;
fn main(): int64 { if (Zahl("41" as pchar) == 41) { return 0; } return 1; }
LYX
rm -f "$T/p"
( cd "$T/leer" && "$LYXC" --std-path="$T/nur" -I"$T/nur" "$T/p.lyx" -o "$T/p" ) > "$T/p.log" 2>&1
if [ -x "$T/p" ]; then
  "$T/p"; RC=$?
  if [ "$RC" -eq 0 ]; then
    pr ok "der FFI-Aufruf aus der gebundenen Unit liefert 41"
  else
    pr no "Programm laeuft, aber atoi liefert nicht 41 (rc=$RC)"
  fi
else
  pr no "uebersetzt nicht nur mit der .lyu: $(grep -i error "$T/p.log" | head -2)"
fi

# 3) Das Erzeugnis ist dynamisch gebunden und nennt die Bibliothek. Ohne das
#    gibt es keinen GOT-Platz -- der Zwischenstand war statisch und stuerzte
#    beim ersten Aufruf ab.
if [ -x "$T/p" ]; then
  if readelf -dW "$T/p" 2>/dev/null | grep -q "NEEDED.*libc.so.6"; then
    pr ok "DT_NEEDED libc.so.6 steht im Erzeugnis"
  else
    pr no "kein DT_NEEDED: $(file "$T/p" | sed 's/.*: //' | cut -c1-80)"
  fi
fi

# 4) Eine Bindung MIT @capabilities wird seit #2449 BESCHRIEBEN, und zwar
#    samt Angabe -- vorher blieb die Unit dafuer quellpflichtig (allein
#    std/net/dns.lyx kostete 50 Faelle). Hier zaehlt, dass die Angabe
#    MITKOMMT: ohne sie waere die wiederhergestellte Bindung eine andere als
#    die geschriebene, und die FFI-Sandbox ist fail-closed.
#
#    Die Gegenprobe fuer das, was weiter NICHT beschrieben wird (Angabe mit
#    Argumenten), steht in tests/lyu_dekl_2449_test.sh.
if "$LYXC" --std-path="$T/src" --with-objcode --compile-unit "$T/src/ff/mitcap.lyx" \
       -o "$T/nur/ff/mitcap.lyu" > "$T/bau2.log" 2>&1; then
  I2="$("$LYXC" --unit-info "$T/nur/ff/mitcap.lyu" 2>&1)"
  if printf '%s' "$I2" | grep -q "extern fn atol" \
     && printf '%s' "$I2" | grep -q '@capabilities(\[system.exit\])'; then
    pr ok "eine @capabilities-Bindung wird samt Angabe beschrieben (#2449)"
  elif printf '%s' "$I2" | grep -q "extern fn atol"; then
    pr no "die Bindung ist beschrieben, die Capability-Angabe fehlt -- Rechte gingen verloren"
  else
    pr no "die @capabilities-Bindung wird nicht beschrieben: $(printf '%s' "$I2" | grep -i extern | head -2)"
  fi
else
  pr no "Unit mit @capabilities-Bindung nicht uebersetzbar: $(grep -i error "$T/bau2.log" | head -2)"
fi

# 5) Eine echte stdlib-Unit mit FFI: vorher der Grund fuer 11 gescheiterte
#    Beispiele. Geprueft am Bestand, nicht am Nachbau.
if [ -f std/x11.lyx ]; then
  mkdir -p "$T/snur/std"
  if "$LYXC" --std-path=. --with-objcode --compile-unit std/x11.lyx \
         -o "$T/snur/std/x11.lyu" > "$T/x11.log" 2>&1; then
    printf 'import std.x11;\nfn main(): int64 { return 0; }\n' > "$T/px.lyx"
    rm -f "$T/px"
    if ( cd "$T/leer" && "$LYXC" --std-path="$T/snur" -I"$T/snur" "$T/px.lyx" -o "$T/px" ) \
         > "$T/px.log" 2>&1 && [ -x "$T/px" ]; then
      pr ok "std.x11 ist nur aus der .lyu uebersetzbar (war: 'Nicht beschrieben: XOpenDisplay')"
    else
      pr no "std.x11 weiter quellpflichtig: $(grep -iE 'nicht lesbar|Nicht beschrieben' "$T/px.log" | head -2)"
    fi
  else
    pr no "std/x11.lyx liefert keine .lyu: $(grep -i error "$T/x11.log" | head -2)"
  fi
else
  echo "SKIP 5: std/x11.lyx fehlt"
fi

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "OK: extern fn steht in der .lyu, FFI-Aufrufe binden (#2502)"
