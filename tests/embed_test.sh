#!/usr/bin/env bash
# #1961 Stufe 1: `@embed("pfad")` bettet den Dateiinhalt zur Uebersetzungszeit
# ein, `@embed_len("pfad")` liefert die Groesse.
#
# GEMESSEN WIRD DER INHALT, nicht das Vorhandensein. Ein Test, der nur prueft,
# dass ein Zeiger ungleich null herauskommt oder dass das Programm uebersetzt,
# waere auch von einer Fassung erfuellt, die eine leere Ressource einbettet —
# und genau das ist der Ausfall, den man nicht bemerkt.
#
# Die Pfade sind RELATIV ZUR QUELLDATEI aufzuloesen (wie beim Import). Deshalb
# wird der Aufruf aus einem ANDEREN Arbeitsverzeichnis heraus gemessen: haenge
# die Aufloesung am Arbeitsverzeichnis, faende der Compiler die Datei nicht.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

# Die Daten liegen neben der Quelldatei, wie es der Normalfall ist.
cp "$ROOT/tests/data/embed_binaer.bin" "$TMP/binaer.bin"
cp "$ROOT/tests/data/embed_text.txt"   "$TMP/text.txt"

pruefe() {  # Name, Quelltext, erwartete Ausgabe, [zusaetzliche lyxc-Argumente]
    local name="$1" src="$2" soll="$3" extra="${4:-}"
    printf '%s' "$src" > "$TMP/p.lyx"
    if ! ( cd / && timeout 120 "$LYXC" $extra --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p" ) >"$TMP/b.log" 2>&1; then
        nok "$name: uebersetzt nicht"; sed -n '1,4p' "$TMP/b.log"; return
    fi
    local ist
    ist="$( ulimit -v 4000000; timeout 60 "$TMP/p" 2>&1 )"
    if [ "$ist" = "$soll" ]; then ok "$name"
    else nok "$name: erwartet '$soll', bekommen '$ist'"; fi
}

echo "--- Stufe 1: Inhalt und Groesse (#1961) ---"

# Die Groesse ist eine Uebersetzungszeit-Konstante.
pruefe "Groesse einer Textdatei" 'unit main;
import std.io;
fn main(): int64 { PrintLn(IntToStr(@embed_len("text.txt"))); return 0; }' '28'

# Der INHALT muss ankommen — vollstaendig, nicht nur der Anfang.
pruefe "Inhalt einer Textdatei" 'unit main;
import std.io;
fn main(): int64 { PrintLn(@embed("text.txt")); return 0; }' 'Hallo Welt aus einer Vorlage'

# BINAERE Daten: die Datei enthaelt ein NULLBYTE an Position 2. Genau daran
# scheitert jede textbasierte Einbettung — und der Fehler faellt erst auf,
# wenn jemand ein Bild einbettet und nur dessen Anfang bekommt.
pruefe "binaere Daten samt Nullbyte" 'unit main;
import std.io;
fn main(): int64 {
  var p: pchar := @embed("binaer.bin");
  var n: int64 := @embed_len("binaer.bin");
  PrintStr(IntToStr(n));
  var i: int64 := 0;
  while (i < n) { PrintStr(" "); PrintStr(IntToStr(peek8((p as int64) + i) as int64)); i := i + 1; }
  PrintLn("");
  return 0;
}' '5 65 66 0 67 68'

# Zweimal derselbe Pfad: EINE Kopie im Erzeugnis. Gemessen an den Adressen —
# sind sie gleich, wurde wiederverwendet.
pruefe "gleicher Pfad wird wiederverwendet" 'unit main;
import std.io;
fn main(): int64 {
  var a: pchar := @embed("text.txt");
  var b: pchar := @embed("text.txt");
  PrintLn(IntToStr((a as int64) - (b as int64)));
  return 0;
}' '0'

# --- Fehlende Datei: LAUT, mit Pfad -----------------------------------------
#
# Ein stiller Ersatz (leere Ressource, Offset 0) waere die schlimmste Antwort:
# das Programm liefe und zeigte nichts.
printf 'unit main;\nimport std.io;\nfn main(): int64 { PrintLn(IntToStr(@embed_len("gibtesnicht.bin"))); return 0; }' > "$TMP/f.lyx"
if ( cd / && timeout 120 "$LYXC" --std-path="$ROOT" "$TMP/f.lyx" -o "$TMP/f" ) >"$TMP/f.log" 2>&1; then
    nok "fehlende Datei wird gemeldet: uebersetzt durch, statt zu melden"
elif grep -q "Datei nicht lesbar" "$TMP/f.log"; then
    ok "fehlende Datei wird gemeldet"
else
    nok "fehlende Datei: falsche Meldung ($(head -1 "$TMP/f.log"))"
fi

# Der Pfad MUSS ein Literal sein — zur Uebersetzungszeit gibt es keinen
# Laufzeitwert, aus dem sich ein Dateiname ergaebe.
printf 'unit main;\nimport std.io;\nfn main(): int64 { var s: pchar := "x"; PrintLn(@embed(s)); return 0; }' > "$TMP/v.lyx"
if ( cd / && timeout 120 "$LYXC" --std-path="$ROOT" "$TMP/v.lyx" -o "$TMP/v" ) >"$TMP/v.log" 2>&1; then
    nok "berechneter Pfad wird abgewiesen: uebersetzt durch"
elif grep -q "Zeichenketten-Literal" "$TMP/v.log"; then
    ok "berechneter Pfad wird abgewiesen"
else
    nok "berechneter Pfad: falsche Meldung ($(head -1 "$TMP/v.log"))"
fi

# --- Zweites Ziel: der gemeinsame IR-Weg -------------------------------------
#
# x86 geht direkt aus dem AST, alle anderen Ziele ueber ir_lower. Eine
# Einbettung, die nur auf einem der beiden Wege ankommt, ist genau die
# unvollstaendige Aufzaehlung, an der hier schon mehrfach etwas still
# ausgefallen ist. Gemessen wird deshalb AUSGEFUEHRT, nicht uebersetzt.
if command -v qemu-aarch64-static >/dev/null 2>&1; then
    printf 'unit main;\nimport std.io;\nfn main(): int64 { PrintLn(IntToStr(@embed_len("text.txt"))); PrintLn(@embed("text.txt")); return 0; }' > "$TMP/a.lyx"
    if ( cd / && timeout 180 "$LYXC" --target=arm64 --std-path="$ROOT" "$TMP/a.lyx" -o "$TMP/a" ) >"$TMP/a.log" 2>&1; then
        aus="$( ulimit -v 4000000; timeout 60 qemu-aarch64-static "$TMP/a" 2>&1 )"
        if [ "$aus" = "28
Hallo Welt aus einer Vorlage" ]; then
            ok "arm64 (IR-Weg) bettet denselben Inhalt ein"
        else
            nok "arm64: bekommen '$aus'"
        fi
    else
        nok "arm64: uebersetzt nicht"; sed -n '1,4p' "$TMP/a.log"
    fi

    # Binaerdaten auf dem IR-Weg: die Zeichenkettentabelle dort ist
    # NULLTERMINIERT, alles ab dem ersten Nullbyte ginge verloren. Das MUSS
    # gemeldet werden — ein halbes Bild ist schlimmer als ein Fehlschlag.
    printf 'unit main;\nimport std.io;\nfn main(): int64 { PrintLn(IntToStr(peek8(@embed("binaer.bin") as int64) as int64)); return 0; }' > "$TMP/ab.lyx"
    if ( cd / && timeout 180 "$LYXC" --target=arm64 --std-path="$ROOT" "$TMP/ab.lyx" -o "$TMP/ab" ) >"$TMP/ab.log" 2>&1; then
        nok "arm64 mit Nullbyte: uebersetzt durch, statt zu melden"
    elif grep -q "Nullbyte" "$TMP/ab.log"; then
        ok "arm64 meldet das Nullbyte, statt still abzuschneiden"
    else
        nok "arm64 mit Nullbyte: falsche Meldung ($(head -1 "$TMP/ab.log"))"
    fi
else
    echo "HINWEIS qemu-aarch64-static fehlt — der IR-Weg bleibt hier ungemessen"
fi

# ===========================================================================
# Stufe 2: benannte Ressourcen (@resource + std.res)
# ===========================================================================
#
# Unterschied zu Stufe 1: der Zugriff laeuft ueber den NAMEN und wird zur
# LAUFZEIT aufgeloest. Damit ist er auch dann moeglich, wenn der Name erst
# zur Laufzeit feststeht — und Werkzeuge koennen die Tabelle auflisten.

cp "$ROOT/tests/data/embed_binaer.bin" "$TMP/binaer.bin"
printf 'zweite Datei' > "$TMP/zweite.txt"

pruefe "Tabelle: Anzahl und Name" 'unit main;
import std.io;
import std.res;
@resource("vorlage", "text.txt");
@resource("zweite", "zweite.txt");
fn main(): int64 {
  PrintStr(IntToStr(ResCount())); PrintStr(" ");
  PrintStr(ResName(0)); PrintStr(" ");
  PrintLn(ResName(1));
  return 0;
}' '2 vorlage zweite'

# Der INHALT muss ueber den Namen auffindbar sein, nicht nur die Groesse.
pruefe "Suche nach Namen liefert den Inhalt" 'unit main;
import std.io;
import std.res;
@resource("vorlage", "text.txt");
fn main(): int64 {
  PrintStr(IntToStr(ResLen("vorlage"))); PrintStr(" ");
  PrintLn(ResFind("vorlage"));
  return 0;
}' '28 Hallo Welt aus einer Vorlage'

# BINAER: die Tabelle fuehrt eine eigene Laenge, ist also nicht auf die
# Nullterminierung angewiesen. Genau das ist der Vorteil gegenueber einem
# blossen Zeiger.
pruefe "binaere Ressource samt Nullbyte" 'unit main;
import std.io;
import std.res;
@resource("bild", "binaer.bin");
fn main(): int64 {
  var p: pchar := ResFind("bild");
  var n: int64 := ResLen("bild");
  PrintStr(IntToStr(n));
  var i: int64 := 0;
  while (i < n) { PrintStr(" "); PrintStr(IntToStr(peek8((p as int64) + i) as int64)); i := i + 1; }
  PrintLn("");
  return 0;
}' '5 65 66 0 67 68'

# GEGENPROBE: ein Name, den es nicht gibt, muss als "gibt es nicht" ankommen.
# ResFind liefert den Nullzeiger, ResLen -1 — und NICHT 0: eine Ressource darf
# leer sein, dann waere 0 von "fehlt" nicht zu unterscheiden.
pruefe "unbekannter Name meldet sich als fehlend" 'unit main;
import std.io;
import std.res;
@resource("vorlage", "text.txt");
fn main(): int64 {
  PrintStr(IntToStr(ResLen("gibtesnicht"))); PrintStr(" ");
  if (ResFind("gibtesnicht") == 0 as pchar) { PrintLn("null"); } else { PrintLn("ZEIGER"); }
  return 0;
}' '-1 null'

# Ein Programm OHNE jede Ressource darf nicht abstuerzen: die Tabelle fehlt,
# GetResTable liefert 0, und jede Funktion muss das abfangen.
pruefe "ohne Ressourcen bleibt std.res benutzbar" 'unit main;
import std.io;
import std.res;
fn main(): int64 {
  PrintStr(IntToStr(ResCount())); PrintStr(" ");
  PrintStr(IntToStr(ResLen("x"))); PrintStr(" ");
  if (ResName(0) == 0 as pchar) { PrintLn("null"); } else { PrintLn("ZEIGER"); }
  return 0;
}' '0 -1 null'

# Doppelter Name: FEHLER, nicht "letzter gewinnt". Ein stiller Austausch waere
# erst am laufenden Programm zu bemerken.
printf 'unit main;\nimport std.io;\nimport std.res;\n@resource("a", "text.txt");\n@resource("a", "zweite.txt");\nfn main(): int64 { PrintLn(IntToStr(ResCount())); return 0; }' > "$TMP/d.lyx"
if ( cd / && timeout 120 "$LYXC" --std-path="$ROOT" "$TMP/d.lyx" -o "$TMP/d" ) >"$TMP/d.log" 2>&1; then
    nok "doppelter Name wird gemeldet: uebersetzt durch"
elif grep -q "zweimal vor" "$TMP/d.log"; then
    ok "doppelter Name wird gemeldet"
else
    nok "doppelter Name: falsche Meldung ($(grep -v Copyright "$TMP/d.log" | head -1))"
fi

# Fehlende Ressourcendatei: LAUT, mit Pfad.
printf 'unit main;\nimport std.io;\nimport std.res;\n@resource("x", "fehlt.bin");\nfn main(): int64 { PrintLn(IntToStr(ResCount())); return 0; }' > "$TMP/rf.lyx"
if ( cd / && timeout 120 "$LYXC" --std-path="$ROOT" "$TMP/rf.lyx" -o "$TMP/rf" ) >"$TMP/rf.log" 2>&1; then
    nok "fehlende Ressourcendatei wird gemeldet: uebersetzt durch"
elif grep -q "Datei nicht lesbar" "$TMP/rf.log"; then
    ok "fehlende Ressourcendatei wird gemeldet"
else
    nok "fehlende Ressourcendatei: falsche Meldung ($(grep -v Copyright "$TMP/rf.log" | head -1))"
fi

# Auf dem IR-Weg gibt es die Tabelle noch nicht. Das MUSS an der Deklaration
# gemeldet werden — und zwar auch dann, wenn das Programm die Ressource gar
# nicht liest, sonst uebersetzte es klanglos ohne sie durch.
if command -v qemu-aarch64-static >/dev/null 2>&1; then
    printf 'unit main;\nimport std.io;\n@resource("x", "text.txt");\nfn main(): int64 { PrintLn("nichts"); return 0; }' > "$TMP/ri.lyx"
    if ( cd / && timeout 180 "$LYXC" --target=arm64 --std-path="$ROOT" "$TMP/ri.lyx" -o "$TMP/ri" ) >"$TMP/ri.log" 2>&1; then
        nok "arm64 mit @resource: uebersetzt durch, statt zu melden"
    elif grep -q "nur mit --target=x86_64" "$TMP/ri.log"; then
        ok "arm64 meldet @resource, statt still ohne Tabelle zu bauen"
    else
        nok "arm64 mit @resource: falsche Meldung ($(grep -v Copyright "$TMP/ri.log" | head -1))"
    fi
fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
