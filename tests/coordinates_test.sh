#!/usr/bin/env bash
# std/coordinates — Vektoren im Raum und Koordinatensysteme
#
# WIE HIER GEPRUEFT WIRD:
#
#   1. GEGEN VON AUSSEN BEKANNTE WERTE. Das Kreuzprodukt der Einheitsvektoren
#      ist festgelegt (x×y = z), der Winkel zwischen x und y ist 90°, das
#      Spatprodukt der drei Einheitsvektoren ist 1.
#
#   2. RICHTUNG UND VORZEICHEN. a×b = −(b×a) ist die Eigenschaft, die bei
#      vertauschter Reihenfolge ein Drehmoment in die falsche Richtung zeigen
#      laesst — und die an symmetrischen Aufbauten nicht auffaellt.
#
#   3. RUNDLAEUFE. kartesisch → zylindrisch → kartesisch und dasselbe ueber
#      beide Kugelkonventionen. Faengt vertauschte sin/cos, die eine
#      Einzelmessung durchlaesst.
#
#   4. DIE BEIDEN KONVENTIONEN GEGENEINANDER. Polarwinkel und Elevation
#      unterscheiden sich um 90°; derselbe Punkt muss ueber beide Wege
#      dieselben kartesischen Koordinaten ergeben. Waeren sie verwechselt,
#      faende genau diese Querprobe es.
#
#   5. GRENZFAELLE. Der Nullvektor hat KEINE Richtung — Normieren muss den
#      Fehlerwert liefern und nicht den Nullvektor, der wie ein Ergebnis
#      aussaehe.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

lauf() {   # Name, Quelltext, erwartete Ausgabe
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

echo "--- Vektoren ---"

# x×y = z, y×x = −z (nicht kommutativ), x·y = 0, Winkel 90°, Spat = 1
lauf "Kreuzprodukt, Reihenfolge und Spatprodukt" 'import std.io;
import std.math;
import std.coordinates.vec3;
fn main(): int64 {
  var c: V3 := V3Cross(V3UnitX(), V3UnitY());
  var d: V3 := V3Cross(V3UnitY(), V3UnitX());
  PrintStr(FloatToStr(c.z, 1)); PrintStr(" ");
  PrintStr(FloatToStr(d.z, 1)); PrintStr(" ");
  PrintStr(FloatToStr(V3Dot(V3UnitX(), V3UnitY()), 1)); PrintStr(" ");
  PrintStr(FloatToStr(V3Angle(V3UnitX(), V3UnitY()) * 180.0 / Pi(), 2)); PrintStr(" ");
  PrintLn(FloatToStr(V3Triple(V3UnitX(), V3UnitY(), V3UnitZ()), 1));
  return 0;
}' '1.0 -1.0 0.0 90.00 1.0'

# 3-4-5: Norm eines (3,4,0)-Vektors ist 5; normiert hat er die Laenge 1.
lauf "Norm und Normieren" 'import std.io;
import std.coordinates.vec3;
fn main(): int64 {
  var v: V3 := V3New(3.0, 4.0, 0.0);
  PrintStr(FloatToStr(V3Norm(v), 4)); PrintStr(" ");
  PrintLn(FloatToStr(V3Norm(V3Normalize(v)), 4));
  return 0;
}' '5.0000 1.0000'

# Projektion und Rest muessen den Ausgangsvektor wieder ergeben, und der Rest
# muss SENKRECHT auf b stehen (Skalarprodukt null).
lauf "Projektion plus Rest ergibt den Vektor" 'import std.io;
import std.coordinates.vec3;
fn main(): int64 {
  var a: V3 := V3New(3.0, 4.0, 5.0);
  var b: V3 := V3New(1.0, 0.0, 0.0);
  var s: V3 := V3Add(V3Project(a, b), V3Reject(a, b));
  PrintStr(FloatToStr(s.x, 3)); PrintStr(" ");
  PrintStr(FloatToStr(s.y, 3)); PrintStr(" ");
  PrintStr(FloatToStr(s.z, 3)); PrintStr(" ");
  PrintLn(FloatToStr(V3Dot(V3Reject(a, b), b), 3));
  return 0;
}' '3.000 4.000 5.000 0.000'

# GRENZFALL: der Nullvektor hat keine Richtung.
lauf "Normieren des Nullvektors liefert den Fehlerwert" 'import std.io;
import std.coordinates.vec3;
fn main(): int64 {
  var n: int64 := 0;
  if (V3IsError(V3Normalize(V3Zero())))         { n := n + 1; }
  if (V3IsError(V3Project(V3UnitX(), V3Zero()))) { n := n + 1; }
  if (V3IsErrorValue(V3Angle(V3Zero(), V3UnitX()))) { n := n + 1; }
  if (V3IsError(V3Normalize(V3UnitX())))        { n := n + 100; }
  PrintLn(IntToStr(n));
  return 0;
}' '3'

echo "--- Koordinatensysteme ---"

# Rundlauf kartesisch -> zylindrisch -> kartesisch
lauf "Rundlauf ueber Zylinderkoordinaten" 'import std.io;
import std.coordinates.vec3;
import std.coordinates.transform;
fn main(): int64 {
  var v: V3 := V3New(3.0, 4.0, 5.0);
  var w: V3 := CylToCart(CartToCyl(v));
  PrintStr(FloatToStr(w.x, 6)); PrintStr(" ");
  PrintStr(FloatToStr(w.y, 6)); PrintStr(" ");
  PrintLn(FloatToStr(w.z, 6));
  return 0;
}' '3.000000 4.000000 5.000000'

# Rundlauf ueber BEIDE Kugelkonventionen — dieselbe Ausgabe beweist, dass sin
# und cos in keiner der beiden vertauscht sind.
lauf "Rundlauf ueber beide Kugelkonventionen" 'import std.io;
import std.coordinates.vec3;
import std.coordinates.transform;
fn main(): int64 {
  var v: V3 := V3New(3.0, 4.0, 5.0);
  var a: V3 := SphPolarToCart(CartToSphPolar(v));
  var b: V3 := SphElevToCart(CartToSphElev(v));
  PrintStr(FloatToStr(a.x, 6)); PrintStr(" "); PrintStr(FloatToStr(a.z, 6)); PrintStr(" ");
  PrintStr(FloatToStr(b.x, 6)); PrintStr(" "); PrintLn(FloatToStr(b.z, 6));
  return 0;
}' '3.000000 5.000000 3.000000 5.000000'

# QUERPROBE: Polarwinkel und Elevation unterscheiden sich um 90°. Ein Punkt auf
# der z-Achse hat theta = 0 und elev = +90°; einer in der xy-Ebene theta = 90°
# und elev = 0.
lauf "die beiden Konventionen unterscheiden sich um 90 Grad" 'import std.io;
import std.math;
import std.coordinates.vec3;
import std.coordinates.transform;
fn main(): int64 {
  var oben: SphPolar := CartToSphPolar(V3UnitZ());
  var obenE: SphElev := CartToSphElev(V3UnitZ());
  var eben: SphPolar := CartToSphPolar(V3UnitX());
  var ebenE: SphElev := CartToSphElev(V3UnitX());
  PrintStr(FloatToStr(oben.theta * 180.0 / Pi(), 2)); PrintStr(" ");
  PrintStr(FloatToStr(obenE.elev * 180.0 / Pi(), 2)); PrintStr(" ");
  PrintStr(FloatToStr(eben.theta * 180.0 / Pi(), 2)); PrintStr(" ");
  PrintLn(FloatToStr(ebenE.elev * 180.0 / Pi(), 2));
  return 0;
}' '0.00 90.00 90.00 0.00'

# Und die Umrechnung zwischen den Konventionen muss dasselbe liefern wie der
# Weg ueber die kartesischen Koordinaten.
lauf "Umrechnung zwischen den Konventionen" 'import std.io;
import std.coordinates.vec3;
import std.coordinates.transform;
fn main(): int64 {
  var v: V3 := V3New(3.0, 4.0, 5.0);
  var p: SphPolar := CartToSphPolar(v);
  var ueber: V3 := SphElevToCart(SphPolarToElev(p));
  PrintStr(FloatToStr(ueber.x, 6)); PrintStr(" ");
  PrintStr(FloatToStr(ueber.y, 6)); PrintStr(" ");
  PrintLn(FloatToStr(ueber.z, 6));
  return 0;
}' '3.000000 4.000000 5.000000'

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
