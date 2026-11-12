#!/usr/bin/env bash
# tests/nn_beispiel_test.sh — examples/ml/nn_auto_mpg.lyx von vorn bis hinten.
#
# Der echte Datensatz (UCI Auto MPG) gehoert nicht zum Repository. Damit das
# Beispiel trotzdem gemessen wird, legt dieser Test eine Tabelle IM SELBEN
# FORMAT an -- Leerraumspalten, Name in Anfuehrungszeichen, einige "?" -- mit
# einem bekannten Zusammenhang zwischen Merkmalen und Ziel.
#
# Gemessen wird nicht "laeuft durch", sondern die WIRKUNG:
#   * das Netz muss den Zusammenhang finden (R2 ueber der Schwelle),
#   * die Vergleichszahl (immer den Mittelwert vorhersagen) muss deutlich
#     schlechter sein -- ohne diese zweite Haelfte waere auch ein Netz
#     bestanden, das bloss den Mittelwert gelernt hat,
#   * die Zeilen mit "?" muessen als uebersprungen gemeldet werden,
#   * das gesicherte Netz muss bitgleich zurueckkommen (das prueft das
#     Beispiel selbst und endet sonst mit rc 9).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# ---------------------------------------------------------------------------
# Tabelle bauen: 300 Zeilen, Spalten wie im Datensatz.
#   mpg = 48 - 0.004*Gewicht - 0.9*Zylinder + 0.22*(Baujahr-70) + Rauschen
# Der Zusammenhang ist nicht linear in den Merkmalen allein (Hubraum und
# Leistung haengen am Gewicht), aber klar genug, dass ein Netz ihn finden muss.
# 7 Zeilen tragen "?" in der Leistungsspalte.
# ---------------------------------------------------------------------------
awk 'BEGIN{
  srand(20261024);
  for (i = 0; i < 300; i++) {
    zyl = (i % 3 == 0) ? 4 : ((i % 3 == 1) ? 6 : 8);
    gew = 1800 + zyl * 220 + (i % 37) * 11;
    hub = zyl * 38 + (i % 11) * 3;
    ps  = zyl * 17 + (i % 13) * 2;
    bes = 20 - zyl * 0.8 + (i % 7) * 0.2;
    jahr = 70 + (i % 12);
    rausch = ((i * 7919) % 100) / 100.0 - 0.5;
    mpg = 48 - 0.004 * gew - 0.9 * zyl + 0.22 * (jahr - 70) + rausch;
    psf = (i % 43 == 5) ? "?" : sprintf("%.1f", ps);
    printf "%.1f   %d   %.1f      %s      %.0f.      %.1f   %d  1\t\"wagen %d\"\n",
           mpg, zyl, hub, psf, gew, bes, jahr, i;
  }
}' > "$TMP/synth.data"

ZEILEN=$(wc -l < "$TMP/synth.data")
FRAGE=$(grep -c '?' "$TMP/synth.data")
[ "$ZEILEN" = "300" ] && ok "Testtabelle hat 300 Zeilen" \
  || no "Testtabelle hat 300 Zeilen" "$ZEILEN"
[ "$FRAGE" -ge 5 ] && ok "Testtabelle enthaelt $FRAGE Zeilen mit '?'" \
  || no "Testtabelle enthaelt Zeilen mit '?'" "nur $FRAGE"

if ! ( cd "$ROOT" && timeout 300 "$LYXC" --std-path="$ROOT" \
        examples/ml/nn_auto_mpg.lyx -o "$TMP/demo" ) >"$TMP/bau.log" 2>&1; then
  no "examples/ml/nn_auto_mpg.lyx uebersetzt" \
     "$(grep -m1 -iE 'error|fehler' "$TMP/bau.log")"
  echo "--- $PASS PASS, $FAIL FAIL"; exit 1
fi
ok "examples/ml/nn_auto_mpg.lyx uebersetzt"

# Ohne Argument muss es die Aufrufhilfe zeigen und rc 1 melden
AUS0="$(ulimit -c 0; timeout 60 "$TMP/demo" 2>&1)"; RC0=$?
if [ "$RC0" = "1" ] && printf '%s' "$AUS0" | grep -q 'Aufruf:'; then
  ok "ohne Argument: Aufrufhilfe und rc 1"
else
  no "ohne Argument: Aufrufhilfe und rc 1" "rc=$RC0 aus='$AUS0'"
fi

# Nicht lesbare Datei wird gemeldet, nicht verschwiegen
AUSX="$(ulimit -c 0; timeout 60 "$TMP/demo" "$TMP/gibtsnicht.data" 2>&1)"; RCX=$?
if [ "$RCX" = "2" ]; then ok "fehlende Datei: rc 2"
else no "fehlende Datei: rc 2" "rc=$RCX aus='$AUSX'"; fi

AUS="$(ulimit -c 0; timeout 600 "$TMP/demo" "$TMP/synth.data" "$TMP/netz.lyxnn" 2>&1)"
RC=$?
echo "$AUS" > "$TMP/lauf.log"
if [ "$RC" != "0" ]; then
  no "Probetraining laeuft durch (rc 0 heisst auch: Modell kam bitgleich zurueck)" \
     "rc=$RC, letzte Zeilen: $(tail -3 "$TMP/lauf.log" | tr '\n' ' ')"
  echo "--- $PASS PASS, $FAIL FAIL"; exit 1
fi
ok "Probetraining laeuft durch (rc 0 heisst auch: Modell kam bitgleich zurueck)"

hol() { printf '%s\n' "$AUS" | grep -m1 "^$1" | sed 's/.*: *//'; }

# Uebersprungene Zeilen: genau die mit "?"
UEBER="$(printf '%s\n' "$AUS" | grep -m1 'uebersprungen:' | sed 's/.*uebersprungen: *//; s/).*//')"
[ "$UEBER" = "$FRAGE" ] && ok "alle $FRAGE Zeilen mit '?' werden als uebersprungen gemeldet" \
  || no "Zeilen mit '?' werden als uebersprungen gemeldet" "gemeldet '$UEBER', erwartet '$FRAGE'"

NETZ_R2="$(hol 'Netz      R2')"
NETZ_MAE="$(hol 'Netz      MAE')"
MW_R2="$(hol 'Mittelwert R2')"
MW_MAE="$(hol 'Mittelwert MAE')"

# Beide Seiten messen: das Netz muss gut sein UND besser als die
# Vergleichszahl. Eine Schwelle allein waere auch von einem Netz erfuellt,
# das den Mittelwert gelernt hat -- dessen R2 liegt bei 0.
if awk "BEGIN{exit !($NETZ_R2 > 0.9)}"; then
  ok "Netz findet den Zusammenhang (R2 $NETZ_R2 > 0.9)"
else
  no "Netz findet den Zusammenhang" "R2 $NETZ_R2 <= 0.9"
fi
if awk "BEGIN{exit !($MW_R2 < 0.05)}"; then
  ok "Vergleichszahl liegt bei null (R2 $MW_R2 < 0.05)"
else
  no "Vergleichszahl liegt bei null" "R2 $MW_R2 >= 0.05"
fi
if awk "BEGIN{exit !($NETZ_MAE < $MW_MAE / 3.0)}"; then
  ok "MAE des Netzes ($NETZ_MAE) unter einem Drittel der Vergleichszahl ($MW_MAE)"
else
  no "MAE des Netzes unter einem Drittel der Vergleichszahl" \
     "Netz $NETZ_MAE, Mittelwert $MW_MAE"
fi

# Das Abbruchkriterium muss greifen, nicht bis maxEpochs laufen
EP="$(printf '%s\n' "$AUS" | grep -m1 '^Epochen gelaufen' | sed 's/.*: *//')"
if [ -n "$EP" ] && [ "$EP" -lt 300 ] && [ "$EP" -gt 0 ]; then
  ok "Abbruchkriterium greift (nach $EP von hoechstens 300 Epochen)"
else
  no "Abbruchkriterium greift" "Epochen '$EP'"
fi

# Modelldatei entstanden und von der gemeldeten Groesse
BYTES="$(printf '%s\n' "$AUS" | grep -m1 'Modell gesichert' | sed 's/.*(\([0-9]*\) Byte).*/\1/')"
if [ -f "$TMP/netz.lyxnn" ] && [ "$(stat -c%s "$TMP/netz.lyxnn")" = "$BYTES" ]; then
  ok "Modelldatei hat die gemeldeten $BYTES Byte"
else
  no "Modelldatei hat die gemeldete Groesse" \
     "gemeldet '$BYTES', auf der Platte '$(stat -c%s "$TMP/netz.lyxnn" 2>/dev/null)'"
fi

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
