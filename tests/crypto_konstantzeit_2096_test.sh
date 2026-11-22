#!/usr/bin/env bash
# tests/crypto_konstantzeit_2096_test.sh — #2096 Abnahmekriterium 7,
# Konstantzeit-Pruefung (dudect-artig) fuer den Tag-Vergleich.
#
# Gemessen wird die WIRKUNG am laufenden Erzeugnis, nicht die Form des
# Quelltexts. Ein Test, der `CTMemEqual` nur im Code sucht, waere auch von
# einer Fassung erfuellt, die frueh ausspringt.
#
# Vier Klassen, im WECHSEL je Probe (nicht blockweise -- ein Taktwechsel oder
# eine Last, die mitten im Lauf einsetzt, traefe sonst nur eine Klasse und
# sieht dann wie ein Datenabhaengigkeitsleck aus):
#
#   gleich   zwei gleiche Tags
#   erstes   Unterschied im ERSTEN Byte
#   letztes  Unterschied im LETZTEN Byte
#   gleich2  wieder zwei gleiche Tags -- daraus kommt der RAUSCHBODEN
#
# Geurteilt wird auf den Median, nicht den Mittelwert (ein Ausreisser durch
# eine fremde Last verschiebt den Mittelwert, den Median nicht), und gegen
# den selbst gemessenen Rauschboden statt gegen eine geratene Prozentzahl.
#
# Die zwei Vergleiche, die den Fehler je zeigen wuerden:
#   * gleich vs. erstes  -- ein memcmp mit frueher Rueckkehr ist bei einem
#     Unterschied im ersten Byte deutlich SCHNELLER als bei Gleichheit.
#   * erstes vs. letztes -- genau dieser Unterschied waechst mit der Stelle,
#     an der sich die Tags unterscheiden. Ohne diesen zweiten Vergleich waere
#     der Test auch von einer Fassung erfuellt, die bei JEDEM Unterschied
#     gleich lange braucht, aber die STELLE verraet.
#
# `taskset` bindet auf einen Kern, wenn vorhanden: ohne Bindung kippt eine
# Wanderung zwischen Kernen das Vorzeichen eines Unterschieds von wenigen
# Prozent.
#
# Gegenprobe gefahren: derselbe Messaufbau mit einem naiven Vergleich, der
# beim ersten abweichenden Byte zurueckkehrt, ergab bei 200 000 Aufrufen
# gleich=1269 us, erstes=1106 us, letztes=2954 us. Der Unterschied
# erstes/letztes von 1848 us liegt um drei Groessenordnungen ueber dem
# Rauschboden -- der Test waere dort rot.
#
# NICHT ABGEDECKT, und darum weiter offen in Kriterium 7: das Signieren
# (ECDSA/RSA) und die Padding-Pruefung von TLS 1.2 im CBC-Modus. Beide
# brauchen ein anderes Geschirr -- beim Signieren streut die Laufzeit schon
# ueber den Nonce, da braucht es den Vergleich zweier SCHLUESSELklassen statt
# zweier Eingabeklassen. Das ist eigene Arbeit und keine Zeile hier.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

WDH="${WDH:-20000}"
PROBEN="${PROBEN:-60}"

cat > "$TMP/ct.lyx" <<'LYXEOF'
unit main;
import std.io;
import std.alloc;
import std.time;
import std.crypto.ct;

// Ein Messpunkt: WDHMARKER Aufrufe von CTMemEqual ueber zwei Puffer. Die
// Rueckgabe wird aufsummiert und am Ende ausgegeben, damit der Aufruf nicht
// als toter Code wegfallen kann.
fn messe(a: int64, b: int64, laenge: int64, wdh: int64, senke: int64): int64 {
  var t0: int64 := NowUs();
  var i: int64 := 0;
  var s: int64 := 0;
  while (i < wdh) {
    s := s + CTMemEqual(a, b, laenge);
    i := i + 1;
  }
  poke64(senke, peek64(senke) + s);
  return NowUs() - t0;
}

fn main(): int64 {
  var laenge: int64 := 16;      // AEAD-Tag
  var wdh: int64 := WDHMARKER;
  var proben: int64 := PROBENMARKER;

  var gleichA: int64 := alloc(laenge);
  var gleichB: int64 := alloc(laenge);
  var erstesByte: int64 := alloc(laenge);
  var letztesByte: int64 := alloc(laenge);
  var i: int64 := 0;
  while (i < laenge) {
    poke8(gleichA + i, (i * 37 + 11) & 255);
    poke8(gleichB + i, (i * 37 + 11) & 255);
    poke8(erstesByte + i, (i * 37 + 11) & 255);
    poke8(letztesByte + i, (i * 37 + 11) & 255);
    i := i + 1;
  }
  poke8(erstesByte, peek8(erstesByte) ^ 255);
  poke8(letztesByte + laenge - 1, peek8(letztesByte + laenge - 1) ^ 255);

  var senke: int64 := alloc(8);
  poke64(senke, 0);

  // Einlaufrunde: der ERSTE Aufruf misst Seitenfehler und kalten Cache.
  messe(gleichA, gleichB, laenge, wdh, senke);

  var p: int64 := 0;
  while (p < proben) {
    Print("probe ");    PrintInt(p);
    Print(" gleich ");  PrintInt(messe(gleichA, gleichB, laenge, wdh, senke));
    Print(" erstes ");  PrintInt(messe(gleichA, erstesByte, laenge, wdh, senke));
    Print(" letztes "); PrintInt(messe(gleichA, letztesByte, laenge, wdh, senke));
    Print(" gleich2 "); PrintInt(messe(gleichB, gleichA, laenge, wdh, senke));
    PrintLn("");
    p := p + 1;
  }
  Print("senke "); PrintInt(peek64(senke)); PrintLn("");
  Print("wiederholungen "); PrintInt(wdh); Print(" proben "); PrintInt(proben); PrintLn("");
  return 0;
}
LYXEOF
sed -i "s|WDHMARKER|$WDH|; s|PROBENMARKER|$PROBEN|" "$TMP/ct.lyx"

if ! ( cd "$ROOT" && timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/ct.lyx" -o "$TMP/ct" ) >"$TMP/log" 2>&1; then
  echo "FAIL uebersetzt nicht: $(grep -m1 -i error "$TMP/log")"; exit 1
fi
[ -x "$TMP/ct" ] || { echo "FAIL kein Erzeugnis (#1682)"; exit 1; }

BIND=""
command -v taskset >/dev/null 2>&1 && BIND="taskset -c 2"
# Erster Lauf von neuem Code gedeckelt (CLAUDE.md).
if ! ( ulimit -v 2000000 -c 0; LC_ALL=C $BIND "$TMP/ct" ) > "$TMP/aus.txt" 2>&1; then
  echo "FAIL Messlauf: $(tail -2 "$TMP/aus.txt" | tr '\n' ' ')"; exit 1
fi

P=0; F=0
ok()  { echo "PASS $1"; P=$((P+1)); }
bad() { echo "FAIL $1${2:+ -- $2}"; F=$((F+1)); }

med() {  # spaltenname -> Median der Werte
  awk -v feld="$1" '
    /^probe / { for (i = 1; i < NF; i++) if ($i == feld) { v[n++] = $(i+1) } }
    END {
      if (n == 0) { print "" ; exit }
      asort_n(v, n)
      print (n % 2) ? v[int(n/2)] : int((v[n/2 - 1] + v[n/2]) / 2)
    }
    function asort_n(a, m,   i, j, t) {
      for (i = 0; i < m; i++) for (j = i + 1; j < m; j++)
        if (a[j] + 0 < a[i] + 0) { t = a[i]; a[i] = a[j]; a[j] = t }
    }
  ' "$TMP/aus.txt"
}

MG=$(med gleich); ME=$(med erstes); ML=$(med letztes); MG2=$(med gleich2)
if [ -z "$MG" ] || [ -z "$ME" ] || [ -z "$ML" ] || [ -z "$MG2" ]; then
  echo "FAIL keine Messpunkte in der Ausgabe"; exit 1
fi
echo "    Mediane je $WDH Aufrufe (us): gleich=$MG erstes=$ME letztes=$ML gleich2=$MG2"

abs() { [ "$1" -lt 0 ] && echo $(( -$1 )) || echo "$1"; }
RAUSCH=$(abs $(( MG - MG2 )))
# Der Rauschboden ist der Unterschied zwischen zwei GLEICHEN Klassen. Darunter
# ist nichts messbar; eine Schwelle, die kleiner waere, wuerde Rauschen als
# Leck melden. Zusaetzlich mindestens 1 % des Medians, damit ein zufaellig
# sehr kleiner Rauschboden die Pruefung nicht unmoeglich scharf macht.
EINPROZENT=$(( MG / 100 )); [ "$EINPROZENT" -lt 1 ] && EINPROZENT=1
SCHWELLE=$(( RAUSCH * 3 ))
[ "$SCHWELLE" -lt "$EINPROZENT" ] && SCHWELLE=$EINPROZENT
echo "    Rauschboden (gleich vs gleich2): $RAUSCH us, Schwelle: $SCHWELLE us"

D1=$(abs $(( MG - ME )))
D2=$(abs $(( ME - ML )))
D3=$(abs $(( MG - ML )))

[ "$D1" -le "$SCHWELLE" ] && ok "Gleichheit vs. Unterschied im ersten Byte: $D1 us <= $SCHWELLE us" \
  || bad "frueher Ausstieg" "Unterschied $D1 us ueber der Schwelle $SCHWELLE us (gleich=$MG erstes=$ME)"
[ "$D2" -le "$SCHWELLE" ] && ok "erstes vs. letztes Byte: $D2 us <= $SCHWELLE us (die STELLE verraet nichts)" \
  || bad "Stelle messbar" "Unterschied $D2 us ueber der Schwelle $SCHWELLE us (erstes=$ME letztes=$ML)"
[ "$D3" -le "$SCHWELLE" ] && ok "Gleichheit vs. Unterschied im letzten Byte: $D3 us <= $SCHWELLE us" \
  || bad "Laufzeit datenabhaengig" "Unterschied $D3 us ueber der Schwelle $SCHWELLE us"

# Gegenprobe auf das MESSMITTEL: ein Lauf, der nichts unterscheiden kann, ist
# kein Nachweis. Die Messung muss ueberhaupt etwas sehen koennen -- darum
# muessen die Mediane ueber dem Rauschen liegen und die Klassen gleich viele
# Proben haben.
ANZ=$(grep -c '^probe ' "$TMP/aus.txt")
[ "$ANZ" = "$PROBEN" ] && ok "alle $PROBEN Proben gemessen" || bad "Proben" "$ANZ von $PROBEN"
[ "$MG" -gt $(( RAUSCH * 10 )) ] && ok "Messfenster traegt (Median $MG us gegen Rauschboden $RAUSCH us)" \
  || bad "Messfenster" "Median $MG us ist nicht deutlich ueber dem Rauschboden $RAUSCH us — WDH erhoehen"

echo "--- $P PASS, $F FAIL"
[ "$F" -eq 0 ] || exit 1
echo "ALL PASS"
