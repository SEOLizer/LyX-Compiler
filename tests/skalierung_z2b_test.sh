#!/usr/bin/env bash
# tests/skalierung_z2b_test.sh — #1476, #1477, #1481, #1482, #1483, #1489, #1490.
#
# Sieben Meldungen, ein wiederkehrender Fehler: **zu früh geteilt**. In
# Ganzzahlarithmetik ist `(a / b) * c` nicht `(a * c) / b` — ist a kleiner als
# b, ist der Quotient 0 und das ganze Ergebnis mit ihm.
#
#   #1476 Vec2Project/Vec2Reflect teilten das Skalarprodukt durch 1000000 →
#         Nullvektor bzw. unveränderter Eingabevektor. Bei Project fehlte
#         zusätzlich der Nenner |onto|² ganz.
#   #1490 CircleUnion: `(neuerRadius - a.radius) / dist` wurde 0, der
#         Mittelpunkt blieb liegen, der Ergebniskreis deckte b nicht ab.
#   #1489 CircleArea nahm Festkomma an, CircleCircumference rohe Einheiten —
#         zwei Annahmen über dieselbe Größe; jede Fläche war 0.
#   #1481 CosLatTable war um Faktor 10 verrechnet: cos(90°) = 0,95.
#   #1482 DistanceM ohne Längenkorrektur und mit Oktagon-Näherung: 437 km.
#   #1483 FormatDMS verwarf das Ergebnis; BoundingBox/AddOffsetM multiplizierten
#         mit dem Kosinus statt zu dividieren; Bearing kannte vier Richtungen.
#   #1477 Vec2Rotate/Heading/AngleTo erbten die Winkelfehler aus std.math.
#
# GEPRÜFT WIRD GEGEN NACHRECHENBARE WERTE — Berlin–Hamburg 255 km, cos 60° =
# 0,5, Kreisfläche r=10 = 314. Ein Test gegen den Ist-Zustand hätte die
# Skalierungsfehler festgeschrieben.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    echo "FAIL $1: uebersetzt nicht"; FAIL=$((FAIL+1)); return
  fi
  got="$(timeout 20 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then echo "FAIL $1: ABSTURZ rc=$rc"; FAIL=$((FAIL+1)); return; fi
  if [ "$got" = "$3" ]; then echo "PASS $1"; PASS=$((PASS+1))
  else echo "FAIL $1: '$got' erwartet '$3'"; FAIL=$((FAIL+1)); fi
}

# ===========================================================================
# #1476 — Projektion und Spiegelung
# ===========================================================================

# (3,4) auf die x-Achse projiziert ist (3,0); auf (0,1) projiziert (0,4).
# Eine Projektion auf einen NICHT normierten Vektor zeigt, ob der Nenner
# |onto|² wirklich in die Rechnung eingeht: (4,4) auf (2,0) ist (4,0), nicht (8,0).
out "#1476: Vec2Project rechnet mit Nenner" 'import std.io;
import std.vector;
fn z(v: Vec2): void { PrintStr("("); PrintStr(IntToStr(v.x)); PrintStr(","); PrintStr(IntToStr(v.y)); PrintStr(") "); }
fn main(): int64 {
  z(Vec2Project(Vec2New(3,4), Vec2New(1,0)));
  z(Vec2Project(Vec2New(3,4), Vec2New(0,1)));
  z(Vec2Project(Vec2New(4,4), Vec2New(2,0)));
  z(Vec2Project(Vec2New(3,4), Vec2New(0,0)));
  PrintLn("");
  return 0;
}' "(3,0) (0,4) (4,0) (0,0) "

# Spiegelung an der Waagerechten kehrt y um; an der Senkrechten x.
# Der dritte Fall nutzt wieder eine nicht normierte Normale.
out "#1476: Vec2Reflect kehrt die Komponente um" 'import std.io;
import std.vector;
fn z(v: Vec2): void { PrintStr("("); PrintStr(IntToStr(v.x)); PrintStr(","); PrintStr(IntToStr(v.y)); PrintStr(") "); }
fn main(): int64 {
  z(Vec2Reflect(Vec2New(1,0-1), Vec2New(0,1)));
  z(Vec2Reflect(Vec2New(0-3,5), Vec2New(1,0)));
  z(Vec2Reflect(Vec2New(1,0-1), Vec2New(0,4)));
  PrintLn("");
  return 0;
}' "(1,1) (3,5) (1,1) "

# ===========================================================================
# #1477 — Winkelfunktionen auf Vektoren (behoben mit den std.math-Fixes)
# ===========================================================================

out "#1477: Vec2Rotate dreht richtig" 'import std.io;
import std.vector;
fn z(v: Vec2): void { PrintStr("("); PrintStr(IntToStr(v.x)); PrintStr(","); PrintStr(IntToStr(v.y)); PrintStr(") "); }
fn main(): int64 {
  var v: Vec2 := Vec2New(100, 0);
  z(Vec2Rotate(v, 0));
  z(Vec2Rotate(v, 90000000));
  z(Vec2Rotate(v, 180000000));
  z(Vec2Rotate(v, 270000000));
  PrintLn("");
  return 0;
}' "(100,0) (0,100) (-100,0) (0,-100) "

# Heading und AngleTo in Mikrograd; ein Rest von wenigen Mikrograd ist der
# Festkomma-Naeherung geschuldet und wird hier auf ganze Grad gerundet.
out "#1477: Heading und AngleTo in Grad" 'import std.io;
import std.vector;
fn grad(mikro: int64): int64 { return (mikro + 500000) / 1000000; }
fn main(): int64 {
  PrintStr(IntToStr(grad(Vec2Heading(Vec2New(1,1))))); PrintStr(" ");
  PrintStr(IntToStr(grad(Vec2Heading(Vec2New(0,1))))); PrintStr(" ");
  PrintLn(IntToStr(grad(Vec2AngleTo(Vec2New(1,0), Vec2New(0,1)))));
  return 0;
}' "45 90 90"

# ===========================================================================
# #1481 — Kosinus der Breite
# ===========================================================================

# Die Werte sind nachrechenbar: cos 60° = 0,5 exakt, cos 90° = 0 exakt.
# Vor dem Fix kam für 90° der Wert 950910 heraus — die Korrektur war damit
# praktisch wirkungslos.
out "#1481: Laengenkorrektur folgt dem Kosinus" 'import std.io;
import std.geo;
fn main(): int64 {
  PrintStr(IntToStr(CorrectLongitudeForLatitude(1000000, 0))); PrintStr(" ");
  PrintStr(IntToStr(CorrectLongitudeForLatitude(1000000, 60000000))); PrintStr(" ");
  PrintLn(IntToStr(CorrectLongitudeForLatitude(1000000, 90000000)));
  return 0;
}' "1000000 500000 0"

# 45 Grad muss nahe 0,7071 liegen (Toleranz 1000 = 0,001).
out "#1481: cos 45 Grad" 'import std.io;
import std.geo;
fn main(): int64 {
  var w: int64 := CorrectLongitudeForLatitude(1000000, 45000000);
  var d: int64 := w - 707107;
  if (d < 0) { d := 0 - d; }
  if (d <= 1000) { PrintLn("nah"); } else { PrintLn(IntToStr(w)); }
  return 0;
}' "nah"

# ===========================================================================
# #1482 — Entfernung
# ===========================================================================

# Berlin–Hamburg sind rund 255 km Luftlinie. Toleranz 3 km deckt die
# Festkomma-Naeherung ab, nicht aber die alten 437 km.
out "#1482: Berlin-Hamburg liegt bei 255 km" 'import std.io;
import std.geo;
fn pruef(m: int64, soll: int64, tol: int64): void {
  var d: int64 := m - soll;
  if (d < 0) { d := 0 - d; }
  if (d <= tol) { PrintStr("ok "); } else { PrintStr(IntToStr(m)); PrintStr(" "); }
}
fn main(): int64 {
  var berlin:  GeoPoint := GeoPointNew(13404954, 52520008);
  var hamburg: GeoPoint := GeoPointNew(9993682, 53551086);
  pruef(DistanceM(berlin, hamburg), 255000, 3000);
  pruef(DistanceMCorrected(berlin, hamburg), 255000, 3000);
  pruef(DistanceMLegacy(52520008, 13404954, 53551086, 9993682), 255000, 3000);
  PrintLn("");
  return 0;
}' "ok ok ok "

# Reine Nord-Sued-Strecke: ein Breitengrad sind 111,3 km, unabhaengig von der
# Laenge. Hier war die alte Rechnung richtig und muss es bleiben.
out "#1482: ein Breitengrad bleibt 111 km" 'import std.io;
import std.geo;
fn main(): int64 {
  var a: GeoPoint := GeoPointNew(13000000, 52000000);
  var b: GeoPoint := GeoPointNew(13000000, 53000000);
  var m: int64 := DistanceM(a, b);
  var d: int64 := m - 111319;
  if (d < 0) { d := 0 - d; }
  if (d <= 500) { PrintLn("ok"); } else { PrintLn(IntToStr(m)); }
  return 0;
}' "ok"

# Und die Gegenprobe zur Kosinus-Korrektur: ein Laengengrad ist bei 60 Grad
# Nord halb so breit wie am Aequator. Ohne Korrektur waeren beide gleich.
out "#1482: ein Laengengrad schrumpft polwaerts" 'import std.io;
import std.geo;
fn main(): int64 {
  var aeq: int64 := DistanceM(GeoPointNew(0, 0), GeoPointNew(1000000, 0));
  var n60: int64 := DistanceM(GeoPointNew(0, 60000000), GeoPointNew(1000000, 60000000));
  var haelfte: int64 := aeq / 2;
  var d: int64 := n60 - haelfte;
  if (d < 0) { d := 0 - d; }
  if (d <= 1000) { PrintLn("ok"); } else { PrintStr(IntToStr(aeq)); PrintStr(" "); PrintLn(IntToStr(n60)); }
  return 0;
}' "ok"

# ===========================================================================
# #1483 — Formatierung, BoundingBox, Offset, Bearing
# ===========================================================================

# Die Erwartung enthaelt Hochkomma UND Anfuehrungszeichen (Minuten- und
# Sekundenzeichen) — sie wird deshalb mit printf gebaut statt inline zitiert.
DMS_ERW="$(printf '52\xc2\xb0 31\x27 12\x22 N\n13\xc2\xb0 24\x27 17\x22 E\n52\xc2\xb0 31\x27 12\x22 S\n13\xc2\xb0 24\x27 17\x22 W\n120\xc2\xb0 30\x27 00\x22 E')"
out "#1483: FormatDMS gibt die Rechnung aus" 'import std.io;
import std.geo;
fn main(): int64 {
  PrintLn(FormatDMS(52520000, true));
  PrintLn(FormatDMS(13404954, false));
  PrintLn(FormatDMS(0 - 52520000, true));
  PrintLn(FormatDMS(0 - 13404954, false));
  PrintLn(FormatDMS(120500000, false));
  return 0;
}' "$DMS_ERW"

# Die BoundingBox um 10 km bei Berlin: Breitenspanne 0,1796 Grad,
# Laengenspanne rund 0,2918 Grad (= Breitenspanne / cos 52,5). Vorher reichte
# sie von -74,9 bis +101,8 Grad.
out "#1483: BoundingBox bleibt im Umkreis" 'import std.io;
import std.geo;
fn main(): int64 {
  var b: GeoPoint := GeoPointNew(13404954, 52520008);
  var mn: GeoPoint := CalculateBoundingBoxMin(b, 10000);
  var mx: GeoPoint := CalculateBoundingBoxMax(b, 10000);
  var latSpanne: int64 := mx.y - mn.y;
  var lonSpanne: int64 := mx.x - mn.x;
  if (latSpanne > 175000 && latSpanne < 185000) { PrintStr("lat-ok "); } else { PrintStr(IntToStr(latSpanne)); PrintStr(" "); }
  if (lonSpanne > 280000 && lonSpanne < 300000) { PrintStr("lon-ok"); } else { PrintStr(IntToStr(lonSpanne)); }
  PrintLn("");
  return 0;
}' "lat-ok lon-ok"

# AddOffsetM: 10 km nach Norden darf die Laenge NICHT anfassen — genau das war
# der auffaelligste Schaden (lon = -88334714706).
out "#1483: AddOffsetM nach Norden laesst die Laenge stehen" 'import std.io;
import std.geo;
fn main(): int64 {
  var b: GeoPoint := GeoPointNew(13404954, 52520008);
  var n: GeoPoint := AddOffsetM(b, 0, 10000);
  if (n.x == b.x) { PrintStr("lon-gleich "); } else { PrintStr(IntToStr(n.x)); PrintStr(" "); }
  var dLat: int64 := n.y - b.y;
  if (dLat > 88000 && dLat < 92000) { PrintStr("lat-ok"); } else { PrintStr(IntToStr(dLat)); }
  PrintLn("");
  return 0;
}' "lon-gleich lat-ok"

# Rundlauf: 10 km in eine Richtung versetzen und die Entfernung nachmessen.
# Das prueft Offset und Distanz gemeinsam — und wuerde jede der beiden
# Skalierungen einzeln auffliegen lassen.
out "#1483: Rundlauf Offset gegen Distanz" 'import std.io;
import std.geo;
fn pruef(m: int64): void {
  var d: int64 := m - 10000;
  if (d < 0) { d := 0 - d; }
  if (d <= 100) { PrintStr("ok "); } else { PrintStr(IntToStr(m)); PrintStr(" "); }
}
fn main(): int64 {
  var b: GeoPoint := GeoPointNew(13404954, 52520008);
  pruef(DistanceM(b, AddOffsetM(b, 0, 10000)));
  pruef(DistanceM(b, AddOffsetM(b, 90000000, 10000)));
  pruef(DistanceM(b, AddOffsetM(b, 180000000, 10000)));
  pruef(DistanceM(b, AddOffsetM(b, 270000000, 10000)));
  pruef(DistanceM(b, AddOffsetM(b, 45000000, 10000)));
  PrintLn("");
  return 0;
}' "ok ok ok ok ok "

# Bearing: die vier Achsen waren als Sonderfaelle richtig, Nordost lieferte 0.
out "#1483: Bearing kennt auch die Zwischenrichtungen" 'import std.io;
import std.geo;
fn grad(mikro: int64): int64 { return (mikro + 500000) / 1000000; }
fn main(): int64 {
  var b: GeoPoint := GeoPointNew(13404954, 52520008);
  PrintStr(IntToStr(grad(Bearing(b, AddOffsetM(b, 0, 10000))))); PrintStr(" ");
  PrintStr(IntToStr(grad(Bearing(b, AddOffsetM(b, 45000000, 10000))))); PrintStr(" ");
  PrintStr(IntToStr(grad(Bearing(b, AddOffsetM(b, 90000000, 10000))))); PrintStr(" ");
  PrintStr(IntToStr(grad(Bearing(b, AddOffsetM(b, 135000000, 10000))))); PrintStr(" ");
  PrintStr(IntToStr(grad(Bearing(b, AddOffsetM(b, 180000000, 10000))))); PrintStr(" ");
  PrintLn(IntToStr(grad(Bearing(b, AddOffsetM(b, 270000000, 10000)))));
  return 0;
}' "0 45 90 135 180 270"

# ===========================================================================
# #1489 — Kreisfläche
# ===========================================================================

# Fläche und Umfang müssen von derselben Einheit ausgehen: r=10 → 314 und 62,
# r=50 → 7853 und 314. Vorher war jede Fläche 0.
out "#1489: Flaeche und Umfang in derselben Einheit" 'import std.io;
import std.circle;
fn main(): int64 {
  PrintStr(IntToStr(CircleArea(CircleFromXYR(0,0,10)))); PrintStr(" ");
  PrintStr(IntToStr(CircleCircumference(CircleFromXYR(0,0,10)))); PrintStr(" ");
  PrintStr(IntToStr(CircleArea(CircleFromXYR(0,0,50)))); PrintStr(" ");
  PrintStr(IntToStr(CircleCircumference(CircleFromXYR(0,0,50)))); PrintStr(" ");
  PrintLn(IntToStr(CircleArea(CircleFromXYR(0,0,2))));
  return 0;
}' "314 62 7853 314 12"

# Der Zusammenhang selbst: Flaeche = Umfang * r / 2. Das gilt unabhaengig von
# der gewaehlten Einheit und faellt auseinander, sobald eine der beiden
# Funktionen ihre Skalierung wechselt.
out "#1489: Flaeche = Umfang * r / 2" 'import std.io;
import std.circle;
fn pruef(r: int64): void {
  var a: int64 := CircleArea(CircleFromXYR(0,0,r));
  var soll: int64 := CircleCircumference(CircleFromXYR(0,0,r)) * r / 2;
  var d: int64 := a - soll;
  if (d < 0) { d := 0 - d; }
  if (d <= r) { PrintStr("ok "); } else { PrintStr(IntToStr(a)); PrintStr("/"); PrintStr(IntToStr(soll)); PrintStr(" "); }
}
fn main(): int64 { pruef(10); pruef(50); pruef(1000); PrintLn(""); return 0; }' "ok ok ok "

# ===========================================================================
# #1490 — Vereinigungskreis
# ===========================================================================

out "#1490: CircleUnion verschiebt den Mittelpunkt" 'import std.io;
import std.circle;
fn z(u: Circle): void {
  PrintStr("("); PrintStr(IntToStr(u.center.x)); PrintStr(","); PrintStr(IntToStr(u.center.y));
  PrintStr(") r="); PrintStr(IntToStr(u.radius)); PrintStr(" ");
}
fn main(): int64 {
  z(CircleUnion(CircleFromXYR(0,0,100), CircleFromXYR(300,0,100)));
  z(CircleUnion(CircleFromXYR(0,0,100), CircleFromXYR(0,400,50)));
  PrintLn("");
  return 0;
}' "(150,0) r=250 (0,175) r=275 "

# Die eigentliche Zusage: der Ergebniskreis deckt BEIDE Ausgangskreise ab.
out "#1490: Ergebniskreis deckt beide ab" 'import std.io;
import std.circle;
fn pruef(a: Circle, b: Circle): void {
  var u: Circle := CircleUnion(a, b);
  if (CircleContainsCircle(u, a) && CircleContainsCircle(u, b)) { PrintStr("ok "); }
  else { PrintStr("LUECKE "); }
}
fn main(): int64 {
  pruef(CircleFromXYR(0,0,100), CircleFromXYR(300,0,100));
  pruef(CircleFromXYR(0,0,100), CircleFromXYR(0,400,50));
  pruef(CircleFromXYR(0-200,0-200,50), CircleFromXYR(200,200,150));
  PrintLn("");
  return 0;
}' "ok ok ok "

# Gegenproben: enthaelt ein Kreis den anderen, wird der groessere unveraendert
# zurueckgegeben; bei gleichem Mittelpunkt bleibt er liegen.
out "#1490: Sonderfaelle unveraendert" 'import std.io;
import std.circle;
fn z(u: Circle): void {
  PrintStr("("); PrintStr(IntToStr(u.center.x)); PrintStr(","); PrintStr(IntToStr(u.center.y));
  PrintStr(") r="); PrintStr(IntToStr(u.radius)); PrintStr(" ");
}
fn main(): int64 {
  z(CircleUnion(CircleFromXYR(0,0,500), CircleFromXYR(10,0,50)));
  z(CircleUnion(CircleFromXYR(10,0,50), CircleFromXYR(0,0,500)));
  z(CircleUnion(CircleFromXYR(5,5,100), CircleFromXYR(5,5,200)));
  PrintLn("");
  return 0;
}' "(0,0) r=500 (0,0) r=500 (5,5) r=200 "

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
