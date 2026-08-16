#!/usr/bin/env bash
# tests/sema_unitgrenzen_z14_test.sh — #1573, #1567, #1514, #1574, #1575.
#
# Vier Luecken an der Unit-Grenze und eine in der Grammatik. Gemeinsam ist den
# ersten dreien, dass sema bzw. Codegen die Antwort nicht MEHR hatte und
# daraufhin schwieg, statt dort nachzusehen, wo sie noch stand:
#
#   #1573 Bei `basis.feld` gab die Pruefung auf, sobald der Typ importiert war
#         (SymNodeIdx == -2). `p.lat` auf einem GeoPoint (Felder x, y)
#         uebersetzte klaglos und lieferte 0 — also fuer JEDE Struktur der
#         stdlib. Jetzt werden Feld- und Methodennamen beim Import
#         abgeschrieben, solange der Knoten gilt (wie klsTab in #1570).
#   #1567 Zwei private `fn` gleichen Namens in einer IMPORTIERTEN Unit wurden
#         angenommen; der Aufruf band an die erste und die Argumentzahl blieb
#         ungeprueft. Die Pruefung aus #1135 lief nur auf dem Wurzelmodul.
#   #1514 `var flag: bool := false` global: "Startwert ist zur Uebersetzungs-
#         zeit nicht bekannt" — fuer ein Literal schlicht unwahr.
#         cg_isConstExpr kannte CGN_LIT_BOOL nicht.
#   #1574 Globale Variable vom Funktionstyp: mit Startwert derselbe Fehler
#         (eine Codeadresse IST konstant), ohne Startwert "undefined function".
#   #1575 `a = b;` wies zu, obwohl die Grammatik einen Parse-Fehler zusagt.
#
# GEMESSEN WIRD MIT TYPEN AUS DER STDLIB, nicht mit einer Struktur in derselben
# Datei — dort griff die Pruefung immer, ein solcher Test waere gruen gewesen
# und haette die Luecke verdeckt.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >"$TMP/c.log" 2>&1; then
    no "$1" "uebersetzt nicht: $(grep -m1 -iE 'error|sema|Parse' "$TMP/c.log")"; return
  fi
  got="$(timeout 20 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then no "$1" "ABSTURZ rc=$rc"; return; fi
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1" "'$got' erwartet '$3'"; fi
}

meldet() { # name, quelltext, textstueck
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  msg="$(timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then no "$1" "uebersetzt klaglos"; return; fi
  if echo "$msg" | grep -qF "$3"; then ok "$1"; else no "$1" "andere Meldung: $(echo "$msg"|grep -iE 'error|Parse'|head -1)"; fi
}

# ===========================================================================
# #1573 — unbekanntes Feld an einem IMPORTIERTEN Typ
# ===========================================================================

meldet "#1573: unbekanntes Feld an importiertem Struct" 'import std.io;
import std.geo;
fn main(): int64 {
  var b: GeoPoint := GeoPointNew(13405000, 52520000);
  PrintLn(IntToStr(b.lat));
  return 0;
}' "unknown field"

# Die gueltigen Felder muessen weiter durchgehen — sonst waere die Pruefung
# schlimmer als die Luecke.
out "#1573: gueltige Felder unveraendert" 'import std.io;
import std.geo;
fn main(): int64 {
  var b: GeoPoint := GeoPointNew(13405000, 52520000);
  PrintStr(IntToStr(b.x)); PrintStr(" "); PrintLn(IntToStr(b.y));
  return 0;
}' "13405000 52520000"

# Zweiter importierter Typ, andere Unit: die Tabelle darf nicht nur den
# zuletzt importierten Typ kennen.
out "#1573: mehrere importierte Typen nebeneinander" 'import std.io;
import std.rect;
import std.vector;
fn main(): int64 {
  var r: Rect := RectFromXYWH(1, 2, 3, 4);
  var p: Vec2 := Vec2New(2, 3);
  PrintStr(IntToStr(r.min.x)); PrintStr(" "); PrintLn(IntToStr(p.y));
  return 0;
}' "1 3"

meldet "#1573: unbekanntes Feld am zweiten importierten Typ" 'import std.io;
import std.rect;
import std.vector;
fn main(): int64 {
  var p: Vec2 := Vec2New(2, 3);
  PrintLn(IntToStr(p.z));
  return 0;
}' "unknown field"

# Eine Klasse MIT Methoden: der Methodenname ist kein unbekanntes Feld.
out "#1573: Methodenzugriff auf importierter Klasse bleibt gueltig" 'import std.io;
import std.string;
fn main(): int64 {
  var sb: StringBuilder := new StringBuilder();
  sb.Init(16);
  sb.Append("ab");
  PrintLn(sb.ToString());
  return 0;
}' "ab"

# ===========================================================================
# #1567 — doppelte private fn in einer importierten Unit
# ===========================================================================
mkdir -p "$TMP/mod"
cat > "$TMP/mod/zwei.lyx" <<'MODEOF'
unit mod.zwei;
fn intern(a: int64, b: int64, c: int64): int64 { return 111; }
fn intern(a: int64): int64 { return 222; }
pub fn wert(): int64 { return intern(7); }
MODEOF
cat > "$TMP/dop.lyx" <<'MAINEOF'
unit main;
import std.io;
import mod.zwei;
pub fn main(argc: int64, argv: pchar): int64 { PrintLn(IntToStr(wert())); return 0; }
MAINEOF
msg="$(timeout 200 "$LYXC" --std-path="$ROOT" -I "$TMP" "$TMP/dop.lyx" -o "$TMP/dop" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$msg" | grep -q "bereits deklariert"; then
  ok "#1567: doppelte private fn in importierter Unit wird gemeldet"
else
  no "#1567: doppelte private fn" "rc=$rc, $(echo "$msg"|grep -iE 'error'|head -1)"
fi

# Gegenprobe: EINE Definition in derselben Unit bleibt gueltig.
cat > "$TMP/mod/eins.lyx" <<'MODEOF'
unit mod.eins;
fn intern(a: int64): int64 { return a * 2; }
pub fn wert(): int64 { return intern(21); }
MODEOF
cat > "$TMP/ein.lyx" <<'MAINEOF'
unit main;
import std.io;
import mod.eins;
pub fn main(argc: int64, argv: pchar): int64 { PrintLn(IntToStr(wert())); return 0; }
MAINEOF
if timeout 200 "$LYXC" --std-path="$ROOT" -I "$TMP" "$TMP/ein.lyx" -o "$TMP/ein" >"$TMP/ein.log" 2>&1; then
  got="$("$TMP/ein" 2>&1)"
  if [ "$got" = "42" ]; then ok "#1567: einfache private fn unveraendert"
  else no "#1567: einfache private fn" "'$got' erwartet '42'"; fi
else
  no "#1567: einfache private fn" "$(grep -m1 -i error "$TMP/ein.log")"
fi

# ===========================================================================
# #1514 — globale bool-Variable mit Startwert
# ===========================================================================

out "#1514: globales bool mit Startwert" 'import std.io;
var flag: bool := false;
var an: bool := true;
fn main(): int64 {
  if (flag) { PrintStr("A"); } else { PrintStr("B"); }
  if (an) { PrintLn("C"); } else { PrintLn("D"); }
  return 0;
}' "BC"

out "#1514: globales char mit Startwert" 'import std.io;
var c: char := 65;
fn main(): int64 { PrintLn(IntToStr(c)); return 0; }' "65"

# Die Gegenprobe: ein wirklich nicht konstanter Startwert muss weiter melden —
# sonst waere aus dem Fix ein stiller Default geworden.
meldet "#1514: nicht konstanter globaler Startwert bleibt ein Fehler" 'import std.io;
fn F(): int64 { return 1; }
var g: int64 := F() + 1;
fn main(): int64 { PrintLn(IntToStr(g)); return 0; }' "nicht bekannt"

# ===========================================================================
# #1574 — globale Variable vom Funktionstyp
# ===========================================================================

out "#1574: mit Startwert" 'import std.io;
fn Triple(x: f64): f64 { return x * 3.0; }
var gFn: fn(f64): f64 := Triple;
fn main(): int64 { PrintLn(FloatToStr(gFn(4.0), 3)); return 0; }' "12.000"

out "#1574: ohne Startwert, spaeter zugewiesen und umgehaengt" 'import std.io;
fn Triple(x: f64): f64 { return x * 3.0; }
fn Half(x: f64): f64 { return x / 2.0; }
var gFn: fn(f64): f64;
fn main(): int64 {
  gFn := Triple;
  PrintStr(FloatToStr(gFn(4.0), 3)); PrintStr(" ");
  gFn := Half;
  PrintLn(FloatToStr(gFn(4.0), 3));
  return 0;
}' "12.000 2.000"

# Die f64-Typspur muss den globalen Zeiger kennen (dieselbe Luecke wie #1565
# beim lokalen): sonst wird aus 12.0 das Bitmuster 4622945017495814144.
out "#1574: Rueckgabe in einer f64-Variablen und im Ausdruck" 'import std.io;
fn Triple(x: f64): f64 { return x * 3.0; }
var gFn: fn(f64): f64 := Triple;
fn main(): int64 {
  var v: f64 := gFn(4.0);
  PrintStr(FloatToStr(v, 3)); PrintStr(" ");
  PrintLn(FloatToStr(gFn(2.0) + 1.0, 3));
  return 0;
}' "12.000 7.000"

out "#1574: mehrere Argumente, Ganzzahl" 'import std.io;
fn Add3(a: int64, b: int64, c: int64): int64 { return a + b + c; }
var gi: fn(int64, int64, int64): int64 := Add3;
fn main(): int64 { PrintLn(IntToStr(gi(1, 2, 39))); return 0; }' "42"

# Ein gleichnamiges Local muss die globale Variable verdecken, wie ueberall.
out "#1574: lokaler Zeiger verdeckt den globalen" 'import std.io;
fn Triple(x: f64): f64 { return x * 3.0; }
fn Half(x: f64): f64 { return x / 2.0; }
var gFn: fn(f64): f64 := Triple;
fn main(): int64 {
  var gFn: fn(f64): f64 := Half;
  PrintLn(FloatToStr(gFn(4.0), 3));
  return 0;
}' "2.000"

# ===========================================================================
# #1575 — einzelnes = in Anweisungsposition
# ===========================================================================

meldet "#1575: a = b wird gemeldet" 'import std.io;
fn main(): int64 {
  var a: int64 := 1;
  var b: int64 := 2;
  a = b;
  PrintLn(IntToStr(a));
  return 0;
}' "kein Zuweisungsoperator"

out "#1575: == bleibt der Vergleich" 'import std.io;
fn main(): int64 {
  var a: int64 := 2;
  if (a == 2) { PrintLn("gleich"); } else { PrintLn("ungleich"); }
  return 0;
}' "gleich"

out "#1575: := unveraendert" 'import std.io;
fn main(): int64 {
  var a: int64 := 1;
  a := 41 + a;
  PrintLn(IntToStr(a));
  return 0;
}' "42"

# Enum-Mitglieder schreiben `NAME = wert` — das ist eine Deklaration, keine
# Anweisung, und darf von der Verschaerfung nicht getroffen werden.
out "#1575: Enum-Mitglieder unveraendert" 'import std.io;
pub enum HttpStatus {
  OK = 200,
  NOT_FOUND = 404,
};
fn main(): int64 { PrintLn(IntToStr(NOT_FOUND)); return 0; }' "404"

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
