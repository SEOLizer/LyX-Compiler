#!/usr/bin/env bash
# tests/codegen_werte_test.sh — #1352, #1338, #1358.
#
# Drei Wege, auf denen der Codegen still falsch rechnete statt zu melden.
#
# #1352: `/` und `%` emittierten immer `cqo; idiv` — auch fuer uint64.
# Vergleiche und Rechtsshift richteten sich laengst nach dem Vorzeichen des
# Typs, Division und Rest nicht. Bei gesetztem obersten Bit las idiv den Wert
# als negativ: 2^64-2 durch 2 ergab -1.
#
# #1338: Konstanten wurden in DEMSELBEN Durchlauf eingetragen, der auch die
# Funktionsruempfe erzeugt. Eine `con`-Zeile unter einer Funktion war beim
# Uebersetzen ihres Rumpfes unbekannt — und loeste still zu 0 auf. Fuer
# Funktionen galt die Vorwaertsreferenz laengst.
#
# #1358: Einheitentypen waren KEINER Typklasse zugeordnet und wurden deshalb
# gar nicht beurteilt. `var d: m := 100.0` ging durch, obwohl
# `var i: int64 := 100.0` abgewiesen wird; die IEEE-Bits landeten in einem
# ganzzahlig gerechneten Slot, und ein spaeteres `as f64` gab sie aus.
#
# Geprueft wird jeweils der WERT, nicht nur dass etwas uebersetzt — bei genau
# diesen Fehlern war das Programm ja lauffaehig.

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
    no "$1" "uebersetzt nicht"; return
  fi
  got="$(timeout 30 "$TMP/p" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then no "$1" "ABSTURZ (rc=$rc)"; return; fi
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1" "'$got' erwartet '$3'"; fi
}

weist_ab() { # name, quelltext, textstueck
  printf '%s\n' "$2" > "$TMP/r.lyx"; rm -f "$TMP/r"
  msg="$("$LYXC" --std-path="$ROOT" "$TMP/r.lyx" -o "$TMP/r" 2>&1)"
  if [ -f "$TMP/r" ]; then no "$1" "uebersetzt, statt zu melden"; return; fi
  case "$msg" in *"$3"*) ok "$1" ;; *) no "$1" "Meldung nennt '$3' nicht: $(echo "$msg"|head -1)" ;; esac
}

# ===========================================================================
# #1352 — vorzeichenlose Division und Rest
# ===========================================================================

# 2^64-2 durch 2. Mit idiv gelesen ist der Dividend -2, das Ergebnis -1.
out "uint64-Division mit gesetztem obersten Bit" 'import std.io;
fn main(): int64 {
  var a: uint64 := 18446744073709551614;
  var b: uint64 := 2;
  PrintLn(IntToStr((a / b) as int64));
  return 0;
}' "9223372036854775807"

out "uint64-Rest mit gesetztem obersten Bit" 'import std.io;
fn main(): int64 {
  var a: uint64 := 18446744073709551614;
  PrintLn(IntToStr((a % 10) as int64));
  return 0;
}' "4"

# Die Gegenprobe ist hier die wichtigere Haelfte: vorzeichenBEHAFTETE Division
# muss weiterhin das Vorzeichen achten. Ein Fix, der pauschal `div` emittiert,
# waere bei den uint64-Faellen ebenso gruen wie dieser hier.
out "signed Division bleibt vorzeichenbehaftet" 'import std.io;
fn main(): int64 {
  var a: int64 := -20;
  var b: int64 := 3;
  PrintStr(IntToStr(a / b)); PrintStr(" "); PrintLn(IntToStr(a % b));
  return 0;
}' "-6 -2"

out "signed Division durch negativen Teiler" 'import std.io;
fn main(): int64 { var a: int64 := -20; var b: int64 := -4; PrintLn(IntToStr(a / b)); return 0; }' "5"

# Kleine vorzeichenlose Werte duerfen sich nicht aendern.
out "uint64 im kleinen Zahlenbereich unveraendert" 'import std.io;
fn main(): int64 {
  var a: uint64 := 100;
  var b: uint64 := 7;
  PrintStr(IntToStr((a / b) as int64)); PrintStr(" "); PrintLn(IntToStr((a % b) as int64));
  return 0;
}' "14 2"

# ===========================================================================
# #1338 — Vorwaertsreferenz auf eine Konstante
# ===========================================================================

out "con unter der Funktion, die sie nutzt" 'import std.io;
fn f(x: int64): int64 { if (x == SPAETER) { return 111; } return 0; }
con SPAETER: int64 := 47;
fn main(): int64 { PrintLn(IntToStr(f(47))); return 0; }' "111"

out "con ueber der Funktion bleibt richtig" 'import std.io;
con FRUEHER: int64 := 47;
fn f(x: int64): int64 { if (x == FRUEHER) { return 111; } return 0; }
fn main(): int64 { PrintLn(IntToStr(f(47))); return 0; }' "111"

# Eine Konstante, die auf eine WEITER UNTEN stehende verweist — dafuer laeuft
# der Vorpass zweimal.
out "con verweist auf eine spaetere con" 'import std.io;
fn f(): int64 { return ABGELEITET; }
con ABGELEITET: int64 := BASIS * 2;
con BASIS: int64 := 21;
fn main(): int64 { PrintLn(IntToStr(f())); return 0; }' "42"

out "Enum-Mitglied vor seiner Deklaration" 'import std.io;
fn f(): int64 { return ROT; }
enum Farbe { ROT = 7, GRUEN = 8 };
fn main(): int64 { PrintLn(IntToStr(f())); return 0; }' "7"

out "Zeichenketten-con unter der Funktion" 'import std.io;
fn f(): pchar { return TEXT; }
con TEXT: pchar := "hallo";
fn main(): int64 { PrintLn(f()); return 0; }' "hallo"

# Gegenprobe: ein Name, den es gar nicht gibt, bleibt ein Fehler — der Vorpass
# darf keine stille Null durch eine stille Registrierung ersetzen.
weist_ab "unbekannter Bezeichner bleibt ein Fehler" 'import std.io;
fn f(): int64 { return GIBTESNICHT; }
fn main(): int64 { PrintLn(IntToStr(f())); return 0; }' "undefined symbol"

# ===========================================================================
# #1358 — Einheitentypen werden beurteilt
# ===========================================================================

# Einheitentypen rechnen ganzzahlig; ein Gleitkomma-Startwert ist derselbe
# Fehler wie bei int64 und wird jetzt genauso gemeldet.
weist_ab "f64-Startwert fuer einen Einheitentyp wird gemeldet" 'import std.io;
dim Length;
utype m: Length = 1.0;
fn main(): int64 { var d: m := 100.0; return d as int64; }' "Einheitentyp erwartet, f64 gegeben"

out "Einheitentyp mit Ganzzahl rechnet richtig" 'import std.io;
dim Length;
utype m: Length = 1.0;
fn main(): int64 {
  var d: m := 100;
  var f: f64 := d as f64;
  var e: m := d * 2;
  PrintStr(IntToStr(d as int64)); PrintStr(" ");
  PrintStr(IntToStr(f as int64)); PrintStr(" ");
  PrintLn(IntToStr(e as int64));
  return 0;
}' "100 100 200"

# Die Dimensionspruefung darf durch die neue Typklasse nicht verlorengehen.
weist_ab "Dimensionswechsel bleibt gemeldet" 'dim Length;
dim Zeit;
utype m: Length = 1.0;
utype s: Zeit = 1.0;
fn main(): int64 { var a: m := 5; var b: s := a; return b as int64; }' "Dimensionsgrenzen"

out "gleiche Dimension bleibt zuweisbar" 'import std.io;
dim Length;
utype m: Length = 1.0;
fn main(): int64 { var a: m := 5; var b: m := a; PrintLn(IntToStr(b as int64)); return 0; }' "5"

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
