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
# lassen, `a * 3` muss erlaubt bleiben, und der `as`-Cast auf einen Typ OHNE
# Einheit (`as int64`, `as f64`) muss weiter herausfuehren. Ohne sie waere eine
# Pruefung, die alles abweist, ebenso gruen.
#
# #1964 hat diesen Fluchtweg VERENGT: ein `as` zwischen zwei Einheiten
# verschiedener Dimension wird jetzt gemeldet. Es sah aus wie eine Umwandlung
# und war eine Umdeutung — zwischen zwei Dimensionen gibt es keinen Faktor,
# `t as M` behielt den Zahlenwert bei und machte aus 5 Sekunden 5 Meter. Damit
# war die schuetzende Haelfte des Systems einen Tastendruck entfernt. Der Weg
# ueber einen dimensionslosen Typ bleibt offen: sichtbar und nachlesbar.

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

# Der as-Cast auf einen Typ OHNE Einheit fuehrt weiter heraus — der bewusste
# Fluchtweg. #1964 hat nur den Cast ZWISCHEN Dimensionen geschlossen.
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

# ── #1964: `as` ueber eine Dimensionsgrenze ───────────────────────────────
#
# Die Zuweisung ueber Dimensionsgrenzen wurde zuverlaessig gemeldet; der Cast
# umging die Pruefung vollstaendig, weil _typeMismatch bei SNK_CAST sofort
# aussteigt. Fuer Breiten und Zeiger ist diese Begruendung richtig — bei
# Einheiten nicht: zwischen zwei Dimensionen gibt es keinen Faktor, den der
# Cast anwenden koennte.
#
# GEMESSEN WIRD BEIDES. Ein Test, der nur die Ablehnung prueft, waere auch von
# einer Fassung erfuellt, die JEDEN Einheiten-Cast verbietet — und die haette
# die Umrechnung aus #1963 mit erschlagen.
D2='import std.io;
dim Length;
dim Zeit;
utype M: Length = 1.0;
utype KM: Length = 1000.0;
utype Sek: Zeit = 1.0;'

rejects "#1964: Cast ueber die Dimensionsgrenze wird gemeldet" "$D2
fn main(): int64 {
    var t: Sek := 5;
    var falsch: M := t as M;
    return falsch as int64;
}" "Cast ueber Dimensionsgrenzen"

# Die Meldung muss den Ausweg NENNEN, sonst steht der Nutzer davor.
rejects "#1964: die Meldung nennt den Weg ueber f64" "$D2
fn main(): int64 {
    var t: Sek := 5;
    var falsch: M := t as M;
    return falsch as int64;
}" "as f64"

# GEGENPROBE 1: gleiche Dimension geht durch UND rechnet um (seit #1963).
out "#1964: gleiche Dimension rechnet weiter um" "$D2
fn main(): int64 {
    var a: KM := 2;
    var b: M := a as M;
    PrintLn(FloatToStr(b as f64, 1));
    return 0;
}" '2000.0'

# GEGENPROBE 2: der Weg ueber einen dimensionslosen Typ bleibt offen.
out "#1964: der Fluchtweg ueber f64 bleibt offen" "$D2
fn main(): int64 {
    var a: M := 2500;
    var roh: f64 := a as f64;
    var b: M := roh as M;
    PrintLn(FloatToStr(b as f64, 1));
    return 0;
}" '2500.0'

# GEGENPROBE 3: ein Ziel ohne Einheit wird nicht bemaengelt.
out "#1964: Cast auf int64 bleibt unberuehrt" "$D2
fn main(): int64 {
    var t: Sek := 7;
    return t as int64;
}" ''

# ── #1956: der Umrechnungsfaktor wirkte nur bei der Zuweisung ─────────────
#
# `500 m + 1 km` ergab 501: die Werte wurden roh addiert, als truegen beide
# denselben Faktor — unabhaengig vom Zieltyp. Der Fall faellt nicht auf, weil
# das Ergebnis eine plausible Zahl ist und der Typ sogar stimmt. Genau die
# Fehlerklasse, gegen die Einheitentypen antreten.
#
# Vergleiche waren noch weiter offen: sie wurden von _checkUtypeBinop gar
# nicht erfasst (nur + und -), also weder umgerechnet NOCH dimensionsgeprueft.
D3='import std.io;
dim L;
dim Z;
utype M: L = 1.0;
utype KM: L = 1000.0;
utype Sek: Z = 1.0;'

# Der WERT wird gemessen, nicht die Uebersetzbarkeit: 500 m + 1 km sind
# 1500 m, und in Kilometern 1.5 — nicht 501.
out "#1956: Addition rechnet den Faktor um (in m)" "$D3
fn main(): int64 {
    var a: M := 500;
    var b: KM := 1;
    var s: M := a + b;
    PrintLn(FloatToStr(s as f64, 1));
    return 0;
}" '1500.0'

# Und das Ergebnis traegt die Einheit der LINKEN Seite, sodass die ZUWEISUNG
# es weiterrechnet. Ohne diese Haelfte blieb die Summe bei 1500 stehen, obwohl
# das Ziel Kilometer waren.
out "#1956: das Ergebnis wird beim Zuweisen weiter umgerechnet" "$D3
fn main(): int64 {
    var a: M := 500;
    var b: KM := 1;
    var s: KM := a + b;
    PrintLn(FloatToStr(s as f64, 3));
    return 0;
}" '1.500'

out "#1956: Subtraktion ebenso" "$D3
fn main(): int64 {
    var a: M := 500;
    var b: KM := 1;
    var d: M := b - a;
    PrintLn(FloatToStr(d as f64, 1));
    return 0;
}" '500.0'

# Der Vergleich. Die Probe des Issues: mit rohen Zahlen kann er gar nicht
# anders ausgehen, solange der Faktor fehlt.
out "#1956: Vergleich rechnet den Faktor um" "$D3
fn main(): int64 {
    var a: M := 500;
    var b: KM := 1;
    if (a > b) { PrintLn(\"500m > 1km\"); } else { PrintLn(\"500m <= 1km\"); }
    return 0;
}" '500m <= 1km'

# Gleichheit ueber verschiedene Faktoren: 1000 m sind 1 km. Ein roher
# Vergleich haette hier "ungleich" gesagt.
out "#1956: 1000 m und 1 km sind gleich" "$D3
fn main(): int64 {
    var a: M := 1000;
    var b: KM := 1;
    if (a == b) { PrintLn(\"gleich\"); } else { PrintLn(\"ungleich\"); }
    return 0;
}" 'gleich'

# Der Vergleich ueber DIMENSIONSGRENZEN war bis 1.2.4B ueberhaupt nicht
# geprueft — _checkUtypeBinop sah nur + und -.
rejects "#1956: Vergleich ueber die Dimensionsgrenze wird gemeldet" "$D3
fn main(): int64 {
    var a: M := 5;
    var t: Sek := 3;
    if (a > t) { return 1; }
    return 0;
}" "verschiedener Dimension verglichen"

# GEGENPROBE 1: der Vorzeichentest gegen eine nackte Zahl bleibt erlaubt.
# Ihn abzuweisen waere eine Verschaerfung ohne Befund — `a > 0` ist im
# Bestand ueberall ueblich und sagt nichts Falsches.
out "#1956: Vergleich gegen eine nackte Zahl bleibt erlaubt" "$D3
fn main(): int64 {
    var a: M := 5;
    if (a > 0) { PrintLn(\"positiv\"); }
    return 0;
}" 'positiv'

# GEGENPROBE 2: gleiche Einheit heisst KEINE Rechnung. Ohne sie waere der
# Test auch von einer Fassung erfuellt, die irgendeinen Faktor anbringt.
out "#1956: gleiche Einheit bleibt unveraendert" "$D3
fn main(): int64 {
    var a: M := 300;
    var b: M := 200;
    var s: M := a + b;
    PrintLn(FloatToStr(s as f64, 1));
    return 0;
}" '500.0'

# GEGENPROBE 3: Skalierung mit einer dimensionslosen Zahl behaelt die Einheit
# und bringt keinen Faktor an.
out "#1956: Skalierung bleibt unberuehrt" "$D3
fn main(): int64 {
    var a: KM := 2;
    var e: KM := a * 3;
    PrintLn(FloatToStr(e as f64, 1));
    return 0;
}" '6.0'

# ── #1962: abgeleitete Dimensionen werden GERECHNET ───────────────────────
#
# `dim Resistance = Voltage / ElectricCurrent;` wurde geparst, angenommen —
# und nie ausgewertet. ebnf.md sagte es woertlich: "NICHT gerechnet werden
# abgeleitete Dimensionen ... das Ergebnis gilt als dimensionslos". Die Zeile
# sah nach einer Zusicherung aus und lieferte keine.
#
# Die Wirkung war BEIDSEITIG, und nur die Gegenprobe zeigt es: `var i: A :=
# u / r;` ging durch — aber `var x: V := u / r;` AUCH, weil das Ergebnis
# einer Division gar keine Dimension trug und deshalb ueberall hin passte.
# Ein Test, der nur die erste Haelfte misst, waere schon vor dem Fix gruen
# gewesen.
E1='import std.io;
dim Spannung;
dim Strom;
dim Widerstand = Spannung / Strom;
utype V: Spannung = 1.0;
utype A: Strom = 1.0;
utype Ohm: Widerstand = 1.0;'

out "#1962: U/R ergibt einen Strom" "$E1
fn main(): int64 {
    var u: V := 12;
    var r: Ohm := 4;
    var i: A := u / r;
    PrintLn(FloatToStr(i as f64, 1));
    return 0;
}" '3.0'

rejects "#1962: U/R ist KEINE Spannung" "$E1
fn main(): int64 {
    var u: V := 12;
    var r: Ohm := 4;
    var x: V := u / r;
    return x as int64;
}" "Dimensionsgrenzen"

# Die Beispiele aus #1956 Befund 3: `*` und `/` trugen keine Dimension, also
# uebersetzte JEDES Ziel.
E2='import std.io;
dim L;
dim Z;
dim Tempo = L / Z;
dim Flaeche = L * L;
utype M: L = 1.0;
utype S: Z = 1.0;
utype Mps: Tempo = 1.0;
utype Qm: Flaeche = 1.0;'

out "#1962: m/s ist ein Tempo" "$E2
fn main(): int64 {
    var m: M := 10;
    var s: S := 2;
    var v: Mps := m / s;
    PrintLn(FloatToStr(v as f64, 1));
    return 0;
}" '5.0'

rejects "#1962: m/s ist keine Laenge" "$E2
fn main(): int64 {
    var m: M := 10;
    var s: S := 2;
    var x: M := m / s;
    return x as int64;
}" "Dimensionsgrenzen"

rejects "#1962: m/s ist keine Zeit" "$E2
fn main(): int64 {
    var m: M := 10;
    var s: S := 2;
    var y: S := m / s;
    return y as int64;
}" "Dimensionsgrenzen"

# "Meter mal Meter ist eine Laenge?" — die Frage aus dem Issue.
rejects "#1962: m*m ist keine Laenge" "$E2
fn main(): int64 {
    var m: M := 10;
    var f: M := m * m;
    return f as int64;
}" "Dimensionsgrenzen"

out "#1962: m*m ist eine Flaeche" "$E2
fn main(): int64 {
    var m: M := 10;
    var f: Qm := m * m;
    PrintLn(FloatToStr(f as f64, 1));
    return 0;
}" '100.0'

# KEHRWERT. Ohne ihn behilft sich std/units.lyx mit `dim Frequency = Time` —
# womit eine Frequenz als dimensionsgleich mit einer Dauer gilt (#1953).
E3='import std.io;
dim Zeit;
dim Frequenz = 1 / Zeit;
utype Sek: Zeit = 1.0;
utype Hz: Frequenz = 1.0;'

out "#1962: 1/t ist eine Frequenz" "$E3
fn main(): int64 {
    var t: Sek := 4;
    var f: Hz := 1 / t;
    PrintLn(FloatToStr(f as f64, 3));
    return 0;
}" '0.250'

rejects "#1962: eine Dauer ist keine Frequenz" "$E3
fn main(): int64 {
    var t: Sek := 4;
    var f: Hz := t;
    return f as int64;
}" "Dimensionsgrenzen"

# DER FAKTOR der abgeleiteten Groesse. Die Dimensionspruefung allein genuegt
# nicht: 36 km/h sind 10 m/s, nicht 36. Ohne diese Pruefung waere der Fix
# gruen und die Zahl falsch — dieselbe Klasse wie ein Invariantentest.
E4='import std.io;
dim L;
dim Z;
dim Tempo = L / Z;
utype KM: L = 1000.0;
utype H: Z = 3600.0;
utype Mps: Tempo = 1.0;'

out "#1962: 36 km/h sind 10 m/s" "$E4
fn main(): int64 {
    var s: KM := 36;
    var t: H := 1;
    var v: Mps := s / t;
    PrintLn(FloatToStr(v as f64, 4));
    return 0;
}" '10.0000'

# GEGENPROBE: eine nackte Zahl bleibt jeder Einheit zuweisbar. Der Nullvektor
# der dimensionslosen Groesse stimmt mit KEINER Einheit ueberein — wer das
# nicht ausnimmt, weist jede Startbelegung ab.
out "#1962: ein Literal bleibt zuweisbar" "$E2
fn main(): int64 {
    var m: M := 42;
    PrintLn(FloatToStr(m as f64, 1));
    return 0;
}" '42.0'

# GEGENPROBE: Skalierung bringt KEINEN Faktor an.
out "#1962: Skalierung bleibt unberuehrt" "$E4
fn main(): int64 {
    var s: KM := 5;
    var d: KM := s * 3;
    PrintLn(FloatToStr(d as f64, 1));
    return 0;
}" '15.0'

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
test "$FAIL" -eq 0
