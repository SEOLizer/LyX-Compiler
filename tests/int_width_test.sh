#!/usr/bin/env bash
# tests/int_width_test.sh — #1151: schmale Ganzzahltypen kuerzen beim Speichern.
#
# Ein Local, ein Parameter und eine globale Variable belegen immer einen
# 64-Bit-Slot, auch wenn sie `int8` heissen. Bis 1.0.11D legte der Compiler den
# Wert ungekuerzt hinein: `var a: int8 := 130` lieferte 130 statt -126, und
# `var d: uint32 := 0-1` lieferte -1 statt 4294967295. Der Typ trug seine
# Breite nur im Namen.
#
# Geprueft wird der WERT nach dem Speichern, an jedem Eintrittspunkt einzeln:
# Initialisierung, Zuweisung, Parameter, Rueckgabe, globale Variable und
# `as`-Cast. Ein Test, der nur einen davon prueft, waere gruen geblieben,
# waehrend die anderen fuenf weiter durchfielen — genau so war der Stand.
#
# Die Gegenprobe gehoert dazu: `int64`/`uint64` duerfen NICHT gekuerzt werden,
# und Strukturfelder lagen schon immer in ihrer eigenen Breite im Speicher.
# Ohne diese Faelle waere eine Kuerzung, die IMMER zuschlaegt, ebenso gruen.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    echo "FAIL $1: uebersetzt nicht"; FAIL=$((FAIL+1)); return
  fi
  got="$(timeout 10 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then echo "FAIL $1: ABSTURZ (rc=$rc)"; FAIL=$((FAIL+1)); return; fi
  if [ "$got" = "$3" ]; then echo "PASS $1"; PASS=$((PASS+1))
  else echo "FAIL $1: '$got' erwartet '$3'"; FAIL=$((FAIL+1)); fi
}

K='import src.std.io;'

# --- Initialisierung eines Locals ----------------------------------------
out "int8 kuerzt bei der Initialisierung" "$K
fn main(): int64 { var a: int8 := 130; PrintLn(a); return 0; }" '-126'

out "uint8 kuerzt vorzeichenlos" "$K
fn main(): int64 { var a: uint8 := 300; PrintLn(a); return 0; }" '44'

out "uint8 aus negativem Wert" "$K
fn main(): int64 { var a: uint8 := 0 - 1; PrintLn(a); return 0; }" '255'

out "int16 kuerzt" "$K
fn main(): int64 { var a: int16 := 40000; PrintLn(a); return 0; }" '-25536'

out "uint32 kuerzt vorzeichenlos" "$K
fn main(): int64 { var a: uint32 := 0 - 1; PrintLn(a); return 0; }" '4294967295'

out "int32 kuerzt vorzeichenbehaftet" "$K
fn main(): int64 { var a: int32 := 4294967295; PrintLn(a); return 0; }" '-1'

# Kurze Schreibweise, laut §7 derselbe Typ.
out "kurze Schreibweise i8 wie int8" "$K
fn main(): int64 { var a: i8 := 130; PrintLn(a); return 0; }" '-126'

# --- Zuweisung nach der Deklaration --------------------------------------
out "Zuweisung kuerzt" "$K
fn main(): int64 { var a: int8 := 0; a := 200; PrintLn(a); return 0; }" '-56'

out "Rechenergebnis kuerzt bei der Zuweisung" "$K
fn main(): int64 { var a: int8 := 100; a := a + 100; PrintLn(a); return 0; }" '-56'

# --- Globale Variable -----------------------------------------------------
out "globale Variable, Literal-Initialisierung" "$K
var g: int8 := 300;
fn main(): int64 { PrintLn(g); return 0; }" '44'

out "globale Variable, Zuweisung" "$K
var g: int8 := 0;
fn main(): int64 { g := 200; PrintLn(g); return 0; }" '-56'

# --- Parameter und Rueckgabe ---------------------------------------------
out "Parameter kuerzt am Eintritt" "$K
fn f(x: int8): int64 { return x; }
fn main(): int64 { PrintLn(f(200)); return 0; }" '-56'

out "Rueckgabe kuerzt" "$K
fn f(): uint8 { return 300; }
fn main(): int64 { PrintLn(f()); return 0; }" '44'

out "Methodenparameter kuerzt" "$K
type K = class { v: int64; fn Put(x: int8): int64 { self.v := x; return self.v; } };
fn main(): int64 { var k: K := new K(); PrintLn(k.Put(200)); return 0; }" '-56'

# --- as-Cast --------------------------------------------------------------
# Die lange Schreibweise kuerzte nicht: die Kette im Codegen kannte nur `i8`
# und `i16`, obwohl §7 beide Formen als denselben Typ fuehrt.
out "Cast as int8, lange Schreibweise" "$K
fn main(): int64 { var a: int64 := 130; PrintLn(a as int8); return 0; }" '-126'

out "Cast as int16, lange Schreibweise" "$K
fn main(): int64 { var a: int64 := 40000; PrintLn(a as int16); return 0; }" '-25536'

# --- Gegenprobe: was NICHT gekuerzt werden darf ---------------------------
out "int64 bleibt unveraendert" "$K
fn main(): int64 { var a: int64 := 4294967296; PrintLn(a); return 0; }" '4294967296'

out "uint64 bleibt unveraendert" "$K
fn main(): int64 { var a: uint64 := 4294967296; PrintLn(a); return 0; }" '4294967296'

# Strukturfelder liegen in ihrer eigenen Breite im Speicher; dort kuerzte
# schon immer der Speicherbefehl. Der Fall gehoert her, damit eine Aenderung
# an dieser Seite nicht unbemerkt bleibt.
out "Strukturfeld kuerzt weiterhin" "$K
type S = struct { a: int8; b: uint8; };
fn main(): int64 { var s: S; s.a := 130; s.b := 300; PrintLn(s.a); PrintLn(s.b); return 0; }" '-126
44'

# --- Der Repro aus dem Issue ---------------------------------------------
out "Repro: int8(130) + uint8(250) auf 64 Bit" "$K
fn main(): int64 {
  var a: int8 := 130;
  var b: uint8 := 250;
  var x: int64 := a + b;
  PrintLn(x);
  return 0;
}" '124'

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
test "$FAIL" -eq 0
