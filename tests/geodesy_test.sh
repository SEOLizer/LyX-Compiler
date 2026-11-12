#!/usr/bin/env bash
# std/geodesy — WGS84-Ellipsoid, ECEF, ENU und NED
#
# WIE HIER GEPRUEFT WIRD:
#
#   1. GEGEN VEROEFFENTLICHTE WERTE. 45° N / 45° O auf dem Ellipsoid ergibt
#      ECEF (3194419,145 | 3194419,145 | 4487348,409). Diese Zahlen stehen in
#      der Literatur und kommen NICHT aus der Unit — sonst prueft sich die
#      Rechnung nur selbst. Dazu die beiden Halbachsen: am Aequator muss x
#      genau a sein, am Pol z genau b.
#
#   2. RUNDLAEUFE. geodaetisch → ECEF → geodaetisch, und ENU → ECEF → ENU.
#      Die Rueckrechnung ist ITERATIV; ein zu frueh abgebrochenes Verfahren
#      faellt genau hier auf.
#
#   3. DAS VORZEICHEN DER DRITTEN ACHSE. Ein Punkt senkrecht ueber dem
#      Ursprung hat in ENU +1000 und in NED −1000. Wer die beiden Systeme
#      verwechselt, fliegt in der Rechnung nach unten — und ein Test, der nur
#      den Betrag prueft, bemerkt es nicht.
#
#   4. DIE BEIDEN KRUEMMUNGSRADIEN SIND VERSCHIEDEN. Am Aequator ist M kleiner
#      als N, am Pol sind beide gleich. Wer fuer eine Nord-Sued-Strecke N
#      nimmt, liegt am Aequator um 0,7 % daneben — die Pruefung misst beides
#      und ihre Ordnung.
#
#   5. DAS ELLIPSOID IST NICHT DIE KUGEL. Ein Laengengrad ist am Aequator rund
#      111,3 km lang, bei 60° Breite nur noch halb so lang. Und ein Breitengrad
#      ist am Pol LAENGER als am Aequator — das Gegenteil der Erwartung, und
#      genau der Unterschied, den die Kugelnaeherung verschluckt.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

lauf() {
    local name="$1" src="$2" soll="$3"
    printf '%s' "$src" > "$TMP/p.lyx"
    if ! ( cd "$ROOT" && timeout 120 "$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p" ) >"$TMP/b.log" 2>&1; then
        nok "$name: uebersetzt nicht"; grep -v Copyright "$TMP/b.log" | sed -n '1,4p'; return
    fi
    local ist
    ist="$( ulimit -v 4000000; timeout 60 "$TMP/p" 2>&1 )"
    if [ "$ist" = "$soll" ]; then ok "$name"
    else nok "$name: erwartet '$soll', bekommen '$ist'"; fi
}

echo "--- Ellipsoid ---"

# WGS84: a = 6378137, b = 6356752,3142, 1/f = 298,257223563
lauf "WGS84-Halbachsen und Abplattung" 'import std.io;
import std.geodesy.ellipsoid;
fn main(): int64 {
  var e: Ellipsoid := EllWgs84();
  PrintStr(FloatToStr(e.a, 1)); PrintStr(" ");
  PrintStr(FloatToStr(EllB(e), 4)); PrintStr(" ");
  PrintLn(FloatToStr(1.0 / e.f, 9));
  return 0;
}' '6378137.0 6356752.3142 298.257223563'

# M < N am Aequator, beide gleich am Pol. Am Aequator: M = 6335439,3 ;
# N = 6378137,0 (dort ist N genau a).
lauf "Kruemmungsradien: M kleiner N am Aequator, gleich am Pol" 'import std.io;
import std.math;
import std.geodesy.ellipsoid;
fn main(): int64 {
  var e: Ellipsoid := EllWgs84();
  PrintStr(FloatToStr(EllM(e, 0.0), 1)); PrintStr(" ");
  PrintStr(FloatToStr(EllN(e, 0.0), 1)); PrintStr(" ");
  var p: f64 := Pi() / 2.0;
  var gleich: int64 := 0;
  var d: f64 := EllM(e, p) - EllN(e, p);
  if (d < 0.0) { d := 0.0 - d; }
  if (d < 0.001) { gleich := 1; }
  PrintLn(IntToStr(gleich));
  return 0;
}' '6335439.3 6378137.0 1'

# Ein Laengengrad: am Aequator 111319,5 m, bei 60° nur noch 55800,0 m.
# Ein Breitengrad wird zum Pol hin LAENGER: 110574,3 -> 111694,0 m.
lauf "Grad-Laengen aendern sich mit der Breite" 'import std.io;
import std.math;
import std.geodesy.ellipsoid;
fn main(): int64 {
  var e: Ellipsoid := EllWgs84();
  var g60: f64 := 60.0 * Pi() / 180.0;
  PrintStr(FloatToStr(EllLonDegreeM(e, 0.0), 1)); PrintStr(" ");
  PrintStr(FloatToStr(EllLonDegreeM(e, g60), 1)); PrintStr(" ");
  PrintStr(FloatToStr(EllLatDegreeM(e, 0.0), 1)); PrintStr(" ");
  PrintLn(FloatToStr(EllLatDegreeM(e, Pi() / 2.0), 1));
  return 0;
}' '111319.5 55800.0 110574.3 111694.0'

echo "--- ECEF ---"

# Gegen Literaturwerte, und die Halbachsen als Randfaelle.
lauf "ECEF gegen veroeffentlichte Werte" 'import std.io;
import std.coordinates.vec3;
import std.geodesy.ellipsoid;
import std.geodesy.frames;
fn main(): int64 {
  var e: Ellipsoid := EllWgs84();
  var p: V3 := GeodToEcef(e, GeodFromDeg(45.0, 45.0, 0.0));
  PrintStr(FloatToStr(p.x, 3)); PrintStr(" ");
  PrintStr(FloatToStr(p.y, 3)); PrintStr(" ");
  PrintStr(FloatToStr(p.z, 3)); PrintStr(" ");
  PrintStr(FloatToStr(GeodToEcef(e, GeodFromDeg(0.0, 0.0, 0.0)).x, 1)); PrintStr(" ");
  PrintLn(FloatToStr(GeodToEcef(e, GeodFromDeg(90.0, 0.0, 0.0)).z, 4));
  return 0;
}' '3194419.145 3194419.145 4487348.409 6378137.0 6356752.3142'

# Rundlauf mit Hoehe — die Rueckrechnung ist iterativ.
lauf "Rundlauf geodaetisch - ECEF - geodaetisch" 'import std.io;
import std.coordinates.vec3;
import std.geodesy.ellipsoid;
import std.geodesy.frames;
fn main(): int64 {
  var e: Ellipsoid := EllWgs84();
  var g: Geodetic := GeodFromDeg(52.5163, 13.3777, 34.0);
  var z: Geodetic := EcefToGeod(e, GeodToEcef(e, g));
  PrintStr(FloatToStr(GeodLatDeg(z), 7)); PrintStr(" ");
  PrintStr(FloatToStr(GeodLonDeg(z), 7)); PrintStr(" ");
  PrintLn(FloatToStr(z.hEll, 4));
  return 0;
}' '52.5163000 13.3777000 34.0000'

echo "--- Lokale Systeme ---"

# DAS VORZEICHEN: senkrecht ueber dem Ursprung ist ENU +1000, NED -1000.
lauf "ENU und NED unterscheiden sich im Vorzeichen der dritten Achse" 'import std.io;
import std.coordinates.vec3;
import std.geodesy.ellipsoid;
import std.geodesy.frames;
fn main(): int64 {
  var e: Ellipsoid := EllWgs84();
  var o: Geodetic := GeodFromDeg(52.0, 13.0, 0.0);
  var oben: V3 := GeodToEcef(e, GeodFromDeg(52.0, 13.0, 1000.0));
  PrintStr(FloatToStr(EcefToEnu(e, o, oben).z, 3)); PrintStr(" ");
  PrintLn(FloatToStr(EcefToNed(e, o, oben).z, 3));
  return 0;
}' '1000.000 -1000.000'

# Rundlauf durch das lokale System, und die Umrechnung ENU<->NED.
lauf "Rundlauf ENU - ECEF - ENU und ENU zu NED" 'import std.io;
import std.coordinates.vec3;
import std.geodesy.ellipsoid;
import std.geodesy.frames;
fn main(): int64 {
  var e: Ellipsoid := EllWgs84();
  var o: Geodetic := GeodFromDeg(52.0, 13.0, 0.0);
  var v: V3 := V3New(100.0, 200.0, 300.0);
  var z: V3 := EcefToEnu(e, o, EnuToEcef(e, o, v));
  PrintStr(FloatToStr(z.x, 5)); PrintStr(" ");
  PrintStr(FloatToStr(z.y, 5)); PrintStr(" ");
  PrintStr(FloatToStr(z.z, 5)); PrintStr(" ");
  var n: V3 := EnuToNed(v);
  PrintStr(FloatToStr(n.x, 1)); PrintStr(" ");
  PrintStr(FloatToStr(n.y, 1)); PrintStr(" ");
  PrintLn(FloatToStr(n.z, 1));
  return 0;
}' '100.00000 200.00000 300.00000 200.0 100.0 -300.0'

# Sichtlinie: ein Punkt genau OESTLICH liegt bei Azimut ~90°, die Elevation
# eines Punktes senkrecht darueber ist 90°.
lauf "Azimut und Elevation" 'import std.io;
import std.math;
import std.coordinates.vec3;
import std.geodesy.ellipsoid;
import std.geodesy.frames;
fn main(): int64 {
  var e: Ellipsoid := EllWgs84();
  var o: Geodetic := GeodFromDeg(52.0, 13.0, 0.0);
  var oben: V3 := EcefToEnu(e, o, GeodToEcef(e, GeodFromDeg(52.0, 13.0, 500.0)));
  PrintStr(FloatToStr(EnuElevation(oben) * 180.0 / Pi(), 2)); PrintStr(" ");
  PrintLn(FloatToStr(EnuSlantRange(oben), 2));
  return 0;
}' '90.00 500.00'

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
