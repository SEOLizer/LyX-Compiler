#!/usr/bin/env bash
# tests/method_tuple_return_test.sh — #1121: Tupel-Rueckgabe aus einer METHODE.
#
# `var a, b := c.Pair();` lieferte im zweiten Wert Speichermuell (wechselnde,
# adressartige Zahlen), ohne jede Meldung beim Uebersetzen. Bei freien
# Funktionen lief dieselbe Rueckgabe seit #1088 korrekt.
#
# Ursache war nicht die Registerkonkurrenz zwischen `self` und der
# Zwei-Register-Rueckgabe, wie im Issue vermutet, sondern eine nicht
# mitgezogene Kopie: `cg_genFuncDecl` erkennt den Tupel-Rueckgabetyp und setzt
# `funcHasTupleReturn`; `cg_genMethodDecl` tat das nie. Ohne die Merkung legte
# `return (3, 6)` nur rax an — rdx trug, was zufaellig drin stand, und der
# Aufrufer las daraus seinen zweiten Wert. Schlimmer noch: die Merkung blieb
# auf dem Stand der zuletzt uebersetzten FUNKTION stehen.
#
# Geprueft werden BEIDE Rueckgabewerte einzeln. Ein Test auf ihre Summe koennte
# durch zufaellig passenden Muell gruen werden, und ein Test auf
# Uebersetzbarkeit waere immer gruen gewesen — uebersetzt wurde ja.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
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

K='import src.std.io;'

# --- Der Repro aus dem Issue ---------------------------------------------
# Beide Werte einzeln, nicht ihre Summe.
out "Repro: Klassenmethode mit konstantem Tupel" "$K
type C = class { v: int64; fn Pair(): (int64, int64) { return (3, 6); } };
fn main(): int64 { var c: C := new C(); var a, b := c.Pair(); PrintLn(a); PrintLn(b); return 0; }" '3
6'

out "Werte aus self" "$K
type C = class { v: int64; fn Pair(): (int64, int64) { return (self.v, self.v * 2); } };
fn main(): int64 { var c: C := new C(); c.v := 4; var a, b := c.Pair(); PrintLn(a); PrintLn(b); return 0; }" '4
8'

out "struct-Methode" "$K
type S = struct { v: int64; fn Pair(): (int64, int64) { return (self.v, 6); } };
fn main(): int64 { var s: S; s.v := 3; var a, b := s.Pair(); PrintLn(a); PrintLn(b); return 0; }" '3
6'

out "static-Methode" "$K
type C = class { v: int64; static fn Pair(): (int64, int64) { return (3, 6); } };
fn main(): int64 { var a, b := C.Pair(); PrintLn(a); PrintLn(b); return 0; }" '3
6'

# --- Die uebrigen Aufrufwege ---------------------------------------------
# virtual laeuft ueber die VMT; der Rumpf wird trotzdem von cg_genMethodDecl
# erzeugt, die Merkung muss also auch dort stehen.
out "virtuelle Methode, spaet gebunden" "$K
type A = class { v: int64; virtual fn Pair(): (int64, int64) { return (1, 2); } };
type B = class extends A { override fn Pair(): (int64, int64) { return (3, 6); } };
fn main(): int64 { var a: A := new B(); var x, y := a.Pair(); PrintLn(x); PrintLn(y); return 0; }" '3
6'

# Geerbte nicht-virtuelle Methode mit Tupel — beides zusammen (#1120).
out "geerbte Methode mit Tupel (#1120)" "$K
type A = class { v: int64; fn Pair(): (int64, int64) { return (3, 6); } };
type B = class extends A { };
fn main(): int64 { var b: B := new B(); var x, y := b.Pair(); PrintLn(x); PrintLn(y); return 0; }" '3
6'

out "Methode mit Parametern" "$K
type C = class { v: int64; fn Pair(k: int64): (int64, int64) { return (k, k * 2); } };
fn main(): int64 { var c: C := new C(); var a, b := c.Pair(5); PrintLn(a); PrintLn(b); return 0; }" '5
10'

# Gemischte Elementtypen: der zweite Wert kam vorher aus rdx-Muell, der erste
# war korrekt — bei (pchar, int64) faellt genau das auf.
out "gemischte Elementtypen (pchar, int64)" "$K
type C = class { v: int64; fn P(): (pchar, int64) { return (\"hi\"c, 7); } };
fn main(): int64 { var c: C := new C(); var s, n := c.P(); PrintStr(s); PrintLn(n); return 0; }" 'hi7'

# Zwei Aufrufe hintereinander: der zweite darf den ersten nicht ueberschreiben.
out "zwei Aufrufe nacheinander" "$K
type C = class { v: int64; fn P(): (int64, int64) { return (3, 6); } };
fn main(): int64 { var c: C := new C(); var a, b := c.P(); var x, y := c.P(); PrintLn(a * y); return 0; }" '18'

out "zwei verschiedene Tupel-Methoden" "$K
type C = class { v: int64; fn P1(): (int64, int64) { return (1, 2); } fn P2(): (int64, int64) { return (10, 20); } };
fn main(): int64 { var c: C := new C(); var a, b := c.P1(); var x, y := c.P2(); PrintLn(a + b); PrintLn(x + y); return 0; }" '3
30'

# --- Gegenproben ---------------------------------------------------------
# Die Merkung darf nicht haengen bleiben: eine gewoehnliche Methode NACH einer
# Tupel-Funktion und eine Tupel-Funktion NACH einer Tupel-Methode.
out "gewoehnliche Methode nach Tupel-Funktion" "$K
fn P(): (int64, int64) { return (1, 2); }
type C = class { v: int64; fn One(): int64 { return 42; } };
fn main(): int64 { var c: C := new C(); PrintLn(c.One()); var a, b := P(); PrintLn(a + b); return 0; }" '42
3'

out "gewoehnliche Methode nach Tupel-Methode" "$K
type C = class { v: int64; fn P(): (int64, int64) { return (3, 6); } fn One(): int64 { return 42; } };
fn main(): int64 { var c: C := new C(); var a, b := c.P(); PrintLn(a + b); PrintLn(c.One()); return 0; }" '9
42'

# Freie Funktionen liefen schon vorher und muessen es weiter.
out "freie Funktion unveraendert" "$K
fn Pair(): (int64, int64) { return (3, 6); }
fn main(): int64 { var a, b := Pair(); PrintLn(a); PrintLn(b); return 0; }" '3
6'

out "Methode mit einem Rueckgabewert unveraendert" "$K
type C = class { v: int64; fn One(): int64 { return self.v + 3; } };
fn main(): int64 { var c: C := new C(); c.v := 4; PrintLn(c.One()); return 0; }" '7'

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
test "$FAIL" -eq 0
