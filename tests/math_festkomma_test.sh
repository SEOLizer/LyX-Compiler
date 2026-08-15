#!/usr/bin/env bash
# tests/math_festkomma_test.sh — #1444, #1445, #1446, #1447, #1448, #1450,
#                                #1536, #1537, #1540, #1545.
#
# Zehn Meldungen in std/math.lyx, eine Familie: Festkomma-Rechnungen, die ihren
# Skalierungsfaktor nie wieder heraustellen, und Naeherungen, die ausserhalb
# ihres Gueltigkeitsbereichs benutzt werden.
#
# GEPRUEFT WIRD GEGEN BEKANNTE REFERENZWERTE — sin(30) = 0,5, Hypot(3,4) = 5,
# atan2(1,1) = 45 Grad —, nicht gegen eine Gegenfunktion derselben Unit. Eine
# Unit, die sich selbst bestaetigt, bestaetigt auch ihren Fehler.

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
  got="$(timeout 60 "$TMP/p" 2>&1)"; rc=$?
  if [ "$rc" -eq 124 ]; then no "$1" "ZEITUEBERSCHREITUNG"; return; fi
  if [ "$rc" -ge 128 ]; then no "$1" "ABSTURZ (rc=$rc)"; return; fi
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1" "'$got' erwartet '$3'"; fi
}

# ===========================================================================
# #1444 — Sinus und Kosinus in Mikrograd
# ===========================================================================
# Die alte Naeherung `rad - rad^3/6e9` kippte: fuer 90 Grad war der
# Korrekturterm zwei Groessenordnungen groesser als der lineare Term.

out "#1444: Sin64 an den bekannten Stellen" 'import std.io;
import std.math;
fn Z(m: int64): void { PrintStr(IntToStr(Sin64(m))); PrintStr(" "); }
fn main(): int64 {
  Z(0); Z(30000000); Z(45000000); Z(60000000); Z(90000000);
  Z(180000000); Z(270000000); Z(360000000);
  PrintLn("");
  return 0;
}' "0 500000 707107 866025 1000000 0 -1000000 0 "

out "#1444: Cos64 an den bekannten Stellen" 'import std.io;
import std.math;
fn Z(m: int64): void { PrintStr(IntToStr(Cos64(m))); PrintStr(" "); }
fn main(): int64 {
  Z(0); Z(60000000); Z(90000000); Z(180000000);
  PrintLn("");
  return 0;
}' "1000000 500000 0 -1000000 "

# Negative Winkel und Werte jenseits eines Vollkreises muessen dasselbe
# liefern wie ihre Entsprechung im ersten Umlauf.
out "#1444: negative Winkel und mehrere Umlaeufe" 'import std.io;
import std.math;
fn main(): int64 {
  PrintStr(IntToStr(Sin64(0 - 90000000))); PrintStr(" ");
  PrintStr(IntToStr(Sin64(450000000))); PrintStr(" ");
  PrintLn(IntToStr(Sin64(0 - 30000000)));
  return 0;
}' "-1000000 1000000 -500000"

# Zwischen zwei Gradstuetzstellen wird interpoliert — sonst waeren alle
# Mikrograd innerhalb eines Grades derselbe Wert.
out "#1444: Zwischenwerte sind keine Stufen" 'import std.io;
import std.math;
fn main(): int64 {
  var a: int64 := Sin64(30000000);
  var b: int64 := Sin64(30500000);
  var c: int64 := Sin64(31000000);
  if (b > a && c > b) { PrintLn("steigend"); } else { PrintLn("stufig"); }
  return 0;
}' "steigend"

# ===========================================================================
# #1445 — Hypot64
# ===========================================================================

out "#1445: Hypot64 gegen bekannte Tripel" 'import std.io;
import std.math;
fn Z(x: int64, y: int64): void { PrintStr(IntToStr(Hypot64(x, y))); PrintStr(" "); }
fn main(): int64 {
  Z(3, 4); Z(5, 12); Z(8, 15); Z(7, 24);
  Z(0, 5); Z(5, 0); Z(0 - 3, 4);
  PrintLn("");
  return 0;
}' "5 13 17 25 5 5 5 "

# ===========================================================================
# #1447 — Atan2 in Mikrograd
# ===========================================================================

out "#1447: Atan2Microdegrees in allen Quadranten" 'import std.io;
import std.math;
fn Z(y: int64, x: int64): void { PrintStr(IntToStr(Atan2Microdegrees(y, x))); PrintStr(" "); }
fn main(): int64 {
  Z(0, 1); Z(1, 1); Z(1, 0); Z(1, 0 - 1); Z(0 - 1, 1); Z(0 - 1, 0);
  PrintLn("");
  return 0;
}' "0 45000000 90000000 135000000 -45000000 -90000000 "

# ===========================================================================
# #1448 / #1545 — negative Zahlen
# ===========================================================================

out "#1448: IsOdd bei negativen Zahlen" 'import std.io;
import std.math;
fn main(): int64 {
  PrintBoolLn(IsOdd(0 - 3));
  PrintBoolLn(IsOdd(0 - 4));
  PrintBoolLn(IsOdd(3));
  PrintBoolLn(IsOdd(4));
  return 0;
}' "true
false
true
false"

out "#1545: PopCount bei negativen Zahlen" 'import std.io;
import std.math;
fn main(): int64 {
  PrintStr(IntToStr(PopCount(0 - 1))); PrintStr(" ");
  PrintStr(IntToStr(PopCount(0 - 2))); PrintStr(" ");
  PrintStr(IntToStr(PopCount(7))); PrintStr(" ");
  PrintLn(IntToStr(PopCount(0)));
  return 0;
}' "64 63 3 0"

# ===========================================================================
# #1446 — der zugesagte Wertebereich
# ===========================================================================
# Random() liefert einen vollen int64 und ist in der Haelfte der Faelle
# negativ; `%` uebernimmt in Lyx das Vorzeichen des Dividenden.

out "#1446: RandomRange und RandomBetween bleiben im Bereich" 'import std.io;
import std.math;
fn main(): int64 {
  var i: int64 := 0;
  var raus: int64 := 0;
  while (i < 5000) {
    var r: int64 := RandomRange(10);
    if (r < 0 || r >= 10) { raus := raus + 1; }
    var b: int64 := RandomBetween(0 - 5, 5);
    if (b < 0 - 5 || b > 5) { raus := raus + 1; }
    i := i + 1;
  }
  PrintLn(IntToStr(raus));
  return 0;
}' "0"

# ===========================================================================
# #1450 — Round64 war eine Attrappe
# ===========================================================================

out "#1450: Round64Fixed rundet wirklich" 'import std.io;
import std.math;
fn main(): int64 {
  PrintStr(IntToStr(Round64Fixed(1500, 1000))); PrintStr(" ");
  PrintStr(IntToStr(Round64Fixed(1499, 1000))); PrintStr(" ");
  PrintStr(IntToStr(Round64Fixed(0 - 1500, 1000))); PrintStr(" ");
  PrintLn(IntToStr(Round64Fixed(2500, 1000)));
  return 0;
}' "2 1 -2 3"

# ===========================================================================
# #1536 / #1537 / #1540 — die f64-Seite an ihren Raendern
# ===========================================================================

# Die Schleife lief fuer x = 1e9 rund 1,4 Milliarden Mal. Der Test misst
# deshalb auch, DASS er zurueckkommt — mit Zeitueberschreitung als Ergebnis.
out "#1536: ExpF64 kommt bei grossen Argumenten sofort zurueck" 'import std.io;
import std.math;
fn main(): int64 {
  PrintStr(FloatToStr(ExpF64(1.0e9), 1)); PrintStr(" ");
  PrintStr(FloatToStr(ExpF64(1.0e18), 1)); PrintStr(" ");
  PrintStr(FloatToStr(ExpF64(0.0 - 1.0e9), 1)); PrintStr(" ");
  PrintLn(FloatToStr(ExpF64(1.0), 4));
  return 0;
}' "inf inf 0.0 2.7183"

out "#1537: SinF64 bleibt im Wertebereich" 'import std.io;
import std.math;
fn main(): int64 {
  var s: f64 := SinF64(1.0e16);
  var c: f64 := CosF64(1.0e16);
  if (s >= 0.0 - 1.0 && s <= 1.0) { PrintStr("sin ok "); } else { PrintStr("sin RAUS "); }
  if (c >= 0.0 - 1.0 && c <= 1.0) { PrintStr("cos ok "); } else { PrintStr("cos RAUS "); }
  PrintLn(FloatToStr(SinF64(3.141592653589793), 4));
  return 0;
}' "sin ok cos ok 0.0000"

out "#1540: TruncF64 jenseits von 2^63" 'import std.io;
import std.math;
fn main(): int64 {
  PrintStr(FloatToStr(TruncF64(1.18e21), 1)); PrintStr(" ");
  PrintStr(FloatToStr(TruncF64(2.5), 1)); PrintStr(" ");
  PrintStr(FloatToStr(TruncF64(0.0 - 2.5), 1)); PrintStr(" ");
  PrintLn(FloatToStr(FloorF64(0.0 - 2.5), 1));
  return 0;
}' "1.2e21 2.0 -2.0 -3.0"

# ===========================================================================
# Gegenprobe: die Nachbarn in derselben Unit bleiben, wie sie waren
# ===========================================================================

out "Gegenprobe: Sqrt64, Abs64, IsEven, IsPrime unveraendert" 'import std.io;
import std.math;
fn main(): int64 {
  PrintStr(IntToStr(Sqrt64(144))); PrintStr(" ");
  PrintStr(IntToStr(Abs64(0 - 7))); PrintStr(" ");
  if (IsEven(4)) { PrintStr("gerade "); } else { PrintStr("ungerade "); }
  if (IsPrime(97)) { PrintStr("prim "); } else { PrintStr("nichtprim "); }
  PrintLn(IntToStr(NextPrime(90)));
  return 0;
}' "12 7 gerade prim 97"

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
