#!/bin/bash
# Runde 16 — drei stille Fehlfunktionen (#1665, #1619, #1666)
#
#   * #1665: Modulvariable, die oberhalb ihrer Deklaration geschrieben wird.
#     Der Schreibzugriff wurde still verworfen; gelesen wurde eine Variable,
#     die nie jemand beschrieben hat.
#   * #1619: globale Variable vom Klassentyp ohne Startwert war NICHT null,
#     das Lazy-Init-Muster lief deshalb nie in seinen Zweig.
#   * #1666: Zuweisung an ein Feld, das es nicht gibt, wurde angenommen,
#     sobald die Basisklasse aus einer anderen Unit stammt.
#
# Der #1666-Teil prueft einen ABBRUCH. Ein Test, der nur "uebersetzt" prueft,
# waere hier verkehrt herum: erwartet wird, dass der Compiler NEIN sagt.
set -u
cd "$(dirname "$0")/.."
LYXC=${LYXC:-./lyxc}
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
DATA="tests/data"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
pruefe() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (erwartet '$3', erhalten '$2')"; fi; }

# ---------------------------------------------------------------- #1665
cat > "$TMP/vor.lyx" <<'EOF'
unit Main;
import std.io;

// Beide Funktionen stehen OBERHALB der Deklaration.
fn Setzen(): void { z := 4; }
fn Erhoehen(): void { z := z + 10; }

var z: int64;
var nachher: int64;

fn main(): int64 {
  Setzen();
  Erhoehen();
  PrintLn("vorher=" + IntToStr(z));
  nachher := 7;
  PrintLn("nachher=" + IntToStr(nachher));
  return 0;
}
EOF
if ! "$LYXC" --std-path=. "$TMP/vor.lyx" -o "$TMP/vor" > "$TMP/vor.log" 2>&1; then
  bad "#1665 uebersetzt"; grep -E "error" "$TMP/vor.log" | head -3
else
  ok "#1665 uebersetzt"
  if timeout 60 "$TMP/vor" > "$TMP/vor.out" 2>&1; then
    v() { grep "^$1=" "$TMP/vor.out" | head -1 | cut -d= -f2; }
    # 4 + 10: beide Schreibzugriffe oberhalb der Deklaration muessen DIESELBE
    # Variable treffen wie der Lesezugriff unterhalb.
    pruefe "#1665 Schreiben vor der Deklaration wirkt" "$(v vorher)"  "14"
    pruefe "#1665 Deklaration vor Nutzung unveraendert" "$(v nachher)" "7"
  else
    bad "#1665 laeuft"; head -3 "$TMP/vor.out"
  fi
fi

# ---------------------------------------------------------------- #1619
cat > "$TMP/lazy.lyx" <<'EOF'
import std.io;
type TTheme = class { n: int64; fn Create(): void { self.n := 42; } }
type TZaehler = struct { wert: int64; }

var g_theme: TTheme;        // Klasse: Referenz, ohne Zuweisung null
var g_zaehler: TZaehler;    // Struct: Wert, hat eigenen Speicher

fn DefaultTheme(): TTheme {
  if (g_theme == null) { g_theme := new TTheme(); }
  return g_theme;
}

fn main(): int64 {
  if (g_theme == null) { PrintLn("null=1"); } else { PrintLn("null=0"); }
  var t: TTheme := DefaultTheme();
  PrintLn("lazy=" + IntToStr(t.n));
  // Zweiter Aufruf muss dieselbe Instanz liefern, nicht eine neue.
  g_theme.n := 99;
  var t2: TTheme := DefaultTheme();
  PrintLn("gleich=" + IntToStr(t2.n));
  // Struct auf Modulebene behaelt seinen Speicher — Wertsemantik.
  g_zaehler.wert := 5;
  PrintLn("struct=" + IntToStr(g_zaehler.wert));
  return 0;
}
EOF
if ! "$LYXC" --std-path=. "$TMP/lazy.lyx" -o "$TMP/lazy" > "$TMP/lazy.log" 2>&1; then
  bad "#1619 uebersetzt"; grep -E "error" "$TMP/lazy.log" | head -3
else
  ok "#1619 uebersetzt"
  if timeout 60 "$TMP/lazy" > "$TMP/lazy.out" 2>&1; then
    w() { grep "^$1=" "$TMP/lazy.out" | head -1 | cut -d= -f2; }
    pruefe "#1619 Klassenglobale ohne Startwert ist null" "$(w null)"   "1"
    pruefe "#1619 Lazy-Init greift"                       "$(w lazy)"   "42"
    pruefe "#1619 zweiter Aufruf liefert dieselbe Instanz" "$(w gleich)" "99"
    pruefe "#1619 Struct behaelt Wertsemantik"            "$(w struct)" "5"
  else
    bad "#1619 laeuft"; head -3 "$TMP/lazy.out"
  fi
fi

# ---------------------------------------------------------------- #1666
cat > "$TMP/feld.lyx" <<'EOF'
unit Main;
import runde16.basis;
import std.io;
pub type TAbl = class extends TBasis {
  b: int64;
  fn Create(): void { self.a := 1; self.b := 2; }
}
fn main(): int64 {
  var x: TAbl := new TAbl();
  x.gibtesnicht := 99;
  PrintLn(IntToStr(x.b));
  return 0;
}
EOF
if "$LYXC" --std-path=. -I "$DATA" "$TMP/feld.lyx" -o "$TMP/feld" > "$TMP/feld.log" 2>&1; then
  bad "#1666 unbekanntes Feld wird abgewiesen (uebersetzte klaglos)"
else
  if grep -q "unknown field" "$TMP/feld.log"; then
    ok "#1666 unbekanntes Feld wird abgewiesen"
  else
    bad "#1666 Meldung nennt das unbekannte Feld"; head -3 "$TMP/feld.log"
  fi
fi

# Gegenprobe: gueltige Felder und geerbte Methoden muessen weiter durchgehen —
# sonst waere die Verschaerfung ein neuer Defekt.
cat > "$TMP/feldok.lyx" <<'EOF'
unit Main;
import runde16.basis;
import std.io;
pub type TAbl = class extends TBasis {
  b: int64;
  fn Create(): void { self.a := 1; self.b := 2; }
}
fn main(): int64 {
  var x: TAbl := new TAbl();
  x.b := 5;
  x.a := 3;                      // geerbtes Feld aus der fremden Unit
  PrintLn("summe=" + IntToStr(x.a + x.b));
  PrintLn("geerbt=" + IntToStr(x.Verdopple()));
  return 0;
}
EOF
if ! "$LYXC" --std-path=. -I "$DATA" "$TMP/feldok.lyx" -o "$TMP/feldok" > "$TMP/feldok.log" 2>&1; then
  bad "#1666 gueltige geerbte Felder bleiben erlaubt"; grep -E "error" "$TMP/feldok.log" | head -3
else
  ok "#1666 gueltige geerbte Felder bleiben erlaubt"
  if timeout 60 "$TMP/feldok" > "$TMP/feldok.out" 2>&1; then
    g() { grep "^$1=" "$TMP/feldok.out" | head -1 | cut -d= -f2; }
    pruefe "#1666 geerbtes Feld traegt"   "$(g summe)"  "8"
    pruefe "#1666 geerbte Methode traegt" "$(g geerbt)" "6"
  else
    bad "#1666 Gegenprobe laeuft"
  fi
fi

echo "----"
echo "$PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
