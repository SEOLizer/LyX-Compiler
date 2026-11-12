#!/usr/bin/env bash
# tests/bounds_check_directive_test.sh — #1124: `@bounds_check(true)` wirkt.
#
# Die Direktive war wirkungslos: dieselbe Ausgabe, dieselbe Binary wie ohne
# sie. Die Ursache steckte im Vorgabewert — `boundsCheckEnabled` steht auf 1,
# "an" liess sich davon also nicht unterscheiden, und der Emissionszweig fragte
# nur ab, ob jemand ABGESCHALTET hat. Die Pruefung selbst haengt an
# `--runtime-checks` (#1156); wer die Direktive setzte, bekam ohne die Option
# nichts.
#
# Behoben ueber ein zweites Feld `boundsCheckForced`: `@bounds_check(true)`
# FORDERT die Pruefung an und wirkt damit auch ohne `--runtime-checks`.
# `@bounds_check(false)` schaltet weiterhin ab, auch WENN die Option gesetzt
# ist — die Direktive steht naeher am Code.
#
# Geprueft wird das VERHALTEN des uebersetzten Programms (bricht der Zugriff
# ausserhalb ab?), nicht die Groesse der Binary.
#
# Nicht Teil dieses Tests, weil laengst vorhanden: die Pruefung eines
# KONSTANTEN Index zur Uebersetzungszeit (sema, ohne Schalter) — dafuer gibt es
# tests/index_bounds_test.sh aus #1156.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

# Der Zugriff ausserhalb muss mit panic abbrechen.
panics() { # name, quelltext, flags
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! "$LYXC" --std-path="$ROOT" $3 "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    echo "FAIL $1: uebersetzt nicht"; FAIL=$((FAIL+1)); return
  fi
  got="$(timeout 10 "$TMP/c" 2>&1)"; rc=$?
  case "$got" in
    *"index out of bounds"*) echo "PASS $1"; PASS=$((PASS+1)) ;;
    *) echo "FAIL $1: kein panic (rc=$rc, '$got')"; FAIL=$((FAIL+1)) ;;
  esac
}

# Das Programm laeuft durch und gibt das Erwartete aus.
out() { # name, quelltext, erwartete ausgabe, flags
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! "$LYXC" --std-path="$ROOT" $4 "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    echo "FAIL $1: uebersetzt nicht"; FAIL=$((FAIL+1)); return
  fi
  got="$(timeout 10 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then echo "FAIL $1: ABSTURZ (rc=$rc)"; FAIL=$((FAIL+1)); return; fi
  if [ "$got" = "$3" ]; then echo "PASS $1"; PASS=$((PASS+1))
  else echo "FAIL $1: '$got' erwartet '$3'"; FAIL=$((FAIL+1)); fi
}

fails() { # name, quelltext, erwarteter meldungsteil
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  msg="$("$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)"
  if [ -f "$TMP/c" ]; then echo "FAIL $1: uebersetzt, statt zu melden"; FAIL=$((FAIL+1)); return; fi
  case "$msg" in
    *"$3"*) echo "PASS $1"; PASS=$((PASS+1)) ;;
    *) echo "FAIL $1: Meldung ohne '$3'"; FAIL=$((FAIL+1)) ;;
  esac
}

K='import src.std.io;'

# --- Der Repro aus dem Issue: die Direktive allein, ohne Option -----------
panics "Repro: @bounds_check(true) ohne --runtime-checks" "$K
@bounds_check(true);
fn main(): int64 { var a: int64[4]; var i: int64 := 9; a[i] := 42; PrintLn(1); return 0; }" ""

# Ein negativer Index faellt in denselben Zweig (der Vergleich ist unsigned).
panics "negativer Index" "$K
@bounds_check(true);
fn main(): int64 { var a: int64[4]; var i: int64 := 0 - 1; a[i] := 1; PrintLn(1); return 0; }" ""

panics "Lesezugriff ausserhalb" "$K
@bounds_check(true);
fn main(): int64 { var a: int64[4]; var i: int64 := 7; PrintLn(a[i]); return 0; }" ""

# Dynamisches Array: die Laenge steht im {cap,len}-Kopf, nicht als Immediate.
panics "dynamisches Array" "$K
@bounds_check(true);
fn main(): int64 { var a: int64[]; push(a, 1); var i: int64 := 5; PrintLn(a[i]); return 0; }" ""

# Die Direktive gilt auch auf Anweisungsebene, nicht nur am Dateikopf.
panics "@bounds_check(true) auf Anweisungsebene" "$K
fn main(): int64 { @bounds_check(true); var a: int64[4]; var i: int64 := 9; a[i] := 42; PrintLn(1); return 0; }" ""

# --- Der gueltige Fall darf nicht abbrechen ------------------------------
out "gueltiger Index laeuft" "$K
@bounds_check(true);
fn main(): int64 { var a: int64[4]; var i: int64 := 2; a[i] := 42; PrintLn(a[i]); return 0; }" '42' ""

out "letzter gueltiger Index" "$K
@bounds_check(true);
fn main(): int64 { var a: int64[4]; var i: int64 := 3; a[i] := 7; PrintLn(a[i]); return 0; }" '7' ""

out "Schleife ueber das ganze Array" "$K
@bounds_check(true);
fn main(): int64 { var a: int64[4]; var i: int64 := 0; while (i < 4) { a[i] := i; i := i + 1; } PrintLn(a[3]); return 0; }" '3' ""

# --- @bounds_check(false) schlaegt die Option ----------------------------
# Wer sie ausdruecklich abschaltet, bekommt sie nicht ueber --runtime-checks
# zurueck: die Direktive steht naeher am Code.
out "@bounds_check(false) mit --runtime-checks" "$K
@bounds_check(false);
fn main(): int64 { var a: int64[4]; var i: int64 := 9; a[i] := 42; PrintLn(1); return 0; }" '1' "--runtime-checks"

# --- Gegenproben: der Vorzustand bleibt ----------------------------------
# OHNE Direktive und OHNE Option wird weiterhin nicht geprueft. Das ist die
# dokumentierte Vorgabe (§20.1) und keine Regression.
out "ohne Direktive und ohne Option ungeprueft" "$K
fn main(): int64 { var a: int64[4]; var i: int64 := 9; a[i] := 42; PrintLn(1); return 0; }" '1' ""

panics "--runtime-checks allein unveraendert (#1156)" "$K
fn main(): int64 { var a: int64[4]; var i: int64 := 9; a[i] := 42; PrintLn(1); return 0; }" "--runtime-checks"

# Ein KONSTANTER Index ausserhalb wird weiterhin zur Uebersetzungszeit
# abgewiesen — ohne Schalter, ohne Direktive (#1156).
fails "konstanter Index wird uebersetzungszeit-abgewiesen" "$K
fn main(): int64 { var a: int64[4]; PrintLn(a[9]); return 0; }" "ausserhalb des Arrays"

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
test "$FAIL" -eq 0
