#!/usr/bin/env bash
# tests/json_haerte_test.sh — #1432, #1433, #1434, #1435.
#
#   #1432  Pipe-Format verliert Typen; ein Pipe-Zeichen im Wert zerlegt das Array
#   #1433  JSONEscape maskiert keine Steuerzeichen — Ergebnis ist kein JSON
#   #1434  isValidJSON prüft bei Arrays und Objekten nur die Klammerpaare
#   #1435  parseValue lässt dest bei Objekten unverändert, meldet Müll als Zahl
#
# ZUR AUSSAGEKRAFT: die Rundläufe werden gegen die ERWARTETE JSON-Form geprüft,
# nicht gegen die eigene Gegenfunktion. Ein toArray/stringify-Paar, das
# denselben Fehler in beide Richtungen macht, ist sonst sein eigener Zeuge —
# und genau das war hier der Fall: `[1,2,3]` kam als `["1","2","3"]` zurück,
# und beide Seiten hielten das für richtig.
#
# Wo es geht, wird zusätzlich gegen python3 -m json.tool geprüft: ein fremder,
# strenger Parser sagt verlässlicher, ob etwas gültiges JSON ist, als eine
# Funktion derselben Unit.

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
    no "$1" "uebersetzt nicht: $("$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p" 2>&1 | grep -i error | head -1)"
    return
  fi
  got="$(timeout 30 "$TMP/p" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then no "$1" "ABSTURZ (rc=$rc)"; return; fi
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1" "'$got' erwartet '$3'"; fi
}

# ===========================================================================
# #1432 — der Rundlauf erhaelt Typen und Trennzeichen
# ===========================================================================

# Die vier Faelle aus der Meldung, in derselben Reihenfolge.
out "#1432: Rundlauf erhaelt Zahlen, Zeichenketten und Verschachtelung" 'import std.io;
import std.json;
import std.alloc;
fn r(s: pchar): void {
  var p: int64 := alloc(512);
  var o: int64 := alloc(512);
  toArray(p as pchar, s);
  stringify(o as pchar, p as pchar);
  PrintLn(o as pchar);
}
fn main(): int64 {
  r("[1,2,3]"c);
  r("[\"a\",\"b\"]"c);
  r("[1,[2,3]]"c);
  r("[\"a|b\",\"c\"]"c);
  r("[true,null,-2.5]"c);
  return 0;
}' "[1,2,3]
[\"a\",\"b\"]
[1,[2,3]]
[\"a|b\",\"c\"]
[true,null,-2.5]"

# Eine nackte Zeichenkette im Zwischenformat — also nicht aus toArray, sondern
# von Hand gebaut — muss weiterhin maskiert werden. Sonst waere aus dem Fix
# die Gegenrichtung geworden: alles unveraendert durchreichen.
out "#1432: nackte Werte werden weiterhin maskiert" 'import std.io;
import std.json;
import std.alloc;
fn main(): int64 {
  var o: int64 := alloc(512);
  serializeArray(o as pchar, "hallo|welt"c);
  PrintLn(o as pchar);
  return 0;
}' "[\"hallo\",\"welt\"]"

# ===========================================================================
# #1433 — alle Steuerzeichen werden maskiert
# ===========================================================================

out "#1433: Steuerzeichen als \\u00XX, \\b und \\f mit Kuerzel" 'import std.io;
import std.json;
import std.alloc;
import std.string;
fn main(): int64 {
  var e: int64 := alloc(64);
  StrSetChar(e as pchar, 0, 65); StrSetChar(e as pchar, 1, 1);
  StrSetChar(e as pchar, 2, 2);  StrSetChar(e as pchar, 3, 8);
  StrSetChar(e as pchar, 4, 12); StrSetChar(e as pchar, 5, 31);
  StrSetChar(e as pchar, 6, 66); StrSetChar(e as pchar, 7, 0);
  var o: int64 := alloc(256);
  JSONEscape(o as pchar, e as pchar);
  PrintLn(o as pchar);
  return 0;
}' "\"A\\u0001\\u0002\\b\\f\\u001fB\""

# Der fremde Zeuge: python muss das Ergebnis annehmen. Vorher wies es
# "Invalid control character" zurueck.
printf 'import std.io;\nimport std.json;\nimport std.alloc;\nimport std.string;\nfn main(): int64 {\n  var e: int64 := alloc(64);\n  StrSetChar(e as pchar, 0, 65); StrSetChar(e as pchar, 1, 1);\n  StrSetChar(e as pchar, 2, 9); StrSetChar(e as pchar, 3, 66); StrSetChar(e as pchar, 4, 0);\n  var o: int64 := alloc(256);\n  JSONEscape(o as pchar, e as pchar);\n  PrintStr(o as pchar);\n  return 0;\n}\n' > "$TMP/pj.lyx"
if "$LYXC" --std-path="$ROOT" "$TMP/pj.lyx" -o "$TMP/pj" >/dev/null 2>&1; then
  if "$TMP/pj" | python3 -c 'import json,sys; json.loads(sys.stdin.read())' 2>/dev/null; then
    ok "#1433: python nimmt das Ergebnis an"
  else
    no "#1433: python nimmt das Ergebnis an" "$("$TMP/pj" | python3 -c 'import json,sys
try:
  json.loads(sys.stdin.read())
except Exception as e:
  print(e)' 2>&1 | head -1)"
  fi
else
  no "#1433: python nimmt das Ergebnis an" "uebersetzt nicht"
fi

# ===========================================================================
# #1434 — isValidJSON prueft die Struktur
# ===========================================================================

# Die sechs Faelle aus der Meldung, dazu die Faelle, an denen eine echte
# Pruefung scheitern kann.
out "#1434: Struktur wird geprueft" 'import std.io;
import std.json;
fn v(s: pchar): void { if (isValidJSON(s)) { PrintStr("1"); } else { PrintStr("0"); } }
fn main(): int64 {
  v("{\"a\":1}"c);                  // 1
  v("[1,2,3]"c);                    // 1
  v("nonsense"c);                   // 0
  v("[abc]"c);                      // 0
  v("{,,,}"c);                      // 0
  v("12.5.7"c);                     // 0
  v("[]"c);                         // 1
  v("{}"c);                         // 1
  v("{\"a\":[1,{\"b\":null}]}"c);   // 1
  v("[1,]"c);                       // 0  Komma ohne Wert
  v("{\"a\"}"c);                    // 0  Schluessel ohne Wert
  v("-2.5e10"c);                    // 1  Exponent
  v(" true "c);                     // 1  Leerraum aussen
  v("[1,2"c);                       // 0  nie geschlossen
  PrintLn("");
  return 0;
}' "11000011100110"

# Gegenprobe gegen python: DERSELBE Text wird beiden vorgelegt und das Urteil
# verglichen. Eine Liste erwarteter Werte, die ich selbst hingeschrieben habe,
# waere nur meine Lesart des Standards — hier entscheidet ein fremder Parser.
mismatch=""
geprueft=0
while IFS= read -r eingabe; do
  [ -z "$eingabe" ] && continue
  # Urteil von python
  perw="$(printf '%s' "$eingabe" | python3 -c 'import json,sys
try:
  json.loads(sys.stdin.read()); print(1)
except Exception:
  print(0)')"
  # Urteil von std.json — die Eingabe als Lyx-Literal einsetzen
  lit="$(printf '%s' "$eingabe" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  printf 'import std.io;\nimport std.json;\nfn main(): int64 { if (isValidJSON("%s"c)) { PrintLn("1"); } else { PrintLn("0"); } return 0; }\n' "$lit" > "$TMP/v.lyx"
  rm -f "$TMP/v"
  if "$LYXC" --std-path="$ROOT" "$TMP/v.lyx" -o "$TMP/v" >/dev/null 2>&1; then
    lerw="$("$TMP/v" 2>/dev/null)"
  else
    lerw="uebersetzt nicht"
  fi
  geprueft=$((geprueft+1))
  if [ "$perw" != "$lerw" ]; then
    mismatch="$mismatch [$eingabe: python=$perw lyx=$lerw]"
  fi
done <<'EINGABEN'
{"a":1}
[1,2,3]
nonsense
[abc]
{,,,}
12.5.7
[]
{}
[1,]
-2.5e10
{"a":[1,{"b":null}]}
[1,2
"abc"
true
EINGABEN

if [ -z "$mismatch" ]; then
  ok "#1434: $geprueft Eingaben, dasselbe Urteil wie python"
else
  no "#1434: dasselbe Urteil wie python" "$mismatch"
fi

# ===========================================================================
# #1435 — parseValue meldet, was es gelesen hat
# ===========================================================================

out "#1435: Objekt leert den Puffer, Muell meldet -1" 'import std.io;
import std.json;
import std.alloc;
import std.string;
fn main(): int64 {
  var d: int64 := alloc(64);
  PrintStr(IntToStr(parseValue(d as pchar, "\"x\""c))); PrintStr(":");
  PrintStr(d as pchar); PrintStr(" ");
  PrintStr(IntToStr(parseValue(d as pchar, "{\"a\":1}"c))); PrintStr(":");
  PrintStr(d as pchar); PrintStr(" ");
  PrintStr(IntToStr(parseValue(d as pchar, "Muell"c))); PrintStr(" ");
  PrintLn(IntToStr(parseValue(d as pchar, "42"c)));
  return 0;
}' "3:x 5: -1 2"

out "#1435: die uebrigen Typen bleiben unveraendert" 'import std.io;
import std.json;
import std.alloc;
import std.string;
fn main(): int64 {
  var d: int64 := alloc(64);
  PrintStr(IntToStr(parseValue(d as pchar, "true"c))); PrintStr(" ");
  PrintStr(IntToStr(parseValue(d as pchar, "false"c))); PrintStr(" ");
  PrintStr(IntToStr(parseValue(d as pchar, "null"c))); PrintStr(" ");
  PrintStr(IntToStr(parseValue(d as pchar, "-2.5"c))); PrintStr(" ");
  PrintLn(IntToStr(parseValue(d as pchar, "[1,2]"c)));
  return 0;
}' "1 1 0 2 4"

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
