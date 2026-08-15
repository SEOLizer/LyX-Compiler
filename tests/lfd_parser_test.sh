#!/usr/bin/env bash
# tests/lfd_parser_test.sh — #1391, #1392, #1393, #1394, #1395, #1396, #1399.
#
# Die LFD-Einheiten waren an sechs Stellen still falsch:
#
#   #1393 Zeichenketten-Werte wurden gelesen und VERWORFEN — `text`, `tooltip`
#         und `onclick` waren über die Schnittstelle nicht erreichbar.
#   #1394 `width: -5` ergab 5. Das Minuszeichen fiel im Lexer in
#         „skip unknown char" — ohne Fehler, ohne Warnung.
#   #1395 Kein Getter für die Textlänge: der Rückgabewert von LFDGetNodeText
#         ist nicht nullterminiert, und die Länge stand nur im Knoten bei +16.
#         Das Knotenlayout war damit faktisch Teil der API.
#   #1396 `LFD_NODE_WIDGET` (3) war identisch mit `LFD_TK_HORIZONTAL`; ein
#         Vergleich darauf traf jede waagerechte Anordnung und kein einziges
#         Bedienelement. `LFD_NODE_ROOT` und `LFD_NODE_EVENT` wurden nie vergeben.
#   #1392 `std.lfd_factory` verglich pchar mit `==` — also Adressen statt
#         Inhalt. Keine einzige Typ-Verzweigung wurde je genommen.
#   #1391 Dieselbe Unit lieferte überall 0/false und sah dabei aus wie eine
#         benutzbare API; libqtlyx.so wird nirgends gebunden.
#
# GEPRÜFT WIRD DER WEG ZUM WERT, nicht nur, dass etwas zurückkommt: bei #1393
# der ausgelesene Text, bei #1394 das Vorzeichen, bei #1392 dass ein
# GLEICH GESCHRIEBENES Literal erkannt und ein anders geschriebenes abgelehnt
# wird — mit `==` wäre beides false gewesen, ein Test auf „unbekannt → false"
# hätte den Fehler nicht gesehen.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# ===========================================================================
# Parser: #1393, #1394, #1395, #1396
# ===========================================================================

cat > "$TMP/p.lyx" <<'LYXEOF'
import std.io;
import std.alloc;
import std.lfd_parser;

fn text(node: int64): pchar {
  var b: int64 := alloc(128);
  LFDCopyNodeText(node, b, 128);
  return b as pchar;
}
fn wert(node: int64): pchar {
  var b: int64 := alloc(128);
  LFDCopyNodeValue(node, b, 128);
  return b as pchar;
}

fn main(): int64 {
  var r: int64 := LFDParseString("form \"Titel\" { horizontal { button \"OK\" { text: \"Speichern\" tooltip: \"Hinweis\" width: -5 height: 30 enabled: true onclick: \"save\" } } }"c);

  // #1395: Text und Laenge ueber die Schnittstelle, ohne peek64 auf +16
  PrintStr("titel="); PrintStr(text(r));
  PrintStr(" laenge="); PrintLn(IntToStr(LFDGetNodeTextLen(r)));

  var box: int64 := LFDGetNodeChild(r, 0);
  var btn: int64 := LFDGetNodeChild(box, 0);
  PrintStr("btn="); PrintStr(text(btn));
  PrintStr(" laenge="); PrintLn(IntToStr(LFDGetNodeTextLen(btn)));

  // #1396: waagerechte Anordnung ist KEIN Bedienelement, der Knopf schon
  PrintStr("istWidget box="); PrintStr(IntToStr(LFDIsWidget(box)));
  PrintStr(" btn="); PrintStr(IntToStr(LFDIsWidget(btn)));
  PrintStr(" istContainer box="); PrintStr(IntToStr(LFDIsContainer(box)));
  PrintStr(" btn="); PrintLn(IntToStr(LFDIsContainer(btn)));

  // #1393 + #1394 + #1396: Eigenschaften mit Wert, Vorzeichen und Knotenart
  var i: int64 := 0;
  while (i < LFDGetNodeChildCount(btn)) {
    var p: int64 := LFDGetNodeChild(btn, i);
    PrintStr(text(p));
    PrintStr("|"); PrintStr(IntToStr(LFDGetNodeType(p)));
    PrintStr("|"); PrintStr(IntToStr(LFDGetNodeIntVal(p)));
    PrintStr("|"); PrintStr(wert(p));
    PrintLn("");
    i := i + 1;
  }

  PrintStr("fehler="); PrintLn(IntToStr(LFDGetErrorCount(0)));

  // #1394: das Vorzeichen darf die Zahl daneben nicht anfassen
  var r2: int64 := LFDParseString("form { label { width: -12 height: 7 } }"c);
  var l2: int64 := LFDGetNodeChild(r2, 0);
  PrintStr("negativ=");
  PrintStr(IntToStr(LFDGetNodeIntVal(LFDGetNodeChild(l2, 0))));
  PrintStr(" positiv=");
  PrintLn(IntToStr(LFDGetNodeIntVal(LFDGetNodeChild(l2, 1))));

  // #1395: eine zu kleine Zielgroesse schneidet ab und terminiert trotzdem
  var klein: int64 := alloc(4);
  var n: int64 := LFDCopyNodeText(r, klein, 4);   // "Titel" passt nicht in 4
  PrintStr("abgeschnitten="); PrintStr(IntToStr(n));
  PrintStr(" rest="); PrintLn(IntToStr(peek8(klein + 3)));
  return 0;
}
LYXEOF

if ! timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p" >/dev/null 2>&1; then
  no "Messprogramm (Parser) uebersetzt" "$("$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p" 2>&1 | grep -i error | head -1)"
else
  A="$(timeout 30 "$TMP/p" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then
    no "Messprogramm (Parser) laeuft" "ABSTURZ rc=$rc"
  else
    z() { echo "$A" | sed -n "$1p"; }

    [ "$(z 1)" = "titel=Titel laenge=5" ] \
      && ok "#1395: Text und Laenge ueber die Schnittstelle" \
      || no "#1395: Text und Laenge ueber die Schnittstelle" "$(z 1)"

    [ "$(z 2)" = "btn=OK laenge=2" ] \
      && ok "#1395: Text eines Bedienelements" \
      || no "#1395: Text eines Bedienelements" "$(z 2)"

    [ "$(z 3)" = "istWidget box=0 btn=1 istContainer box=1 btn=0" ] \
      && ok "#1396: Anordnung und Bedienelement sind unterscheidbar" \
      || no "#1396: Anordnung und Bedienelement sind unterscheidbar" "$(z 3)"

    [ "$(z 4)" = "text|101|0|Speichern" ] \
      && ok "#1393: Zeichenkettenwert von text" \
      || no "#1393: Zeichenkettenwert von text" "$(z 4)"

    [ "$(z 5)" = "tooltip|101|0|Hinweis" ] \
      && ok "#1393: Zeichenkettenwert von tooltip" \
      || no "#1393: Zeichenkettenwert von tooltip" "$(z 5)"

    [ "$(z 6)" = "width|101|-5|" ] \
      && ok "#1394: negative Zahl behaelt ihr Vorzeichen" \
      || no "#1394: negative Zahl behaelt ihr Vorzeichen" "$(z 6)"

    [ "$(z 7)" = "height|101|30|" ] \
      && ok "#1394: positive Zahl unveraendert" \
      || no "#1394: positive Zahl unveraendert" "$(z 7)"

    [ "$(z 8)" = "enabled|101|1|" ] \
      && ok "#1393: Wahrheitswert unveraendert" \
      || no "#1393: Wahrheitswert unveraendert" "$(z 8)"

    [ "$(z 9)" = "onclick|102|0|save" ] \
      && ok "#1396: onclick ist ein Ereignisknoten mit Wert" \
      || no "#1396: onclick ist ein Ereignisknoten mit Wert" "$(z 9)"

    [ "$(z 10)" = "fehler=0" ] \
      && ok "#1394: keine Fehler bei negativer Zahl" \
      || no "#1394: keine Fehler bei negativer Zahl" "$(z 10)"

    [ "$(z 11)" = "negativ=-12 positiv=7" ] \
      && ok "#1394: Vorzeichen faerbt nicht auf den Nachbarn ab" \
      || no "#1394: Vorzeichen faerbt nicht auf den Nachbarn ab" "$(z 11)"

    [ "$(z 12)" = "abgeschnitten=3 rest=0" ] \
      && ok "#1395: zu kleines Ziel schneidet ab und terminiert" \
      || no "#1395: zu kleines Ziel schneidet ab und terminiert" "$(z 12)"
  fi
fi

# ===========================================================================
# Factory: #1391, #1392
# ===========================================================================

cat > "$TMP/f.lyx" <<'LYXEOF'
import std.io;
import std.lfd_factory;
fn main(): int64 {
  // #1392: Inhalt zaehlt, nicht die Adresse. Ein gleich geschriebenes Literal
  // hat eine ANDERE Adresse — mit `==` waere hier ueberall false gestanden.
  PrintStr(BoolToStr(LFDFactoryKenntWidget("button"c))); PrintStr(" ");
  PrintStr(BoolToStr(LFDFactoryKenntWidget("custom"c))); PrintStr(" ");
  PrintStr(BoolToStr(LFDFactoryKenntWidget("Button"c))); PrintStr(" ");
  PrintStr(BoolToStr(LFDFactoryKenntWidget("quatsch"c))); PrintStr(" ");
  PrintStr(BoolToStr(LFDFactoryKenntLayout("vertical"c))); PrintStr(" ");
  PrintStr(BoolToStr(LFDFactoryKenntProperty("width"c))); PrintStr(" ");
  PrintLn(BoolToStr(LFDFactoryKenntEvent("onclick"c)));
  // #1391: die Anbindung fehlt, und der Aufrufer kann danach fragen
  PrintLn(BoolToStr(LFDFactoryAvailable()));
  return 0;
}
LYXEOF

if ! timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/f.lyx" -o "$TMP/f" >/dev/null 2>&1; then
  no "Messprogramm (Factory) uebersetzt" "uebersetzt nicht"
else
  B="$(timeout 30 "$TMP/f" 2>/dev/null)"
  [ "$(echo "$B" | sed -n 1p)" = "true true false false true true true" ] \
    && ok "#1392: Typen werden nach Inhalt verglichen" \
    || no "#1392: Typen werden nach Inhalt verglichen" "$(echo "$B" | sed -n 1p)"
  [ "$(echo "$B" | sed -n 2p)" = "false" ] \
    && ok "#1391: fehlende Anbindung ist abfragbar" \
    || no "#1391: fehlende Anbindung ist abfragbar" "$(echo "$B" | sed -n 2p)"
fi

# #1391: Ein erzeugender Aufruf muss MELDEN, statt stumm 0 zu liefern.
cat > "$TMP/g.lyx" <<'LYXEOF'
import std.io;
import std.lfd_factory;
fn main(): int64 {
  var w: int64 := createWidget("button"c, 0);
  PrintLn(IntToStr(w));
  return 0;
}
LYXEOF
if timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/g.lyx" -o "$TMP/g" >/dev/null 2>&1; then
  MELD="$(timeout 30 "$TMP/g" 2>&1 >/dev/null)"
  AUSG="$(timeout 30 "$TMP/g" 2>/dev/null)"
  if echo "$MELD" | grep -q "1391"; then ok "#1391: createWidget meldet die fehlende Anbindung"
  else no "#1391: createWidget meldet die fehlende Anbindung" "stderr: '$MELD'"; fi
  [ "$AUSG" = "0" ] && ok "#1391: Rueckgabewert bleibt 0" || no "#1391: Rueckgabewert bleibt 0" "$AUSG"
else
  no "#1391: createWidget meldet die fehlende Anbindung" "uebersetzt nicht"
  no "#1391: Rueckgabewert bleibt 0" "uebersetzt nicht"
fi

# ===========================================================================
# #1399 — @description beschreibt die Unit
# ===========================================================================

if grep -q '@description("LFD binary file' "$ROOT/std/lfd_parser.lyx" "$ROOT/std/lfd_factory.lyx" 2>/dev/null; then
  no "#1399: keine Binaerformat-Beschreibung mehr" "@description nennt weiter ein Binaerformat"
else
  ok "#1399: keine Binaerformat-Beschreibung mehr"
fi

if grep -q '@description(".*Parser.*LFD' "$ROOT/std/lfd_parser.lyx"; then
  ok "#1399: lfd_parser beschreibt sich als Parser"
else
  no "#1399: lfd_parser beschreibt sich als Parser" "$(grep '@description' "$ROOT/std/lfd_parser.lyx" | head -1)"
fi

if grep -qi '@description(".*Factory' "$ROOT/std/lfd_factory.lyx"; then
  ok "#1399: lfd_factory beschreibt sich als Factory"
else
  no "#1399: lfd_factory beschreibt sich als Factory" "$(grep '@description' "$ROOT/std/lfd_factory.lyx" | head -1)"
fi

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
