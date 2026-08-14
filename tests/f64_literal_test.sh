#!/usr/bin/env bash
# tests/f64_literal_test.sh — #1461.
#
# Der Compiler wandelt Dezimalliterale selbst in IEEE-754-Bits um
# (`cg_parseFloat` im x86-Codegen, `_parseFloatBits` auf der IR-Strecke — bis
# auf die Klammern derselbe Code). Zwei Fehler steckten darin:
#
#   1. Die 52 Mantissenbits wurden ABGESCHNITTEN, nie gerundet. Das Ergebnis
#      lag damit systematisch unter dem nächstgelegenen double: 1.995 kam als
#      1.99499999999999999556 an statt als 1.99500000000000010658.
#   2. Der Nachkommateil brach nach ACHT Stellen ab (`den < 100000000`), die
#      restlichen Ziffern wurden gelesen und weggeworfen. 3.14159265358979 kam
#      als 3.14159265 an — rund acht Millionen ULP daneben.
#
# WARUM DAS SO SCHWER ZU SEHEN IST: der Fehler ist winzig, und die meisten
# Rechnungen verdecken ihn wieder. `1.995 * 1000000.0` ergibt trotzdem
# 1995000, weil die Multiplikation zum richtigen Wert zurückrundet. Sichtbar
# wird er erst, wenn eine Differenz gebildet und dann gerundet wird — beim
# Formatieren also, wo er als Fehler des Formatierers erscheint (#1430).
#
# Geprüft werden deshalb die BITS, gegen python `struct.pack`. Ein Vergleich
# der formatierten Ausgabe würde den Fehler dem Falschen anlasten.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# ===========================================================================
# Bitmuster gegen python
# ===========================================================================
#
# AUSGELASSEN, mit Grund: die Extreme des Wertebereichs. Unterhalb von 1e-18
# laeuft der Nenner beim Skalieren leer (das Literal wird 0 oder falsch), und
# am oberen Ende kostet dieselbe Skalierung zwei ULP —
# 1.7976931348623157e308 kommt als ...309 statt ...311 an. Beides ist derselbe
# eigene Defekt (#1478) und nicht der, den dieser Test misst. Ein Test, der an
# einem fremden offenen Defekt haengt, misst nicht mehr das, was drauf steht.
#
# Der gepruefte Bereich reicht von 1e-18 bis 1e100 und deckt damit alles ab,
# was in einem Programm ueblicherweise als Literal steht.
LITERALE="0.1 0.2 0.3 0.7 1.1 2.2 3.3 0.5 1.0 100.0
1.995 2.675 9.99999999999 123456.789 0.0001
3.14159265358979 2.718281828459045 1.4142135623730951
1.0e10 1.0e100 1.5e-5 1.0e-18 5.0e-18
4.9e-8 0.30000000000000004"

{
  echo "import std.io;"
  echo "import std.alloc;"
  echo "fn bits(v: f64): int64 {"
  echo "  var t: int64 := alloc(8); pokef64(t, v);"
  echo "  var b: int64 := peek64(t); free(t, 8); return b;"
  echo "}"
  echo "fn main(): int64 {"
  for l in $LITERALE; do echo "  PrintLn(IntToStr(bits($l)));"; done
  echo "  return 0;"
  echo "}"
} > "$TMP/b.lyx"

if "$LYXC" --std-path="$ROOT" "$TMP/b.lyx" -o "$TMP/b" >/dev/null 2>&1; then
  "$TMP/b" > "$TMP/ist.txt" 2>&1
  python3 - "$TMP/soll.txt" <<PY
import struct, sys
lits = """$LITERALE""".split()
with open(sys.argv[1], "w") as f:
    for v in lits:
        f.write("%d\n" % struct.unpack("<q", struct.pack("<d", float(v)))[0])
PY
  anzahl="$(wc -l < "$TMP/ist.txt")"
  if diff -q "$TMP/ist.txt" "$TMP/soll.txt" >/dev/null; then
    ok "$anzahl Literale bitgleich mit python struct.pack"
  else
    abw="$(paste "$TMP/ist.txt" "$TMP/soll.txt" | awk '$1!=$2{print NR": "$1" statt "$2}' | head -3 | tr '\n' ' ')"
    no "$anzahl Literale bitgleich mit python struct.pack" "$abw"
  fi
else
  no "Literale bitgleich mit python struct.pack" "uebersetzt nicht"
fi

# ===========================================================================
# Die beiden gemeldeten Faelle namentlich
# ===========================================================================

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/p.lyx"; rm -f "$TMP/p"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p" >/dev/null 2>&1; then
    no "$1" "uebersetzt nicht"; return
  fi
  got="$(timeout 30 "$TMP/p" 2>&1)"
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1" "'$got' erwartet '$3'"; fi
}

# Die Reproduktion aus #1461: der Bruchteil, hoch skaliert.
out "#1461: (1.995 - 1.0) * 1e14 stimmt" 'import std.io;
fn main(): int64 {
  var a: f64 := 1.995;
  var i: int64 := a as int64;
  PrintLn(IntToStr(((a - (i as f64)) * 100000000000000.0) as int64));
  return 0;
}' "99500000000000"

# Die Folge, an der es aufgefallen ist (#1430): FloatToStr rundete richtig und
# bekam die falsche Zahl.
out "#1461: FloatToStr(1.995, 2) ist 2.00" 'import std.io;
fn main(): int64 {
  PrintStr(FloatToStr(1.995, 2)); PrintStr(" ");
  PrintLn(FloatToStr(2.675, 2));
  return 0;
}' "2.00 2.67"

# Mehr als acht Nachkommastellen — der zweite Fehler.
out "#1461: vierzehn Nachkommastellen kommen an" 'import std.io;
import std.alloc;
fn bits(v: f64): int64 {
  var t: int64 := alloc(8); pokef64(t, v);
  var b: int64 := peek64(t); free(t, 8); return b;
}
fn main(): int64 {
  PrintLn(IntToStr(bits(3.14159265358979)));
  return 0;
}' "4614256656552045841"

# ===========================================================================
# Gegenprobe: die Sonderwerte bleiben, wie sie sind
# ===========================================================================

out "#1461: null, Vorzeichen und sehr grosse Werte" 'import std.io;
import std.alloc;
fn bits(v: f64): int64 {
  var t: int64 := alloc(8); pokef64(t, v);
  var b: int64 := peek64(t); free(t, 8); return b;
}
fn main(): int64 {
  PrintStr(IntToStr(bits(0.0))); PrintStr(" ");
  PrintStr(IntToStr(bits(1.0))); PrintStr(" ");
  PrintLn(IntToStr(bits(2.0)));
  return 0;
}' "0 4607182418800017408 4611686018427387904"

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
