#!/usr/bin/env bash
# tests/rect_color_z9_test.sh — #1479, #1480, #1484, #1485.
#
#   #1479 RectContains prüfte inklusive, RectContainsInclusive halboffen — die
#         Namen sagten jeweils das Gegenteil.
#   #1480 RectCorners gab ein nie befülltes Array zurück (der Parameter kam im
#         Rumpf nicht vor); RectDistanceToPoint lieferte den Manhattan- statt
#         des euklidischen Abstands.
#   #1484 ColorFromHSL war eine verunglückte Übertragung der
#         Fließkomma-Formel: 60° ergab Gelbgrün statt Gelb, Helligkeiten über
#         128 liefen aus dem Wertebereich.
#   #1485 ColorFromHex entschied per Größenvergleich, ob ein Alphabyte da ist —
#         Alpha 0 war damit nicht darstellbar.
#
# GEPRÜFT WIRD GEGEN NACHRECHENBARE WERTE: das 3-4-5-Dreieck für den Abstand,
# die sechs Grundfarben des Farbkreises, der Rundlauf einer transparenten
# Farbe. Ein Test gegen den Ist-Zustand hätte die vertauschten Namen und die
# verschobenen Farben festgeschrieben.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    echo "FAIL $1: uebersetzt nicht"; FAIL=$((FAIL+1)); return
  fi
  got="$(timeout 20 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then echo "FAIL $1: ABSTURZ rc=$rc"; FAIL=$((FAIL+1)); return; fi
  if [ "$got" = "$3" ]; then echo "PASS $1"; PASS=$((PASS+1))
  else echo "FAIL $1: '$got' erwartet '$3'"; FAIL=$((FAIL+1)); fi
}

# ===========================================================================
# #1479 — Name und Verhalten in Deckung
# ===========================================================================

# Das Rechteck aus der Meldung: 10..110 x 20..70. Der Eckpunkt (110,70) liegt
# genau auf dem oberen Rand — daran trennen sich die beiden Funktionen.
out "#1479: halboffen und inklusive sind vertauscht gewesen" 'import std.io;
import std.rect;
import std.vector;
fn main(): int64 {
  var r: Rect := RectFromXYWH(10, 20, 100, 50);
  PrintStr(BoolToStr(RectContains(r, Vec2New(110, 70)))); PrintStr(" ");
  PrintStr(BoolToStr(RectContainsInclusive(r, Vec2New(110, 70)))); PrintStr(" ");
  PrintStr(BoolToStr(RectContains(r, Vec2New(10, 20)))); PrintStr(" ");
  PrintLn(BoolToStr(RectContainsInclusive(r, Vec2New(10, 20))));
  return 0;
}' "false true true true"

# Der eigentliche Zweck der halboffenen Form: zwei aneinandergrenzende
# Rechtecke duerfen sich keinen Punkt teilen.
out "#1479: angrenzende Rechtecke ueberschneiden sich nicht" 'import std.io;
import std.rect;
import std.vector;
fn main(): int64 {
  var links: Rect := RectFromXYWH(0, 0, 10, 10);
  var rechts: Rect := RectFromXYWH(10, 0, 10, 10);
  var p: Vec2 := Vec2New(10, 5);
  PrintStr(BoolToStr(RectContains(links, p))); PrintStr(" ");
  PrintLn(BoolToStr(RectContains(rechts, p)));
  return 0;
}' "false true"

# Punkte im Inneren und ausserhalb bleiben, wie sie waren.
out "#1479: innen und aussen unveraendert" 'import std.io;
import std.rect;
import std.vector;
fn main(): int64 {
  var r: Rect := RectFromXYWH(10, 20, 100, 50);
  PrintStr(BoolToStr(RectContains(r, Vec2New(50, 40)))); PrintStr(" ");
  PrintStr(BoolToStr(RectContains(r, Vec2New(5, 40)))); PrintStr(" ");
  PrintLn(BoolToStr(RectContainsInclusive(r, Vec2New(200, 40))));
  return 0;
}' "true false false"

# ===========================================================================
# #1480 — Ecken und Abstand
# ===========================================================================

out "#1480: RectCorners liefert die vier Ecken" 'import std.io;
import std.rect;
import std.vector;
fn main(): int64 {
  var e: [4]Vec2 := RectCorners(RectFromXYWH(0, 0, 100, 100));
  var i: int64 := 0;
  while (i < 4) {
    PrintStr("("); PrintStr(IntToStr(e[i].x)); PrintStr(",");
    PrintStr(IntToStr(e[i].y)); PrintStr(")");
    i := i + 1;
  }
  PrintLn("");
  return 0;
}' "(0,0)(100,0)(100,100)(0,100)"

# Ein verschobenes Rechteck zeigt, dass wirklich `r` gelesen wird und nicht
# zufaellig Nullen im Stack stehen.
out "#1480: Ecken folgen dem Rechteck" 'import std.io;
import std.rect;
import std.vector;
fn main(): int64 {
  var e: [4]Vec2 := RectCorners(RectFromXYWH(10, 20, 30, 40));
  PrintStr(IntToStr(e[0].x)); PrintStr(",");
  PrintStr(IntToStr(e[0].y)); PrintStr(" ");
  PrintStr(IntToStr(e[2].x)); PrintStr(",");
  PrintLn(IntToStr(e[2].y));
  return 0;
}' "10,20 40,60"

# 3-4-5-Dreieck: der Punkt (0,0) liegt 3 nach links und 4 nach unten vom
# Rechteck bei (3,4). Manhattan waere 7, euklidisch ist 5.
out "#1480: Abstand ist euklidisch, nicht Manhattan" 'import std.io;
import std.rect;
import std.vector;
fn main(): int64 {
  PrintStr(IntToStr(RectDistanceToPoint(RectFromXYWH(3, 4, 10, 10), Vec2New(0, 0)))); PrintStr(" ");
  PrintStr(IntToStr(RectDistanceToPoint(RectFromXYWH(0, 0, 10, 10), Vec2New(15, 0)))); PrintStr(" ");
  PrintLn(IntToStr(RectDistanceToPoint(RectFromXYWH(0, 0, 10, 10), Vec2New(5, 5))));
  return 0;
}' "5 5 0"

# ===========================================================================
# #1484 — HSL
# ===========================================================================

# Die sechs Ecken des Farbkreises. Vorher stimmten nur die reinen
# Primaerfarben, die Mischfarben waren um rund 30 Grad verschoben.
out "#1484: die sechs Grundfarben stimmen" 'import std.io;
import std.color;
fn z(c: Color): void {
  PrintStr("("); PrintStr(IntToStr(c.r)); PrintStr(",");
  PrintStr(IntToStr(c.g)); PrintStr(","); PrintStr(IntToStr(c.b)); PrintStr(")");
}
fn main(): int64 {
  z(ColorFromHSL(0, 255, 128));
  z(ColorFromHSL(60, 255, 128));
  z(ColorFromHSL(120, 255, 128));
  z(ColorFromHSL(180, 255, 128));
  z(ColorFromHSL(240, 255, 128));
  z(ColorFromHSL(300, 255, 128));
  PrintLn("");
  return 0;
}' "(255,0,0)(255,255,0)(0,255,0)(0,255,255)(0,0,255)(255,0,255)"

# Helligkeit ueber 128 lief vorher aus dem Wertebereich: der Rotanteil muss
# voll bleiben, die anderen beiden steigen zusammen an (Richtung Weiss).
out "#1484: Helligkeit ueber 128 hellt auf" 'import std.io;
import std.color;
fn main(): int64 {
  var hell: Color := ColorFromHSL(0, 255, 200);
  var dunkel: Color := ColorFromHSL(0, 255, 64);
  if (hell.r == 255 && hell.g == hell.b && hell.g > 100 && hell.g < 200) { PrintStr("hell-ok "); }
  else { PrintStr(IntToStr(hell.r)); PrintStr(","); PrintStr(IntToStr(hell.g)); PrintStr(" "); }
  if (dunkel.r > 110 && dunkel.r < 140 && dunkel.g == 0) { PrintLn("dunkel-ok"); }
  else { PrintStr(IntToStr(dunkel.r)); PrintStr(","); PrintLn(IntToStr(dunkel.g)); }
  return 0;
}' "hell-ok dunkel-ok"

# Zwischenwinkel: 30 Grad liegt zwischen Rot und Gelb — Gruen etwa halb.
out "#1484: Zwischenwinkel liegen dazwischen" 'import std.io;
import std.color;
fn main(): int64 {
  var orange: Color := ColorFromHSL(30, 255, 128);
  if (orange.r == 255 && orange.b == 0 && orange.g > 100 && orange.g < 160) { PrintLn("ok"); }
  else { PrintStr(IntToStr(orange.r)); PrintStr(","); PrintStr(IntToStr(orange.g)); PrintStr(","); PrintLn(IntToStr(orange.b)); }
  return 0;
}' "ok"

# Saettigung 0 ergibt Grau, unabhaengig vom Winkel — der Sonderfall war schon
# vorher richtig und muss es bleiben.
out "#1484: Saettigung 0 bleibt Grau" 'import std.io;
import std.color;
fn main(): int64 {
  var a: Color := ColorFromHSL(0, 0, 128);
  var b: Color := ColorFromHSL(200, 0, 128);
  PrintStr(IntToStr(a.r)); PrintStr(IntToStr(a.g)); PrintStr(IntToStr(a.b)); PrintStr(" ");
  PrintLn(IntToStr(b.r));
  return 0;
}' "128128128 128"

# Schwarz und Weiss an den Raendern.
out "#1484: Raender der Helligkeit" 'import std.io;
import std.color;
fn main(): int64 {
  var schwarz: Color := ColorFromHSL(120, 255, 0);
  var weiss: Color := ColorFromHSL(120, 255, 255);
  PrintStr(IntToStr(schwarz.r + schwarz.g + schwarz.b)); PrintStr(" ");
  if (weiss.r > 250 && weiss.g > 250 && weiss.b > 250) { PrintLn("weiss"); }
  else { PrintStr(IntToStr(weiss.r)); PrintStr(","); PrintStr(IntToStr(weiss.g)); PrintStr(","); PrintLn(IntToStr(weiss.b)); }
  return 0;
}' "0 weiss"

# ===========================================================================
# #1485 — Alpha 0
# ===========================================================================

# Der Rundlauf aus der Meldung: eine unsichtbare Farbe muss unsichtbar bleiben.
out "#1485: transparente Farbe uebersteht den Rundlauf" 'import std.io;
import std.color;
fn main(): int64 {
  var c: Color := ColorEmpty();
  var hex: int64 := ColorToHexARGB(c);
  var zurueck: Color := ColorFromHexARGB(hex);
  PrintStr(IntToStr(hex)); PrintStr(" "); PrintLn(IntToStr(zurueck.a));
  return 0;
}' "0 0"

# Auch eine sichtbare Farbe mit Alpha 0 (0x0000FF00) muss transparent bleiben.
out "#1485: Alpha 0 bei gesetzter Farbe" 'import std.io;
import std.color;
fn main(): int64 {
  var c: Color := ColorFromHexARGB(65280);
  PrintStr(IntToStr(c.r)); PrintStr(","); PrintStr(IntToStr(c.g)); PrintStr(",");
  PrintStr(IntToStr(c.b)); PrintStr(","); PrintLn(IntToStr(c.a));
  return 0;
}' "0,255,0,0"

# Die ausdrueckliche RGB-Form setzt immer volle Deckung.
out "#1485: ColorFromHexRGB setzt Alpha 255" 'import std.io;
import std.color;
fn main(): int64 {
  var c: Color := ColorFromHexRGB(16711680);
  PrintStr(IntToStr(c.r)); PrintStr(","); PrintStr(IntToStr(c.g)); PrintStr(",");
  PrintStr(IntToStr(c.b)); PrintStr(","); PrintLn(IntToStr(c.a));
  return 0;
}' "255,0,0,255"

# Gegenprobe: der in der Meldung als korrekt vermerkte Fall bleibt korrekt.
out "#1485: 0x80FF0000 unveraendert" 'import std.io;
import std.color;
fn main(): int64 {
  var c: Color := ColorFromHex(2164195328);
  PrintStr(IntToStr(c.r)); PrintStr(","); PrintStr(IntToStr(c.g)); PrintStr(",");
  PrintStr(IntToStr(c.b)); PrintStr(","); PrintLn(IntToStr(c.a));
  return 0;
}' "255,0,0,128"

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
