#!/usr/bin/env bash
# tests/regex_z8_test.sh — #1466, #1467, #1468, #1378.
#
#   #1468 Gruppen wurden abgeglichen, ihre Grenzen aber nirgends festgehalten:
#         RegexCaptureCount lieferte 0, jede Abfrage −1. Die Klammern waren nur
#         Struktur, nie Ergebnis.
#   #1467 Die drei *Ex-Funktionen nahmen `flags` entgegen und werteten sie nicht
#         aus — beide Zweige der Abfrage taten dasselbe. IGNORE_CASE, ANCHORED
#         und MULTILINE waren in der Muster-API wirkungslos.
#   #1466 RegexReplace zählte nur Treffer; `replacement` kam im Rumpf nicht vor.
#   #1378 Aus dem Neuvermessen der verrotteten Tests: Captures und ignore-case
#         falsch. Search/Match selbst sind seit #1313 in Ordnung; übrig blieben
#         genau die beiden Punkte oben.
#
# ZUR MESSRICHTUNG: #1378 hielt fest, dass die NEGATIVfälle grün waren — eine
# Funktion, die durchgehend „nichts gefunden" meldet, besteht jeden Test, der
# nur prüft, dass Unsinn nicht passt. Hier steht deshalb neben jedem
# Negativfall ein Positivfall, und die Captures werden auf ihren INHALT
# geprüft, nicht auf „ist gesetzt".

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    echo "FAIL $1: uebersetzt nicht"; FAIL=$((FAIL+1)); return
  fi
  got="$(timeout 20 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then echo "FAIL $1: ABSTURZ rc=$rc"; FAIL=$((FAIL+1)); return; fi
  if [ "$got" = "$3" ]; then echo "PASS $1"; PASS=$((PASS+1))
  else echo "FAIL $1: '$got' erwartet '$3'"; FAIL=$((FAIL+1)); fi
}

# ===========================================================================
# #1468 — Capture-Gruppen
# ===========================================================================

# Das Beispiel aus der Meldung, mit Inhalten statt bloss Positionen.
out "#1468: Gruppen liefern Position und Text" 'import std.io;
import std.alloc;
import std.regex;
fn main(): int64 {
  var text: pchar := "GET /api/users HTTP/1.1";
  PrintStr(IntToStr(RegexSearch("(GET|POST) (/[a-z/]+)", text))); PrintStr(" ");
  PrintStr(IntToStr(RegexCaptureCount())); PrintStr(" ");
  var i: int64 := 0;
  while (i < RegexCaptureCount()) {
    var buf: int64 := alloc(64);
    RegexCaptureText(buf as pchar, text, i);
    PrintStr("["); PrintStr(buf as pchar); PrintStr("]");
    i := i + 1;
  }
  PrintLn("");
  return 0;
}' "0 3 [GET /api/users][GET][/api/users]"

# Gruppe 0 ist der ganze Treffer, auch ohne Klammern im Muster.
out "#1468: Gruppe 0 ist der ganze Treffer" 'import std.io;
import std.alloc;
import std.regex;
fn main(): int64 {
  var t: pchar := "abc 123 def";
  RegexSearch("[0-9]+", t);
  PrintStr(IntToStr(RegexCaptureCount())); PrintStr(" ");
  PrintStr(IntToStr(RegexCaptureStart(0))); PrintStr(" ");
  PrintStr(IntToStr(RegexCaptureEnd(0))); PrintStr(" ");
  var b: int64 := alloc(32);
  RegexCaptureText(b as pchar, t, 0);
  PrintLn(b as pchar);
  return 0;
}' "1 4 7 123"

# Ein misslungener Abgleich darf keine alten Gruppen stehen lassen — sonst
# liest der naechste Aufrufer Reste vom vorigen Treffer.
out "#1468: nach Fehlschlag bleiben keine Reste" 'import std.io;
import std.regex;
fn main(): int64 {
  RegexSearch("(abc)", "xx abc yy");
  PrintStr(IntToStr(RegexCaptureCount())); PrintStr(" ");
  RegexSearch("(zzz)", "xx abc yy");
  PrintStr(IntToStr(RegexCaptureCount())); PrintStr(" ");
  PrintLn(IntToStr(RegexCaptureStart(1)));
  return 0;
}' "2 0 -1"

# Eine Gruppe ausserhalb des Bereichs muss -1 liefern, nicht irgendetwas.
out "#1468: Gruppe ausserhalb liefert -1" 'import std.io;
import std.regex;
fn main(): int64 {
  RegexSearch("(a)(b)", "ab");
  PrintStr(IntToStr(RegexCaptureCount())); PrintStr(" ");
  PrintStr(IntToStr(RegexCaptureStart(5))); PrintStr(" ");
  PrintLn(IntToStr(RegexCaptureEnd(0 - 1)));
  return 0;
}' "3 -1 -1"

# ===========================================================================
# #1467 — die Flags
# ===========================================================================

out "#1467: IGNORE_CASE wirkt und wirkt nur mit Flag" 'import std.io;
import std.regex;
fn main(): int64 {
  PrintStr(IntToStr(RegexSearchEx("hello", "say HELLO now", REGEX_FLAG_IGNORE_CASE))); PrintStr(" ");
  PrintStr(IntToStr(RegexSearchEx("hello", "say HELLO now", 0))); PrintStr(" ");
  PrintStr(BoolToStr(RegexMatchEx("HELLO", "hello world", REGEX_FLAG_IGNORE_CASE))); PrintStr(" ");
  PrintLn(BoolToStr(RegexMatchEx("HELLO", "hello world", 0)));
  return 0;
}' "4 -1 true false"

# Auch Zeichenklassen und Bereiche muessen falten — sonst greift das Flag nur
# bei Literalen und die Luecke waere nur verschoben.
out "#1467: IGNORE_CASE gilt auch fuer Klassen" 'import std.io;
import std.regex;
fn main(): int64 {
  PrintStr(IntToStr(RegexSearchEx("[a-z]+", "ABC", REGEX_FLAG_IGNORE_CASE))); PrintStr(" ");
  PrintStr(IntToStr(RegexSearchEx("[a-z]+", "ABC", 0))); PrintStr(" ");
  PrintLn(IntToStr(RegexSearchEx("[abc]", "B", REGEX_FLAG_IGNORE_CASE)));
  return 0;
}' "0 -1 0"

out "#1467: ANCHORED bindet an den Anfang" 'import std.io;
import std.regex;
fn main(): int64 {
  PrintStr(IntToStr(RegexSearchEx("world", "hello world", REGEX_FLAG_ANCHORED))); PrintStr(" ");
  PrintStr(IntToStr(RegexSearchEx("hello", "hello world", REGEX_FLAG_ANCHORED))); PrintStr(" ");
  PrintLn(IntToStr(RegexSearchEx("world", "hello world", 0)));
  return 0;
}' "-1 0 6"

# Der Zustand darf den naechsten Aufruf nicht faerben.
out "#1467: Flags gelten nur fuer ihren Aufruf" 'import std.io;
import std.regex;
fn main(): int64 {
  RegexSearchEx("hello", "HELLO", REGEX_FLAG_IGNORE_CASE);
  PrintStr(IntToStr(RegexSearch("hello", "HELLO"))); PrintStr(" ");
  RegexSearchEx("x", "x", REGEX_FLAG_ANCHORED);
  PrintLn(IntToStr(RegexSearch("world", "hello world")));
  return 0;
}' "-1 6"

# ===========================================================================
# #1466 — die Ersetzung ersetzt
# ===========================================================================

out "#1466: RegexReplaceAlloc ersetzt wirklich" 'import std.io;
import std.regex;
fn main(): int64 {
  PrintLn(RegexReplaceAlloc("foo", "foo bar foo baz foo", "XXX"));
  PrintLn(RegexReplaceAlloc("[0-9]+", "a1b22c333", "#"));
  PrintLn(RegexReplaceAlloc("xyz", "hello world", "A"));
  PrintLn(RegexReplaceAlloc("o", "foo", ""));
  return 0;
}' "XXX bar XXX baz XXX
a#b#c#
hello world
f"

out "#1466: mit Flags ersetzen" 'import std.io;
import std.regex;
fn main(): int64 {
  PrintLn(RegexReplaceAllocEx("foo", "FOO bar Foo", "X", REGEX_FLAG_IGNORE_CASE));
  PrintLn(RegexReplaceAllocEx("foo", "FOO bar Foo", "X", 0));
  return 0;
}' "X bar X
FOO bar Foo"

# Die Trefferzahl gibt es weiter — unter einem Namen, der sie benennt.
out "#1466: RegexCountMatches zaehlt" 'import std.io;
import std.regex;
fn main(): int64 {
  PrintStr(IntToStr(RegexCountMatches("foo", "foo bar foo"))); PrintStr(" ");
  PrintStr(IntToStr(RegexCountMatches("xyz", "foo bar"))); PrintStr(" ");
  PrintLn(IntToStr(RegexReplace("foo", "foo bar foo", "X")));
  return 0;
}' "2 0 2"

# RegexReplaceInto war der einzige Weg, der schon vorher ersetzte — er muss
# unveraendert arbeiten.
out "#1466: RegexReplaceInto unveraendert" 'import std.io;
import std.alloc;
import std.regex;
fn main(): int64 {
  var b: int64 := alloc(64);
  var n: int64 := RegexReplaceInto(b as pchar, "world", "hello world", "Lyx");
  PrintStr(b as pchar); PrintStr(" "); PrintLn(IntToStr(n));
  return 0;
}' "hello Lyx 1"

# ===========================================================================
# #1378 — die Faelle aus dem Neuvermessen
# ===========================================================================

# Positiv- UND Negativfall nebeneinander: eine Funktion, die immer "nicht
# gefunden" meldet, faellt nur an der ersten Zeile auf.
out "#1378: Match und Search, positiv wie negativ" 'import std.io;
import std.regex;
fn main(): int64 {
  PrintStr(BoolToStr(RegexMatch("hello", "hello world"))); PrintStr(" ");
  PrintStr(BoolToStr(RegexMatch("xyz", "hello world"))); PrintStr(" ");
  PrintStr(IntToStr(RegexSearch("world", "hello world"))); PrintStr(" ");
  PrintLn(IntToStr(RegexSearch("xyz", "hello world")));
  return 0;
}' "true false 6 -1"

out "#1378: Alternation und Anker unveraendert" 'import std.io;
import std.regex;
fn main(): int64 {
  PrintStr(BoolToStr(RegexMatch("cat|dog", "hotdog"))); PrintStr(" ");
  PrintStr(IntToStr(RegexSearch("^hello", "hello world"))); PrintStr(" ");
  PrintStr(IntToStr(RegexSearch("^world", "hello world"))); PrintStr(" ");
  PrintLn(BoolToStr(RegexMatch("^[a-z]+$", "Hallo")));
  return 0;
}' "true 0 -1 false"

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
