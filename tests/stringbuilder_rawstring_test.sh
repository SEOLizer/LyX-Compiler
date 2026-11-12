#!/usr/bin/env bash
# tests/stringbuilder_rawstring_test.sh — #1377, #1378 (Teil), #1381.
#
# #1377: StringBuilder legte seinen Puffer bei Init einmal an und vergrösserte
# ihn nie. `StrAppendStr` hängt an Ort und Stelle an und kennt keine
# Kapazität — drei Append nach `Init(16)` genügten, um den Heap zu
# zerschreiben (rc=139). Ausserdem stand im Builder zweimal
# `poke64(addr - 8, …)`, als trüge `StrNew` ein Längenwort vor dem Puffer;
# es ist ein blankes mmap, die Schreibzugriffe gingen in die Seite davor.
#
# #1378: `r"..."` wird als eigenes Token gelext (TK_REGEX_LIT), die Spanne
# enthielt aber das führende `r`. Der Codegen überspringt genau ein Zeichen
# als öffnendes Anführungszeichen — also das `r` — und lieferte `"hello`
# samt Anführungszeichen. Deshalb fand die Regex-Suche nichts; die Engine
# war in Ordnung. Zusätzlich wurden Escapes ausgewertet, was einer
# Rohzeichenkette gerade widerspricht (`r"\d+"` scheiterte).
#
# #1381: Der Rückgabetyp eines METHODENaufrufs steht in der Registry unter
# dem gemangelten Namen `Klasse_Methode`. Die Typbestimmung schlug mit dem
# blossen Methodennamen nach und hielt das Ergebnis für eine Ganzzahl —
# `PrintLn(sb.ToString())` gab die Adresse aus.

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

# ===========================================================================
# #1377 — StringBuilder waechst
# ===========================================================================

# Der Kern: mehr anhaengen, als der Anfangspuffer fasst. Vorher rc=139.
out "Append ueber die Anfangskapazitaet hinaus" 'import std.io;
import std.string;
fn main(): int64 {
  var sb: StringBuilder := new StringBuilder();
  sb.Init(16);
  sb.Append("Hello");
  sb.Append(", ");
  sb.Append("eine deutlich laengere Zeichenkette als sechzehn Byte");
  var r: pchar := sb.ToString();
  PrintLn(r);
  return 0;
}' "Hello, eine deutlich laengere Zeichenkette als sechzehn Byte"

out "AppendChar und AppendInt wachsen mit" 'import std.io;
import std.string;
fn main(): int64 {
  var sb: StringBuilder := new StringBuilder();
  sb.Init(4);
  var i: int64 := 0;
  while (i < 20) { sb.AppendChar(65); sb.AppendInt(i); i := i + 1; }
  PrintLn(IntToStr(sb.Length()));
  return 0;
}' "50"

out "Clear setzt zurueck, der Puffer bleibt nutzbar" 'import std.io;
import std.string;
fn main(): int64 {
  var sb: StringBuilder := new StringBuilder();
  sb.Init(8);
  sb.Append("erste Runde mit reichlich Text");
  sb.Clear();
  sb.Append("zweite");
  var r: pchar := sb.ToString();
  PrintStr(r); PrintStr(" "); PrintLn(IntToStr(sb.Length()));
  return 0;
}' "zweite 6"

# Die Kapazitaet muss tatsaechlich WACHSEN — sonst haette der Test oben auch
# mit einem zufaellig grosszuegigen Anfangspuffer bestanden.
out "Capacity waechst, Length stimmt" 'import std.io;
import std.string;
fn main(): int64 {
  var sb: StringBuilder := new StringBuilder();
  sb.Init(16);
  var vorher: int64 := sb.Capacity();
  sb.Append("Zeichenkette mit deutlich mehr als sechzehn Zeichen");
  var nachher: int64 := sb.Capacity();
  if (nachher > vorher) { PrintStr("gewachsen "); } else { PrintStr("NICHT gewachsen "); }
  PrintLn(IntToStr(sb.Length()));
  return 0;
}' "gewachsen 51"

# ===========================================================================
# #1381 — Rueckgabetyp eines Methodenaufrufs
# ===========================================================================

out "PrintLn mit Methodenrueckgabe pchar" 'import std.io;
type K = class { fn Name(): pchar { return "hallo"; } };
fn main(): int64 { var k: K := new K(); PrintLn(k.Name()); return 0; }' "hallo"

out "Verkettung mit Methodenrueckgabe" 'import std.io;
type K = class { fn Name(): pchar { return "welt"; } };
fn main(): int64 { var k: K := new K(); PrintLn("[" + k.Name() + "]"); return 0; }' "[welt]"

# Gegenprobe: eine Methode mit int64-Rueckgabe bleibt eine Zahl.
out "Methode mit int64 bleibt Zahl" 'import std.io;
type K = class { fn Wert(): int64 { return 42; } };
fn main(): int64 { var k: K := new K(); PrintLn(IntToStr(k.Wert())); return 0; }' "42"

# ===========================================================================
# #1378 (Teil) — Rohzeichenkette r"..."
# ===========================================================================

out "r-Literal ohne Anfuehrungszeichen im Inhalt" 'import std.io;
fn main(): int64 {
  var p: pchar := r"hello";
  PrintStr("["); PrintStr(p); PrintStr("] "); PrintLn(IntToStr(StrLen(p)));
  return 0;
}' "[hello] 5"

# Der eigentliche Zweck: Backslashes bleiben stehen. Vorher scheiterte das
# schon beim Uebersetzen ("unbekannte Escape-Sequenz").
out "Backslash bleibt im r-Literal erhalten" 'import std.io;
fn main(): int64 {
  var p: pchar := r"\d+";
  PrintStr("["); PrintStr(p); PrintStr("] "); PrintLn(IntToStr(StrLen(p)));
  return 0;
}' "[\d+] 3"

# Gegenprobe: die gewoehnliche Zeichenkette wertet Escapes weiterhin aus.
out "gewoehnliche Zeichenkette wertet Escapes aus" 'import std.io;
fn main(): int64 { var s: pchar := "a\tb"; PrintLn(IntToStr(StrLen(s))); return 0; }' "3"

out "Regex-Suche mit r-Literal findet das Muster" 'import std.io;
import std.regex;
fn main(): int64 {
  PrintStr(IntToStr(RegexSearch(r"world", "hello world"))); PrintStr(" ");
  var m: bool := RegexMatch(r"hello", "hello world");
  if (m) { PrintLn("true"); } else { PrintLn("false"); }
  return 0;
}' "6 true"

# NICHT behoben und offen als #1378: Capture-Positionen und das
# ignore-case-Flag der Engine. tests/regression/regex/test_regex_match meldet
# dafuer weiterhin zwei FAIL — der Eintrag bleibt deshalb in
# tests/suite-broken.txt stehen.

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
