#!/usr/bin/env bash
# tests/sprachluecken_z5_test.sh — #1515, #1519.
#
#   #1515 `abstract fn` in einem Interface liess den Parser HÄNGEN. Die
#         Mitgliederschleife kannte nur `fn`; bei allem anderen ging sie in die
#         nächste Runde, OHNE das Token zu verbrauchen — eine Endlosschleife.
#         Gemessen wurde das als Zeitüberschreitung (rc=124), nicht als Fehler.
#   #1519 Eine Variable mit Klassentyp ohne Startwert wurde stillschweigend
#         angenommen. Der Zeiger blieb 0; ein Feldzugriff oder Methodenaufruf
#         darauf stürzte irgendwann später ab, weit weg von der Ursache.
#
# GEPRÜFT WIRD BEI #1515 DIE ZEIT, nicht nur der Rückgabewert: der Parser hing,
# er stürzte nicht ab. Ein Test ohne timeout würde selbst hängen statt rot zu
# werden. Bei #1519 wird die MELDUNG geprüft — ein Test auf "übersetzt nicht"
# wäre auch bei einem beliebigen anderen Fehler grün.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

uebersetzt() { # name, quelltext  — muss ohne Haenger uebersetzen
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  msg="$(timeout 60 "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -eq 124 ]; then no "$1" "HAENGT (rc=124)"; return 1; fi
  if [ "$rc" -ne 0 ]; then no "$1" "rc=$rc: $(echo "$msg" | grep -i error | head -1)"; return 1; fi
  ok "$1"; return 0
}

laeuft() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! timeout 60 "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    no "$1" "uebersetzt nicht"; return
  fi
  got="$(timeout 20 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then no "$1" "ABSTURZ rc=$rc"; return; fi
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1" "'$got' erwartet '$3'"; fi
}

meldet() { # name, quelltext, textstueck der meldung
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  msg="$(timeout 60 "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -eq 124 ]; then no "$1" "HAENGT (rc=124)"; return; fi
  if [ "$rc" -eq 0 ]; then no "$1" "uebersetzt klaglos"; return; fi
  if echo "$msg" | grep -qF "$3"; then ok "$1"; else no "$1" "andere Meldung: $(echo "$msg"|grep -i error|head -1)"; fi
}

# ===========================================================================
# #1515 — abstract fn im Interface
# ===========================================================================

uebersetzt "#1515: abstract fn im Interface haengt nicht" 'import std.io;
type Zeichenbar = interface {
  abstract fn Zeichne(): int64;
};
fn main(): int64 { PrintLn("ok"); return 0; }'

uebersetzt "#1515: mehrere abstract-Mitglieder" 'import std.io;
type Form = interface {
  abstract fn Flaeche(): int64;
  abstract fn Umfang(): int64;
  fn Name(): int64;
};
fn main(): int64 { PrintLn("ok"); return 0; }'

# Ein ueberzaehliges Semikolon zwischen den Mitgliedern hing aus demselben
# Grund — auch das war kein `fn`.
uebersetzt "#1515: ueberzaehliges Semikolon" 'import std.io;
type I = interface {
  fn A(): int64;
  ;
  fn B(): int64;
};
fn main(): int64 { PrintLn("ok"); return 0; }'

# Und wirklich Unsinniges muss MELDEN statt haengen — genau das war die Wurzel.
meldet "#1515: Unsinn im Interface wird gemeldet" 'import std.io;
type I = interface {
  var x: int64;
};
fn main(): int64 { return 0; }' "interface"

# Gegenprobe: ein normales Interface samt Implementierung laeuft unveraendert.
laeuft "#1515: Interface mit Implementierung unveraendert" 'import std.io;
type Flaechig = interface {
  fn Flaeche(): int64;
};
type Rechteck = class implements Flaechig {
  b: int64;
  h: int64;
  fn Flaeche(): int64 { return self.b * self.h; }
};
fn main(): int64 {
  var r: Rechteck := new Rechteck();
  r.b := 4; r.h := 4;
  PrintLn(IntToStr(r.Flaeche()));
  return 0;
}' "16"

# ===========================================================================
# #1519 — Klassenvariable ohne Startwert
# ===========================================================================

meldet "#1519: Klasse ohne Startwert wird gemeldet" 'import std.io;
type K = class {
  a: int64;
  fn Hol(): int64 { return self.a; }
};
fn main(): int64 {
  var k: K;
  k.a := 5;
  PrintLn(IntToStr(k.a));
  return 0;
}' "ohne Startwert"

# Auch ohne jeden Zugriff — die Meldung haengt an der DEKLARATION, sonst
# haette sie nur den zufaellig zuerst benutzten Fall erwischt.
meldet "#1519: auch ohne Zugriff gemeldet" 'import std.io;
type K = class {
  a: int64;
  fn Hol(): int64 { return self.a; }
};
fn main(): int64 {
  var k: K;
  PrintLn("nichts");
  return 0;
}' "ohne Startwert"

# Gegenproben: die drei gueltigen Schreibweisen duerfen nicht anschlagen.
laeuft "#1519: new K() unveraendert" 'import std.io;
type K = class {
  a: int64;
  fn Hol(): int64 { return self.a; }
};
fn main(): int64 {
  var k: K := new K();
  k.a := 5;
  PrintLn(IntToStr(k.Hol()));
  return 0;
}' "5"

laeuft "#1519: ausdrueckliches null unveraendert" 'import std.io;
type K = class {
  a: int64;
  fn Hol(): int64 { return self.a; }
};
fn main(): int64 {
  var k: K := null;
  PrintLn("ok");
  return 0;
}' "ok"

# Ein STRUCT ohne Startwert ist gueltig — es wird angelegt, nicht referenziert.
# Faellt die Unterscheidung weg, ist der halbe Bestand nicht mehr uebersetzbar.
laeuft "#1519: struct ohne Startwert bleibt gueltig" 'import std.io;
type S = struct { a: int64; b: int64; }
fn main(): int64 {
  var s: S;
  s.a := 5; s.b := 7;
  PrintStr(IntToStr(s.a)); PrintStr(" "); PrintLn(IntToStr(s.b));
  return 0;
}' "5 7"

# Eine methodenlose Klasse bekommt im Codegen struct-Layout und liegt auf dem
# Stapel — sie OHNE new zu deklarieren ist gueltiger Bestand. Traf die Pruefung
# auch diesen Fall, war unknown_field_test.sh rot.
laeuft "#1519: methodenlose Klasse bleibt gueltig" 'type Base = class { a: int64; };
type Derived = class extends Base { b: int64; };
fn main(): int64 { var d: Derived; d.a := 40; d.b := 2; return d.a + d.b; }' ""

# Ein Typalias auf einen eingebauten Typ ist keine Klasse.
laeuft "#1519: Typalias bleibt gueltig" 'import std.io;
type Zahl = int64;
fn main(): int64 {
  var z: Zahl;
  z := 9;
  PrintLn(IntToStr(z));
  return 0;
}' "9"

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
