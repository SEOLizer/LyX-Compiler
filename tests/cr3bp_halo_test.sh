#!/usr/bin/env bash
# tests/cr3bp_halo_test.sh — #2016: Halo-Fortsetzung ueber 0.45 gamma hinaus.
#
# Die alte Fortsetzung endete bei rund 0.45 gamma. Ursache war ein FALTPUNKT:
# z0 (|z| am Startzustand, x0 < xL) hat entlang der Schar ein Maximum bei
# 0.4986 gamma; dort wird die Korrektur bei festem z0 singulaer, darueber gibt
# es keine solche Bahn. Die "rund 800 000 km" von JWST sind die GROESSTE
# z-Auslenkung, und die liegt an der Gegenkreuzung.
#
# Gemessen wird gegen REFERENZWERTE, nicht gegen Invarianten:
#   * NASA/JPL Three-Body Periodic Orbits (ssd-api.jpl.nasa.gov, Sun-Earth,
#     halo, L2, Zweig N; mass_ratio 3.0542e-6): drei Bahnen aus deren
#     Datensatz — Periode, Jacobi-Konstante und Zustand an der Kreuzung
#     muessen stimmen. Die JPL-Bahn N liegt an der Gegenkreuzung bei z > 0,
#     ist also hier nordSued = -1.
#   * die Ergebnisse der alten Fassung fuer kleine Amplituden (Regression);
#   * zusaetzlich Periodizitaet und Erhaltung der Jacobi-Konstante.
# Und beide Seiten des Faltpunkts: 0.498 gamma konvergiert, 0.50 meldet.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ulimit -c 0

cat > "$TMP/h.lyx" <<'EOF'
import std.io;
import std.math;
import std.astro.state;
import std.astro.cr3bp;

fn pruef(name: pchar, ok: bool, wert: f64): void {
  if (ok) { PrintStr("PASS "c); } else { PrintStr("FAIL "c); }
  PrintStr(name); PrintStr("  ("c);
  // Zahlen als ganzzahliges Vielfaches von 1e-12: FloatToStr kennt nur sechs
  // Nachkommastellen.
  PrintInt((wert * 1000000000000.0) as int64); PrintStrLn("e-12)"c);
}

fn jacobi(mu: f64, s: AState): f64 {
  return AJacobiConstant(mu, AVec(s.rx, s.ry, s.rz), AVec(s.vx, s.vy, s.vz));
}

// Nach einer Periode wieder am Start? Liefert die groesste Abweichung.
fn rundAbw(mu: f64, s: AState, dt: f64): f64 {
  var T: f64 := AHaloPeriod(mu, s, dt);
  if (AIsError(T)) { return 1.0; }
  var n: int64 := (T / dt) as int64;
  var r: AState := ACr3bpPropagate(mu, s, T / (n as f64), n);
  var d: f64 := AbsF64(r.rx - s.rx);
  if (AbsF64(r.ry - s.ry) > d) { d := AbsF64(r.ry - s.ry); }
  if (AbsF64(r.rz - s.rz) > d) { d := AbsF64(r.rz - s.rz); }
  if (AbsF64(r.vx - s.vx) > d) { d := AbsF64(r.vx - s.vx); }
  if (AbsF64(r.vy - s.vy) > d) { d := AbsF64(r.vy - s.vy); }
  if (AbsF64(r.vz - s.vz) > d) { d := AbsF64(r.vz - s.vz); }
  return d;
}

// Eine JPL-Bahn nachrechnen: Ziel ist deren z an der Kreuzung (in gamma).
fn jpl(name: pchar, muJ: f64, gJ: f64, x: f64, z: f64, vy: f64, T: f64, C: f64, dt: f64): void {
  var s: AState := AHaloFromAmplitudeZMax(muJ, gJ, true, z / gJ, 0.0 - 1.0, dt, 10);
  if (AIsError(s.rx)) { pruef(name, false, 0.0); return; }
  var e: AState := ACr3bpBisEbene(muJ, s, dt, 200000);
  var tMein: f64 := AHaloPeriod(muJ, s, dt);
  PrintStr("  "c); PrintStrLn(name);
  pruef("    Periode wie JPL (1e-8)"c, AbsF64(tMein - T) < 0.00000001, tMein - T);
  pruef("    Jacobi-Konstante wie JPL (1e-10)"c, AbsF64(jacobi(muJ, s) - C) < 0.0000000001,
        jacobi(muJ, s) - C);
  pruef("    x an der Kreuzung wie JPL (1e-9)"c, AbsF64(e.rx - x) < 0.000000001, e.rx - x);
  pruef("    vy an der Kreuzung wie JPL (1e-9)"c, AbsF64(e.vy - vy) < 0.000000001, e.vy - vy);
  pruef("    z an der Kreuzung wie JPL (1e-11)"c, AbsF64(e.rz - z) < 0.00000000001, e.rz - z);
}

fn main(argc: int64, argv: pchar): int64 {
  var se: f64 := AMuSunEarth();
  var g: f64 := ALagrange2Gamma(se);
  var dt: f64 := 0.002;
  var au: f64 := 149597870700.0;

  // --- Regression: die alten Ergebnisse fuer kleine Amplituden ----------
  // Werte der Fassung vor #2016 (gleiche Aufrufe, dt = 0.005). Die neue
  // Fortsetzung trifft dieselbe Bahn; der Rest ist die Konvergenzschwelle
  // der Korrektur (1e-11 auf vx, vz), gemessen 2e-12 in x0 und 9e-12 in vy0.
  var a35: AState := AHaloFromAmplitudeZ(se, g, true, 0.35, 1.0, 0.005, 8);
  pruef("0.35 gamma: x0 wie vorher"c, AbsF64(a35.rx - 1.006852510780179) < 0.0000000001,
        a35.rx - 1.006852510780179);
  pruef("0.35 gamma: z0 wie vorher"c, AbsF64(a35.rz - 0.003512991733415) < 0.000000000001,
        a35.rz - 0.003512991733415);
  pruef("0.35 gamma: vy0 wie vorher"c, AbsF64(a35.vy - 0.014537931345520) < 0.0000000001,
        a35.vy - 0.014537931345520);
  var a10: AState := AHaloFromAmplitudeZ(se, g, true, 0.10, 0.0 - 1.0, 0.005, 3);
  pruef("0.10 gamma Sued: x0 wie vorher"c, AbsF64(a10.rx - 1.008269833793535) < 0.0000000001,
        a10.rx - 1.008269833793535);
  pruef("0.10 gamma Sued: vy0 wie vorher"c, AbsF64(a10.vy - 0.010128545750849) < 0.0000000001,
        a10.vy - 0.010128545750849);

  // --- Der Faltpunkt: beide Seiten ---------------------------------------
  var a45: AState := AHaloFromAmplitudeZ(se, g, true, 0.45, 1.0, dt, 20);
  pruef("0.45 gamma mit 20 statt 200 Schritten"c, !AIsError(a45.rx), a45.rz / g);
  var a498: AState := AHaloFromAmplitudeZ(se, g, true, 0.498, 1.0, dt, 40);
  pruef("0.498 gamma (knapp unter dem Maximum) konvergiert"c,
        !AIsError(a498.rx) && AbsF64(a498.rz - 0.498 * g) < 0.000000000001, a498.rz / g);
  pruef("0.498 gamma ist periodisch (1e-9)"c, rundAbw(se, a498, dt) < 0.000000001,
        rundAbw(se, a498, dt));
  var a50: AState := AHaloFromAmplitudeZ(se, g, true, 0.50, 1.0, dt, 40);
  pruef("0.50 gamma liegt jenseits des Maximums und meldet"c, AIsError(a50.rx), 0.0);

  // --- JWST: groesste z-Auslenkung 0.53 gamma -----------------------------
  var jw: AState := AHaloFromAmplitudeZMax(se, g, true, 0.53, 1.0, dt, 10);
  pruef("JWST-Bahn (0.53 gamma groesste z-Auslenkung) gefunden"c, !AIsError(jw.rx), jw.rz / g);
  var kmMax: f64 := AHaloAmplitudeZMax(se, jw, dt, au) / 1000.0;
  pruef("ihre groesste z-Auslenkung ist 0.53 gamma (1 m)"c,
        AbsF64(kmMax - 0.53 * g * au / 1000.0) < 0.001, kmMax);
  pruef("sie ist periodisch (1e-9)"c, rundAbw(se, jw, dt) < 0.000000001, rundAbw(se, jw, dt));
  var TJ: f64 := AHaloPeriod(se, jw, dt);
  var nJ: int64 := (TJ / dt) as int64;
  var jr: AState := ACr3bpPropagate(se, jw, TJ / (nJ as f64), nJ);
  pruef("Jacobi-Konstante bleibt ueber die Periode (1e-12)"c,
        AbsF64(jacobi(se, jr) - jacobi(se, jw)) < 0.000000000001, jacobi(se, jr) - jacobi(se, jw));
  // Dieselbe Bahn ueber die andere Messgroesse: ihr z0 als Ziel von
  // AHaloFromAmplitudeZ muss sie wiederfinden.
  var jz: AState := AHaloFromAmplitudeZ(se, g, true, AbsF64(jw.rz) / g, 1.0, dt, 10);
  pruef("AHaloFromAmplitudeZ findet dieselbe Bahn ueber z0"c,
        !AIsError(jz.rx) && AbsF64(jz.rx - jw.rx) < 0.000000001, jz.rx - jw.rx);

  // --- Referenz: NASA/JPL Three-Body Periodic Orbits ---------------------
  var muJ: f64 := 0.0000030542;
  var gJ: f64 := ALagrange2Gamma(muJ);
  pruef("gamma(L2) wie JPL"c, AbsF64((1.0 - muJ + gJ) - 1.01009043578556) < 0.00000000001,
        (1.0 - muJ + gJ) - 1.01009043578556);
  jpl("JPL: z 0.527 gamma, Periode 178 Tage"c, muJ, gJ,
      1.0108782969696402, 0.0053184872672842280, 0.0 - 0.011952444638744054,
      3.0708647852305457, 3.00067454613331, dt);
  jpl("JPL: z 0.911 gamma (Startseite nahe dem Maximum)"c, muJ, gJ,
      1.0097113507169873, 0.0091980240213338591, 0.0 - 0.014650174850107922,
      2.9552007104792901, 3.00042886565156, dt);
  jpl("JPL: z 1.080 gamma (Startseite jenseits des Maximums)"c, muJ, gJ,
      1.0087563148869279, 0.010899417867620682, 0.0 - 0.015221864064278565,
      2.8000128013692382, 3.00030605102457, dt);
  return 0;
}
EOF

(cd "$ROOT" && "$LYXC" --std-path="$ROOT" "$TMP/h.lyx" -o "$TMP/h" >"$TMP/h.log" 2>&1)
if [ ! -x "$TMP/h" ]; then
  echo "FAIL uebersetzt nicht: $(grep -i error "$TMP/h.log" | head -3 | tr '\n' ' ')"
  echo "Ergebnis: 0 PASS, 1 FAIL"; exit 1
fi
timeout 600 "$TMP/h" > "$TMP/h.out" 2>&1; rc=$?
cat "$TMP/h.out"
PASS=$(grep -c '^PASS' "$TMP/h.out"); FAIL=$(grep -c '^FAIL' "$TMP/h.out")
if [ $rc -ne 0 ]; then echo "FAIL Lauf rc=$rc"; FAIL=$((FAIL+1)); fi
if [ "$PASS" -lt 25 ]; then echo "FAIL nur $PASS Pruefungen gelaufen"; FAIL=$((FAIL+1)); fi
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
