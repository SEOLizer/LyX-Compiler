#!/usr/bin/env bash
# tests/utype_test.sh — #1110: Einheitentypen (§11) haben Semantik.
#
# `dim` und `utype` wurden geparst und bewirkten nichts: der Faktor blieb
# folgenlos, eine Laenge liess sich in eine Zeit zuweisen, eine rohe Zahl
# mischte sich kommentarlos darunter, und `range`/`wraps` scheiterten am
# Parser. In der Form war `utype` ein Typalias mit dekorativem Faktor — fuer
# die Fehlerklasse, gegen die Einheitentypen antreten (Mars Climate Orbiter),
# also irrefuehrend.
#
# Geprueft wird das VERHALTEN: der umgerechnete Wert, die Meldung bei
# Dimensionsfehlern, der Abbruch bzw. das Umrechnen an den Grenzen. Ein Test
# auf Uebersetzbarkeit waere bei jedem Punkt gruen gewesen.
#
# Die Gegenproben gehoeren dazu: ein Literal muss sich einer Einheit zuweisen
# lassen, `a * 3` muss erlaubt bleiben, und der `as`-Cast muss aus der Pruefung
# herausfuehren. Ohne sie waere eine Pruefung, die alles abweist, ebenso gruen.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

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

rejects() { # name, quelltext, erwartete meldung
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  got=$("$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)
  if ! echo "$got" | grep -q "$3"; then
    echo "FAIL $1: nicht abgewiesen — '$(echo "$got" | grep -iE 'error' | head -1)'"; FAIL=$((FAIL+1)); return
  fi
  if [ -f "$TMP/c" ]; then
    echo "FAIL $1: gemeldet, aber trotzdem uebersetzt"; FAIL=$((FAIL+1)); return
  fi
  echo "PASS $1 (abgewiesen)"; PASS=$((PASS+1))
}

panics() { # name, quelltext
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    echo "FAIL $1: uebersetzt nicht"; FAIL=$((FAIL+1)); return
  fi
  got="$(timeout 10 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then echo "FAIL $1: laeuft durch (rc=0)"; FAIL=$((FAIL+1)); return; fi
  if echo "$got" | grep -q "weiter"; then
    echo "FAIL $1: rechnet nach dem Fehler weiter"; FAIL=$((FAIL+1)); return
  fi
  if echo "$got" | grep -q "unit value out of range"; then
    echo "PASS $1 (bricht ab)"; PASS=$((PASS+1))
  else
    echo "FAIL $1: bricht ab, aber ohne Bereichsmeldung — '$(echo "$got" | tail -1)'"; FAIL=$((FAIL+1))
  fi
}

K='import src.std.io;
dim Meter;
utype Km: Meter = 1000;
utype M: Meter = 1;
dim Sekunde;
utype S: Sekunde = 1;'

# --- 1. Konversionsfaktor wirkt -------------------------------------------
out "Repro: Km nach M multipliziert" "$K
fn main(): int64 {
    var a: Km := 2;
    var b: M := a;
    PrintLn(b as int64);
    return 0;
}" '2000'

# Die andere Richtung schneidet ab, wie die Ganzzahldivision sonst auch.
out "M nach Km schneidet ab" "$K
fn main(): int64 {
    var c: M := 2500;
    var d: Km := c;
    PrintLn(d as int64);
    return 0;
}" '2'

out "gleiche Einheit rechnet nicht um" "$K
fn main(): int64 {
    var a: Km := 7;
    var b: Km := a;
    PrintLn(b as int64);
    return 0;
}" '7'

out "Umrechnung auch bei spaeterer Zuweisung" "$K
fn main(): int64 {
    var a: Km := 3;
    var b: M := 0;
    b := a;
    PrintLn(b as int64);
    return 0;
}" '3000'

# --- 2. Dimensionen werden geprueft ---------------------------------------
rejects "Laenge in eine Zeit zugewiesen" "$K
fn main(): int64 {
    var a: Km := 2;
    var t: S := a;
    return 0;
}" "Dimensionsgrenzen"

rejects "Einheit mit roher Zahl addiert" "$K
fn main(): int64 {
    var a: Km := 2;
    var r: int64 := 5;
    PrintLn(a + r);
    return 0;
}" "dimensionsloser Zahl"

rejects "zwei Dimensionen addiert" "$K
fn main(): int64 {
    var a: Km := 2;
    var t: S := 1;
    PrintLn(a + t);
    return 0;
}" "verschiedener Dimension"

rejects "Einheit an dimensionslosen Typ" "$K
fn main(): int64 {
    var a: Km := 2;
    var r: int64 := a;
    return 0;
}" "dimensionslosen Typ"

# --- 3. range und wraps ---------------------------------------------------
# Beide Formen parsten bis 1.0.13D gar nicht ("expected ;, got IDENT 'range'").
out "wraps rechnet in den Bereich" 'import src.std.io;
dim G;
utype Deg: G = 1 wraps 0..359;
fn calc(): int64 { return 400; }
fn main(): int64 {
    var w: Deg := calc();
    PrintLn(w as int64);
    return 0;
}' '40'

out "wraps auch nach unten" 'import src.std.io;
dim G;
utype Deg: G = 1 wraps 0..359;
fn neg(): int64 { return 0 - 10; }
fn main(): int64 {
    var w: Deg := neg();
    PrintLn(w as int64);
    return 0;
}' '350'

panics "range bricht ausserhalb ab" 'import src.std.io;
dim G;
utype Pct: G = 1 range 0..100;
fn calc(): int64 { return 150; }
fn main(): int64 {
    var p: Pct := calc();
    PrintLn("weiter");
    return 0;
}'

out "range innerhalb laeuft durch" 'import src.std.io;
dim G;
utype Pct: G = 1 range 0..100;
fn calc(): int64 { return 50; }
fn main(): int64 {
    var p: Pct := calc();
    PrintLn(p as int64);
    return 0;
}' '50'

# Steht der Wert fest, meldet der Compiler ihn — wie beim Bereichstyp (#1082).
rejects "konstanter Wert ausserhalb der Grenzen" 'import src.std.io;
dim G;
utype Pct: G = 1 range 0..100;
fn main(): int64 {
    var p: Pct := 150;
    return 0;
}' "ausserhalb der Grenzen"

rejects "verdrehte Grenzen" 'dim G;
utype H: G = 1 range 360..0;
fn main(): int64 { return 0; }' "obere Grenze liegt unter"

# --- 4. Gegenproben -------------------------------------------------------
# Ein Literal muss sich zuweisen lassen, sonst waere die Einheit unbenutzbar.
out "Literal an eine Einheit" "$K
fn main(): int64 {
    var a: Km := 42;
    PrintLn(a as int64);
    return 0;
}" '42'

# Skalieren mit einer Zahl bleibt erlaubt: das Ergebnis behaelt die Einheit.
out "Skalierung mit einer Zahl" "$K
fn main(): int64 {
    var a: Km := 2;
    var e: Km := a * 3;
    PrintLn(e as int64);
    return 0;
}" '6'

# Der as-Cast fuehrt aus der Pruefung heraus — der bewusste Fluchtweg.
out "as-Cast fuehrt heraus" "$K
fn main(): int64 {
    var a: Km := 2;
    var r: int64 := 5;
    PrintLn((a as int64) + r);
    return 0;
}" '7'

# dim und utype ohne Grenzen verhalten sich wie bisher.
out "dim mit abgeleiteter Dimension uebersetzt" 'import src.std.io;
dim Meter;
dim Second;
dim Speed = Meter / Second;
utype Mps: Speed = 1;
fn main(): int64 {
    var v: Mps := 12;
    PrintLn(v as int64);
    return 0;
}' '12'

# ===========================================================================
# #1955 Befund 2 — die Umrechnung verlor die Nachkommastellen
# ===========================================================================
#
# Bis 1.2.1A rechneten Einheitenwerte ganzzahlig (#1358). Damit war nicht nur
# `1250.5 m` unschreibbar, sondern die UMRECHNUNG selbst verlustbehaftet:
# 2500 m nach km ergab 2 statt 2.5, weil `wert * zaehler / nenner` als
# Ganzzahldivision lief. Fuer eine Einheitenbibliothek ist das der Kern —
# genau die Umrechnung, wegen der man Einheitentypen ueberhaupt benutzt.
#
# Gemessen wird deshalb der WERT nach der Umrechnung, in beide Richtungen.
# Ein Test, der nur "uebersetzt" prueft, waere auch von der alten,
# abschneidenden Rechnung erfuellt gewesen.
out "Umrechnung nach oben behaelt die Nachkommastellen" 'import std.io;
dim Length;
utype M: Length = 1.0;
utype Km: Length = 1000.0;
fn main(): int64 {
    var a: M := 2500;
    var b: Km := a;
    PrintLn(FloatToStr(b as f64, 4));
    return 0;
}' '2.5000'

out "Umrechnung nach unten rechnet ebenso" 'import std.io;
dim Length;
utype M: Length = 1.0;
utype Km: Length = 1000.0;
fn main(): int64 {
    var c: Km := 1;
    var d: M := c;
    PrintLn(FloatToStr(d as f64, 1));
    return 0;
}' '1000.0'

out "gebrochener Wert ueberlebt die Umrechnung" 'import std.io;
dim Length;
utype M: Length = 1.0;
utype Km: Length = 1000.0;
fn main(): int64 {
    var a: M := 1250.5;
    var b: Km := a;
    PrintLn(FloatToStr(b as f64, 4));
    return 0;
}' '1.2505'

# Der Faktor bleibt ein BRUCH (#1158). Bei 0.017453 ist das nachweisbar:
# 1000 deg sind 17.453 rad — ein eingefrorener, gerundeter Gleitkommafaktor
# traefe die vierte Stelle nicht mehr.
out "Bruchfaktor rechnet exakt weiter" 'import std.io;
dim Winkel;
utype Rad: Winkel = 1.0;
utype Deg: Winkel = 0.017453;
fn main(): int64 {
    var w: Deg := 1000;
    var r: Rad := w;
    PrintLn(FloatToStr(r as f64, 4));
    return 0;
}' '17.4530'

# Und die Grenzen muessen auf GEBROCHENEN Werten weiter greifen. Sie werden im
# Codegen unmittelbar neben der Umrechnung durchgesetzt; bliebe dort der
# ganzzahlige Vergleich stehen, verglichen sie ab jetzt IEEE-Bitmuster statt
# Zahlen und liessen stillschweigend alles durch.
panics "range greift auch bei gebrochenem Wert" 'import std.io;
dim G;
utype Pct: G = 1 range 0..100;
fn calc(): f64 { return 100.5; }
fn main(): int64 {
    var p: Pct := calc();
    PrintLn("weiter");
    return 0;
}'

out "range laesst den gebrochenen Wert INNERHALB durch" 'import std.io;
dim G;
utype Pct: G = 1 range 0..100;
fn calc(): f64 { return 99.5; }
fn main(): int64 {
    var p: Pct := calc();
    PrintLn(FloatToStr(p as f64, 1));
    return 0;
}' '99.5'

out "wraps rechnet einen gebrochenen Wert in den Bereich" 'import std.io;
dim G;
utype Deg: G = 1 wraps 0..359;
fn calc(): f64 { return 400.5; }
fn main(): int64 {
    var w: Deg := calc();
    PrintLn(FloatToStr(w as f64, 1));
    return 0;
}' '40.5'

out "wraps auch nach unten mit Nachkomma" 'import std.io;
dim G;
utype Deg: G = 1 wraps 0..359;
fn calc(): f64 { return 0.0 - 0.5; }
fn main(): int64 {
    var w: Deg := calc();
    PrintLn(FloatToStr(w as f64, 1));
    return 0;
}' '359.5'

# ===========================================================================
# #1963 — die Umrechnung kannte nur EINE Herkunft
# ===========================================================================
#
# cg_utypeOfExpr sah nur den Bezeichner; bei Cast, Aufrufergebnis und
# Feldzugriff lieferte sie -1, und cg_emitUtypeConv kehrte daraufhin STUMM
# zurueck. `var b: Km := a;` ergab 2.5, `var b: Km := a as Km;` dagegen 2500 —
# kein Fehler, keine Meldung, nur eine falsche Zahl, die wie eine gueltige
# Groesse aussieht.
#
# Geprueft wird jede Herkunft EINZELN und am WERT. Ein Test, der nur eine
# davon misst, waere von genau dem Zustand erfuellt gewesen, der hier behoben
# wird.
out "Umrechnung aus einem Bezeichner" 'import std.io;
dim Length;
utype M: Length = 1.0;
utype Km: Length = 1000.0;
fn main(): int64 {
    var a: M := 2500;
    var b: Km := a;
    PrintLn(FloatToStr(b as f64, 4));
    return 0;
}' '2.5000'

out "Umrechnung im as-Cast" 'import std.io;
dim Length;
utype M: Length = 1.0;
utype Km: Length = 1000.0;
fn main(): int64 {
    var a: M := 2500;
    var b: Km := a as Km;
    PrintLn(FloatToStr(b as f64, 4));
    return 0;
}' '2.5000'

out "Umrechnung aus einem Aufrufergebnis" 'import std.io;
dim Length;
utype M: Length = 1.0;
utype Km: Length = 1000.0;
fn hoehe(): M { return 2500; }
fn main(): int64 {
    var b: Km := hoehe();
    PrintLn(FloatToStr(b as f64, 4));
    return 0;
}' '2.5000'

out "Umrechnung aus einem Feldzugriff" 'import std.io;
dim Length;
utype M: Length = 1.0;
utype Km: Length = 1000.0;
type Strecke = struct { s: M; };
fn main(): int64 {
    var st: Strecke;
    st.s := 2500;
    var b: Km := st.s;
    PrintLn(FloatToStr(b as f64, 4));
    return 0;
}' '2.5000'

# Ein Feld mit Einheitentyp muss den Wert auch als ZAHL halten. Stuende dort
# das rohe Bitmuster der Ganzzahl, lieferte das Lesen 1,2e-320 — formatiert
# 0.00, also eine Null, die nach einem Rechenfehler aussieht statt nach einem
# Speicherfehler.
out "Feld mit Einheitentyp haelt den Wert" 'import std.io;
dim Length;
utype M: Length = 1.0;
type Strecke = struct { s: M; };
fn main(): int64 {
    var st: Strecke;
    st.s := 1250.5;
    PrintLn(FloatToStr(st.s as f64, 1));
    return 0;
}' '1250.5'

# GEGENPROBE: gleiche Einheit heisst KEINE Rechnung. Ohne diese Pruefung waere
# der Test auch von einer Fassung erfuellt, die bei jedem Cast irgendeinen
# Faktor anwendet.
out "gleiche Einheit bleibt unveraendert" 'import std.io;
dim Length;
utype M: Length = 1.0;
fn main(): int64 {
    var a: M := 2500;
    var b: M := a as M;
    PrintLn(FloatToStr(b as f64, 1));
    return 0;
}' '2500.0'

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
test "$FAIL" -eq 0
