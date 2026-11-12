#!/usr/bin/env bash
# tests/units_test.sh — #1953: std/units.lyx hat endlich Nutzer und Nachweis.
#
# Die Unit trug drei Mangel, und keiner waere aufgefallen: sie wurde von KEINER
# Datei im Repo importiert und von keinem Test angefasst. Eine Bibliothek ohne
# Nutzer ist derselbe Verfall wie ein Test, der an keinem Ziel haengt.
#
#   1. `dim Frequency = Time` war dimensional falsch — eine Frequenz galt als
#      dimensionsgleich mit einer DAUER. Seit #1962 ist der Kehrwert
#      ausdrueckbar, also steht dort jetzt `1 / Time`. Dazu gab es zu dieser
#      Dimension ueberhaupt keine Einheit; Hz/kHz/MHz/GHz sind neu.
#   2. Die Umrechnungsfaktoren waren abgeschnitten: `deg` mit 0.017453 statt
#      pi/180 liegt ueber 360 Grad um rund 0.0012 rad daneben. Wo die exakte
#      Zahl endlich ist (lb, oz), steht sie jetzt exakt da; wo sie es nicht ist
#      (deg, grad, kmh, kts), stehen die 14 Stellen, die der Compiler traegt.
#   3. Celsius und Fahrenheit sind AFFIN und standen als Einheitentypen mit
#      einem blossen Faktor da, mit dem Vermerk "offset handled in code" — den
#      Code gab es nicht. Sie sind jetzt Funktionen.
#
# GEMESSEN WIRD DER WERT gegen die Definition, nicht die Uebersetzbarkeit. Ein
# Test auf "uebersetzt" waere bei jedem der drei Punkte gruen gewesen.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! ( cd "$ROOT" && "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" ) >/dev/null 2>&1; then
    echo "FAIL $1: uebersetzt nicht"; FAIL=$((FAIL+1)); return
  fi
  got="$(timeout 10 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then echo "FAIL $1: ABSTURZ (rc=$rc)"; FAIL=$((FAIL+1)); return; fi
  if [ "$got" = "$3" ]; then echo "PASS $1"; PASS=$((PASS+1))
  else echo "FAIL $1: '$got' erwartet '$3'"; FAIL=$((FAIL+1)); fi
}

rejects() { # name, quelltext, erwartete meldung
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  got=$( cd "$ROOT" && "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1 )
  if ! echo "$got" | grep -q "$3"; then
    echo "FAIL $1: nicht abgewiesen — '$(echo "$got" | grep -iE 'error' | head -1)'"; FAIL=$((FAIL+1)); return
  fi
  if [ -f "$TMP/c" ]; then
    echo "FAIL $1: gemeldet, aber trotzdem uebersetzt"; FAIL=$((FAIL+1)); return
  fi
  echo "PASS $1 (abgewiesen)"; PASS=$((PASS+1))
}

K='import std.io;
import std.units;'

echo "--- std.units: Faktoren gegen ihre Definition (#1953) ---"

# deg: 360 Grad sind 2*pi. Mit dem alten 0.017453 kam 6.283080 heraus — der
# Fehler lag bei rund 0.0012 rad und damit in der vierten Stelle.
out "360 deg sind 2*pi rad" "$K
fn main(): int64 {
    var a: deg := 360;
    var r: rad := a;
    PrintLn(FloatToStr(r as f64, 6));
    return 0;
}" '6.283185'

out "200 grad sind pi rad" "$K
fn main(): int64 {
    var a: grad := 200;
    var r: rad := a;
    PrintLn(FloatToStr(r as f64, 6));
    return 0;
}" '3.141593'

# Die exakt darstellbaren Faktoren MUESSEN exakt sein. 16 Unzen sind genau ein
# Pfund — das ist die Definition der Unze, kein Naeherungswert.
out "16 oz sind genau 1 lb" "$K
fn main(): int64 {
    var m: oz := 16;
    var p: lb := m;
    PrintLn(FloatToStr(p as f64, 6));
    return 0;
}" '1.000000'

out "1 lb sind 0.45359237 kg" "$K
fn main(): int64 {
    var p: lb := 1;
    var k: kg := p;
    PrintLn(FloatToStr(k as f64, 8));
    return 0;
}" '0.45359237'

out "36 km/h sind 10 m/s" "$K
fn main(): int64 {
    var v: kmh := 36;
    var w: mps := v;
    PrintLn(FloatToStr(w as f64, 4));
    return 0;
}" '10.0000'

# Ein Knoten ist eine Seemeile je Stunde: 1852/3600 m/s.
out "1 kts ist 1852/3600 m/s" "$K
fn main(): int64 {
    var v: kts := 3600;
    var w: mps := v;
    PrintLn(FloatToStr(w as f64, 2));
    return 0;
}" '1852.00'

out "1 nmi ist 1852 m" "$K
fn main(): int64 {
    var d: nmi := 1;
    var m2: m := d;
    PrintLn(FloatToStr(m2 as f64, 1));
    return 0;
}" '1852.0'

echo
echo "--- std.units: Frequenz ist der KEHRWERT einer Zeit (#1953 + #1962) ---"

# Bis 1.2.4D stand `dim Frequency = Time` — eine Frequenz war damit
# dimensionsgleich mit einer Dauer.
out "1 durch 4 s sind 0.25 Hz" "$K
fn main(): int64 {
    var t: s := 4;
    var f: Hz := 1 / t;
    PrintLn(FloatToStr(f as f64, 4));
    return 0;
}" '0.2500'

out "1 kHz sind 1000 Hz" "$K
fn main(): int64 {
    var f: kHz := 1;
    var g: Hz := f;
    PrintLn(FloatToStr(g as f64, 1));
    return 0;
}" '1000.0'

# DIE PRUEFUNG, die den alten Zustand entlarvt: eine DAUER ist keine FREQUENZ.
# Mit `dim Frequency = Time` ging diese Zuweisung kommentarlos durch.
rejects "eine Dauer ist keine Frequenz" "$K
fn main(): int64 {
    var t: s := 4;
    var f: Hz := t;
    return f as int64;
}" "Dimensionsgrenzen"

# Und die Gegenrichtung.
rejects "eine Frequenz ist keine Dauer" "$K
fn main(): int64 {
    var f: Hz := 50;
    var t: s := f;
    return t as int64;
}" "Dimensionsgrenzen"

echo
echo "--- std.units: Temperatur ist AFFIN, nicht skalar (#1953) ---"

# C und F standen als Einheitentypen mit blossem Faktor da; `var k: K :=
# celsius` rechnete 20 Grad Celsius in 20 Kelvin um. Jetzt sind es Funktionen,
# und der Versatz ist sichtbar.
out "100 C sind 373.15 K" "$K
fn main(): int64 {
    PrintLn(FloatToStr(CelsiusToKelvin(100.0), 2));
    return 0;
}" '373.15'

out "absoluter Nullpunkt ist -273.15 C" "$K
fn main(): int64 {
    PrintLn(FloatToStr(KelvinToCelsius(0.0), 2));
    return 0;
}" '-273.15'

out "212 F sind 100 C" "$K
fn main(): int64 {
    PrintLn(FloatToStr(FahrenheitToCelsius(212.0), 2));
    return 0;
}" '100.00'

out "-40 ist in beiden Skalen gleich" "$K
fn main(): int64 {
    PrintLn(FloatToStr(CelsiusToFahrenheit(0.0 - 40.0), 2));
    return 0;
}" '-40.00'

out "32 F sind 273.15 K" "$K
fn main(): int64 {
    PrintLn(FloatToStr(FahrenheitToKelvin(32.0), 2));
    return 0;
}" '273.15'

# RUNDLAUF: die Umrechnung muss umkehrbar sein. Ein Vorzeichenfehler im
# Versatz faellt hier auf, ein Einzelwert koennte ihn verdecken.
out "Rundlauf C -> F -> C" "$K
fn main(): int64 {
    PrintLn(FloatToStr(FahrenheitToCelsius(CelsiusToFahrenheit(21.5)), 4));
    return 0;
}" '21.5000'

echo
echo "--- std.units: die Dimensionen halten zusammen (#1962) ---"

out "Strecke durch Zeit ist ein Tempo" "$K
fn main(): int64 {
    var d: m := 100;
    var t: s := 4;
    var v: mps := d / t;
    PrintLn(FloatToStr(v as f64, 1));
    return 0;
}" '25.0'

rejects "Strecke durch Zeit ist keine Strecke" "$K
fn main(): int64 {
    var d: m := 100;
    var t: s := 4;
    var x: m := d / t;
    return x as int64;
}" "Dimensionsgrenzen"

out "Laenge mal Laenge ist eine Flaeche" "$K
fn main(): int64 {
    var a: m := 3;
    var b: m := 4;
    var f: m2 := a * b;
    PrintLn(FloatToStr(f as f64, 1));
    return 0;
}" '12.0'

rejects "Laenge mal Laenge ist keine Laenge" "$K
fn main(): int64 {
    var a: m := 3;
    var b: m := 4;
    var x: m := a * b;
    return x as int64;
}" "Dimensionsgrenzen"

# Kraft mal Weg ist Energie — die Kette Mass * Acceleration * Length haelt
# ueber DREI Deklarationen hinweg zusammen.
out "Kraft mal Weg ist Energie" "$K
fn main(): int64 {
    var f: N := 10;
    var d: m := 3;
    var e: J := f * d;
    PrintLn(FloatToStr(e as f64, 1));
    return 0;
}" '30.0'

out "1 kWh sind 3.6 MJ" "$K
fn main(): int64 {
    var e: kWh := 1;
    var j: MJ := e;
    PrintLn(FloatToStr(j as f64, 1));
    return 0;
}" '3.6'

out "Spannung durch Strom ist ein Widerstand" "$K
fn main(): int64 {
    var u: V := 12;
    var i: A := 3;
    var r: Ohm := u / i;
    PrintLn(FloatToStr(r as f64, 1));
    return 0;
}" '4.0'

rejects "Spannung durch Strom ist keine Spannung" "$K
fn main(): int64 {
    var u: V := 12;
    var i: A := 3;
    var x: V := u / i;
    return x as int64;
}" "Dimensionsgrenzen"

# GEGENPROBE: gleiche Dimension bleibt selbstverstaendlich zuweisbar, und ein
# Literal auch. Ohne sie waere der Test auch von einer Fassung erfuellt, die
# alles abweist.
out "gleiche Dimension bleibt zuweisbar" "$K
fn main(): int64 {
    var a: km := 2;
    var b: m := a;
    PrintLn(FloatToStr(b as f64, 1));
    return 0;
}" '2000.0'

out "ein Literal bleibt zuweisbar" "$K
fn main(): int64 {
    var a: MB := 4;
    var b: KB := a;
    PrintLn(FloatToStr(b as f64, 1));
    return 0;
}" '4096.0'

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
