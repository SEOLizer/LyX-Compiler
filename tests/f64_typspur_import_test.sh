#!/usr/bin/env bash
# tests/f64_typspur_import_test.sh — #1565, #1566, #1570.
#
# Zwei Löcher in der f64-Typspur und eines in der Import-Sicht:
#
#   #1566 `extern fn` mit Gleitkomma-Rückgabe fehlte in der f64-Registry. Der
#         Parser lässt bei extern-Deklarationen c0 UND c1 auf −1 — der
#         Rückgabetyp steht NIE im Baum ("call-site arity is enough"). Die
#         Pre-Pass las c1 und sah deshalb nichts. Dass `sqrt` funktionierte,
#         war Zufall: der Name steht ohnehin als Builtin in der Registry.
#         `fabs` (ebenfalls f64!) zeigte denselben Fehler.
#   #1565 Ein Aufruf über einen Funktionszeiger trägt als Namen eine VARIABLE,
#         keine Funktion — die Registry kennt ihn nicht.
#   #1570 Die Prüfung aus #1519 ("Klasse ohne new") gab bei importierten Typen
#         auf, weil der Knotenindex nach dem Import auf −2 steht. Das ist aber
#         nicht „unentscheidbar", sondern nur „woanders zu beantworten".
#
# WAS DER FEHLER ANRICHTET: fällt ein Ausdruck stumm auf int64 zurück, wandelt
# die Zuweisung das korrekte IEEE-Bitmuster nach Ganzzahl-Regeln um — aus 4.0
# wird 4616189618054758400. Der Wert ist also nicht ungenau, sondern etwas
# völlig anderes.
#
# GEMESSEN WIRD MIT NAMEN, DIE NICHT EINGEBAUT SIND. Ein Test mit `sqrt` wäre
# bei #1566 grün gewesen und hätte die Wurzel verdeckt.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    no "$1" "uebersetzt nicht"; return
  fi
  got="$(timeout 20 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then no "$1" "ABSTURZ rc=$rc"; return; fi
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1" "'$got' erwartet '$3'"; fi
}

meldet() { # name, quelltext, textstueck
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  msg="$(timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then no "$1" "uebersetzt klaglos"; return; fi
  if echo "$msg" | grep -qF "$3"; then ok "$1"; else no "$1" "andere Meldung: $(echo "$msg"|grep -i error|head -1)"; fi
}

# ===========================================================================
# #1565 — Aufruf über einen Funktionszeiger
# ===========================================================================

# Alle drei Formen aus der Meldung. A lief schon vorher (der Wert geht
# unverändert durch den return), B und C lieferten das Bitmuster.
out "#1565: Zeigeraufruf in return, Variable und Ausdruck" 'unit main;
import std.io;
fn Half(x: f64): f64 { return x / 2.0; }
fn ApplyDirect(f: fn(f64): f64, x: f64): f64 { return f(x); }
fn ApplyViaVar(f: fn(f64): f64, x: f64): f64 { var v: f64 := f(x); return v; }
fn ApplyInline(f: fn(f64): f64, x: f64): f64 { return f(x) / 2.0; }
fn main(): int64 {
  PrintStr(FloatToStr(ApplyDirect(Half, 8.0), 3)); PrintStr(" ");
  PrintStr(FloatToStr(ApplyViaVar(Half, 8.0), 3)); PrintStr(" ");
  PrintLn(FloatToStr(ApplyInline(Half, 8.0), 3));
  return 0;
}' "4.000 4.000 2.000"

# Ein Zeiger als lokale VARIABLE, nicht als Parameter — andere Stelle im
# Codegen, dieselbe Frage.
out "#1565: Zeiger als lokale Variable" 'unit main;
import std.io;
fn Drittel(x: f64): f64 { return x / 3.0; }
fn main(): int64 {
  var f: fn(f64): f64 := Drittel;
  var v: f64 := f(9.0);
  PrintStr(FloatToStr(v, 3)); PrintStr(" ");
  PrintLn(FloatToStr(f(3.0) + 1.0, 3));
  return 0;
}' "3.000 2.000"

# Gegenprobe: ein Zeiger mit GANZZAHL-Rueckgabe darf nicht ploetzlich als
# Gleitkomma gelten.
out "#1565: Zeiger mit int64-Rueckgabe unveraendert" 'unit main;
import std.io;
fn Doppelt(x: int64): int64 { return x * 2; }
fn main(): int64 {
  var f: fn(int64): int64 := Doppelt;
  var v: int64 := f(21);
  PrintLn(IntToStr(v));
  return 0;
}' "42"

# ===========================================================================
# #1566 — extern fn mit Gleitkomma-Rückgabe
# ===========================================================================

if [ ! -e /lib/x86_64-linux-gnu/libm.so.6 ] && [ ! -e /usr/lib/x86_64-linux-gnu/libm.so.6 ]; then
  echo "SKIP #1566: libm.so.6 nicht gefunden"
else
  # fabs statt sqrt: der Name darf NICHT als Builtin in der Registry stehen,
  # sonst misst der Test am falschen Objekt.
  out "#1566: extern f64 ueber eine Variable" 'import std.io;
@capabilities([system.unsafe.math])
extern fn fabs(x: f64): f64 link "libm.so.6";
fn main(): int64 {
  var v: f64 := fabs(0.0 - 2.5);
  PrintLn(FloatToStr(v, 3));
  return 0;
}' "2.500"

  # Der Fall aus der Meldung: f32-Rueckgabe, beide Aufnahmewege.
  out "#1566: extern f32 auf beiden Wegen" 'import std.io;
@capabilities([system.unsafe.math])
extern fn sqrtf(x: f32): f32 link "libm.so.6";
fn main(): int64 {
  var a: f32 := 4.0;
  PrintStr(FloatToStr(a as f64, 3)); PrintStr(" ");
  var r: f32 := sqrtf(16.0);
  PrintStr(FloatToStr(r as f64, 3)); PrintStr(" ");
  var r2: f64 := sqrtf(16.0);
  PrintLn(FloatToStr(r2, 3));
  return 0;
}' "4.000 4.000 4.000"

  # Auch im Ausdruck, nicht nur in der Zuweisung.
  out "#1566: extern f64 im Ausdruck" 'import std.io;
@capabilities([system.unsafe.math])
extern fn fmax(a: f64, b: f64): f64 link "libm.so.6";
fn main(): int64 {
  PrintLn(FloatToStr(fmax(2.5, 7.5) / 2.0, 3));
  return 0;
}' "3.750"

  # Gegenprobe: eine extern fn mit int64-Rueckgabe bleibt Ganzzahl.
  out "#1566: extern int64 unveraendert" 'import std.io;
@capabilities([system.unsafe.math])
extern fn abs(x: int64): int64 link "libc.so.6";
fn main(): int64 {
  var v: int64 := abs(0 - 7);
  PrintLn(IntToStr(v));
  return 0;
}' "7"
fi

# ===========================================================================
# #1570 — die Prüfung aus #1519 gilt auch für importierte Klassen
# ===========================================================================

# Der ursprüngliche Auslöser: StringBuilder aus std.string, ohne new.
meldet "#1570: importierte Klasse ohne new wird gemeldet" 'import std.io;
import std.string;
fn main(): int64 {
  var sb: StringBuilder;
  sb.Init(16);
  sb.Append("abc");
  PrintLn(sb.ToString());
  return 0;
}' "Variable hat Klassentyp ohne Startwert"

# Mit new muss dasselbe Programm laufen — sonst waere die Meldung wertlos.
out "#1570: mit new laeuft es" 'import std.io;
import std.string;
fn main(): int64 {
  var sb: StringBuilder := new StringBuilder();
  sb.Init(16);
  sb.Append("abc");
  PrintLn(sb.ToString());
  return 0;
}' "abc"

# Ein importiertes STRUCT ohne Startwert bleibt gueltig — es wird angelegt,
# nicht referenziert. Faellt diese Unterscheidung weg, ist der halbe Bestand
# nicht mehr uebersetzbar.
out "#1570: importiertes Struct bleibt gueltig" 'import std.io;
import std.rect;
import std.vector;
fn main(): int64 {
  var r: Rect := RectFromXYWH(1, 2, 3, 4);
  var p: Vec2 := Vec2New(2, 3);
  PrintStr(IntToStr(r.min.x)); PrintStr(" "); PrintLn(IntToStr(p.y));
  return 0;
}' "1 3"

# Deklarieren und DANACH zuweisen ist gueltiger Bestand — der Zeiger wird
# gebunden, bevor er benutzt wird. std/lyxvision/group.lyx macht das mit TView,
# und vier Beispiele haengen daran. Die Pruefung darf nur greifen, wo NIRGENDS
# eine Zuweisung steht.
out "#1570: deklarieren und danach zuweisen bleibt erlaubt" 'import std.io;
import std.string;
fn main(): int64 {
  var sb: StringBuilder;
  sb := new StringBuilder();
  sb.Init(16);
  sb.Append("xy");
  PrintLn(sb.ToString());
  return 0;
}' "xy"

# Und die Gegenprobe aus #1519: eine methodenlose Klasse liegt als Wert vor.
out "#1570: methodenlose Klasse weiter erlaubt" 'type Base = class { a: int64; };
type Derived = class extends Base { b: int64; };
fn main(): int64 { var d: Derived; d.a := 40; d.b := 2; return d.a + d.b; }' ""

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
