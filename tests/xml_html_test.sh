#!/usr/bin/env bash
# tests/xml_html_test.sh — #1422, #1423, #1424, #1425 (std.xml)
#                          #1418, #1419, #1420 (std.html)
#
# Sieben Meldungen, zwei Units, ein Muster: eine Funktion beantwortet eine
# andere Frage als die, die ihr Name stellt.
#
#   #1422  IsValid prüft „fängt das mit '<' an", nicht Wohlgeformtheit
#   #1423  ParseString meldet immer Erfolg und schreibt nichts
#   #1424  PrettyPrint bricht Textinhalte um und verändert damit das Dokument
#   #1425  WriteDeclaration/WriteElement/WriteDocument terminieren nicht
#   #1418  Unescape kennt nur &quot;, numerische Entities unerreichbar
#   #1419  Escape zerstört UTF-8 (Byte 160 als NBSP)
#   #1420  ValidateBalance zählt Void-Elemente und Text-'<' als offene Tags
#
# ZUR AUSSAGEKRAFT: geprüft wird gegen die ERWARTUNG AUS DER MELDUNG, nicht
# gegen die jeweilige Gegenfunktion derselben Unit. Ein Escape/Unescape-Paar,
# das denselben Fehler in beide Richtungen macht, bestätigt sich sonst selbst.

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
# #1422 — IsValid urteilt ueber die Tagstruktur
# ===========================================================================

# Die fuenf Faelle aus der Meldung, dazu die Faelle, an denen eine echte
# Pruefung scheitern koennte: Deklaration, Kommentar, Selbstschluss, zwei
# Wurzeln, '>' im Text.
out "#1422: IsValid prueft die Tagstruktur" 'import std.io;
import std.xml;
fn z(s: pchar): void { if (IsValid(s)) { PrintStr("1"); } else { PrintStr("0"); } }
fn main(): int64 {
  z("<a>x</a>"c);            // 1
  z("<a><b></a>"c);          // 0  ueber Kreuz
  z("<a"c);                  // 0  nie geschlossen
  z("</a>"c);                // 0  nur schliessend
  z("kein XML"c);            // 0
  z("<?xml version=\"1.0\"?><a/>"c);  // 1
  z("<a><b>t</b></a>"c);     // 1
  z("<a/><b/>"c);            // 0  zwei Wurzeln
  z("<!-- k --><a></a>"c);   // 1
  z("<a>text mit > drin</a>"c); // 1
  PrintLn("");
  return 0;
}' "1000011011"

out "#1422: CountElements zaehlt kein Text-Kleinerzeichen" 'import std.io;
import std.xml;
fn main(): int64 {
  PrintStr(IntToStr(CountElements("<a><b>x</b></a>"c))); PrintStr(" ");
  PrintStr(IntToStr(CountElements("<a>3 < 5</a>"c))); PrintStr(" ");
  PrintLn(IntToStr(CountElements("<?xml version=\"1.0\"?><a/>"c)));
  return 0;
}' "2 1 1"

# ===========================================================================
# #1423 — ParseString liefert Daten und einen aussagekraeftigen Rueckgabewert
# ===========================================================================

out "#1423: die gelesenen Werte stehen im Ausgabepuffer" 'import std.io;
import std.xml;
import std.alloc;
fn main(): int64 {
  var o: int64 := alloc(XML_PARSE_BUFFER_SIZE);
  PrintStr(IntToStr(ParseString("<?xml version=\"1.0\" encoding=\"UTF-8\"?><root>Hallo</root>"c, o as pchar)));
  PrintStr(" ");
  PrintStr((o + XML_OFF_VERSION) as pchar);  PrintStr(" ");
  PrintStr((o + XML_OFF_ENCODING) as pchar); PrintStr(" ");
  PrintStr((o + XML_OFF_ROOTNAME) as pchar); PrintStr(" ");
  PrintLn((o + XML_OFF_ROOTTEXT) as pchar);
  return 0;
}' "1 1.0 UTF-8 root Hallo"

# Der Kern der Meldung: gueltiges XML und Muell muessen unterscheidbar sein.
out "#1423: Muell liefert 0 statt Erfolg" 'import std.io;
import std.xml;
import std.alloc;
fn main(): int64 {
  var o: int64 := alloc(XML_PARSE_BUFFER_SIZE);
  PrintStr(IntToStr(ParseString("Muell"c, o as pchar))); PrintStr(" ");
  PrintLn(IntToStr(ParseString("<a>x</a>"c, o as pchar)));
  return 0;
}' "0 1"

# ===========================================================================
# #1424 — PrettyPrint laesst den Text in Ruhe
# ===========================================================================

# Die erwartete Ausgabe steht so in der Meldung.
out "#1424: Textinhalte werden nicht umgebrochen" 'import std.io;
import std.xml;
import std.alloc;
fn main(): int64 {
  var o: int64 := alloc(1024);
  PrettyPrint("<a><b>x</b><c/></a>"c, o as pchar, 2);
  PrintStr(o as pchar);
  PrintLn("<<");
  return 0;
}' "<a>
  <b>x</b>
  <c/>
</a><<"

# Der Text selbst muss Zeichen fuer Zeichen erhalten bleiben — auch mit
# Leerzeichen darin, die vorher an den Umbruechen verloren gingen.
out "#1424: Text mit Leerzeichen bleibt unveraendert" 'import std.io;
import std.xml;
import std.alloc;
fn main(): int64 {
  var o: int64 := alloc(1024);
  PrettyPrint("<a><b>Hallo Welt</b></a>"c, o as pchar, 2);
  PrintStr(o as pchar);
  PrintLn("<<");
  return 0;
}' "<a>
  <b>Hallo Welt</b>
</a><<"

# ===========================================================================
# #1425 — die Schreibfunktionen terminieren
# ===========================================================================

# Reproduktion aus der Meldung: derselbe Puffer nacheinander fuer
# EscapeAttribute und WriteDeclaration. Vorher standen hinter dem '?>' die
# letzten Bytes der vorherigen Ausgabe.
out "#1425: WriteDeclaration terminiert" 'import std.io;
import std.xml;
import std.alloc;
fn main(): int64 {
  var o: int64 := alloc(512);
  EscapeAttribute("Tom & Jerry <b> \"zitiert\""c, o as pchar);
  PrintLn(o as pchar);
  WriteDeclaration(o as pchar, "1.0"c, "UTF-8"c);
  PrintStr(o as pchar);
  PrintLn("<<");
  return 0;
}' "\"Tom &amp; Jerry &lt;b> &quot;zitiert&quot;\"
<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<<"

out "#1425: WriteElement terminiert" 'import std.io;
import std.xml;
import std.alloc;
fn main(): int64 {
  var o: int64 := alloc(512);
  EscapeAttribute("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"c, o as pchar);
  WriteElement(o as pchar, "kurz"c, 0 as pchar, 0, "t"c, 0);
  PrintStr(o as pchar);
  PrintLn("<<");
  return 0;
}' "<kurz>t</kurz>
<<"

# ===========================================================================
# #1418 — Unescape kennt die Entities
# ===========================================================================

out "#1418: benannte und numerische Entities" 'import std.io;
import std.html;
import std.alloc;
fn main(): int64 {
  var o: int64 := alloc(512);
  Unescape("&amp; &lt; &gt; &quot; &apos; &#39; &#x41; &unknown;"c, o as pchar);
  PrintLn(o as pchar);
  return 0;
}' "& < > \" ' ' A &unknown;"

# Ein unbekannter Name bleibt stehen, statt still zu verschwinden — das ist
# die richtige Antwort auf etwas, das die Unit nicht kennt.
out "#1418: der Rueckweg ueber Escape stimmt" 'import std.io;
import std.html;
import std.alloc;
fn main(): int64 {
  var o: int64 := alloc(512);
  var b: int64 := alloc(512);
  Escape("<a href=\"x\">Tom & Jerry"c, o as pchar);
  PrintLn(o as pchar);
  Unescape(o as pchar, b as pchar);
  PrintLn(b as pchar);
  return 0;
}' "&lt;a href=&quot;x&quot;&gt;Tom &amp; Jerry
<a href=\"x\">Tom & Jerry"

# ===========================================================================
# #1419 — Escape laesst UTF-8 heil
# ===========================================================================

# Zwei Zeichen, deren zweites Byte 0xA0 ist. Vorher wurde daraus
# "C3 &nbsp;" — das Zeichen war zerrissen.
out "#1419: Mehrbyte-Zeichen ueberleben Escape" 'import std.io;
import std.html;
import std.alloc;
import std.string;
fn main(): int64 {
  var o: int64 := alloc(512);
  var e: int64 := alloc(8);
  StrSetChar(e as pchar, 0, 195); StrSetChar(e as pchar, 1, 160);   // U+00E0
  StrSetChar(e as pchar, 2, 197); StrSetChar(e as pchar, 3, 160);   // U+0160
  StrSetChar(e as pchar, 4, 0);
  var n: int64 := Escape(e as pchar, o as pchar);
  StrSetChar(o as pchar, n, 0);
  PrintStr(IntToStr(n)); PrintStr(" ");
  PrintStr(IntToStr(StrCharAt(o as pchar, 0))); PrintStr(" ");
  PrintStr(IntToStr(StrCharAt(o as pchar, 1))); PrintStr(" ");
  PrintStr(IntToStr(StrCharAt(o as pchar, 2))); PrintStr(" ");
  PrintLn(IntToStr(StrCharAt(o as pchar, 3)));
  return 0;
}' "4 195 160 197 160"

# Und die Gegenrichtung: &nbsp; wird als UTF-8 ausgegeben (C2 A0), nicht als
# nacktes Byte 160 — das waere fuer sich allein kein gueltiges UTF-8.
out "#1419: &nbsp; wird zu C2 A0" 'import std.io;
import std.html;
import std.alloc;
import std.string;
fn main(): int64 {
  var o: int64 := alloc(64);
  Unescape("&nbsp;"c, o as pchar);
  PrintStr(IntToStr(StrCharAt(o as pchar, 0))); PrintStr(" ");
  PrintLn(IntToStr(StrCharAt(o as pchar, 1)));
  return 0;
}' "194 160"

# Die Zeichen, die maskiert werden MUESSEN, werden weiterhin maskiert.
out "#1419: die noetigen Maskierungen bleiben" 'import std.io;
import std.html;
import std.alloc;
fn main(): int64 {
  var o: int64 := alloc(256);
  Escape("<&>\""c, o as pchar);
  PrintLn(o as pchar);
  return 0;
}' "&lt;&amp;&gt;&quot;"

# ===========================================================================
# #1420 — ValidateBalance zaehlt Elemente, keine Zeichen
# ===========================================================================

# Die fuenf Faelle aus der Meldung.
out "#1420: Void-Elemente und Text zaehlen nicht mit" 'import std.io;
import std.html;
fn b(s: pchar): void { PrintStr(IntToStr(ValidateBalance(s))); PrintStr(" "); }
fn main(): int64 {
  b("<p><b>x</b></p>"c);     // 0
  b("<p><b>x</p>"c);         // 1
  b("<p>a<br>b</p>"c);       // 0
  b("<img src=x/>"c);        // 0
  b("5 < 7 und 9 > 2"c);     // 0
  b("<p>a<BR>b</p>"c);       // 0  Grossschreibung
  b("<!-- <p> --><p></p>"c); // 0  Kommentar
  PrintLn("");
  return 0;
}' "0 1 0 0 0 0 0 "

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
