#!/usr/bin/env bash
# tests/time_civil_test.sh — Kalenderrechnung in std.time.
#
# Gefunden beim ZIP-Zeitstempel (#1404): `CivilYearFromDays` lieferte für jedes
# Datum im Januar oder Februar das VORJAHR. Tag 0 galt als 1969-01-01, und
# `CivilYearFromDays(DaysFromCivil(2017,1,1))` ergab 2016.
#
# Ursache: der Algorithmus rechnet in einem Jahr, das im März beginnt — damit
# fällt der Schalttag ans Jahresende und die Monatsformel kommt ohne Sonderfall
# aus. `DaysFromCivil` zieht dafür für Januar und Februar ein Jahr ab; die
# Rückrichtung machte das nicht rückgängig.
#
# Monat und Tag waren richtig. Genau deshalb fällt so etwas nicht auf: eine
# Ausgabe wie „1.1." stimmt, und erst wer das Jahr liest, sieht den Fehler.
#
# Geprüft wird deshalb nicht ein Datum, sondern der RUNDLAUF über einen
# vollständigen Bereich: jeder Tag von 1970 bis 2050 muss sich in Jahr, Monat
# und Tag zerlegen und daraus wieder in dieselbe Tageszahl zusammensetzen
# lassen. Ein Test mit ein paar handverlesenen Daten hätte den Fehler nur dann
# gefunden, wenn zufällig eines davon im Januar lag.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/p.lyx"; rm -f "$TMP/p"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p" >/dev/null 2>&1; then
    no "$1" "uebersetzt nicht"; return
  fi
  got="$(timeout 120 "$TMP/p" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then no "$1" "ABSTURZ (rc=$rc)"; return; fi
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1" "'$got' erwartet '$3'"; fi
}

# ===========================================================================
# Der Rundlauf ueber 80 Jahre
# ===========================================================================

out "jeder Tag von 1970 bis 2050 laeuft verlustfrei hin und zurueck" 'import std.io;
import std.time;
fn main(): int64 {
  var d: int64 := 0;
  var ende: int64 := DaysFromCivil(2050, 12, 31);
  var fehler: int64 := 0;
  var ersterFehler: int64 := 0;
  while (d <= ende) {
    var j: int64 := CivilYearFromDays(d);
    var m: int64 := CivilMonthFromDays(d);
    var t: int64 := CivilDayFromDays(d);
    if (DaysFromCivil(j, m, t) != d) {
      if (fehler == 0) { ersterFehler := d; }
      fehler := fehler + 1;
    }
    d := d + 1;
  }
  PrintStr(IntToStr(fehler)); PrintStr(" ");
  PrintLn(IntToStr(ersterFehler));
  return 0;
}' "0 0"

# ===========================================================================
# Die Stellen, an denen es schiefging — namentlich
# ===========================================================================

out "Tag 0 ist der 1. Januar 1970" 'import std.io;
import std.time;
fn main(): int64 {
  PrintStr(IntToStr(CivilYearFromDays(0))); PrintStr("-");
  PrintStr(IntToStr(CivilMonthFromDays(0))); PrintStr("-");
  PrintLn(IntToStr(CivilDayFromDays(0)));
  return 0;
}' "1970-1-1"

# Januar und Februar waren die betroffenen Monate, Maerz war schon richtig.
# Beide Seiten der Grenze gehoeren geprueft.
out "Jahreswechsel und Monatsgrenze Februar/Maerz" 'import std.io;
import std.time;
fn zeig(y: int64, m: int64, t: int64): void {
  var d: int64 := DaysFromCivil(y, m, t);
  PrintStr(IntToStr(CivilYearFromDays(d))); PrintStr("-");
  PrintStr(IntToStr(CivilMonthFromDays(d))); PrintStr("-");
  PrintStr(IntToStr(CivilDayFromDays(d))); PrintStr(" ");
}
fn main(): int64 {
  zeig(2016, 12, 31);
  zeig(2017, 1, 1);
  zeig(2017, 2, 28);
  zeig(2017, 3, 1);
  PrintLn("");
  return 0;
}' "2016-12-31 2017-1-1 2017-2-28 2017-3-1 "

# Schaltjahre: der 29. Februar ist der Tag, den die Maerz-Rechnung ans
# Jahresende schiebt — genau dort sass der Fehler.
out "29. Februar in Schaltjahren" 'import std.io;
import std.time;
fn zeig(y: int64, m: int64, t: int64): void {
  var d: int64 := DaysFromCivil(y, m, t);
  PrintStr(IntToStr(CivilYearFromDays(d))); PrintStr("-");
  PrintStr(IntToStr(CivilMonthFromDays(d))); PrintStr("-");
  PrintStr(IntToStr(CivilDayFromDays(d))); PrintStr(" ");
}
fn main(): int64 {
  zeig(2016, 2, 29);
  zeig(2000, 2, 29);
  zeig(2024, 2, 29);
  PrintLn("");
  return 0;
}' "2016-2-29 2000-2-29 2024-2-29 "

# 1900 ist kein Schaltjahr, 2000 schon — die Jahrhundertregel.
out "Jahrhundertregel 1900 und 2000" 'import std.io;
import std.time;
fn main(): int64 {
  if (IsLeapYear(1900)) { PrintStr("ja "); } else { PrintStr("nein "); }
  if (IsLeapYear(2000)) { PrintStr("ja "); } else { PrintStr("nein "); }
  var d: int64 := DaysFromCivil(1900, 3, 1);
  PrintStr(IntToStr(CivilYearFromDays(d))); PrintStr("-");
  PrintStr(IntToStr(CivilMonthFromDays(d))); PrintStr("-");
  PrintLn(IntToStr(CivilDayFromDays(d)));
  return 0;
}' "nein ja 1900-3-1"

# Daten vor 1970 (negative Tageszahlen) — dort greift der andere Zweig der
# Bereichsrechnung.
out "Daten vor 1970" 'import std.io;
import std.time;
fn zeig(y: int64, m: int64, t: int64): void {
  var d: int64 := DaysFromCivil(y, m, t);
  PrintStr(IntToStr(CivilYearFromDays(d))); PrintStr("-");
  PrintStr(IntToStr(CivilMonthFromDays(d))); PrintStr("-");
  PrintStr(IntToStr(CivilDayFromDays(d))); PrintStr(" ");
}
fn main(): int64 {
  zeig(1969, 12, 31);
  zeig(1969, 1, 1);
  zeig(1900, 1, 1);
  PrintLn("");
  return 0;
}' "1969-12-31 1969-1-1 1900-1-1 "

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
