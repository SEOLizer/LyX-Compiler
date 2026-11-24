#!/usr/bin/env bash
# tests/klasse_vorwaerts_extends_2607_test.sh — ist eine spaeter deklarierte
# Klasse MIT `extends` vorwaerts auflösbar? (#2607)
#
# BEFUND. `s.Wert := 7` in einer Methode, die UEBER der Deklaration von
# `TSpaet` steht, brach mit "#2134: Feld nicht aufloesbar (Typ der Basis
# unbekannt)" ab -- aber nur, wenn TSpaet ein `extends` trug. Ohne `extends`
# ging derselbe Vorwaertsverweis durch, mit vertauschter Reihenfolge ebenfalls.
# Der Ausloeser war die KOMBINATION, und nur auf x86 (und damit win64):
# arm64, riscv64 und lyxos uebersetzten alle vier Formen, weil der IR-Weg ueber
# eine namensindizierte Tabelle aufloest.
#
# URSACHE: zwei Aufzaehlungen derselben Sache, ein Fall in keiner.
#   cg_istStructDecl  verlangt `cg_nc2(ni) == -1`  -> kein extends
#   cg_istKlassenDecl verlangt Methoden ODER Elternklasse MIT VMT
# Eine methodenlose Klasse mit extends auf eine VMT-freie Basis fiel durch
# beide Vorlaeufe und wurde erst im Hauptdurchlauf vermessen.
#
# GEPRUEFT WIRD BEIDES: dass die Formen uebersetzen UND dass die Feldversaetze
# dieselben bleiben. Ein Test, der nur "uebersetzt" prueft, waere auch von
# einer Fassung erfuellt, die der Klasse ein Layout mit VMT-Platz gibt und
# damit JEDEN ihrer Feldversaetze um acht verschiebt.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$ROOT/tests/lib/lyxc_guard.sh"; [ -f "$_g" ] && . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ulimit -c 0 2>/dev/null
pr() { if [ "$1" = ok ]; then PASS=$((PASS+1)); echo "PASS $2"; else FAIL=$((FAIL+1)); echo "FAIL $2"; fi; }

cat > "$TMP/main.lyx" <<'LYX'
import w2;
fn main(): int64 { return 0; }
LYX

uebersetzt() { # name, unit-quelle, [ziel]
  printf '%s' "$2" > "$TMP/w2.lyx"
  local ziel="${3:-}"
  ( cd "$TMP" && "$LYXC" --std-path="$ROOT" -I . $ziel main.lyx -o "$TMP/m.out" ) > "$TMP/log" 2>&1
  if grep -q "#2134" "$TMP/log"; then
    pr fail "$1${ziel:+ ($ziel)}: #2134 -- $(grep -m1 '#2134' "$TMP/log")"
  elif ! [ -s "$TMP/m.out" ]; then
    pr fail "$1${ziel:+ ($ziel)}: kein Erzeugnis -- $(grep -m1 -i error "$TMP/log")"
  else
    pr ok "$1${ziel:+ ($ziel)}"
  fi
}

EIGEN='unit w2;
pub type TBasis = class { Platz: int64; };
pub type TFrueh = class { fn Setze(s: TSpaet): void { s.Wert := 7; } };
pub type TSpaet = class extends TBasis { Wert: int64; };
'
GEERBT='unit w2;
pub type TBasis = class { Platz: int64; };
pub type TFrueh = class { fn Setze(s: TSpaet): void { s.Platz := 7; } };
pub type TSpaet = class extends TBasis { Wert: int64; };
'
BASIS_SPAET='unit w2;
pub type TFrueh = class { fn Setze(s: TSpaet): void { s.Wert := 7; } };
pub type TSpaet = class extends TBasis { Wert: int64; };
pub type TBasis = class { Platz: int64; };
'
ERGEBNIS='unit w2;
pub type TBasis = class { Platz: int64; };
pub type TFrueh = class { fn Hol(): TSpaet { return 0 as TSpaet; } fn Setze(): void { self.Hol().Wert := 7; } };
pub type TSpaet = class extends TBasis { Wert: int64; };
'

echo "--- Vorwaertsverweis auf eine Klasse mit extends ---"
uebersetzt "eigenes Feld, spaeter deklariert"        "$EIGEN"
uebersetzt "geerbtes Feld, spaeter deklariert"       "$GEERBT"
uebersetzt "Basis erst nach der Kindklasse"          "$BASIS_SPAET"
uebersetzt "ueber ein Methodenergebnis"              "$ERGEBNIS"

# Die anderen Ziele gingen schon vorher -- sie bleiben im Lauf, damit eine
# kuenftige Aenderung an diesem Vorlauf sie nicht mitnimmt.
echo "--- dieselbe Form auf den IR-Zielen (gingen schon vorher) ---"
for z in --target=arm64 --target=riscv64 --target=lyxos; do
  uebersetzt "eigenes Feld, spaeter deklariert" "$EIGEN" "$z"
done

# --- Feldversaetze: die Werte, nicht die Uebersetzbarkeit ------------------
echo "--- Feldversaetze unveraendert (Wert messen, nicht Vorhandensein) ---"
mkdir -p "$TMP/v"
cat > "$TMP/v/u1.lyx" <<'LYX'
unit u1;
pub type TBasis = class { Platz: int64; };
pub type TKind = class extends TBasis { Wert: int64; };
pub fn NeuKind(): TKind { var k: TKind := new TKind(); k.Platz := 11; k.Wert := 22; return k; }
pub fn LesePlatz(k: TKind): int64 { return k.Platz; }
pub fn LeseWert(k: TKind): int64 { return k.Wert; }
LYX
cat > "$TMP/v/m.lyx" <<'LYX'
import std.io;
import u1;
fn main(): int64 {
  var k: TKind := NeuKind();
  PrintLn(IntToStr(LesePlatz(k)));
  PrintLn(IntToStr(LeseWert(k)));
  PrintLn(IntToStr(k.Platz));
  PrintLn(IntToStr(k.Wert));
  return 0;
}
LYX
if ( cd "$TMP/v" && "$LYXC" --std-path="$ROOT" -I . m.lyx -o "$TMP/v/p" ) >"$TMP/v/log" 2>&1 && [ -s "$TMP/v/p" ]; then
  AUS="$("$TMP/v/p" | tr '\n' ' ')"
  if [ "$AUS" = "11 22 11 22 " ]; then
    pr ok "geerbtes und eigenes Feld liefern 11/22, aus der Unit und von aussen"
  else
    pr fail "Feldwerte sind '$AUS', erwartet '11 22 11 22 ' -- Versaetze verschoben"
  fi
else
  pr fail "Messprogramm uebersetzt nicht: $(grep -m1 -i error "$TMP/v/log")"
fi

echo ""
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
