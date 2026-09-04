#!/usr/bin/env bash
# tests/aero_test.sh — std.aero gegen eine unabhaengige Referenz.
#
# Fuenf Units: atmos (Standardatmosphaere und Geschwindigkeiten), perf
# (Flugleistung, Kurven, Pseudo-Wegpunkte), fplan (Vorhersage und Reserven),
# vnav (segmentierte Profile, Drift-Down, Notabstieg), holding
# (Warteschleifen).
#
# WIE HIER GEMESSEN WIRD — die Reihenfolge ist Absicht:
#
#   1. GEGEN EINE ZWEITE UMSETZUNG. tests/lib/aero_ref.py rechnet dieselben
#      Groessen in Python NEU, und ausdruecklich anders geschrieben: die Unit
#      nimmt fuer den Druck die Potenzform auf das Temperaturverhaeltnis, die
#      Referenz die Exponentialform. Ein Denkfehler steckt so nicht in beiden.
#
#   2. GEGEN VEROEFFENTLICHTE TABELLENWERTE. Die ICAO-Standardatmosphaere ist
#      normiert; 22632,1 Pa in 11 km und 661,4788 kt Schallgeschwindigkeit auf
#      Meereshoehe stehen in jedem Handbuch. Diese Werte kommen NICHT aus der
#      Referenz, sondern von aussen — sonst pruefte sich die Rechnung nur
#      selbst.
#
#   3. RUNDLAEUFE. CAS→TAS→CAS und Hoehe→Druck→Hoehe muessen auf den
#      Ausgangswert zurueckfuehren. Das faengt Vorzeichen- und
#      Einheitenfehler, die eine Einzelmessung durchlaesst.
#
#   4. BEIDE SEITEN. Zu jeder gueltigen Eingabe gehoert eine ungueltige: die
#      Unit muss den Fehlerwert liefern und nicht eine plausible Zahl. Ohne
#      diese Haelfte waere eine Fassung, die immer 0 zurueckgibt, bei den
#      Rundlaeufen auffaellig — bei den Grenzfaellen aber nicht.
#
#   5. QUERPROBEN ZWISCHEN FUNKTIONEN. Zwei Wege zur selben Groesse muessen
#      dasselbe ergeben: der Sinkflug ueber das integrierte Profil und die
#      Strecke aus demselben Profil; die noetige Sinkrate und der Bahnwinkel.
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

command -v python3 >/dev/null 2>&1 || {
  echo "UEBERSPRUNGEN std.aero: python3 fehlt — ohne die Referenz gaebe es keinen Abgleich"; exit 0; }
[ -f "$ROOT/tests/lib/aero_ref.py" ] || {
  echo "UEBERSPRUNGEN std.aero: tests/lib/aero_ref.py fehlt"; exit 0; }

echo "--- std.aero: Atmosphaere, Flugleistung, Vorhersage, Profile, Warteschleifen ---"

# ── Sonde ────────────────────────────────────────────────────────────────────
cat > "$TMP/sonde.lyx" <<'EOF'
unit main;
import std.aero.atmos;
import std.aero.perf;
import std.aero.fplan;
import std.aero.vnav;
import std.aero.holding;
import std.io;

fn z(t: pchar, v: f64): void { Print(t); Print("="); PrintF64(v); PrintLn(""c); }
fn zi(t: pchar, v: int64): void { Print(t); Print("="); PrintInt(v); PrintLn(""c); }

fn main(): int64 {
  // — Standardatmosphaere —
  z("isa_t_0"c, AvIsaTemperaturK(0.0));
  z("isa_p_0"c, AvIsaDruckPa(0.0));
  z("isa_rho_0"c, AvIsaDichte(0.0));
  z("isa_t_11000"c, AvIsaTemperaturK(11000.0));
  z("isa_p_11000"c, AvIsaDruckPa(11000.0));
  z("isa_p_20000"c, AvIsaDruckPa(20000.0));
  z("isa_rho_5000"c, AvIsaDichte(5000.0));
  z("a_sl_kt"c, AvSchallgeschwindigkeitKt(288.15));

  // — Geschwindigkeiten —
  z("mach_300_10668"c, AvMachAusCasKt(300.0, 10668.0));
  z("tas_300_10668"c, AvTasKtAusCasKt(300.0, 10668.0, 0.0 - 50.0));
  z("dichtehoehe_0_30"c, AvDichtehoeheM(0.0, 30.0));

  // — Rundlaeufe —
  z("rund_cas"c, AvCasKtAusTasKt(AvTasKtAusCasKt(280.0, 9000.0, 0.0 - 40.0), 9000.0, 0.0 - 40.0));
  z("rund_hoehe"c, AvHoeheAusDruckM(AvIsaDruckPa(7500.0)));
  z("rund_mach"c, AvCasKtAusMach(AvMachAusCasKt(250.0, 6000.0), 6000.0));

  // — Flugleistung —
  z("sinkrate_140_3"c, AvSinkrateFpm(140.0, 3.0));
  z("radius_250_25"c, AvKurvenradiusNm(250.0, 25.0));
  z("rate_250_25"c, AvKurvenrateGradProS(250.0, 25.0));
  z("vorhalt_250_25_90"c, AvKurvenvorhaltNm(250.0, 25.0, 90.0));
  z("tod_35000_3000"c, AvTodStreckeNm(35000.0, 3000.0, 17.0, 280.0, 30.0));
  z("etp_1000_450_50"c, AvPunktGleicherZeitNm(1000.0, 450.0, 50.0));

  // — Querprobe: Bahnwinkel und Sinkrate muessen zusammenpassen —
  z("quer_winkel"c, AvBahnwinkelGrad(140.0, AvSinkrateFpm(140.0, 3.0)));

  // — Querprobe: Profilstrecke und TOD aus demselben Profil —
  z("profil_strecke"c, AvProfilStreckeNm(
      AvSinkprofil(35000.0, 3000.0, 500.0, 300.0, 0.78, 0.0, 1800.0, 1200.0, 0.0, 0.0, 0.0)));
  z("profil_tod"c, AvTodStreckeAusProfilNm(35000.0, 3000.0, 500.0, 300.0, 0.78, 0.0,
                                            1800.0, 1200.0, 0.0));

  // — Vorhersage —
  var v: AvVorhersage := AvVorhersageStart(10000.0);
  AvVorhersageAbschnitt(v, 450.0, 450.0, 2000.0);
  AvVorhersageZeitabschnitt(v, 30.0, 1800.0);
  z("vorher_zeit"c, AvVorhersageZeitMin(v));
  z("vorher_efob"c, AvVorhersageEfobKg(v));
  z("ankunft"c, AvAnkunftMinuten(23.0 * 60.0 + 40.0, 50.0));

  // — Warteschleifen —
  zi("einflug_090_090"c, AvEinflugverfahren(90.0, 90.0, true));
  zi("einflug_090_270"c, AvEinflugverfahren(90.0, 270.0, true));
  zi("einflug_090_030"c, AvEinflugverfahren(90.0, 30.0, true));
  z("warte_ias_10000"c, AvMaxWartegeschwindigkeitKt(10000.0));
  z("warte_ias_18000"c, AvMaxWartegeschwindigkeitKt(18000.0));
  z("schenkel_20000"c, AvSchenkelzeitMin(20000.0));

  // — Grenzfaelle: hier MUSS der Fehlerwert kommen —
  zi("f_hoehe_zu_hoch"c, AvIsError(AvIsaDruckPa(25000.0)) as int64);
  zi("f_negativ_cas"c, AvIsError(AvMachAusCasKt(0.0 - 10.0, 5000.0)) as int64);
  zi("f_kehrtwende"c, AvIsError(AvKurvenvorhaltNm(250.0, 25.0, 180.0)) as int64);
  zi("f_bank_90"c, AvIsError(AvKurvenradiusNm(250.0, 90.0)) as int64);
  zi("f_gegenwind_zu_stark"c, AvIsError(AvTodStreckeNm(35000.0, 3000.0, 17.0, 100.0, 0.0 - 200.0)) as int64);
  zi("f_ziel_ueber_start"c, AvIsError(AvTodStreckeNmFaustformel(3000.0, 35000.0)) as int64);
  zi("f_warte_mach_bereich"c, AvIsError(AvMaxWartegeschwindigkeitKt(36000.0)) as int64);
  zi("f_druck_null"c, AvIsError(AvHoeheAusDruckM(0.0)) as int64);

  // — und hier darf er NICHT kommen —
  zi("g_hoehe_grenze"c, AvIsError(AvIsaDruckPa(20000.0)) as int64);
  zi("g_bank_60"c, AvIsError(AvKurvenradiusNm(250.0, 60.0)) as int64);
  zi("g_kursaenderung_179"c, AvIsError(AvKurvenvorhaltNm(250.0, 25.0, 179.0)) as int64);
  return 0;
}
EOF

if ! ( cd "$ROOT" && timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/sonde.lyx" -o "$TMP/sonde" ) >"$TMP/build.log" 2>&1; then
  nok "die Sonde uebersetzt nicht"; sed -n '1,6p' "$TMP/build.log"
  echo; echo "Ergebnis: $PASS PASS, $FAIL FAIL"; exit 1
fi

AUS="$( ulimit -v 2097152; timeout 120 "$TMP/sonde" 2>/dev/null )"; rc=$?
if [ "$rc" -ne 0 ]; then
  nok "die Sonde bricht ab (rc=$rc)"
  echo; echo "Ergebnis: $PASS PASS, $FAIL FAIL"; exit 1
fi
ok "die Sonde laeuft durch"
printf '%s\n' "$AUS" > "$TMP/aus.txt"

hole() { grep -oP "^$1=\K.*" "$TMP/aus.txt" | head -1; }

# ── 1. Gegen die unabhaengige Referenz ──────────────────────────────────────
if out=$( ulimit -v 2097152; timeout 120 python3 "$ROOT/tests/lib/aero_ref.py" "$TMP/aus.txt" 2>&1 ); then
  ok "gegen die Python-Referenz gehalten ($(printf '%s' "$out" | head -1))"
else
  if printf '%s' "$out" | grep -q "Traceback"; then
    nok "die Referenz selbst bricht ab (kein Befund ueber die Unit)"
  else
    nok "Referenz meldet Abweichungen"
  fi
  printf '%s\n' "$out" | sed -n '1,6p'
fi

# ── 2. Gegen veroeffentlichte Tabellenwerte ─────────────────────────────────
#
# Diese Zahlen stammen NICHT aus der Referenz, sondern aus der Norm. Damit
# prueft sich die Rechnung nicht selbst.
nahe() { # ist soll toleranz name
  python3 -c "
import sys
ist, soll, tol = float('$1'), float('$2'), float('$3')
sys.exit(0 if abs(ist-soll) <= tol else 1)" 2>/dev/null
}

if nahe "$(hole isa_p_11000)" 22632.1 0.1; then
  ok "Druck in 11 km trifft den Normwert 22632,1 Pa"
else
  nok "Druck in 11 km: $(hole isa_p_11000), Norm 22632,1"
fi
if nahe "$(hole a_sl_kt)" 661.4788 0.001; then
  ok "Schallgeschwindigkeit auf Meereshoehe trifft 661,4788 kt"
else
  nok "Schallgeschwindigkeit: $(hole a_sl_kt), Norm 661,4788"
fi
if nahe "$(hole isa_p_20000)" 5474.89 0.05; then
  ok "Druck in 20 km trifft den Normwert 5474,89 Pa"
else
  nok "Druck in 20 km: $(hole isa_p_20000), Norm 5474,89"
fi

# ── 3. Rundlaeufe ───────────────────────────────────────────────────────────
if nahe "$(hole rund_cas)" 280.0 0.001; then
  ok "CAS -> TAS -> CAS fuehrt auf 280 kt zurueck"
else
  nok "CAS-Rundlauf endet bei $(hole rund_cas), erwartet 280"
fi
if nahe "$(hole rund_hoehe)" 7500.0 0.01; then
  ok "Hoehe -> Druck -> Hoehe fuehrt auf 7500 m zurueck"
else
  nok "Hoehen-Rundlauf endet bei $(hole rund_hoehe), erwartet 7500"
fi
if nahe "$(hole rund_mach)" 250.0 0.001; then
  ok "CAS -> Mach -> CAS fuehrt auf 250 kt zurueck"
else
  nok "Mach-Rundlauf endet bei $(hole rund_mach), erwartet 250"
fi

# ── 4. Querproben zwischen Funktionen ───────────────────────────────────────
if nahe "$(hole quer_winkel)" 3.0 0.0001; then
  ok "Sinkrate und Bahnwinkel sind zueinander invers (3,0 Grad)"
else
  nok "Querprobe Winkel: $(hole quer_winkel), erwartet 3,0"
fi
ps="$(hole profil_strecke)"; pt="$(hole profil_tod)"
if [ -n "$ps" ] && [ "$ps" = "$pt" ]; then
  ok "Profilstrecke und TOD aus dem Profil stimmen ueberein ($ps NM)"
else
  nok "Profil: Strecke '$ps' gegen TOD '$pt'"
fi

# Vorhersage: 450 NM bei 450 kt sind 60 Minuten, plus 30 Minuten Warteflug.
if nahe "$(hole vorher_zeit)" 90.0 0.0001; then
  ok "Vorhersage summiert Abschnitt und Warteflug zu 90 min"
else
  nok "Vorhersagezeit: $(hole vorher_zeit), erwartet 90"
fi
# 2000 kg/h fuer 1 h plus 1800 kg/h fuer 0,5 h = 2900 kg ab 10000 kg.
if nahe "$(hole vorher_efob)" 7100.0 0.0001; then
  ok "EFOB nach beiden Abschnitten betraegt 7100 kg"
else
  nok "EFOB: $(hole vorher_efob), erwartet 7100"
fi
# 23:40 plus 50 Minuten ist 00:30 — also 30 Minuten nach Mitternacht.
if nahe "$(hole ankunft)" 30.0 0.0001; then
  ok "Ankunft ueber Mitternacht ergibt 00:30"
else
  nok "Ankunft: $(hole ankunft), erwartet 30"
fi

# ── 5. Warteschleifen: die beiden dokumentierten Proben ─────────────────────
[ "$(hole einflug_090_090)" = "1" ] \
  && ok "Einflug bei Kurs 090 und Anflug 090 ist direkt" \
  || nok "Einflug 090/090: $(hole einflug_090_090), erwartet 1 (direkt)"
[ "$(hole einflug_090_270)" = "2" ] \
  && ok "Einflug bei Kurs 090 und Anflug 270 ist parallel" \
  || nok "Einflug 090/270: $(hole einflug_090_270), erwartet 2 (parallel)"
[ "$(hole einflug_090_030)" = "3" ] \
  && ok "Einflug bei Kurs 090 und Anflug 030 ist versetzt" \
  || nok "Einflug 090/030: $(hole einflug_090_030), erwartet 3 (versetzt)"
[ "$(hole warte_ias_10000)" = "230.000000" ] \
  && ok "Wartegeschwindigkeit bis 14000 ft betraegt 230 kt" \
  || nok "Wartegeschwindigkeit FL100: $(hole warte_ias_10000)"
[ "$(hole schenkel_20000)" = "1.500000" ] \
  && ok "Schenkelzeit ueber 14000 ft betraegt 1,5 min" \
  || nok "Schenkelzeit FL200: $(hole schenkel_20000)"

# ── 6. Beide Seiten: Grenzfaelle muessen den Fehlerwert liefern ─────────────
#
# Ohne diesen Block waere eine Fassung, die jede Eingabe annimmt, von allem
# oben erfuellt.
fehlerfaelle="f_hoehe_zu_hoch f_negativ_cas f_kehrtwende f_bank_90 \
f_gegenwind_zu_stark f_ziel_ueber_start f_warte_mach_bereich f_druck_null"
schlecht=""
for n in $fehlerfaelle; do
  [ "$(hole "$n")" = "1" ] || schlecht="$schlecht $n"
done
if [ -z "$schlecht" ]; then
  ok "alle acht Grenzfaelle liefern den Fehlerwert"
else
  nok "diese Grenzfaelle liefern eine Zahl statt des Fehlerwerts:$schlecht"
fi

gutfaelle="g_hoehe_grenze g_bank_60 g_kursaenderung_179"
schlecht2=""
for n in $gutfaelle; do
  [ "$(hole "$n")" = "0" ] || schlecht2="$schlecht2 $n"
done
if [ -z "$schlecht2" ]; then
  ok "gueltige Eingaben an der Bereichsgrenze liefern ein Ergebnis"
else
  nok "diese gueltigen Eingaben wurden abgewiesen:$schlecht2"
fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
