#!/usr/bin/env bash
# tests/ini_haerte_test.sh — #1426, #1427, #1428, #1429.
#
# Vier Meldungen zu std.ini. Der schwerste Fall ist ein Heap-Overflow bei jedem
# Schreibvorgang, der den Text verlängert — und INI-Werte kommen aus
# Konfigurationsdateien, also von außen.
#
#   #1426  ParseString legt den Puffer exakt so groß wie den Ausgangstext an;
#          jede Änderung kopiert aus einem 64-KB-Zwischenpuffer dorthin zurück
#   #1427  EscapeValue maskiert ';' und '#' nicht, GetString schneidet dort ab
#   #1428  GetString alloziert je Aufruf, es gab keine Funktion zum Freigeben
#   #1429  fünf MAX_*-Konstanten, die nichts begrenzen und nichts beschreiben
#
# ZUR AUSSAGEKRAFT: bei #1426 wird der NACHBARBLOCK geprüft, nicht der
# Rückgabewert. Eine Schreibfunktion, die den Überlauf meldet und trotzdem
# schreibt, wäre bei einer Rückgabeprüfung grün. Bei #1428 wird der
# Adressabstand einer Größenklasse vor und nach 1000 Aufrufen verglichen — ein
# Leck zeigt sich nur so, nicht am Ergebnis der einzelnen Abfrage.

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
  got="$(timeout 60 "$TMP/p" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then no "$1" "ABSTURZ (rc=$rc)"; return; fi
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1" "'$got' erwartet '$3'"; fi
}

# ===========================================================================
# #1426 — der Dokumentpuffer haelt, was hineingeschrieben wird
# ===========================================================================

# Reproduktion aus dem Issue. Entscheidend ist das Wachtbyte: 108 Zeichen
# gingen vorher in einen 9-Byte-Puffer.
out "#1426: Verlaengern ueberschreibt den Nachbarn nicht" 'import std.io;
import std.ini;
import std.alloc;
import std.string;

fn main(): int64 {
    var doc: int64 := ParseString("[a]\nk=1\n"c);
    var wache: int64 := alloc(64);
    var i: int64 := 0;
    while (i < 64) { poke8(wache + i, 0x7A); i := i + 1; }

    SetString(doc, "a"c, "sehr_langer_schluessel"c, "und_ein_sehr_langer_wert_dazu"c);
    SetString(doc, "neu"c, "zweiter"c, "auch_das_passt_nicht_mehr_hinein"c);

    PrintLn(StrConcat("Laenge nach Set: ", IntToStr(StrLen(doc as pchar))));
    PrintLn(StrConcat("Wachtbyte (erwartet 122): ", IntToStr(peek8(wache))));
    return 0;
}' "Laenge nach Set: 108
Wachtbyte (erwartet 122): 122"

# Der Fix darf das Schreiben nicht bloss verhindern — die Werte muessen
# nachher auch dastehen. Ohne diese Probe waere ein `return` am Anfang von
# SetString ebenfalls gruen.
out "#1426: die geschriebenen Werte sind lesbar" 'import std.io;
import std.ini;
import std.string;
fn main(): int64 {
    var doc: int64 := ParseString("[a]\nk=1\n"c);
    SetString(doc, "a"c, "zwei"c, "b"c);
    SetString(doc, "neu"c, "drei"c, "c"c);
    PrintStr(GetString(doc, "a"c, "k"c, "?"c)); PrintStr(" ");
    PrintStr(GetString(doc, "a"c, "zwei"c, "?"c)); PrintStr(" ");
    PrintLn(GetString(doc, "neu"c, "drei"c, "?"c));
    return 0;
}' "1 b c"

# Ueber der Grenze wird gemeldet statt geschrieben.
out "#1426: zu grosse Eingabe wird abgewiesen" 'import std.io;
import std.ini;
import std.alloc;
import std.string;
fn main(): int64 {
    var gross: int64 := alloc(70000);
    var i: int64 := 0;
    while (i < 69999) { poke8(gross + i, 120); i := i + 1; }
    poke8(gross + 69999, 0);
    PrintLn(IntToStr(ParseString(gross as pchar)));
    return 0;
}' "0"

# ===========================================================================
# #1427 — Semikolon und Doppelkreuz ueberleben den Rundlauf
# ===========================================================================

out "#1427: EscapeValue maskiert ; und #" 'import std.io;
import std.ini;
import std.alloc;
fn main(): int64 {
    var o: int64 := alloc(256);
    EscapeValue("Hallo; Welt # jetzt"c, o as pchar);
    PrintLn(o as pchar);
    var u: int64 := alloc(256);
    UnescapeValue(o as pchar, u as pchar);
    PrintLn(u as pchar);
    return 0;
}' "Hallo\; Welt \# jetzt
Hallo; Welt # jetzt"

# Der Inline-Kommentar bleibt, was er ist — sonst waere aus dem Fix ein
# Fehler in der Gegenrichtung geworden.
out "#1427: unmaskiertes ; bleibt Kommentarbeginn" 'import std.io;
import std.ini;
fn main(): int64 {
    var doc: int64 := ParseString("[a]\ntext = Hallo; Welt\n"c);
    PrintLn(GetString(doc, "a"c, "text"c, "?"c));
    return 0;
}' "Hallo"

out "#1427: die uebrigen Maskierungen bleiben unveraendert" 'import std.io;
import std.ini;
import std.alloc;
fn main(): int64 {
    var o: int64 := alloc(256);
    EscapeValue("a\\b"c, o as pchar);
    PrintLn(o as pchar);
    return 0;
}' "a\\\\b"

# ===========================================================================
# #1428 — Freigabe ist moeglich
# ===========================================================================

# Reproduktion aus dem Issue, mit FreeString ergaenzt: der Abstand muss 0 sein.
out "#1428: 1000 Abfragen mit FreeString verbrauchen nichts" 'import std.io;
import std.ini;
import std.alloc;
import std.string;
fn main(): int64 {
    var doc: int64 := ParseString("[a]\nk=1234567890\n"c);
    var a: int64 := alloc(16); free(a, 16);
    var vorher: int64 := alloc(16); free(vorher, 16);
    var i: int64 := 0;
    while (i < 1000) {
      var v: pchar := GetString(doc, "a"c, "k"c, "?"c);
      FreeString(v);
      i := i + 1;
    }
    var nachher: int64 := alloc(16);
    PrintLn(StrConcat("Abstand: ", IntToStr(nachher - vorher)));
    return 0;
}' "Abstand: 0"

out "#1428: FreeDocument gibt den Dokumentpuffer zurueck" 'import std.io;
import std.ini;
import std.alloc;
import std.string;
fn main(): int64 {
    var a: int64 := alloc(65536); free(a, 65536);
    var vorher: int64 := alloc(65536); free(vorher, 65536);
    var i: int64 := 0;
    while (i < 20) {
      var doc: int64 := ParseString("[a]\nk=1\n"c);
      FreeDocument(doc);
      i := i + 1;
    }
    var nachher: int64 := alloc(65536);
    PrintLn(StrConcat("Abstand: ", IntToStr(nachher - vorher)));
    return 0;
}' "Abstand: 0"

# Nullzeiger duerfen nicht abstuerzen — beide Funktionen werden im Fehlerfall
# aufgerufen, wo der Wert 0 sein kann.
out "#1428: Freigabe von 0 ist harmlos" 'import std.io;
import std.ini;
fn main(): int64 {
    FreeString(0 as pchar);
    FreeDocument(0);
    PrintLn("ok");
    return 0;
}' "ok"

# ===========================================================================
# #1429 — die Konstanten, die nichts begrenzten, sind weg
# ===========================================================================

# Ein Verweis auf eine der fuenf muss jetzt beim Uebersetzen scheitern. Solange
# sie dastanden, sagten sie etwas zu, woran sich der Code nicht hielt.
printf 'import std.ini;\nfn main(): int64 { return MAX_KEY_LENGTH; }\n' > "$TMP/k.lyx"
rm -f "$TMP/k"
if "$LYXC" --std-path="$ROOT" "$TMP/k.lyx" -o "$TMP/k" >/dev/null 2>&1; then
  no "#1429: MAX_KEY_LENGTH gibt es nicht mehr" "uebersetzt weiterhin"
else
  ok "#1429: MAX_KEY_LENGTH gibt es nicht mehr"
fi

# INI_BUFFER_SIZE ist die eine echte Grenze und bleibt.
out "#1429: INI_BUFFER_SIZE bleibt und stimmt" 'import std.io;
import std.ini;
fn main(): int64 { PrintLn(IntToStr(INI_BUFFER_SIZE)); return 0; }' "65536"

# Und das Verhalten, das die Konstanten behaupteten, bleibt wie es war: ein
# langer Schluessel geht durch. Das ist kein Mangel, sondern der Ist-Zustand,
# der jetzt nicht mehr bestritten wird.
out "#1429: langer Schluessel geht weiterhin durch" 'import std.io;
import std.ini;
import std.string;
fn main(): int64 {
    var doc: int64 := ParseString("[a]\n"c);
    SetString(doc, "a"c, "ein_sehr_langer_schluessel_mit_deutlich_mehr_als_vierundsechzig_zeichen_laenge"c, "x"c);
    PrintLn(GetString(doc, "a"c, "ein_sehr_langer_schluessel_mit_deutlich_mehr_als_vierundsechzig_zeichen_laenge"c, "FEHLT"c));
    return 0;
}' "x"

# ===========================================================================
# #1827 — WriteString schreibt das Dokument, nicht einen Beispieltext
# ===========================================================================

# Reproduktion aus dem Issue, woertlich. Vorher kam hier
# "# Generated by std.ini / [Settings] / key=value" heraus — egal, was in doc
# stand. Geprueft wird der INHALT: der Rueckgabewert war auch vorher plausibel
# (Laenge des Beispieltexts), eine Rueckgabepruefung waere gruen gewesen.
out "#1827: WriteString gibt das Dokument aus" 'import std.io;
import std.ini;
import std.alloc;

fn main(): int64 {
  var doc: int64 := ParseString("[s]\nk=1\n"c);
  SetString(doc, "s"c, "sem"c, "Hallo Welt"c);
  var o: pchar := alloc(4096) as pchar;
  WriteString(doc, o, 4096);
  PrintLn(o);
  return 0;
}' '[s]
k=1
sem=Hallo Welt'

# Der Beispieltext darf nirgends mehr auftauchen — auch nicht als Kopfzeile.
out "#1827: kein Beispieltext mehr im Ergebnis" 'import std.io;
import std.ini;
import std.alloc;
import std.string;

fn main(): int64 {
  var doc: int64 := ParseString("[eigen]\nwert=7\n"c);
  var o: pchar := alloc(4096) as pchar;
  WriteString(doc, o, 4096);
  if (StrFind(o, "[Settings]"c) >= 0) { PrintLn("BEISPIEL"); return 0; }
  if (StrFind(o, "Generated by"c) >= 0) { PrintLn("KOPFZEILE"); return 0; }
  PrintLn("sauber");
  return 0;
}' "sauber"

# WriteString und WriteFile muessen denselben Text liefern — sie sind zwei
# Wege zu einem Inhalt, und genau dieses Auseinanderlaufen war der Defekt.
out "#1827: WriteString == WriteFile" 'import std.io;
import std.ini;
import std.alloc;
import std.string;

fn main(): int64 {
  var doc: int64 := ParseString("[a]\nx=1\n"c);
  SetString(doc, "a"c, "y"c, "zwei"c);
  var o: pchar := alloc(4096) as pchar;
  WriteString(doc, o, 4096);
  WriteFile(doc, "/tmp/lyx_ini_1827.ini"c);
  var wieder: int64 := LoadFile("/tmp/lyx_ini_1827.ini"c);
  if (wieder == 0) { PrintLn("LADEN FEHLGESCHLAGEN"); return 0; }
  if (StrCmp(o, wieder as pchar) == 0) { PrintLn("gleich"); } else { PrintLn("VERSCHIEDEN"); }
  return 0;
}' "gleich"

# Zu kleiner Puffer: -1 und NICHTS geschrieben. Eine stille Kuerzung ergaebe
# eine INI-Datei, der die letzten Abschnitte fehlen — plausibel und falsch.
out "#1827: zu kleiner Puffer meldet und schreibt nicht" 'import std.io;
import std.ini;
import std.alloc;
import std.string;

fn main(): int64 {
  var doc: int64 := ParseString("[abschnitt]\nschluessel=wert\n"c);
  var o: pchar := alloc(64) as pchar;
  var i: int64 := 0;
  while (i < 64) { poke8((o as int64) + i, 0x7A); i := i + 1; }
  var r: int64 := WriteString(doc, o, 8);
  PrintLn(IntToStr(r));
  PrintLn(IntToStr(peek8(o as int64)));
  return 0;
}' "-1
122"

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
