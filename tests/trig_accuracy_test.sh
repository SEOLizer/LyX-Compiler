#!/usr/bin/env bash
# tests/trig_accuracy_test.sh — SinF64/CosF64/TanF64 aus std/math.lyx.
#
# Bis 1.0.12A rechnete die Trigonometrie mit PI = 355/113 und einer
# Taylor-Reihe, die nach x^9 abbrach. Der Fehler war rund 7e-3:
#
#     cos(0)     kam als 1.000003   statt 1.0
#     cos(PI/2)  kam als 0.006925   statt 6.1e-17
#     sin(PI)    kam als 0.006925   statt 1.2e-16
#
# Aufgefallen ist das nicht beim Rechnen von Sinuswerten, sondern an einer
# Drehmatrix: die erhielt keine Laengen mehr. Genau so wird es wieder
# auffallen, wenn es zurueckkommt — deshalb prueft dieser Test die Zahlen
# selbst, an der Stelle, wo sie entstehen.
#
# ZUR AUSSAGEKRAFT
#
# Die Sollwerte kommen von python `math`, nicht von hier hingeschriebenen
# Konstanten — sonst prueft der Test die eigene Erwartung mit.
#
# Gemessen wird ueber ein Gitter, das die Quadrantenreduktion wirklich
# ausreizt: beide Vorzeichen, Werte innerhalb und ausserhalb von [0, 2PI],
# und die Stellen unmittelbar an den Quadrantengrenzen. Ein Reduktionsfehler
# zeigt sich genau dort und nirgends sonst; ein Gitter aus lauter kleinen
# Winkeln haette den alten Fehler ebenfalls durchgelassen.
#
# GRENZE DER MESSUNG: PrintLn gibt sechs Nachkommastellen aus und schneidet
# dabei ab, statt zu runden. Feiner als rund 2e-6 kann dieser Test deshalb
# nicht urteilen. Das genuegt fuer die Frage, die er beantwortet — der alte
# Fehler war dreitausendmal groesser. Wer die letzten Stellen pruefen will,
# braucht einen Bitvergleich wie in tests/f64_literal_test.sh.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 fehlt"; exit 0; }

# Das Gitter. Bewusst als Dezimalzahlen MIT Punkt: ein Ganzzahlliteral im
# f64-Initialisierer ergibt still 0.0 (#1502), und der Test wuerde dann die
# falsche Zahl messen.
PTS="0.0 0.1 0.5 0.7853981633974483 1.0 1.5707963267948966 2.0 2.356194490192345
     3.0 3.141592653589793 4.0 4.71238898038469 6.283185307179586 7.0 10.0
     100.0 1000.0 0.3333333333333333 1.2345678901234567 6.28 1.57 3.14"

# ---------------------------------------------------------------------------
# Sinus und Kosinus ueber das ganze Gitter, beide Vorzeichen
# ---------------------------------------------------------------------------

{
  echo 'import std.math;'
  echo 'fn main(): int64 {'
  i=0
  for x in $PTS; do
    echo "  var p$i: f64 := $x;"
    echo "  var n$i: f64 := 0.0 - p$i;"
    echo "  var sp$i: f64 := SinF64(p$i); PrintLn(sp$i);"
    echo "  var cp$i: f64 := CosF64(p$i); PrintLn(cp$i);"
    echo "  var sn$i: f64 := SinF64(n$i); PrintLn(sn$i);"
    echo "  var cn$i: f64 := CosF64(n$i); PrintLn(cn$i);"
    i=$((i+1))
  done
  echo '  return 0;'
  echo '}'
} > "$TMP/trig.lyx"

if ! "$LYXC" --std-path="$ROOT" "$TMP/trig.lyx" -o "$TMP/trig" >/dev/null 2>&1; then
  no "Sinus/Kosinus uebersetzen" "$("$LYXC" --std-path="$ROOT" "$TMP/trig.lyx" -o "$TMP/trig" 2>&1 | grep -i error | head -1)"
else
  if ! timeout 60 "$TMP/trig" > "$TMP/trig.out" 2>&1; then
    no "Sinus/Kosinus laufen" "Abbruch (rc=$?)"
  else
    res="$(PTS="$PTS" python3 - "$TMP/trig.out" <<'PY'
import math, sys, os
pts = [float(t) for t in os.environ["PTS"].split()]
vals = [float(l) for l in open(sys.argv[1])]
tol = 2e-6
worst, where = 0.0, None
bad = 0
for i, x in enumerate(pts):
    want = [math.sin(x), math.cos(x), math.sin(-x), math.cos(-x)]
    for j, w in enumerate(want):
        g = vals[4*i + j]
        e = abs(g - w)
        if e > worst:
            worst, where = e, (x, ["sin","cos","sin(-x)","cos(-x)"][j], g, w)
        if e > tol:
            bad += 1
print("%d %d %.3e %r %s %.9f %.9f" % (len(pts)*4, bad, worst, where[0], where[1], where[2], where[3]))
PY
)"
    set -- $res
    total=$1; bad=$2; worst=$3
    if [ "$bad" -eq 0 ]; then
      ok "Sinus/Kosinus: $total Werte, groesster Abstand $worst (Grenze 2e-6)"
    else
      no "Sinus/Kosinus" "$bad von $total ueber der Grenze, schlechtester: $(echo $res | cut -d' ' -f4-)"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Die drei Stellen, an denen der alte Fehler sass
# ---------------------------------------------------------------------------
# Sie stehen hier einzeln, damit ein Rueckfall im Testprotokoll benannt wird
# und nicht in einer Gesamtzahl verschwindet.

check_point() { # name, lyx-ausdruck, python-ausdruck
  { echo 'import std.math;'
    echo 'fn main(): int64 {'
    echo "  var v: f64 := $2;"
    echo '  PrintLn(v);'
    echo '  return 0;'
    echo '}'
  } > "$TMP/pt.lyx"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/pt.lyx" -o "$TMP/pt" >/dev/null 2>&1; then
    no "$1" "uebersetzt nicht"; return
  fi
  got="$(timeout 60 "$TMP/pt" 2>&1)"
  want="$(python3 -c "import math; print('%.6f' % ($3))")"
  d="$(python3 -c "print(abs($got - ($want)) <= 2e-6)")"
  if [ "$d" = "True" ]; then ok "$1 ($got)"; else no "$1" "$got, erwartet $want"; fi
}

check_point "cos(0) ist 1, nicht 1.000003"        "CosF64(0.0)"                "math.cos(0)"
check_point "cos(PI/2) ist 0, nicht 0.006925"     "CosF64(1.5707963267948966)" "math.cos(math.pi/2)"
check_point "sin(PI) ist 0, nicht 0.006925"       "SinF64(3.141592653589793)"  "math.sin(math.pi)"

# ---------------------------------------------------------------------------
# Tangens
# ---------------------------------------------------------------------------
# Nicht an den Polen gemessen: dort ist der Wert unendlich, und die Ausgabe
# von PrintLn laeuft ueber. Geprueft wird der Bereich, in dem der Tangens
# eine Zahl ist — inklusive negativer Winkel, wo sin und cos ihre Vorzeichen
# unterschiedlich behandeln.

{
  echo 'import std.math;'
  echo 'fn main(): int64 {'
  i=0
  for x in 0.0 0.5 1.0 1.2 2.0 3.0 0.7853981633974483; do
    echo "  var p$i: f64 := $x;"
    echo "  var t$i: f64 := TanF64(p$i); PrintLn(t$i);"
    echo "  var n$i: f64 := 0.0 - p$i;"
    echo "  var tn$i: f64 := TanF64(n$i); PrintLn(tn$i);"
    i=$((i+1))
  done
  echo '  return 0;'
  echo '}'
} > "$TMP/tan.lyx"

if ! "$LYXC" --std-path="$ROOT" "$TMP/tan.lyx" -o "$TMP/tan" >/dev/null 2>&1; then
  no "Tangens uebersetzen" "$("$LYXC" --std-path="$ROOT" "$TMP/tan.lyx" -o "$TMP/tan" 2>&1 | grep -i error | head -1)"
else
  timeout 60 "$TMP/tan" > "$TMP/tan.out" 2>&1
  res="$(python3 - "$TMP/tan.out" <<'PY'
import math, sys
xs = [0.0, 0.5, 1.0, 1.2, 2.0, 3.0, 0.7853981633974483]
vals = [float(l) for l in open(sys.argv[1])]
tol = 2e-6
worst, bad = 0.0, 0
for i, x in enumerate(xs):
    for j, w in enumerate([math.tan(x), math.tan(-x)]):
        e = abs(vals[2*i + j] - w)
        worst = max(worst, e)
        if e > tol: bad += 1
print("%d %d %.3e" % (len(xs)*2, bad, worst))
PY
)"
  set -- $res
  if [ "$2" -eq 0 ]; then
    ok "Tangens: $1 Werte, groesster Abstand $3 (Grenze 2e-6)"
  else
    no "Tangens" "$2 von $1 ueber der Grenze, groesster Abstand $3"
  fi
fi

# ---------------------------------------------------------------------------
# #1829: grosse Argumente — melden statt raten
# ---------------------------------------------------------------------------
# SinF64(1e16) lieferte 0.909297. Das ist sin(2): die Reduktion hatte bei
# dieser Groesse keine Stellen mehr uebrig, und das Ergebnis gehoerte zu einem
# ANDEREN Winkel — ohne jeden Hinweis.
#
# Die Reduktion ist jetzt dreistufig (Cody-Waite) und traegt bis TrigMaxArg()
# = 2^40; darueber wird NaN geliefert. Geprueft wird beides, denn eine
# Reduktion allein waere hier nicht zu haben: fuer 1e16 braeuchte es
# Payne-Hanek mit vielen Stellen von pi.
grenze() { # name, lyx-ausdruck, erwartung: NAN oder ZAHL
  { echo 'import std.math;'
    echo 'fn main(): int64 {'
    echo "  var v: f64 := $2;"
    echo '  if (v != v) { PrintLn("NAN"c); } else { PrintLn("ZAHL"c); }'
    echo '  return 0;'
    echo '}'
  } > "$TMP/g.lyx"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/g.lyx" -o "$TMP/g" >/dev/null 2>&1; then
    no "$1" "uebersetzt nicht"; return
  fi
  got="$(timeout 60 "$TMP/g" 2>&1)"
  if [ "$got" = "$3" ]; then ok "$1 ($got)"; else no "$1" "$got, erwartet $3"; fi
}

grenze "sin(1e16) meldet statt sin(2) zu liefern"  "SinF64(10000000000000000.0)"  "NAN"
grenze "cos(1e16) meldet ebenso"                   "CosF64(10000000000000000.0)"  "NAN"
grenze "tan(1e16) erbt die Meldung"                "TanF64(10000000000000000.0)"  "NAN"
grenze "sin an der Grenze 2^40 rechnet noch"       "SinF64(1099511627776.0)"      "ZAHL"
grenze "sin knapp darueber meldet"                 "SinF64(1099511627777.0)"      "NAN"
grenze "negative Argumente ebenso"                 "SinF64(0.0 - 10000000000000000.0)" "NAN"

# Der uebliche Bereich darf davon nichts merken.
check_point "#1829: sin(1e9) bleibt genau"  "SinF64(1000000000.0)"  "math.sin(1e9)"
check_point "#1829: sin(1e11) bleibt genau" "SinF64(100000000000.0)" "math.sin(1e11)"

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
