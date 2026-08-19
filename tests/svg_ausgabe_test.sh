#!/bin/bash
# #1684, #1685, #1686, #1687, #1688 — std.svg schrieb still falsche Dokumente.
#
# Alle fuenf Faelle sind still: die Ausgabe blieb wohlgeformtes XML, der
# Betrachter zeichnete nur nichts oder etwas Falsches. Ein Test, der nur
# "laeuft durch" prueft, waere bei vier von fuenf gruen gewesen. Geprueft wird
# deshalb der TEXT der Ausgabe und der gelesene ZAHLENWERT.
LYXC=${LYXC:-./lyxc}
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
P=0; F=0
ok()  { echo "PASS: $1"; P=$((P+1)); }
bad() { echo "FAIL: $1"; F=$((F+1)); }

# baut $TMP/prog aus $1 und legt die Ausgabe in $TMP/aus ab; rc im Aufrufer
bauen() {
  if ! "$LYXC" --std-path=. "$1" -o "$TMP/prog" > "$TMP/build.log" 2>&1; then
    return 2
  fi
  chmod +x "$TMP/prog"
  "$TMP/prog" > "$TMP/aus" 2>&1
  return $?
}

# ---------------------------------------------------------------------------
# #1686 — negative Koordinaten
# ---------------------------------------------------------------------------
cat > "$TMP/neg.lyx" <<'EOF'
import std.io;
import std.svg.builder;
import std.svg.elements;
fn main(): int64 {
  var doc: int64 := SvgNew(400.0, 300.0);
  SvgRect(doc, -10.0, -0.1, 200.0, 100.0); SvgApply(doc);
  SvgCircle(doc, -0.5, -1.5, 20.0); SvgApply(doc);
  Print(SvgToString(doc)); Print("\n");
  return 0;
}
EOF
if bauen "$TMP/neg.lyx"; then
  # Vorher: x="--10" y="0./" cx="0.+" cy="--1.+"
  if grep -q 'x="-10" y="-0.1"' "$TMP/aus"; then
    ok "negative Ganz- und Nachkommazahl: x=-10 y=-0.1"
  else
    bad "negative Werte falsch: $(grep -o '<rect[^>]*>' "$TMP/aus" | head -1)"
  fi
  if grep -q 'cx="-0.5" cy="-1.5"' "$TMP/aus"; then
    ok "Vorzeichen bleibt bei Betrag < 1 erhalten"
  else
    bad "Vorzeichen bei Betrag < 1 verloren: $(grep -o '<circle[^>]*>' "$TMP/aus" | head -1)"
  fi
  if grep -qE '\-\-|\./|\.\+' "$TMP/aus"; then
    bad "Ausgabe enthaelt noch doppelte Minus oder Zeichen ausserhalb 0-9"
  else
    ok "kein doppeltes Minus, keine Zeichen ausserhalb 0-9 in Zahlen"
  fi
else
  bad "negative Koordinaten: Programm laeuft nicht (rc=$?)"
fi

# ---------------------------------------------------------------------------
# #1684 — SvgSetRounding
# ---------------------------------------------------------------------------
cat > "$TMP/rund.lyx" <<'EOF'
import std.io;
import std.svg.builder;
import std.svg.elements;
fn main(): int64 {
  var doc: int64 := SvgNew(400.0, 300.0);
  SvgSetRounding(doc, 10.0, 7.5);
  SvgRoundRect(doc, 10.0, 130.0, 200.0, 100.0); SvgApply(doc);
  Print(SvgToString(doc)); Print("\n");
  return 0;
}
EOF
if bauen "$TMP/rund.lyx"; then
  if grep -q 'rx="10" ry="7.5"' "$TMP/aus"; then
    ok "SvgSetRounding kommt als rx/ry heraus"
  else
    bad "Rundung verloren (erwartet rx=\"10\" ry=\"7.5\"): $(grep -o '<rect[^>]*>' "$TMP/aus" | head -1)"
  fi
else
  bad "Rundung: Programm laeuft nicht"
fi

# ---------------------------------------------------------------------------
# #1688 — SvgCurveTo schrieb nach Adresse 0
# ---------------------------------------------------------------------------
cat > "$TMP/kurve.lyx" <<'EOF'
import std.io;
import std.svg.builder;
import std.svg.elements;
import std.svg.style;
import std.svg.path;
fn main(): int64 {
  var doc: int64 := SvgNew(300.0, 250.0);
  SvgSetFillNone(doc);
  SvgPathBegin(doc);
  SvgMoveTo(doc, 10.0, 230.0);
  SvgCurveSetCP(doc, 40.0, 160.0, 65.0, 160.0);
  SvgCurveTo(doc, 95.0, 230.0);
  SvgApply(doc);
  Print(SvgToString(doc)); Print("\n");
  return 0;
}
EOF
bauen "$TMP/kurve.lyx"; rc=$?
if [ "$rc" -eq 0 ]; then
  ok "SvgCurveTo stuerzt nicht mehr ab"
  if grep -q 'd="M10 230 C40 160 65 160 95 230"' "$TMP/aus"; then
    ok "SvgCurveTo schreibt den C-Befehl vollstaendig"
  else
    bad "C-Befehl falsch: $(grep -o 'd="[^"]*"' "$TMP/aus" | head -1)"
  fi
else
  bad "SvgCurveTo: rc=$rc (139 = der alte Absturz)"
fi

# SvgCurveTo2 muss dasselbe liefern — sonst stehen wieder zwei Faelle nebeneinander
sed 's/SvgCurveTo(/SvgCurveTo2(/' "$TMP/kurve.lyx" > "$TMP/kurve2.lyx"
if bauen "$TMP/kurve2.lyx" && grep -q 'd="M10 230 C40 160 65 160 95 230"' "$TMP/aus"; then
  ok "SvgCurveTo2 liefert dasselbe wie SvgCurveTo"
else
  bad "SvgCurveTo2 weicht von SvgCurveTo ab"
fi

# ---------------------------------------------------------------------------
# #1687 — Parser lieferte das Bitmuster
# ---------------------------------------------------------------------------
cat > "$TMP/in.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" width="400" height="300" viewBox="0 0 400 300">
  <circle id="logo" cx="120" cy="80" r="40" fill="red"/>
</svg>
EOF
cat > "$TMP/lesen.lyx" <<EOF
import std.io;
import std.svg.parser;
fn main(): int64 {
  var doc: int64 := SvgOpen("$TMP/in.svg");
  PrintF64(SvgReadWidth(doc));
  PrintF64(SvgReadHeight(doc));
  var logo: int64 := SvgFindId(doc, "logo");
  PrintF64(SvgAttrF64(logo, "cx", 0.0));
  PrintF64(SvgAttrF64(logo, "cy", 0.0));
  return 0;
}
EOF
if bauen "$TMP/lesen.lyx"; then
  gelesen=$(tr '\n' ' ' < "$TMP/aus")
  # Vorher: 4645744490609377280.000000 — das Bitmuster von 400.0
  if [ "$gelesen" = "400.000000 300.000000 120.000000 80.000000 " ]; then
    ok "Parser liefert Werte statt Bitmuster"
  else
    bad "Parser liefert '$gelesen' (erwartet 400 300 120 80)"
  fi
else
  bad "Parser: Programm laeuft nicht"
fi

# ---------------------------------------------------------------------------
# #1685 — Definitionen bleiben leer, href trifft nichts
# ---------------------------------------------------------------------------
cat > "$TMP/defs.lyx" <<'EOF'
import std.io;
import std.svg.builder;
import std.svg.elements;
import std.svg.style;
import std.svg.defs;
fn main(): int64 {
  var doc: int64 := SvgNew(400.0, 300.0);
  var sym: int64 := SvgSymbolBegin(doc, "stern", 100.0, 100.0);
  SvgSetFillHex(doc, "gold");
  SvgPolygon(doc, "50,5 61,35 95,35");
  SvgApply(doc);
  SvgSymbolEnd(doc);
  SvgUseId(doc, sym, 150.0, 150.0, 40.0, 40.0);
  SvgCircle(doc, 200.0, 200.0, 30.0); SvgApply(doc);
  Print(SvgToString(doc)); Print("\n");
  return 0;
}
EOF
if bauen "$TMP/defs.lyx"; then
  # Die Form muss ZWISCHEN <symbol> und </symbol> stehen, nicht dahinter.
  vor=$(grep -n "<symbol" "$TMP/aus" | head -1 | cut -d: -f1)
  poly=$(grep -n "<polygon" "$TMP/aus" | head -1 | cut -d: -f1)
  zu=$(grep -n "</symbol>" "$TMP/aus" | head -1 | cut -d: -f1)
  if [ -n "$vor" ] && [ -n "$poly" ] && [ -n "$zu" ] && [ "$poly" -gt "$vor" ] && [ "$poly" -lt "$zu" ]; then
    ok "Form landet in der Definition, nicht im Rumpf"
  else
    bad "Form nicht in der Definition (symbol=$vor polygon=$poly /symbol=$zu)"
  fi
  # Nach SymbolEnd muss die Ausgabe wieder in den Rumpf gehen.
  if grep -q "<circle" "$TMP/aus" && ! sed -n "/<defs>/,/<\/defs>/p" "$TMP/aus" | grep -q "<circle"; then
    ok "nach SvgSymbolEnd geht die Ausgabe wieder in den Rumpf"
  else
    bad "circle steht noch in <defs> — die Umleitung wird nicht zurueckgenommen"
  fi
  # href muss die vergebene id treffen.
  id=$(grep -o 'id="sym[0-9]*"' "$TMP/aus" | head -1 | sed 's/id="//; s/"//')
  if [ -n "$id" ] && grep -q "href=\"#$id\"" "$TMP/aus"; then
    ok "SvgUseId trifft die vergebene id ($id)"
  else
    bad "href trifft die id nicht (id=$id, href=$(grep -o 'href="[^"]*"' "$TMP/aus" | head -1))"
  fi
else
  bad "Definitionen: Programm laeuft nicht"
fi

echo "----"
echo "$P PASS, $F FAIL"
[ "$F" -eq 0 ]
