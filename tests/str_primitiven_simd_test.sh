#!/usr/bin/env bash
# tests/str_primitiven_simd_test.sh — die vektorisierten Zeichenketten- und
# Kopier-Primitiven des x86-Codegens (T1: StrLen, StrEquals,
# StrStartsWith, memcpy).
#
# Geprueft wird in zwei Richtungen, weil eine Richtung allein nichts sagt:
#
#   A) VERHALTEN. Drei Proben rechnen jeden Fall gegen eine unabhaengige
#      byteweise Fassung — Laengen, Versaetze, Abweichung an jeder
#      Position, Praefixverhaeltnis, Ueberlappung, Laenge 0, und jeweils
#      eine Zeichenkette, deren Ende das letzte Byte einer belegten Seite
#      ist (dahinter unbelegt). Der Seitenfall ist der Grund, warum
#      _lyx_strlen_simd auf 16 abrundet und _lyx_streq eine Seitenpruefung
#      traegt; ohne sie faultet er, und zwar nur dort.
#
#   B) ERZEUGNIS. Dass die Proben gruen sind, hiesse auch bei den ALTEN
#      byteweisen Fassungen gruen — sie waren ja richtig. Deshalb wird am
#      Erzeugnis nachgesehen, dass die schnellen Wege tatsaechlich darin
#      stehen und die alten Einsetzungen nicht mehr. Bytemuster, kein
#      Text: das Lyx-Erzeugnis hat keine Sektionen, `objdump -d` meldet
#      daran 0 Befehle.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# ---------------------------------------------------------------- A) Verhalten
for probe in strlen_simd memcpy_weiche streq_simd; do
  src="$ROOT/tests/${probe}_probe.lyx"
  if [ ! -f "$src" ]; then no "$probe" "Probe $src fehlt"; continue; fi
  if ! (cd "$ROOT" && "$LYXC" --std-path=. "tests/${probe}_probe.lyx" -o "$TMP/$probe") >"$TMP/$probe.build" 2>&1; then
    no "$probe" "uebersetzt nicht: $(grep -iE 'error|fehler' "$TMP/$probe.build" | head -1)"
    continue
  fi
  # Deckel beim Lauf: eine Endlosschleife in einem dieser Helfer wuerde
  # sonst nicht den eigenen Prozess treffen, sondern den groessten
  # Verbraucher im System (#1370).
  out="$( ulimit -v 2000000; "$TMP/$probe" 2>&1 )"
  rc=$?
  if [ $rc -ne 0 ]; then
    no "$probe" "rc=$rc — $(echo "$out" | head -2 | tr '\n' ' ')"
  elif ! echo "$out" | grep -q "ALL PASS"; then
    no "$probe" "$(echo "$out" | head -2 | tr '\n' ' ')"
  else
    ok "$probe ($(echo "$out" | sed -n 's/^geprueft=\([0-9]*\).*/\1/p') Faelle)"
  fi
done

# ---------------------------------------------------------------- B) Erzeugnis
# Ein Programm, das alle vier Primitiven benutzt.
cat > "$TMP/alle.lyx" <<'LYX'
import std.io;
import std.string;
fn main(): int64 {
  var a: int64 := alloc(64);
  var b: int64 := alloc(64);
  poke8(a, 65); poke8(a + 1, 0);
  poke8(b, 65); poke8(b + 1, 0);
  var n: int64 := StrLen(a as pchar);
  memcpy(b, a, 40);
  if (StrEquals(a as pchar, b as pchar)) { n += 1; }
  if (StrStartsWith(a as pchar, b as pchar)) { n += 1; }
  PrintLn(n);
  return 0;
}
LYX
if ! (cd "$ROOT" && "$LYXC" --std-path=. "$TMP/alle.lyx" -o "$TMP/alle") >"$TMP/alle.build" 2>&1; then
  no "Erzeugnis" "uebersetzt nicht: $(grep -iE 'error|fehler' "$TMP/alle.build" | head -1)"
else
  zaehl() {  # $1 = Hexmuster
    python3 -c "
import sys
d=open('$TMP/alle','rb').read()
print(d.count(bytes.fromhex('$1')))"
  }
  pruef() {  # name muster soll vergleich
    local n="$1" m="$2" soll="$3" vgl="$4"
    local ist; ist="$(zaehl "$m")"
    case "$vgl" in
      eq) [ "$ist" -eq "$soll" ] && ok "$n ($ist×)" || no "$n" "$ist× im Erzeugnis, erwartet $soll×" ;;
      ge) [ "$ist" -ge "$soll" ] && ok "$n ($ist×)" || no "$n" "$ist× im Erzeugnis, erwartet mindestens $soll×" ;;
    esac
  }
  # Die schnellen Wege MUESSEN da sein — je genau einmal, sie sind Helfer.
  pruef "_lyx_strlen_simd im Erzeugnis"  "d3e885c0"           1 eq   # shr eax,cl; test eax,eax
  pruef "_lyx_memcpy im Erzeugnis"       "4889f94829f14839d1" 1 eq   # Ueberlappungspruefung
  pruef "_lyx_streq im Erzeugnis"        "0fa3d0"             1 eq   # bt eax,edx
  pruef "_lyx_startswith im Erzeugnis"   "0fa3d1"             1 eq   # bt ecx,edx
  # Der Vorfilter steht EINGESETZT an der Aufrufstelle, also mindestens
  # zweimal (Aufrufstelle + Helfer).
  pruef "memcpy-Vorfilter eingesetzt"    "4881fa00020000"     2 ge   # cmp rdx,512
  # Und die alten byteweisen Einsetzungen duerfen NICHT mehr an
  # Aufrufstellen stehen. `cmp byte [rdi+rax],0` gehoert allein zum
  # verankerten _lyx_strlen bei Versatz 79, den auf Linux niemand mehr
  # ruft; mehr als einmal heisst, eine Aufrufstelle setzt wieder ein.
  pruef "alter strlen nur verankert"     "803c0700"           1 eq
  # `mov al,[rdi]; cmp al,[rsi]` kommt GENAU ZWEIMAL vor, und beide Stellen
  # sind nachgesehen: einmal im Map-Kern (CG_H_MAP_STR, dort vergleicht die
  # Laufzeit pchar-Schluessel byteweise — unberuehrt von T1.2), einmal im
  # byteweisen Rueckfall von _lyx_streq am Seitenende. Eine DRITTE Stelle
  # hiesse, eine Aufrufstelle setzt den alten Vergleich wieder ein.
  pruef "alter StrEquals nur Map-Kern + Rueckfall" "8a073a06" 2 eq
fi

echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
