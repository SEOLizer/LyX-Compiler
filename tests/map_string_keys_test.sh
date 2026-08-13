#!/usr/bin/env bash
# tests/map_string_keys_test.sh — #1291.
#
# `Map<pchar, V>` war abgewiesen, weil die Laufzeit Schlüssel mit `cmp r10, r12`
# vergleicht — also als ZAHL. Bei einem pchar wäre das die Adresse, und zwei
# gleich geschriebene Literale liegen an verschiedenen Adressen: `m["Alpha"c]`
# fände den eigenen Eintrag nicht.
#
# Jetzt gibt es `_lyx_map_str`: FNV-1a über die Bytes bis NUL, Hash im dritten
# Feld des Slots, beim Sondieren zuerst Hash- und dann Byte-Vergleich.
#
# ENTSCHEIDEND für jede Prüfung hier: Schreiben und Lesen benutzen VERSCHIEDENE
# Literale gleichen Inhalts. Mit demselben Literal wäre der Test auch beim
# Adressvergleich grün gewesen — genau die Falle, die #1152 gemeldet hat.
# Eine Prüfung geht weiter und baut den Schlüssel zur Laufzeit zusammen; sie
# schließt auch aus, dass hier bloss Literale zusammengefasst werden.

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
  got="$(timeout 30 "$TMP/p" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then no "$1" "ABSTURZ (rc=$rc)"; return; fi
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1" "'$got' erwartet '$3'"; fi
}

# ===========================================================================
# Der Kern: zwei verschiedene Literale gleichen Inhalts
# ===========================================================================

out "schreiben und lesen ueber verschiedene Literale" 'import std.io;
fn main(): int64 {
  var m: Map<pchar, int64>;
  m["Alpha"c] := 100;
  PrintLn(IntToStr(m["Alpha"c]));
  return 0;
}' "100"

out "mehrere Schluessel nebeneinander" 'import std.io;
fn main(): int64 {
  var m: Map<pchar, int64>;
  m["Alpha"c] := 100;
  m["Beta"c]  := 7;
  PrintStr(IntToStr(m["Beta"c])); PrintStr(" "); PrintLn(IntToStr(m["Alpha"c]));
  return 0;
}' "7 100"

out "ueberschreiben zaehlt keinen neuen Eintrag" 'import std.io;
fn main(): int64 {
  var m: Map<pchar, int64>;
  m["Alpha"c] := 100;
  m["Alpha"c] := 200;
  PrintStr(IntToStr(m["Alpha"c])); PrintStr(" "); PrintLn(IntToStr(len(m)));
  return 0;
}' "200 1"

out "fehlender Schluessel liefert 0 und fuegt nichts ein" 'import std.io;
fn main(): int64 {
  var m: Map<pchar, int64>;
  m["Alpha"c] := 1;
  var x: int64 := m["Gamma"c];
  PrintStr(IntToStr(x)); PrintStr(" "); PrintLn(IntToStr(len(m)));
  return 0;
}' "0 1"

out "in-Operator ueber den Inhalt" 'import std.io;
fn main(): int64 {
  var m: Map<pchar, int64>;
  m["Alpha"c] := 1;
  if ("Alpha"c in m) { PrintStr("ja "); } else { PrintStr("nein "); }
  if ("Gamma"c in m) { PrintLn("ja"); } else { PrintLn("nein"); }
  return 0;
}' "ja nein"

# Die schaerfste Probe: der Schluessel entsteht zur LAUFZEIT. Damit ist
# ausgeschlossen, dass hier nur gleiche Literale zusammengefasst werden —
# verglichen wird wirklich der Inhalt.
out "zur Laufzeit gebauter Schluessel findet den Eintrag" 'import std.io;
fn main(): int64 {
  var m: Map<pchar, int64>;
  m["Alpha"c] := 42;
  var k: pchar := StrNew(8);
  StrSetChar(k, 0, 65); StrSetChar(k, 1, 108); StrSetChar(k, 2, 112);
  StrSetChar(k, 3, 104); StrSetChar(k, 4, 97);  StrSetChar(k, 5, 0);
  PrintStr(IntToStr(m[k])); PrintStr(" ");
  if (k in m) { PrintLn("ja"); } else { PrintLn("nein"); }
  return 0;
}' "42 ja"

# Aehnliche, aber verschiedene Schluessel duerfen sich nicht vermischen —
# ein reiner Hash-Vergleich ohne Byte-Pruefung faellt hier auf.
out "aehnliche Schluessel bleiben getrennt" 'import std.io;
fn main(): int64 {
  var m: Map<pchar, int64>;
  m["Alpha"c]  := 1;
  m["Alpha2"c] := 2;
  m["alpha"c]  := 3;
  m[""c]       := 4;
  PrintStr(IntToStr(m["Alpha"c])); PrintStr(" ");
  PrintStr(IntToStr(m["Alpha2"c])); PrintStr(" ");
  PrintStr(IntToStr(m["alpha"c])); PrintStr(" ");
  PrintStr(IntToStr(m[""c])); PrintStr(" ");
  PrintLn(IntToStr(len(m)));
  return 0;
}' "1 2 3 4 4"

out "Map-Literal mit Zeichenketten-Schluesseln" 'import std.io;
fn main(): int64 {
  var m: Map<pchar, int64> := {"a"c: 1, "b"c: 2};
  PrintStr(IntToStr(m["a"c])); PrintStr(" "); PrintLn(IntToStr(m["b"c]));
  return 0;
}' "1 2"

# Der Schluesseltyp muss auch an einem PARAMETER ankommen: sonst liest die
# gerufene Funktion mit dem Zahlenvergleich und findet nichts, waehrend
# derselbe Zugriff beim Aufrufer stimmt.
out "Map als Parameter behaelt den Schluesseltyp" 'import std.io;
fn lies(m: Map<pchar, int64>): int64 { return m["Alpha"c]; }
fn main(): int64 {
  var m: Map<pchar, int64>;
  m["Alpha"c] := 42;
  PrintStr(IntToStr(m["Alpha"c])); PrintStr(" "); PrintLn(IntToStr(lies(m)));
  return 0;
}' "42 42"

out "viele Schluessel — Sondierung ueber mehrere Slots" 'import std.io;
fn main(): int64 {
  var m: Map<pchar, int64>;
  m["eins"c] := 1; m["zwei"c] := 2; m["drei"c] := 3; m["vier"c] := 4;
  m["fuenf"c] := 5; m["sechs"c] := 6; m["sieben"c] := 7; m["acht"c] := 8;
  var s: int64 := m["eins"c] + m["zwei"c] + m["drei"c] + m["vier"c]
                + m["fuenf"c] + m["sechs"c] + m["sieben"c] + m["acht"c];
  PrintStr(IntToStr(s)); PrintStr(" "); PrintLn(IntToStr(len(m)));
  return 0;
}' "36 8"

# ===========================================================================
# Gegenproben: die ganzzahlige Fassung bleibt unveraendert
# ===========================================================================

out "ganzzahlige Map unveraendert" 'import std.io;
fn main(): int64 {
  var m: Map<int64, int64>;
  m[11] := 100;
  m[22] := 7;
  m[11] := 200;
  PrintStr(IntToStr(m[11])); PrintStr(" ");
  PrintStr(IntToStr(m[22])); PrintStr(" ");
  if (11 in m) { PrintStr("ja "); } else { PrintStr("nein "); }
  PrintLn(IntToStr(len(m)));
  return 0;
}' "200 7 ja 2"

# Ein Schluesseltyp, den die Laufzeit weiterhin nur ueber die Adresse
# vergleichen koennte, wird nach wie vor abgewiesen — der Fix hat die Sperre
# nicht pauschal geoeffnet.
printf 'import std.io;\ntype S = struct { a: int64; };\nfn main(): int64 { var m: Map<S, int64>; return 0; }\n' > "$TMP/r.lyx"
rm -f "$TMP/r"
msg="$("$LYXC" --std-path="$ROOT" "$TMP/r.lyx" -o "$TMP/r" 2>&1)"
if [ -f "$TMP/r" ]; then
  no "unpassender Schluesseltyp bleibt abgewiesen" "uebersetzt, statt zu melden"
else
  case "$msg" in
    *"Ganzzahlen und pchar"*) ok "unpassender Schluesseltyp bleibt abgewiesen" ;;
    *) no "unpassender Schluesseltyp bleibt abgewiesen" "$(echo "$msg" | head -1)" ;;
  esac
fi

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
