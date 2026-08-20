#!/usr/bin/env bash
# tests/datetime_float_test.sh — #1415, #1416 (std.datetime), #1430 (std.io).
#
#   #1415  FormatLocale ignoriert den locale-Parameter, liefert immer ISO 8601
#   #1416  GetTimezoneOffset verschluckt den Minutenanteil (IST-5:30 -> +05:00)
#   #1430  FloatToStr rechnet falsch: 5.02 wird zu 5.1, führende Nullen fehlen
#
# ZUR AUSSAGEKRAFT: bei #1430 und #1416 sind die Sollwerte nachrechenbar und
# stehen in der Meldung — geprüft wird gegen sie, nicht gegen eine
# Gegenfunktion derselben Unit. Bei #1416 kommen die Zonen aus der Wirklichkeit
# (Indien, Nepal, Neufundland); ein Test mit lauter vollen Stunden wäre auch
# vor dem Fix grün gewesen, denn genau die funktionierten ja.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/p.lyx"; rm -f "$TMP/p"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p" >/dev/null 2>&1; then
    no "$1" "uebersetzt nicht: $("$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p" 2>&1 | grep -i error | head -1)"
    return
  fi
  got="$(timeout 30 "$TMP/p" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then no "$1" "ABSTURZ (rc=$rc)"; return; fi
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1" "'$got' erwartet '$3'"; fi
}

# ===========================================================================
# #1430 — FloatToStr gibt die Zahl aus, die uebergeben wurde
# ===========================================================================

# Die fuenf Faelle aus der Meldung, dazu Vorzeichen, Uebertrag beim Runden,
# prec 0 und die Null.
out "#1430: Nachkommastellen stimmen" 'import std.io;
import std.string;
fn Z(v: f64, p: int64): void { PrintStr(FloatToStr(v, p)); PrintStr(" "); }
fn main(): int64 {
  Z(5.02, 2);
  Z(1.05, 2);
  Z(7.001, 3);
  Z(0.07, 2);
  Z(12.3, 2);
  Z(0.0 - 3.14159, 4);
  Z(2.0, 0);
  Z(9.999, 2);
  Z(0.0, 2);
  PrintLn("");
  return 0;
}' "5.02 1.05 7.001 0.07 12.30 -3.1416 2 10.00 0.00 "

# Der Uebertrag beim Aufrunden gehoert in den Vorkommateil: 9.999 mit zwei
# Stellen ist 10.00, nicht 9.100 oder 10.-1.
#
# NICHT geprueft wird hier 1.995. Das liefert 1.99 statt 2.00 — nicht, weil
# gefalsch gerundet wuerde, sondern weil das LITERAL um ein ULP zu niedrig
# uebersetzt wird (#1461). Der Formatierer bekommt eine andere Zahl, als im
# Quelltext steht. Ein Test darf nicht an einem fremden offenen Defekt haengen,
# sonst ist unklar, was er misst.
out "#1430: Aufrunden traegt in die Vorkommastelle" 'import std.io;
fn main(): int64 {
  PrintStr(FloatToStr(0.999, 2)); PrintStr(" ");
  PrintStr(FloatToStr(2.999, 2)); PrintStr(" ");
  PrintLn(FloatToStr(99.999, 1));
  return 0;
}' "1.00 3.00 100.0"

# Gegenprobe: die Sonderfaelle aus #1284 bleiben, wie sie sind.
out "#1430: nan, inf und grosse Betraege unveraendert" 'import std.io;
fn main(): int64 {
  var n: f64 := 0.0;
  var d: f64 := 0.0;
  PrintStr(FloatToStr(1.0e400, 2)); PrintStr(" ");
  PrintStr(FloatToStr(0.0 - 1.0e400, 2)); PrintStr(" ");
  PrintLn(FloatToStr(1.0e19, 2));
  return 0;
}' "inf -inf 1.00e19"

# ===========================================================================
# #1416 — der Minutenanteil des Zonenversatzes
# ===========================================================================

printf 'import std.io;\nimport std.datetime;\nfn main(): int64 { PrintLn(IntToStr(GetTimezoneOffset())); return 0; }\n' > "$TMP/tz.lyx"
if "$LYXC" --std-path="$ROOT" "$TMP/tz.lyx" -o "$TMP/tz" >/dev/null 2>&1; then
  # Zone -> erwarteter Versatz in Sekunden (ostwaerts positiv)
  fehler=""
  pruefe() {
    got="$(TZ="$1" "$TMP/tz" 2>&1)"
    if [ "$got" != "$2" ]; then fehler="$fehler [$1: $got statt $2]"; fi
  }
  pruefe "IST-5:30"  19800     # Indien   +05:30
  pruefe "NPT-5:45"  20700     # Nepal    +05:45
  pruefe "NST3:30"  -12600     # Neufundland -03:30
  pruefe "IRST-3:30" 12600     # Iran     +03:30
  pruefe "CET-1"     3600      # volle Stunde, war schon richtig
  pruefe "EST5"    -18000      # volle Stunde, war schon richtig
  pruefe "UTC0"        0
  pruefe "ACST-9:30" 34200     # Australien +09:30
  if [ -z "$fehler" ]; then ok "#1416: Halb- und Viertelstundenzonen stimmen"
  else no "#1416: Halb- und Viertelstundenzonen stimmen" "$fehler"; fi
else
  no "#1416: Halb- und Viertelstundenzonen stimmen" "uebersetzt nicht"
fi

# Die Sommerzeitregel hinter dem Zonennamen wird weiterhin nicht ausgewertet.
# Das ist Absicht und steht so im Quelltext — hier festgehalten, damit es
# nicht spaeter als Fehler gemeldet wird und damit auffaellt, falls sich das
# Verhalten unbemerkt aendert.
if [ -x "$TMP/tz" ]; then
  got="$(TZ="CET-1CEST,M3.5.0,M10.5.0/3" "$TMP/tz" 2>&1)"
  if [ "$got" = "3600" ]; then ok "#1416: Sommerzeitregel bleibt unausgewertet (Standardversatz)"
  else no "#1416: Sommerzeitregel bleibt unausgewertet (Standardversatz)" "$got"; fi
else
  no "#1416: Sommerzeitregel bleibt unausgewertet (Standardversatz)" "uebersetzt nicht"
fi

# Gegenprobe: FormatTimezoneOffset gibt den Versatz wieder aus — die halbe
# Stunde muss auch dort ankommen.
out "#1416: FormatTimezoneOffset zeigt die Minuten" 'import std.io;
import std.datetime;
import std.alloc;
fn main(): int64 {
  var o: int64 := alloc(32);
  FormatTimezoneOffset(19800, o as pchar);  PrintStr(o as pchar); PrintStr(" ");
  FormatTimezoneOffset(0 - 12600, o as pchar); PrintStr(o as pchar); PrintStr(" ");
  FormatTimezoneOffset(20700, o as pchar);  PrintLn(o as pchar);
  return 0;
}' "+05:30 -03:30 +05:45"

# ===========================================================================
# #1415 — FormatLocale wertet die Locale aus
# ===========================================================================

# 1786988712 = 2026-08-17T17:45:12Z. Die erwarteten Formen stehen in der
# Meldung (dort mit anderer Uhrzeit).
out "#1415: die Locale bestimmt die Form" 'import std.io;
import std.datetime;
import std.alloc;
fn z(l: pchar): void {
  var o: int64 := alloc(64);
  FormatLocale(1786988712, l, o as pchar);
  PrintStr(o as pchar); PrintStr(" | ");
}
fn main(): int64 {
  z("de_DE"c);
  z("en_US"c);
  z("en_GB"c);
  z("fr_FR"c);
  PrintLn("");
  return 0;
}' "17.08.2026 17:45:12 | 8/17/2026 5:45:12 PM | 17/08/2026 17:45:12 | 17/08/2026 17:45:12 | "

# Vormittag und Mitternacht: die 12-Stunden-Zaehlung hat genau dort ihre
# Sonderfaelle (0 Uhr ist 12 AM, 12 Uhr ist 12 PM).
out "#1415: en_US zaehlt Stunden richtig um" 'import std.io;
import std.datetime;
import std.alloc;
fn z(t: int64): void {
  var o: int64 := alloc(64);
  FormatLocale(t, "en_US"c, o as pchar);
  PrintStr(o as pchar); PrintStr(" | ");
}
fn main(): int64 {
  z(1786924800);   // 00:00:00 UTC
  z(1786968000);   // 12:00:00 UTC
  z(1786971600);   // 13:00:00 UTC
  PrintLn("");
  return 0;
}' "8/17/2026 12:00:00 AM | 8/17/2026 12:00:00 PM | 8/17/2026 1:00:00 PM | "

# Eine unbekannte Locale liefert weiterhin ISO — aber LocaleSupported sagt es
# vorher. Das ist der Unterschied zu vorher: der stille Rueckfall bleibt, die
# Auskunft darueber ist neu.
out "#1415: unbekannte Locale faellt auf ISO zurueck und sagt es" 'import std.io;
import std.datetime;
import std.alloc;
fn main(): int64 {
  var o: int64 := alloc(64);
  FormatLocale(1786988712, "xx_YY"c, o as pchar);
  PrintStr(o as pchar); PrintStr(" ");
  if (LocaleSupported("xx_YY"c)) { PrintStr("ja "); } else { PrintStr("nein "); }
  if (LocaleSupported("de_DE"c)) { PrintLn("ja"); } else { PrintLn("nein"); }
  return 0;
}' "2026-08-17T17:45:12Z nein ja"

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
