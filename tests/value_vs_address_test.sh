#!/usr/bin/env bash
# tests/value_vs_address_test.sh — #1328, #1203, #1286, #1197, #1284.
#
# Fünf Fälle, in denen der Codegen eine ADRESSE oder ein BITMUSTER lieferte,
# wo ein Wert stehen sollte. Gemeinsame Wurzel bei den ersten vier: eine
# Typspur, die eine Knotenart nicht kennt, fällt auf "Ganzzahl" durch.
#
# #1328: `Print(t.name)` mit `name: pchar` druckte die Adresse — die
# Typbestimmung für Print kannte den Feldzugriff nicht. Über eine
# Zwischenvariable ging es, weil dort der deklarierte Typ gelesen wird.
#
# #1203: `s.lat as int64` mit `lat: f64` lieferte das rohe IEEE-Bitmuster
# statt der Umrechnung — dieselbe Lücke eine Knotenart weiter.
#
# #1286: `"a" + g("b")` mit eigener pchar-Funktion ADDIERTE die Adressen. Bei
# zwei Operanden kam eine sinnlose Zahl heraus, bei drei stürzte das Programm
# ab: die erfundene Adresssumme wurde dereferenziert.
#
# #1197: ein `array<T>`-Parameter blieb im Callee ungemarkt; der Indexzugriff
# las 16 Byte zu früh, also den {cap,len}-Kopf statt des ersten Elements.
#
# #1284: FloatToStr lieferte für inf, NaN und Beträge ab 2^63 eine erfundene
# Zahl samt eines Bytes, das aus keinem Ziffernpfad stammte.
#
# Geprüft wird jeweils der WERT, nicht bloss dass etwas herauskommt — eine
# Adresse ist auch eine Zahl, und genau daran sind diese Fehler jahrelang
# vorbeigelaufen.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    no "$1" "uebersetzt nicht"; return
  fi
  got="$(timeout 30 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then no "$1" "ABSTURZ (rc=$rc)"; return; fi
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1" "'$got' erwartet '$3'"; fi
}

# ===========================================================================
# #1328 — pchar-Feld an Print
# ===========================================================================

out "pchar-Feld druckt den Inhalt" 'import std.io;
type T = struct { name: pchar; n: int64; };
fn main(): int64 {
  var t: T;
  t.name := "hallo"c;
  t.n := 7;
  PrintLn(t.name);
  var s: pchar := t.name;
  PrintLn(s);
  PrintLn(IntToStr(t.n));
  return 0;
}' "hallo
hallo
7"

out "pchar-Feld einer Klasse in einer Methode" 'import std.io;
type C = class {
  prefix: pchar;
  fn Zeig(): int64 { PrintLn(self.prefix); return 0; }
};
fn main(): int64 {
  var c: C := new C();
  c.prefix := "vorn"c;
  c.Zeig();
  return 0;
}' "vorn"

# Gegenprobe: ein int64-Feld bleibt eine Zahl, kein Zeichenkettenversuch.
out "int64-Feld bleibt eine Zahl" 'import std.io;
type T = struct { n: int64; };
fn main(): int64 { var t: T; t.n := 123; PrintLn(IntToStr(t.n)); return 0; }' "123"

# ===========================================================================
# #1203 — f64-Feld mit `as int64`
# ===========================================================================

out "f64-Feld wird umgerechnet, nicht als Bitmuster gelesen" 'import std.io;
type S = struct { lat: f64; };
fn main(): int64 {
  var f: f64 := 48.137;
  PrintLn(IntToStr(f as int64));
  var s: S;
  s.lat := 48.137;
  PrintLn(IntToStr(s.lat as int64));
  return 0;
}' "48
48"

out "f64-Feld rechnet auch in einem Ausdruck" 'import std.io;
type S = struct { a: f64; b: f64; };
fn main(): int64 {
  var s: S;
  s.a := 10.5;
  s.b := 2.0;
  PrintLn(IntToStr((s.a / s.b) as int64));
  return 0;
}' "5"

# ===========================================================================
# #1286 — Verkettung mit dem Aufruf einer eigenen pchar-Funktion
# ===========================================================================

KOPF='import std.io;
type T = struct { name: pchar; };
fn g(x: pchar): pchar { return x; }'

out "Verkettung mit eigener pchar-Funktion" "$KOPF
fn main(): int64 { PrintLn(\"a\" + g(\"b\")); return 0; }" "ab"

# Der Absturzfall: drei Operanden dereferenzierten die Adresssumme.
out "drei Operanden stuerzen nicht mehr ab" "$KOPF
fn main(): int64 { var s: pchar := \"a\" + g(\"b\") + \"c\"; PrintLn(s); return 0; }" "abc"

out "beide Seiten Funktionsaufrufe" "$KOPF
fn main(): int64 { PrintLn(g(\"a\") + g(\"b\")); return 0; }" "ab"

out "pchar-Feld in der Verkettung" "$KOPF
fn main(): int64 {
  var t: T;
  t.name := \"N\"c;
  PrintLn(\"[\" + t.name + \"]\");
  return 0;
}" "[N]"

# Gegenproben: die Wege, die vorher schon stimmten.
out "Literale und Builtins unveraendert" "$KOPF
fn main(): int64 {
  PrintLn(\"a\" + \"b\" + \"c\" + \"d\");
  PrintLn(\"a\" + IntToStr(7) + \"b\");
  var r: pchar := g(\"b\");
  PrintLn(\"a\" + r + \"c\");
  return 0;
}" "abcd
a7b
abc"

# ===========================================================================
# #1197 — dynamisches Array als Parameter
# ===========================================================================

out "array<T> als Parameter liefert den Wert" 'import std.io;
fn F(a: array<int64>): int64 { return a[0]; }
fn main(): int64 { var v: array<int64> := [10, 20]; PrintLn(IntToStr(F(v))); return 0; }' "10"

out "Array<T> mit berechnetem Index" 'import std.io;
fn G(a: Array<int64>, i: int64): int64 { return a[i]; }
fn main(): int64 { var v: Array<int64> := [10, 20, 30]; PrintLn(IntToStr(G(v, 2))); return 0; }' "30"

# Gegenprobe: die feste Form war nie kaputt (#1115) und bleibt es nicht.
out "feste Form unveraendert" 'import std.io;
fn H(a: int64[4]): int64 { return a[0]; }
fn main(): int64 { var w: int64[4]; w[0] := 42; PrintLn(IntToStr(H(w))); return 0; }' "42"

# ===========================================================================
# #1284 — FloatToStr an den Raendern
# ===========================================================================

out "inf, -inf und nan sind benannt" 'import std.io;
fn main(): int64 {
  var a: f64 := 1.0;
  var z: f64 := 0.0;
  PrintLn(FloatToStr(a / z));
  PrintLn(FloatToStr((0.0 - a) / z));
  PrintLn(FloatToStr(z / z));
  return 0;
}' "inf
-inf
nan"

# Ein Betrag ab 2^63 traegt keine Ziffernfolge in den 32-Byte-Puffer. Statt
# einer erfundenen Zahl (vorher `9223372036854775808.<0xFF>75808`) steht dort
# ein Wort, das man nicht mit einem Messwert verwechselt.
out "nicht darstellbarer Betrag wird benannt" 'import std.io;
fn main(): int64 { PrintLn(FloatToStr(1.0e30)); return 0; }' "overflow"

out "gewoehnliche Werte unveraendert" 'import std.io;
fn main(): int64 {
  PrintLn(FloatToStr(3.5));
  PrintLn(FloatToStr(0.0 - 2.25));
  PrintLn(FloatToStr(0.0));
  return 0;
}' "3.500000
-2.250000
0.000000"

# ===========================================================================
# #1254 — PrintF64 als Builtin, und Float-Ausgabe an den Raendern
# ===========================================================================
# Die Doku benutzt `PrintF64` an 48 Stellen, oft in Schnipseln OHNE Import —
# `Print`, `PrintLn` und `IntToStr` sind Builtins, also muss es dieses auch
# sein, sonst scheitert ein Beispiel an einer einzigen fehlenden Zeile.
out "PrintF64 ohne Import" 'fn main(): int64 { PrintF64(3.75); return 0; }' "3.750000"

out "PrintF64 mit Import unveraendert" 'import std.io;
fn main(): int64 { PrintF64(0.0 - 1.5); return 0; }' "-1.500000"

# #1284 gilt jetzt auch fuer die AUSGABE, nicht nur fuer FloatToStr: vorher
# druckte `PrintFloat(inf)` dieselbe erfundene Zahl.
out "Float-Ausgabe an den Raendern" 'fn main(): int64 {
  var z: f64 := 0.0;
  var a: f64 := 1.0;
  PrintF64(a / z);
  PrintFloat(z / z);
  PrintLn("");
  return 0;
}' "inf
nan"

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
