#!/usr/bin/env bash
# tests/units_atif_energy_test.sh — #1158, #1159 und #1162.
#
# #1159: `@if (NAME)` mit einem Namen, den es nicht gibt, waehlte kommentarlos
# den @else-Zweig. Genau so blieb die Umbenennung TARGET_X86_64 ->
# TARGET_IS_X86_64 unbemerkt: der Schnappschusstest fragte weiter den alten
# Namen ab und druckte klaglos `other`.
#
# #1162: `@energy(N)` vor einer Funktion wurde vom CLI-Flag --target-energy
# ueberstimmt, obwohl Quelltext und Doku das Gegenteil zusagen; und die Vorgabe
# ohne Angabe war Level 1 statt der zugesagten 3.
#
# #1158: `pub` an `dim`/`utype` landete nur in iVal, nicht im ISPUB-Slot, den
# die Export-Pruefung liest — std/units.lyx war damit von aussen unerreichbar.
# Dazu der Faktor: gelesen wurde nur ein GANZZAHLIGES Literal, `1000.0` fiel
# still auf 1 zurueck. std/units.lyx schreibt seine Faktoren durchgehend als
# Float, die Umrechnung war dort also wirkungslos.
#
# Gemessen wird die Meldung bzw. die Ausfuehrung. Ein Test, der nur schaut, ob
# etwas uebersetzt, waere bei allen dreien vorher gruen gewesen.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

# Der Compiler-Aufruf bekommt eine Grenze: ein Endlosfall soll den Test rot
# machen, nicht die Maschine (#1294).
lyxc_run() { ( ulimit -v $(( 4 * 1024 * 1024 )); timeout 60 "$LYXC" "$@" ); }

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! lyxc_run --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    echo "FAIL $1: uebersetzt nicht"; FAIL=$((FAIL+1)); return
  fi
  got="$(timeout 10 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then echo "FAIL $1: ABSTURZ (rc=$rc)"; FAIL=$((FAIL+1)); return; fi
  if [ "$got" = "$3" ]; then echo "PASS $1"; PASS=$((PASS+1))
  else echo "FAIL $1: '$got' erwartet '$3'"; FAIL=$((FAIL+1)); fi
}

rejects() { # name, quelltext, erwartete meldung
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  got=$(lyxc_run --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)
  if echo "$got" | grep -q "$3"; then echo "PASS $1 (abgewiesen)"; PASS=$((PASS+1))
  else echo "FAIL $1: nicht abgewiesen — '$(echo "$got" | tail -1)'"; FAIL=$((FAIL+1)); fi
}

KOPF='import src.std.io;'

# ===========================================================================
# #1159 — @if meldet einen Namen, den es nicht gibt
# ===========================================================================

rejects "@if mit unbekanntem Bezeichner" "
fn main(): int64 {
  var x: int64 := 0;
  @if (VOELLIG_UNBEKANNT) { x := 1; } @else { x := 2; }
  return x;
}" "unbekannter Bezeichner"

rejects "@if auf einer Variablen statt einem con" "
fn main(): int64 {
  var lauf: int64 := 1;
  @if (lauf) { return 1; } @else { return 2; }
}" "@if: kein con"

# Gegenprobe: die echten Flags muessen weiter durchgehen — eine Pruefung, die
# ALLES abweist, waere ebenso gruen.
out "@if mit den gesetzten Target-Flags" "$KOPF
fn main(): int64 {
  @if (TARGET_IS_X86_64) { PrintLn(\"x86_64\"); } @else { PrintLn(\"other\"); }
  @if (TARGET_LINUX) { PrintLn(\"linux\"); } @else { PrintLn(\"anders\"); }
  return 0;
}" "x86_64
linux"

out "@if mit einem selbst erklaerten con" "$KOPF
con EIGEN: int64 := 1;
fn main(): int64 {
  @if (EIGEN) { PrintLn(\"an\"); } @else { PrintLn(\"aus\"); }
  return 0;
}" "an"

# ===========================================================================
# #1162 — @energy schlaegt das CLI-Flag, Vorgabe ist 3
# ===========================================================================
# Gemessen wird am erzeugten Code, nicht an einer Ausgabe: der Level aendert
# die Abrollung, nicht das Ergebnis. Ein Ergebnistest waere hier blind.

cat > "$TMP/en_attr.lyx" <<'LYXEOF'
@energy(1)
fn Rechne(): int64 {
    var s: int64 := 0;
    for i := 0; i < 8; i++ { s := s + i * 3 - 1; }
    return s;
}
fn main(): int64 { return Rechne(); }
LYXEOF
sed '1d' "$TMP/en_attr.lyx" > "$TMP/en_plain.lyx"

en_build() { # datei, flags, ziel
  lyxc_run "$TMP/$1.lyx" $2 --std-path="$ROOT" -o "$TMP/$3" >/dev/null 2>&1
}
en_build en_attr  ""                   a_kein_flag
en_build en_attr  "--target-energy=5"  a_flag5
en_build en_plain "--target-energy=5"  p_flag5
en_build en_plain ""                   p_kein_flag
en_build en_plain "--target-energy=1"  p_flag1
en_build en_plain "--target-energy=3"  p_flag3

cmp_test() { # name, datei_a, datei_b, "gleich"|"verschieden"
  if [ ! -f "$TMP/$2" ] || [ ! -f "$TMP/$3" ]; then
    echo "FAIL $1: uebersetzt nicht"; FAIL=$((FAIL+1)); return
  fi
  if cmp -s "$TMP/$2" "$TMP/$3"; then ist="gleich"; else ist="verschieden"; fi
  if [ "$ist" = "$4" ]; then echo "PASS $1"; PASS=$((PASS+1))
  else echo "FAIL $1: $ist, erwartet $4"; FAIL=$((FAIL+1)); fi
}

# Das Attribut gewinnt: mit und ohne Flag entsteht derselbe Code.
cmp_test "@energy(1) bleibt unter --target-energy=5" a_kein_flag a_flag5 gleich
# ... und es ist nicht einfach dasselbe wie ohne Attribut.
cmp_test "@energy(1) unterscheidet sich von Flag 5 allein" a_flag5 p_flag5 verschieden
# Die Vorgabe ist Level 3.
cmp_test "Vorgabe entspricht Level 3" p_kein_flag p_flag3 gleich
cmp_test "Vorgabe ist nicht Level 1"  p_kein_flag p_flag1 verschieden
# Gegenprobe: das Flag wirkt weiterhin, wo kein Attribut steht.
cmp_test "--target-energy wirkt ohne Attribut" p_flag1 p_flag5 verschieden

# ===========================================================================
# #1158 — pub an dim/utype, und der Faktor als Bruch
# ===========================================================================

mkdir -p "$TMP/mit/mymod" "$TMP/ohne/mymod"
cat > "$TMP/mit/mymod/messung.lyx" <<'LYXEOF'
unit mymod.messung;
pub dim Laenge;
pub utype Meter: Laenge = 1.0;
LYXEOF
sed 's/^pub utype/utype/' "$TMP/mit/mymod/messung.lyx" > "$TMP/ohne/mymod/messung.lyx"
cat > "$TMP/mit/nutz.lyx" <<'LYXEOF'
import mymod.messung;
fn main(): int64 { var m: Meter := 5; return m as int64; }
LYXEOF
cp "$TMP/mit/nutz.lyx" "$TMP/ohne/nutz.lyx"

# pub utype ist ein Angebot an den Aufrufer.
if ( cd "$TMP/mit" && lyxc_run nutz.lyx -I . --std-path="$ROOT" -o nutz >/dev/null 2>&1 ); then
  "$TMP/mit/nutz"; rc=$?
  if [ "$rc" -eq 5 ]; then echo "PASS pub utype ist ueber die Unit-Grenze nutzbar"; PASS=$((PASS+1))
  else echo "FAIL pub utype: rc=$rc erwartet 5"; FAIL=$((FAIL+1)); fi
else
  echo "FAIL pub utype ist ueber die Unit-Grenze nutzbar: uebersetzt nicht"; FAIL=$((FAIL+1))
fi

# Gegenprobe: OHNE pub bleibt es unit-intern — sonst haette die Aenderung die
# Sichtbarkeitspruefung schlicht abgeschaltet.
got=$( cd "$TMP/ohne" && lyxc_run nutz.lyx -I . --std-path="$ROOT" -o nutz 2>&1 )
if echo "$got" | grep -q "nicht pub"; then
  echo "PASS ohne pub bleibt utype unit-intern (abgewiesen)"; PASS=$((PASS+1))
else
  echo "FAIL ohne pub: nicht abgewiesen"; FAIL=$((FAIL+1))
fi

# Der Faktor als Float — die Schreibweise, die std/units.lyx benutzt.
out "Float-Faktor rechnet um" "$KOPF
dim Laenge;
utype Meter:     Laenge = 1.0;
utype Kilometer: Laenge = 1000.0;
fn main(): int64 {
    var k: Kilometer := 2;
    var m: Meter := k;
    PrintLn(IntToStr(m as int64));
    return 0;
}" "2000"

# Ganzzahliger Faktor bleibt, wie er war.
out "Ganzzahl-Faktor rechnet weiterhin um" "$KOPF
dim Laenge;
utype Meter:     Laenge = 1;
utype Kilometer: Laenge = 1000;
fn main(): int64 {
    var k: Kilometer := 2;
    var m: Meter := k;
    PrintLn(IntToStr(m as int64));
    return 0;
}" "2000"

# Ein Faktor unter 1 braucht den Bruch: 180 * 0.017453 = 3.14 -> 3.
out "gebrochener Faktor unter 1" "$KOPF
dim Winkel;
utype Grad:    Winkel = 0.017453;
utype Bogen:   Winkel = 1.0;
fn main(): int64 {
    var w: Grad := 180;
    var b: Bogen := w;
    PrintLn(IntToStr(b as int64));
    return 0;
}" "3"

# Die andere Richtung schneidet ab, wie die Ganzzahldivision sonst auch.
out "Umrechnung nach oben schneidet ab" "$KOPF
dim Laenge;
utype Meter:     Laenge = 1.0;
utype Kilometer: Laenge = 1000.0;
fn main(): int64 {
    var m: Meter := 2500;
    var k: Kilometer := m;
    PrintLn(IntToStr(k as int64));
    return 0;
}" "2"

# std/units.lyx selbst — der Grund, aus dem #1158 aufgemacht wurde.
out "std.units ist importierbar und rechnet um" "$KOPF
import std.units;
fn main(): int64 {
    var d: km := 2;
    var e: m := d;
    PrintLn(IntToStr(e as int64));
    return 0;
}" "2000"

# Gegenproben zu #1110: Dimensionspruefung und Grenzen bleiben in Kraft.
rejects "Zuweisung ueber Dimensionsgrenzen bleibt Fehler" "
dim Laenge;
dim Zeit;
utype Meter:   Laenge = 1.0;
utype Sekunde: Zeit   = 1.0;
fn main(): int64 {
    var m: Meter := 5;
    var s: Sekunde := m;
    return s as int64;
}" "Dimensionsgrenzen"

rejects "range-Grenze bleibt in Kraft" "
dim Winkel;
utype Grad: Winkel = 1 range 0..360;
fn main(): int64 { var g: Grad := 400; return g as int64; }" "ausserhalb der Grenzen"

echo
echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
