#!/usr/bin/env bash
# tests/datetime_runde5_test.sh — #1600, #1601, #1602, #1603, #1605.
#
# std.datetime und std.time. Der Kalenderkern war in Ordnung (7236 Datensaetze
# gegen Pythons datetime, null Abweichungen) — falsch waren die Zeichenausgabe,
# die Formatspezifizierer und der Umfang.
#
# GEPRUEFT WIRD DER WEG:
#   #1605 an den Werten, die vorher Muellzeichen ergaben (negativ, >= 1000 h) —
#         ein Test mit "normalen" Dauern waere vorher gruen gewesen.
#   #1602 daran, dass ein UNBEKANNTER Spezifizierer sich im Rueckgabewert
#         meldet; die Ausgabe allein sah immer plausibel aus.
#   #1603 daran, dass der Zielpuffer nach einem Misserfolg NICHT mehr den
#         vorherigen Wert traegt — genau daran scheiterte das Einlesen in
#         einer Schleife lautlos.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

lauf() {
  local name="$1" erwartet="$2" quelle="$3"
  printf '%s\n' "$quelle" > "$TMP/t.lyx"
  if ! timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/t.lyx" -o "$TMP/t" >"$TMP/c.log" 2>&1; then
    no "$name" "uebersetzt nicht: $(grep -m1 -iE 'sema error|codegen error|^error' "$TMP/c.log")"
    return
  fi
  local got; got="$(timeout 60 "$TMP/t" 2>&1 | tr -d '\r' \
    | grep -vE 'Capabilit|^===|^Programm:|^  o |^  [A-Za-z-]+ |^$|^Runtime')"
  if [ "$got" = "$erwartet" ]; then ok "$name"; else
    no "$name" "erwartet [$(echo "$erwartet"|tr '\n' '|')], bekam [$(echo "$got"|tr '\n' '|')]"
  fi
}

# ===========================================================================
# #1605 — Zifferndarstellung: Vorzeichen und Bereich
# ===========================================================================
lauf "#1605: negative Dauern tragen ein Vorzeichen statt Muellzeichen" \
'-26h 03m 04s
-45s
-1h
-00:45' 'import std.io;
import std.datetime;
fn main(): int64 {
  var b: pchar := alloc(64) as pchar;
  FormatDuration(0-93784, b); PrintLn(b);
  FormatDuration(0-45, b);    PrintLn(b);
  FormatDuration(0-3600, b);  PrintLn(b);
  FormatDurationShort(0-45, b); PrintLn(b);
  return 0;
}'

lauf "#1605: Stundenzahl ab 1000 bleibt vollstaendig" \
'1000h
12345h
999h 59m 59s
12345:00:00' 'import std.io;
import std.datetime;
fn main(): int64 {
  var b: pchar := alloc(64) as pchar;
  FormatDuration(1000*3600, b);  PrintLn(b);
  FormatDuration(12345*3600, b); PrintLn(b);
  FormatDuration(999*3600 + 59*60 + 59, b); PrintLn(b);
  FormatDurationShort(12345*3600, b); PrintLn(b);
  return 0;
}'

# Gegenprobe: gewoehnliche Dauern unveraendert.
lauf "#1605: gewoehnliche Dauern unveraendert" \
'45s
1h 01m 01s
30:45' 'import std.io;
import std.datetime;
fn main(): int64 {
  var b: pchar := alloc(64) as pchar;
  FormatDuration(45, b);   PrintLn(b);
  FormatDuration(3661, b); PrintLn(b);
  FormatDurationShort(1845, b); PrintLn(b);
  return 0;
}'

# ===========================================================================
# #1602 — Format-Spezifizierer
# ===========================================================================
lauf "#1602: %I, %j und %% funktionieren" \
'PM 02
229
100% fertig' 'import std.io;
import std.datetime;
fn main(): int64 {
  var b: pchar := alloc(128) as pchar;
  Format(1786977000, "%p %I"c, b); PrintLn(b);
  Format(1786977000, "%j"c, b);    PrintLn(b);
  Format(1786977000, "100%% fertig"c, b); PrintLn(b);
  return 0;
}'

# Der eigentliche Punkt: ein unbekannter Spezifizierer meldet sich jetzt.
lauf "#1602: unbekannter Spezifizierer meldet sich im Rueckgabewert" \
'19
-7' 'import std.io;
import std.datetime;
fn main(): int64 {
  var b: pchar := alloc(128) as pchar;
  PrintLn(IntToStr(Format(1786977000, "%Y-%m-%d %H:%M:%S"c, b)));
  PrintLn(IntToStr(Format(1786977000, "%e %s %%"c, b)));
  return 0;
}'

# ===========================================================================
# #1603 — ParseFlexible und der Zielpuffer bei Misserfolg
# ===========================================================================
lauf "#1603: vier Formate werden gelesen" \
'1 1786977000
1 1786924800
1 1786924800
1 1786977000
1 1786977000' 'import std.io;
import std.datetime;
fn P(t: pchar): void {
  var r: int64 := alloc(8);
  poke64(r, 0-1);
  var rc: int64 := ParseFlexible(t, r);
  PrintStr(IntToStr(rc)); PrintStr(" "); PrintLn(IntToStr(peek64(r)));
}
fn main(): int64 {
  P("2026-08-17T14:30:00Z"c);
  P("2026-08-17"c);
  P("17.08.2026"c);
  P("17.08.2026 14:30"c);
  P("Mon, 17 Aug 2026 14:30:00 +0000"c);
  return 0;
}'

# Der gefaehrliche Teil: nach einem Misserfolg darf NICHT der vorherige Wert
# im Puffer stehen — sonst liest eine Schleife den letzten guten Wert weiter.
lauf "#1603: Misserfolg hinterlaesst keinen plausiblen Altwert" \
'1 1786977000
0 0' 'import std.io;
import std.datetime;
fn main(): int64 {
  var r: int64 := alloc(8);
  var rc: int64 := ParseFlexible("2026-08-17T14:30:00Z"c, r);
  PrintStr(IntToStr(rc)); PrintStr(" "); PrintLn(IntToStr(peek64(r)));
  rc := ParseFlexible("kein Datum"c, r);
  PrintStr(IntToStr(rc)); PrintStr(" "); PrintLn(IntToStr(peek64(r)));
  return 0;
}'

# ===========================================================================
# #1601 — Kalenderwerte <-> Zeitstempel
# ===========================================================================
lauf "#1601: Konstruktor und Akkessoren" \
'2026 8 17
14 30 0
1 Monday' 'import std.io;
import std.datetime;
fn main(): int64 {
  var dt: int64 := DatetimeFromYmdHms(2026, 8, 17, 14, 30, 0);
  PrintStr(IntToStr(YearOf(dt))); PrintStr(" "); PrintStr(IntToStr(MonthOf(dt))); PrintStr(" "); PrintLn(IntToStr(DayOf(dt)));
  PrintStr(IntToStr(HourOf(dt))); PrintStr(" "); PrintStr(IntToStr(MinuteOf(dt))); PrintStr(" "); PrintLn(IntToStr(SecondOf(dt)));
  PrintStr(IntToStr(DayOfWeek(dt))); PrintStr(" "); PrintLn(WeekdayLong(DayOfWeek(dt)));
  return 0;
}'

# Das Wochenjahr: der 29.12.2025 liegt in KW 1 — aber von 2026.
lauf "#1601: WeekYear nennt das Jahr zur Kalenderwoche" \
'1 2026
53 2026' 'import std.io;
import std.datetime;
fn main(): int64 {
  PrintStr(IntToStr(WeekNumber(2025,12,29))); PrintStr(" "); PrintLn(IntToStr(WeekYear(2025,12,29)));
  PrintStr(IntToStr(WeekNumber(2026,12,31))); PrintStr(" "); PrintLn(IntToStr(WeekYear(2026,12,31)));
  return 0;
}'

# Alter aus einem Geburtsdatum — mit DiffDays/365 wird es falsch.
lauf "#1601: DiffYears zaehlt volle Jahre, angefangene nicht" \
'35
36' 'import std.io;
import std.datetime;
fn main(): int64 {
  var geb: int64 := DatetimeFromYmd(1990, 8, 18);
  PrintLn(IntToStr(DiffYears(geb, DatetimeFromYmd(2026, 8, 17))));
  PrintLn(IntToStr(DiffYears(geb, DatetimeFromYmd(2026, 8, 18))));
  return 0;
}'

lauf "#1601: Tages- und Monatsgrenzen" \
'0 0 0
23 59 59
1
31' 'import std.io;
import std.datetime;
fn main(): int64 {
  var dt: int64 := DatetimeFromYmdHms(2026, 8, 17, 14, 30, 0);
  var a: int64 := StartOfDay(dt);
  PrintStr(IntToStr(HourOf(a))); PrintStr(" "); PrintStr(IntToStr(MinuteOf(a))); PrintStr(" "); PrintLn(IntToStr(SecondOf(a)));
  var e: int64 := EndOfDay(dt);
  PrintStr(IntToStr(HourOf(e))); PrintStr(" "); PrintStr(IntToStr(MinuteOf(e))); PrintStr(" "); PrintLn(IntToStr(SecondOf(e)));
  PrintLn(IntToStr(DayOf(StartOfMonth(dt))));
  PrintLn(IntToStr(DayOf(EndOfMonth(dt))));
  return 0;
}'

# ===========================================================================
# #1600 — Zeitzonen
# ===========================================================================
# Die krummen Versaetze sind der Punkt: sie abzutippen ist fehleranfaellig.
lauf "#1600: krumme Versaetze stimmen" \
'20700
45900
-34200
31500
50400' 'import std.io;
import std.time;
fn main(): int64 {
  PrintLn(IntToStr(ZoneByCode("NPT"c).offset_seconds));
  PrintLn(IntToStr(ZoneByCode("CHAST"c).offset_seconds));
  PrintLn(IntToStr(ZoneByCode("MART"c).offset_seconds));
  PrintLn(IntToStr(ZoneByCode("ACWST"c).offset_seconds));
  PrintLn(IntToStr(ZoneByCode("LINT"c).offset_seconds));
  return 0;
}'

# Die drei doppelt belegten Kuerzel: dokumentierte Lesart, und die andere
# Bedeutung ueber eine eigene Funktion erreichbar.
lauf "#1600: mehrdeutige Kuerzel folgen der dokumentierten Lesart" \
'19800 7200
14400 -7200
25200 21600' 'import std.io;
import std.time;
fn main(): int64 {
  PrintStr(IntToStr(ZoneByCode("IST"c).offset_seconds)); PrintStr(" "); PrintLn(IntToStr(ZoneIsrael().offset_seconds));
  PrintStr(IntToStr(ZoneByCode("GST"c).offset_seconds)); PrintStr(" "); PrintLn(IntToStr(ZoneSouthGeorgia().offset_seconds));
  PrintStr(IntToStr(ZoneByCode("ICT"c).offset_seconds)); PrintStr(" "); PrintLn(IntToStr(ZoneChagos().offset_seconds));
  return 0;
}'

# Unbekannt muss sich von UTC unterscheiden lassen — sonst waere ein Tippfehler
# im Kuerzel stillschweigend Greenwich.
lauf "#1600: unbekanntes Kuerzel ist unterscheidbar von UTC" \
'0 1
0 0' 'import std.io;
import std.time;
fn main(): int64 {
  PrintStr(IntToStr(ZoneByCode("UTC"c).offset_seconds)); PrintStr(" "); PrintLn(IntToStr(ZoneCodeKnown("UTC"c)));
  PrintStr(IntToStr(ZoneByCode("XYZ"c).offset_seconds)); PrintStr(" "); PrintLn(IntToStr(ZoneCodeKnown("XYZ"c)));
  return 0;
}'

# Gegenprobe: die drei bisherigen Funktionen unveraendert.
lauf "#1600: UTC, CET und CEST unveraendert" \
'0
3600
7200' 'import std.io;
import std.time;
fn main(): int64 {
  PrintLn(IntToStr(ZoneUTC().offset_seconds));
  PrintLn(IntToStr(ZoneCET().offset_seconds));
  PrintLn(IntToStr(ZoneCEST().offset_seconds));
  return 0;
}'

echo
echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
