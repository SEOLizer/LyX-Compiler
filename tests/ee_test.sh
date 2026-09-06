#!/usr/bin/env bash
# std/ee — Elektrotechnik: Konstanten, Gleichstrom, Wechselstrom
#
# WIE HIER GEPRUEFT WIRD. Eine Zahl "sieht plausibel aus" ist keine Aussage;
# in dieser Sammlung ist fast jedes Ergebnis eine positive Zahl in der
# richtigen Groessenordnung, auch wenn die Formel falsch ist. Deshalb:
#
#   1. GEGEN VON AUSSEN BEKANNTE WERTE. Die Thermospannung bei 300 K ist
#      25,852 mV, der Freiraumwellenwiderstand 376,73 Ohm, XC bei 50 Hz und
#      10 µF ist 318,31 Ohm. Diese Zahlen stehen in jedem Lehrbuch und kommen
#      NICHT aus der Unit selbst — sonst prueft sich die Rechnung nur selbst.
#
#   2. VORZEICHEN UND RICHTUNG. Der kapazitive Blindwiderstand geht mit MINUS
#      in die Impedanz ein. Eine Fassung, die beide positiv einsetzt, liefert
#      denselben Betrag, wenn nur eine Blindkomponente da ist — auffaellig
#      wird sie erst am Phasenwinkel und an der Resonanz. Beides wird gemessen.
#
#   3. RUNDLAEUFE. Effektivwert -> Scheitelwert -> Effektivwert; Querschnitt
#      mm² -> m² -> mm². Faengt Einheiten- und Faktorfehler, die eine
#      Einzelmessung durchlaesst.
#
#   4. BEIDE SEITEN. Zu jeder gueltigen Eingabe gehoert eine ungueltige: R = 0
#      beim Stromgesetz, negative Frequenz, cos φ ausserhalb [0,1]. Die Unit
#      muss den Fehlerwert liefern und nicht eine plausible Zahl. Ohne diese
#      Haelfte waere eine Fassung, die immer 0 zurueckgibt, bei den Rundlaeufen
#      auffaellig — bei den Grenzfaellen aber nicht.
#
#   5. QUERPROBEN ZWISCHEN FUNKTIONEN. Der belastete Spannungsteiler mit
#      unendlicher Last muss dem unbelasteten entsprechen; die Reihenschaltung
#      zweier gleicher Widerstaende dem Doppelten; die Resonanzfrequenz muss
#      genau die Frequenz sein, bei der die Reihenimpedanz reell wird.
#
# Alle Laeufe stehen unter `ulimit -v`.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

# Ein Programm uebersetzen und ausfuehren; Ausgabe zeilenweise gegen die
# Erwartung. Die Erwartungswerte stehen als TEXT im Test — nachgerechnet und
# nicht aus der Unit uebernommen.
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

echo "--- 1. Konstanten gegen Lehrbuchwerte ---"

# kT/q bei 300 K = 1,380649e-23 · 300 / 1,602176634e-19 = 25,852 mV
# Z0 = µ0 · c = 1,25663706212e-6 · 299792458 = 376,730 Ohm
lauf "Thermospannung und Wellenwiderstand" 'import std.io;
import std.ee.const;
fn main(): int64 {
  PrintStr(FloatToStr(EeThermalVoltage(300.0) * 1000.0, 3)); PrintStr(" ");
  PrintLn(FloatToStr(EeZ0(), 3));
  return 0;
}' '25.852 376.730'

# Rundlauf mm² -> m² -> mm², und der Querschnitt aus dem Durchmesser:
# d = 2 mm -> A = pi · 1² = 3,1416 mm²
lauf "Querschnitt: Rundlauf und aus dem Durchmesser" 'import std.io;
import std.ee.const;
fn main(): int64 {
  PrintStr(FloatToStr(EeM2ToMm2(EeMm2ToM2(2.5)), 4)); PrintStr(" ");
  PrintLn(FloatToStr(EeDiameterMmToAreaMm2(2.0), 4));
  return 0;
}' '2.5000 3.1416'

echo "--- 2. Gleichstrom ---"

# 100||100 = 50; drei mal 100 parallel = 33,333; Reihe = 200
lauf "Zusammenschaltungen" 'import std.io;
import std.ee.dc;
fn main(): int64 {
  PrintStr(FloatToStr(DcParallel2(100.0, 100.0), 3)); PrintStr(" ");
  PrintStr(FloatToStr(DcParallel3(100.0, 100.0, 100.0), 3)); PrintStr(" ");
  PrintStr(FloatToStr(DcParallelN(100.0, 4), 3)); PrintStr(" ");
  PrintLn(FloatToStr(DcSeries2(100.0, 100.0), 3));
  return 0;
}' '50.000 33.333 25.000 200.000'

# QUERPROBE: der belastete Teiler mit sehr hochohmiger Last muss dem
# unbelasteten entsprechen — und mit gleicher Last deutlich davon abweichen.
# 12 V an 1k/1k: unbelastet 6 V; mit 1k Last wird R2||RL = 500, also
# 12 · 500/1500 = 4 V.
lauf "Spannungsteiler unbelastet und belastet" 'import std.io;
import std.ee.dc;
fn main(): int64 {
  PrintStr(FloatToStr(DcVoltageDivider(12.0, 1000.0, 1000.0), 3)); PrintStr(" ");
  PrintStr(FloatToStr(DcVoltageDividerLoaded(12.0, 1000.0, 1000.0, 1.0e9), 3)); PrintStr(" ");
  PrintLn(FloatToStr(DcVoltageDividerLoaded(12.0, 1000.0, 1000.0, 1000.0), 3));
  return 0;
}' '6.000 6.000 4.000'

# Leitung: 2 x 10 m, 1,5 mm², Kupfer, 16 A.
# R = 0,01724 · 10 / 1,5 = 0,11493 Ohm; dU = 2 · 16 · 0,11493 = 3,678 V
# an 230 V sind das 1,599 %.
lauf "Spannungsfall auf der Leitung" 'import std.io;
import std.ee.dc;
fn main(): int64 {
  PrintStr(FloatToStr(DcWireResistanceOhm(DcRhoCopper(), 10.0, 1.5), 5)); PrintStr(" ");
  PrintStr(FloatToStr(DcVoltageDropV(16.0, DcRhoCopper(), 10.0, 1.5), 3)); PrintStr(" ");
  PrintLn(FloatToStr(DcVoltageDropPercent(16.0, 230.0, DcRhoCopper(), 10.0, 1.5), 3));
  return 0;
}' '0.11493 3.678 1.599'

# QUERPROBE: der erforderliche Querschnitt muss den Spannungsfall wieder auf
# den Grenzwert bringen. 3,678 V bei 1,5 mm² -> fuer 3,678 V verlangt die
# Umkehrung genau 1,5 mm².
lauf "erforderlicher Querschnitt ist die Umkehrung" 'import std.io;
import std.ee.dc;
fn main(): int64 {
  var du: f64 := DcVoltageDropV(16.0, DcRhoCopper(), 10.0, 1.5);
  PrintLn(FloatToStr(DcRequiredAreaMm2(16.0, DcRhoCopper(), 10.0, du), 4));
  return 0;
}' '1.5000'

# Temperaturgang: 1 Ohm Kupfer bei 20 °C -> bei 70 °C 1 + 0,00393·50 = 1,1965
lauf "Temperaturgang" 'import std.io;
import std.ee.dc;
fn main(): int64 {
  PrintLn(FloatToStr(DcResistanceAtTemp(1.0, DcAlphaCopper(), 70.0), 4));
  return 0;
}' '1.1965'

echo "--- 3. Wechselstrom ---"

# XL = 2π·50·0,1 = 31,4159 ; XC = 1/(2π·50·10µ) = 318,3099
# Z = 10 + j(31,4159 - 318,3099) = 10 - j286,894
# |Z| = sqrt(100 + 82308,1) = 287,0682 ; phi = atan2(-286,894, 10) = -88,0037°
lauf "Blindwiderstaende, Betrag und Phase" 'import std.io;
import std.ee.const;
import std.ee.ac;
import std.complex;
fn main(): int64 {
  PrintStr(FloatToStr(AcReactanceL(50.0, 0.1), 4)); PrintStr(" ");
  PrintStr(FloatToStr(AcReactanceC(50.0, 10.0e-6), 4)); PrintStr(" ");
  var z: Cx := AcSeriesRLC(10.0, 0.1, 10.0e-6, 50.0);
  PrintStr(FloatToStr(CxAbs(z), 4)); PrintStr(" ");
  PrintLn(FloatToStr(AcPhaseDeg(z), 4));
  return 0;
}' '31.4159 318.3099 287.0682 -88.0037'

# DIE PROBE AUFS VORZEICHEN: bei der Resonanzfrequenz muss die Reihenimpedanz
# REELL werden, also |Z| = R und phi = 0. Setzte man XC positiv ein, gaebe es
# diese Frequenz nicht — die Impedanz stiege monoton.
lauf "bei Resonanz wird die Reihenimpedanz reell" 'import std.io;
import std.ee.const;
import std.ee.ac;
import std.complex;
fn main(): int64 {
  var f0: f64 := AcResonanceHz(0.1, 10.0e-6);
  var z: Cx := AcSeriesRLC(10.0, 0.1, 10.0e-6, f0);
  PrintStr(FloatToStr(f0, 4)); PrintStr(" ");
  PrintStr(FloatToStr(CxAbs(z), 4)); PrintStr(" ");
  PrintLn(FloatToStr(AcPhaseDeg(z), 4));
  return 0;
}' '159.1549 10.0000 0.0000'

# Guete: Reihe Q = sqrt(L/C)/R = sqrt(0,1/10µ)/10 = 100/10 = 10
# Parallel Q = R·sqrt(C/L) = 10·0,01 = 0,1 — der KEHRWERT der Abhaengigkeit.
# Bandbreite = f0/Q = 15,9155
lauf "Guete Reihe und Parallel, Bandbreite" 'import std.io;
import std.ee.ac;
fn main(): int64 {
  PrintStr(FloatToStr(AcQSeries(10.0, 0.1, 10.0e-6), 4)); PrintStr(" ");
  PrintStr(FloatToStr(AcQParallel(10.0, 0.1, 10.0e-6), 4)); PrintStr(" ");
  PrintLn(FloatToStr(AcBandwidthHz(AcResonanceHz(0.1, 10.0e-6), 10.0), 4));
  return 0;
}' '10.0000 0.1000 15.9155'

# Effektivwerte: Rundlauf, und die drei Kurvenformen im Vergleich.
# Sinus 325,27 -> 230,0 ; Rechteck 100 -> 100 ; Dreieck 100 -> 57,735
lauf "Effektivwerte je Kurvenform" 'import std.io;
import std.ee.ac;
fn main(): int64 {
  PrintStr(FloatToStr(AcRmsFromPeakSine(AcPeakFromRmsSine(230.0)), 4)); PrintStr(" ");
  PrintStr(FloatToStr(AcRmsFromPeakSquare(100.0), 4)); PrintStr(" ");
  PrintLn(FloatToStr(AcRmsFromPeakTriangle(100.0), 4));
  return 0;
}' '230.0000 100.0000 57.7350'

# Leistungsfaktor: cos φ = 0,8 ohne Verzerrung ergibt λ = 0,8; mit THD = 0,3
# ist λ = 0,8/sqrt(1,09) = 0,7663 — deutlich kleiner. Genau der Unterschied,
# der Zuleitungen unterdimensioniert.
lauf "Leistungsfaktor mit und ohne Verzerrung" 'import std.io;
import std.ee.ac;
fn main(): int64 {
  PrintStr(FloatToStr(AcPowerFactor(800.0, 1000.0), 4)); PrintStr(" ");
  PrintLn(FloatToStr(AcPowerFactorWithThd(0.8, 0.3), 4));
  return 0;
}' '0.8000 0.7663'

echo "--- 4. Grenzfaelle: Fehlerwert statt plausibler Zahl ---"

lauf "ungueltige Eingaben liefern den Fehlerwert" 'import std.io;
import std.ee.const;
import std.ee.dc;
import std.ee.ac;
fn main(): int64 {
  var n: int64 := 0;
  if (EeIsError(DcCurrent(12.0, 0.0)))            { n := n + 1; }
  if (EeIsError(DcResistance(12.0, 0.0)))         { n := n + 1; }
  if (EeIsError(EeThermalVoltage(0.0)))           { n := n + 1; }
  if (EeIsError(AcReactanceC(0.0, 10.0e-6)))      { n := n + 1; }
  if (EeIsError(AcResonanceHz(0.0, 10.0e-6)))     { n := n + 1; }
  if (EeIsError(AcQSeries(0.0, 0.1, 10.0e-6)))    { n := n + 1; }
  if (EeIsError(AcPowerFactor(800.0, 0.0)))       { n := n + 1; }
  if (EeIsError(DcWireResistanceOhm(0.01724, 10.0, 0.0))) { n := n + 1; }
  PrintLn(IntToStr(n));
  return 0;
}' '8'

# GEGENPROBE zur vorigen Pruefung: dieselben Funktionen mit GUELTIGEN Werten
# duerfen KEINEN Fehlerwert liefern. Ohne diese Haelfte waere eine Fassung,
# die immer den Fehlerwert zurueckgibt, oben unauffaellig.
lauf "gueltige Eingaben liefern keinen Fehlerwert" 'import std.io;
import std.ee.const;
import std.ee.dc;
import std.ee.ac;
fn main(): int64 {
  var n: int64 := 0;
  if (EeIsError(DcCurrent(12.0, 4.0)))            { n := n + 1; }
  if (EeIsError(DcResistance(12.0, 3.0)))         { n := n + 1; }
  if (EeIsError(EeThermalVoltage(300.0)))         { n := n + 1; }
  if (EeIsError(AcReactanceC(50.0, 10.0e-6)))     { n := n + 1; }
  if (EeIsError(AcResonanceHz(0.1, 10.0e-6)))     { n := n + 1; }
  if (EeIsError(AcQSeries(10.0, 0.1, 10.0e-6)))   { n := n + 1; }
  if (EeIsError(AcPowerFactor(800.0, 1000.0)))    { n := n + 1; }
  if (EeIsError(DcWireResistanceOhm(0.01724, 10.0, 1.5))) { n := n + 1; }
  PrintLn(IntToStr(n));
  return 0;
}' '0'

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
