#!/usr/bin/env bash
# tests/import_namensraum_test.sh — #1262.
#
# 110 der 5140 `pub`-Funktionen in std/ werden von mehr als einer Unit
# exportiert; 31 Unit-Paare ließen sich deshalb nicht gemeinsam importieren.
# Der Fehler trat schon beim bloßen Import auf, das Symbol musste gar nicht
# verwendet werden. Einen Ausweg gab es nicht: kein Alias-Import, kein
# qualifizierter Aufruf, und `restrict` änderte nichts.
#
# Jetzt: `import eins as e;` legt die Unit in einen eigenen Namensraum, und
# `e.Wert()` bindet gezielt.
#
# WAS DIESER TEST WIRKLICH PRÜFT: nicht „übersetzt", sondern WELCHE Funktion
# gebunden wird. Beide Units führen `Wert()` — die eine gibt 11 zurück, die
# andere 22. Ein Aufruf, der an der falschen landet, ist hier sichtbar; bei
# gleichem Rückgabewert wäre er es nicht. Genau das ist die Gefahr an dieser
# Änderung: sema kann den Aufruf erlauben, während der Codegen ihn an die
# falsche Marke patcht, weil dort beide Funktionen schlicht `Wert` heißen.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cp "$ROOT/tests/data/ns/eins.lyx" "$ROOT/tests/data/ns/zwei.lyx" "$TMP/" 2>/dev/null
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/p.lyx"; rm -f "$TMP/p"
  if ! (cd "$TMP" && "$LYXC" --std-path="$ROOT" p.lyx -o p >/dev/null 2>&1); then
    no "$1" "uebersetzt nicht: $(cd "$TMP" && "$LYXC" --std-path="$ROOT" p.lyx -o p 2>&1 | grep -i error | head -1)"
    return
  fi
  got="$(cd "$TMP" && timeout 30 ./p 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then no "$1" "ABSTURZ (rc=$rc)"; return; fi
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1" "'$got' erwartet '$3'"; fi
}

fehler() { # name, quelltext, erwartetes textstueck
  printf '%s\n' "$2" > "$TMP/p.lyx"; rm -f "$TMP/p"
  msg="$(cd "$TMP" && "$LYXC" --std-path="$ROOT" p.lyx -o p 2>&1)"
  if [ -f "$TMP/p" ]; then no "$1" "uebersetzt, statt zu melden"; return; fi
  case "$msg" in
    *"$3"*) ok "$1" ;;
    *) no "$1" "$(echo "$msg" | grep -i error | head -1)" ;;
  esac
}

# ===========================================================================
# Der Kern: zwei gleichnamige Funktionen, beide erreichbar, jede die richtige
# ===========================================================================

out "beide Wert() nebeneinander, jede bindet richtig" 'import std.io;
import eins as e;
import zwei as z;
fn main(): int64 {
  PrintStr(IntToStr(e.Wert())); PrintStr(" ");
  PrintStr(IntToStr(z.Wert())); PrintStr(" ");
  PrintStr(IntToStr(e.NurEins())); PrintStr(" ");
  PrintLn(IntToStr(z.NurZwei()));
  return 0;
}' "11 22 1 2"

# Argumente: ein Namensraum-Aufruf ist im Baum ein METHODENaufruf, seine
# Argumente stehen deshalb in einem anderen Feld als bei einem gewoehnlichen.
# Wird das verwechselt, liest der Aufgerufene, was zufaellig in den Registern
# steht — und ein Test ohne Argumente merkt davon nichts.
out "Argumente kommen an" 'import std.io;
import eins as e;
import zwei as z;
fn main(): int64 {
  PrintStr(IntToStr(e.Summe(1, 2))); PrintStr(" ");
  PrintLn(IntToStr(z.Summe(1, 2)));
  return 0;
}' "103 203"

out "Namensraum-Aufruf im Ausdruck und geschachtelt" 'import std.io;
import eins as e;
import zwei as z;
fn main(): int64 {
  PrintStr(IntToStr(e.Wert() + z.Wert())); PrintStr(" ");
  PrintLn(IntToStr(e.Summe(z.Wert(), e.Wert())));
  return 0;
}' "33 133"

# ===========================================================================
# Gegenproben — die Sperre bleibt, wo sie hingehoert
# ===========================================================================

# OHNE Alias muss die Mehrdeutigkeit weiterhin gemeldet werden. Faellt diese
# Pruefung weg, waere aus dem Ausweg eine neue stille Falle geworden.
fehler "ohne Alias bleibt es mehrdeutig" 'import std.io;
import eins;
import zwei;
fn main(): int64 { PrintLn(IntToStr(Wert())); return 0; }' "mehrdeutiges Symbol"

# Eine aliasierte Unit ist NICHT flach sichtbar — sonst waere der Namensraum
# nur Zierde und die Kollision zurueck.
fehler "aliasierte Unit ist flach unsichtbar" 'import std.io;
import eins as e;
fn main(): int64 { PrintLn(IntToStr(Wert())); return 0; }' "undefined"

fehler "unbekannter Name im Namensraum wird gemeldet" 'import std.io;
import eins as e;
fn main(): int64 { PrintLn(IntToStr(e.GibtEsNicht())); return 0; }' "Namensraum"

# ===========================================================================
# Mischbetrieb: einer flach, einer im Namensraum
# ===========================================================================

# Das ist der praktische Fall aus dem Issue: eine Unit benutzt man staendig,
# die andere selten. Nur die zweite bekommt einen Alias.
out "eine flach, eine im Namensraum" 'import std.io;
import eins;
import zwei as z;
fn main(): int64 {
  PrintStr(IntToStr(Wert())); PrintStr(" ");
  PrintStr(IntToStr(z.Wert())); PrintStr(" ");
  PrintLn(IntToStr(NurEins()));
  return 0;
}' "11 22 1"

# ===========================================================================
# Was der Alias NICHT tut — festgehalten, damit es nicht als Fehler gilt
# ===========================================================================

# Der Alias wirkt nur auf die DIREKT importierte Unit. Was sie ihrerseits
# importiert, bleibt flach sichtbar. Anders waere `alloc` aus std.alloc
# ploetzlich `e_alloc`, und jede Unit muesste ihre Abhaengigkeiten mit
# umbenennen lassen.
out "transitive Importe bleiben flach sichtbar" 'import std.io;
import std.string as s;
fn main(): int64 {
  PrintLn(IntToStr(StrLen("abcd"c)));
  return 0;
}' "4"

# Der Standardfall ohne jeden Alias muss unveraendert laufen — die
# Sichtbarkeitspruefung liegt in Lookup und damit auf JEDEM Nachschlagen.
out "Standardbibliothek ohne Alias unveraendert" 'import std.io;
import std.string;
fn main(): int64 {
  PrintStr(IntToStr(StrLen("hallo"c))); PrintStr(" ");
  PrintLn(StrConcat("a", "b"));
  return 0;
}' "5 ab"

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
