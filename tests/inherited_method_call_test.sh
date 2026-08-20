#!/usr/bin/env bash
# tests/inherited_method_call_test.sh — #1120: geerbte NICHT-virtuelle Methode.
#
# `b.G()` auf einer abgeleiteten Klasse brach die Uebersetzung ab:
#
#   error: undefined function 'B_G' — no codegen implementation found
#
# Der Aufruf wurde auf den gemangelten Namen der STATISCHEN Klasse des
# Empfaengers abgebildet. Anders als die Felder wird eine Methode aber nicht in
# die abgeleitete Klasse kopiert — der Rumpf steht unter `A_G`, ein `B_G` gibt
# es nie. Der Fehler nannte damit einen Namen, den niemand geschrieben hat, und
# zwang dazu, jede geerbte Methode `virtual` zu machen (nur dann lief der
# Aufruf ueber die VMT), auch wo keine Ueberschreibung vorgesehen war.
#
# Behoben ueber eine Liste der je Klasse DEKLARIERTEN Methoden im
# Klassen-Layout (VMTLIST fuehrt nur die virtuellen) und `cg_findMethodOwner`,
# das die Vererbungskette ueber `CG_CLASS_OFF_PARENTIDX` hochlaeuft — dieselbe
# Kette, die `cg_isDescendantClass` schon benutzt.
#
# Geprueft wird das ERGEBNIS des Aufrufs, nicht nur die Uebersetzbarkeit: die
# naeheste Definition muss gewinnen, sonst traefe `c.G()` bei A -> B -> C mit
# Definition in B stillschweigend die von A.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
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

fails() { # name, quelltext, erwarteter meldungsteil
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  msg="$("$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)"
  if [ -f "$TMP/c" ]; then echo "FAIL $1: uebersetzt, statt zu melden"; FAIL=$((FAIL+1)); return; fi
  case "$msg" in
    *"$3"*) echo "PASS $1"; PASS=$((PASS+1)) ;;
    *) echo "FAIL $1: Meldung ohne '$3'"; FAIL=$((FAIL+1)) ;;
  esac
}

K='import src.std.io;'

# --- Der Repro aus dem Issue ---------------------------------------------
out "Repro: geerbte nicht-virtuelle Methode" "$K
type A = class { v: int64; fn G(): int64 { return 7; } };
type B = class extends A { fn H(): int64 { return 1; } };
fn main(): int64 { var b: B := new B(); PrintLn(b.G()); return 0; }" '7'

# Die geerbte Methode arbeitet auf einem ererbten Feld — self muss stimmen,
# nicht nur der Name aufloesbar sein.
out "geerbte Methode benutzt self auf ererbtem Feld" "$K
type A = class { v: int64; fn G(): int64 { return self.v + 1; } };
type B = class extends A { };
fn main(): int64 { var b: B := new B(); b.v := 5; PrintLn(b.G()); return 0; }" '6'

out "geerbte Methode mit Argumenten" "$K
type A = class { v: int64; fn G(x: int64): int64 { return x + 7; } };
type B = class extends A { };
fn main(): int64 { var b: B := new B(); PrintLn(b.G(3)); return 0; }" '10'

out "geerbte void-Methode" "$K
type A = class { v: int64; fn P(): void { Print(\"a\"c); } };
type B = class extends A { };
fn main(): int64 { var b: B := new B(); b.P(); PrintStrLn(\"\"c); return 0; }" 'a'

# Eine geerbte Methode, die ueber self eine weitere geerbte Methode ruft.
out "geerbte Methode ruft geerbte Methode" "$K
type A = class { v: int64; fn K(): int64 { return 4; } fn G(): int64 { return self.K() + 1; } };
type B = class extends A { };
fn main(): int64 { var b: B := new B(); PrintLn(b.G()); return 0; }" '5'

# --- Mehrstufige Vererbung ------------------------------------------------
out "drei Stufen A -> B -> C" "$K
type A = class { v: int64; fn G(): int64 { return 7; } };
type B = class extends A { };
type C = class extends B { };
fn main(): int64 { var c: C := new C(); PrintLn(c.G()); return 0; }" '7'

# --- Die naeheste Definition gewinnt --------------------------------------
# Ein reiner Uebersetzbarkeitstest waere hier gruen, auch wenn die Kette die
# FALSCHE Definition faende.
out "eigene Definition schlaegt die geerbte" "$K
type A = class { v: int64; fn G(): int64 { return 7; } };
type B = class extends A { fn G(): int64 { return 9; } };
fn main(): int64 { var b: B := new B(); PrintLn(b.G()); return 0; }" '9'

out "Definition in der Mitte der Kette gewinnt" "$K
type A = class { v: int64; fn G(): int64 { return 7; } };
type B = class extends A { fn G(): int64 { return 9; } };
type C = class extends B { };
fn main(): int64 { var c: C := new C(); PrintLn(c.G()); return 0; }" '9'

# --- Gegenproben: die anderen Aufrufwege bleiben --------------------------
# `virtual` laeuft weiter ueber die VMT, also nach dem DYNAMISCHEN Typ — hier
# muss B_G treffen, obwohl die Variable als A deklariert ist.
out "virtual bleibt spaet gebunden" "$K
type A = class { v: int64; virtual fn G(): int64 { return 7; } };
type B = class extends A { override fn G(): int64 { return 9; } };
fn main(): int64 { var a: A := new B(); PrintLn(a.G()); return 0; }" '9'

# super.G() geht weiter DIREKT zur Elternimplementierung (#1091) und nicht
# ueber die VMT — sonst riefe es sich endlos selbst.
out "super erreicht die Elternimplementierung (#1091)" "$K
type A = class { v: int64; virtual fn G(): int64 { return 7; } };
type B = class extends A { override fn G(): int64 { return super.G() + 1; } };
fn main(): int64 { var b: B := new B(); PrintLn(b.G()); return 0; }" '8'

out "Aufruf auf der Basisklasse selbst" "$K
type A = class { v: int64; fn G(): int64 { return 7; } };
fn main(): int64 { var a: A := new A(); PrintLn(a.G()); return 0; }" '7'

out "geerbte Methode ueber eine Basis-Variable" "$K
type A = class { v: int64; fn G(): int64 { return 7; } };
type B = class extends A { };
fn main(): int64 { var a: A := new B(); PrintLn(a.G()); return 0; }" '7'

out "geerbte Felder unveraendert" "$K
type A = class { v: int64; };
type B = class extends A { w: int64; };
fn main(): int64 { var b: B := new B(); b.v := 3; b.w := 4; PrintLn(b.v + b.w); return 0; }" '7'

# --- Der Fehler bleibt laut ----------------------------------------------
# Eine Methode, die es NIRGENDS in der Kette gibt, muss weiterhin melden — die
# Aufloesung darf nicht in einen stillen Default fallen.
fails "unbekannte Methode meldet weiterhin" "$K
type A = class { v: int64; };
type B = class extends A { };
fn main(): int64 { var b: B := new B(); PrintLn(b.Nope()); return 0; }" "undefined function"

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
test "$FAIL" -eq 0
