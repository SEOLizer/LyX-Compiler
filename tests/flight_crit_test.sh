#!/usr/bin/env bash
# tests/flight_crit_test.sh — #1140: `@flight_crit` schaltet die FPU-Traps frei.
#
# `sprache/datentypen.txt` sagt zu: in @flight_crit-Code loest jede entstehende
# NaN/Inf-Operation panic aus statt still weiterzulaufen. Bis 1.0.14L geschah
# nichts -- das Attribut war ein blosser Vermerk (#1099), `1.0 / 0.0` lieferte
# still +Inf.
#
# UMSETZUNG: MXCSR. Beim Eintritt in die annotierte Funktion werden die Masken
# fuer *invalid* (Bit 7) und *divide-by-zero* (Bit 9) geloescht, beim Verlassen
# wird der alte Wert zurueckgeschrieben. Der ausgeloeste SIGFPE trifft einen
# Handler, den der Compiler mitgibt; ohne ihn staerbe das Programm wortlos.
#
# REICHWEITE: MXCSR ist THREAD-Zustand. Ab dem Eintritt gilt der Trap deshalb
# auch fuer alles, was die Funktion RUFT -- bis sie zurueckkehrt. Genau das
# pruefen die Faelle "gerufene Funktion" und "nach der Rueckkehr".
#
# Der Test misst das VERHALTEN: Meldung, Exit-Code und die Gegenprobe, dass
# dasselbe Programm ohne das Attribut unveraendert durchlaeuft. Ohne diese
# Gegenprobe waere die Wirkung nicht dem Attribut zuzuordnen.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

# baut und fuehrt aus; erwartet Trap: Meldungsteil + Exit-Code 134
traps() { # name, quelltext, erwarteter meldungsteil
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    echo "FAIL $1: uebersetzt nicht"; FAIL=$((FAIL+1)); return
  fi
  got="$(timeout 10 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -ne 134 ]; then
    echo "FAIL $1: Exit $rc erwartet 134 — Ausgabe: $got"; FAIL=$((FAIL+1)); return
  fi
  case "$got" in
    *"$3"*) echo "PASS $1"; PASS=$((PASS+1)) ;;
    *) echo "FAIL $1: Meldung ohne '$3' — war: $got"; FAIL=$((FAIL+1)) ;;
  esac
}

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    echo "FAIL $1: uebersetzt nicht"; FAIL=$((FAIL+1)); return
  fi
  got="$(timeout 10 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then echo "FAIL $1: ABSTURZ (rc=$rc)"; FAIL=$((FAIL+1)); return; fi
  if [ "$got" = "$3" ]; then echo "PASS $1"; PASS=$((PASS+1))
  else echo "FAIL $1: '$got' erwartet '$3'"; FAIL=$((FAIL+1)); fi
}

K='import src.std.io;'

# --- Der Repro aus dem Issue ---------------------------------------------
traps "Repro: 1.0/0.0 unter @flight_crit" "$K
@flight_crit
fn F(): f64 { var z: f64 := 0.0; return 1.0 / z; }
fn main(): int64 { var r: f64 := F(); PrintStrLn(\"kein Trap\"); return 0; }" \
  "FPU-Ausnahme"

# Die Meldung nennt die Funktion — bei mehreren @flight_crit-Funktionen waere
# sie sonst nicht zu gebrauchen.
traps "Meldung nennt die Funktion" "$K
@flight_crit
fn Harmlos(a: f64): f64 { return a + 1.0; }
@flight_crit
fn Schuldig(): f64 { var z: f64 := 0.0; return 1.0 / z; }
fn main(): int64 { var h: f64 := Harmlos(1.0); var r: f64 := Schuldig(); PrintStrLn(\"kein Trap\"); return 0; }" \
  "unter @flight_crit in \`Schuldig\`"

# 0.0/0.0 ist *invalid*, nicht divide-by-zero — die zweite freigeschaltete Maske.
traps "NaN aus 0.0/0.0 (invalid)" "$K
@flight_crit
fn F(): f64 { var z: f64 := 0.0; return z / z; }
fn main(): int64 { var r: f64 := F(); PrintStrLn(\"kein Trap\"); return 0; }" \
  "FPU-Ausnahme"

# --- Reichweite: MXCSR ist Thread-Zustand --------------------------------
# Die gerufene Funktion traegt selbst kein Attribut, rechnet aber im
# freigeschalteten Zustand — das ist die zugesagte Wirkung.
traps "gerufene Funktion wird mitgetrappt" "$K
fn Hilf(x: f64): f64 { var z: f64 := 0.0; return x / z; }
@flight_crit
fn F(): f64 { return Hilf(1.0); }
fn main(): int64 { var r: f64 := F(); PrintStrLn(\"kein Trap\"); return 0; }" \
  "in \`F\`"

# Nach der Rueckkehr ist der alte MXCSR zurueck: dieselbe Rechnung in main
# laeuft still durch. Ohne diese Pruefung koennte der Prolog die Maske dauerhaft
# umstellen, ohne dass es auffiele.
out "nach der Rueckkehr wieder maskiert" "$K
@flight_crit
fn F(a: f64): f64 { return a * 2.0; }
fn main(): int64 {
    var ok: f64 := F(1.5);
    var z: f64 := 0.0;
    var r: f64 := 1.0 / z;
    PrintStrLn(\"still\");
    return 0;
}" 'still'

# Schachtelung: die innere Funktion meldet sich, die aeussere hat ihren Zustand
# vorher gesichert.
traps "zwei @flight_crit-Funktionen ineinander" "$K
@flight_crit
fn Innen(): f64 { var z: f64 := 0.0; return 1.0 / z; }
@flight_crit
fn Aussen(): f64 { return Innen(); }
fn main(): int64 { var r: f64 := Aussen(); PrintStrLn(\"kein Trap\"); return 0; }" \
  "in \`Innen\`"

# --- Methoden ------------------------------------------------------------
# Am Methodenknoten belegen die Modifier-Bits die iVal; ohne eigenen Zweig
# waere das Attribut dort angenommen und wirkungslos.
traps "Methode mit @flight_crit" "$K
type C = class { v: int64;
  @flight_crit
  fn G(): f64 { var z: f64 := 0.0; return 1.0 / z; }
};
fn main(): int64 { var c: C := new C(); var r: f64 := c.G(); PrintStrLn(\"kein Trap\"); return 0; }" \
  "in \`G\`"

# --- Ganzzahlige Division durch 0 ----------------------------------------
# SIGFPE kommt auch von #DE. Der Handler faengt das mit ab; die Meldung nennt
# deshalb beide Anlaesse und behauptet nicht "nur NaN/Inf".
traps "ganzzahlige Division durch 0" "$K
@flight_crit
fn F(a: int64): int64 { var z: int64 := 0; return a / z; }
fn main(): int64 { PrintLn(F(7)); return 0; }" \
  "oder Division durch 0"

# --- Gegenproben: ohne das Attribut aendert sich nichts ------------------
out "dieselbe Funktion ohne @flight_crit" "$K
fn F(): f64 { var z: f64 := 0.0; return 1.0 / z; }
fn main(): int64 { var r: f64 := F(); PrintStrLn(\"kein Trap\"); return 0; }" 'kein Trap'

out "NaN ohne Attribut bleibt still" "$K
fn F(): f64 { var z: f64 := 0.0; return z / z; }
fn main(): int64 { var n: f64 := F(); if (n != n) { PrintStrLn(\"NaN selbst erkannt\"); } return 0; }" \
  'NaN selbst erkannt'

# Gewoehnliche Gleitkommarechnung unter dem Attribut laeuft unveraendert.
out "normale f64-Rechnung unter @flight_crit" "$K
@flight_crit
fn F(a: f64): f64 { return a * 2.0 + 1.0; }
fn main(): int64 { PrintLn(F(20.5) as int64); return 0; }" '42'

# Ueberlauf ist eine ANDERE Ausnahme (Bit 10) und bleibt maskiert — das
# Attribut sagt NaN/Inf zu, nicht jede IEEE-Ausnahme.
out "Ueberlauf bleibt maskiert" "$K
@flight_crit
fn F(): f64 { var a: f64 := 1.0e308; return a * 10.0; }
fn main(): int64 { var r: f64 := F(); PrintStrLn(\"Overflow bleibt still\"); return 0; }" \
  'Overflow bleibt still'

# Ein Programm ganz ohne das Attribut bekommt weder Handler noch MXCSR-Code.
out "Programm ohne @flight_crit unveraendert" "$K
fn Rechne(a: f64, b: f64): f64 { return a / b; }
fn main(): int64 { PrintLn(Rechne(84.0, 2.0) as int64); return 0; }" '42'

# --- Der Vermerk aus #1099 ist weg ---------------------------------------
printf '%s\n' "$K
@flight_crit
fn F(a: f64): f64 { return a + 1.0; }
fn main(): int64 { PrintLn(F(41.0) as int64); return 0; }" > "$TMP/w.lyx"
wmsg="$("$LYXC" --std-path="$ROOT" "$TMP/w.lyx" -o "$TMP/w" 2>&1)"
case "$wmsg" in
  *"@flight_crit: die Zusicherung wird vom Compiler NICHT nachgewiesen"*)
    echo "FAIL Vermerk 'nicht nachgewiesen' ist weg: steht noch da"; FAIL=$((FAIL+1)) ;;
  *) echo "PASS Vermerk 'nicht nachgewiesen' ist weg"; PASS=$((PASS+1)) ;;
esac

# @integrity meldet seit 1.1.15A (#1878) NICHT mehr — es wird nachgewiesen.
# `@dal` bleibt als Vertreter der unbewiesenen Attribute stehen, sonst pruefte
# der Block nur noch eine leere Menge.
printf '%s\n' "$K
@dal(A)
fn F(): int64 { return 1; }
fn main(): int64 { return F(); }" > "$TMP/v.lyx"
vmsg="$("$LYXC" --std-path="$ROOT" "$TMP/v.lyx" -o "$TMP/v" 2>&1)"
case "$vmsg" in
  *"NICHT nachgewiesen"*) echo "PASS @dal meldet weiterhin"; PASS=$((PASS+1)) ;;
  *) echo "FAIL @dal meldet weiterhin: Meldung fehlt"; FAIL=$((FAIL+1)) ;;
esac

printf '%s\n' "$K
@integrity(mode: software_lockstep)
fn F(): int64 { return 1; }
fn main(): int64 { return F(); }" > "$TMP/w.lyx"
wmsg="$("$LYXC" --std-path="$ROOT" "$TMP/w.lyx" -o "$TMP/w" 2>&1)"
case "$wmsg" in
  *"NICHT nachgewiesen"*) echo "FAIL @integrity meldet nicht mehr: Meldung steht noch da"; FAIL=$((FAIL+1)) ;;
  *) echo "PASS @integrity meldet nicht mehr (#1878)"; PASS=$((PASS+1)) ;;
esac

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
test "$FAIL" -eq 0
