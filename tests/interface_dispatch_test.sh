#!/usr/bin/env bash
# tests/interface_dispatch_test.sh — #1133: Aufruf ueber den Interface-Typ.
#
# `var i: I := p; i.Zeig();` lieferte still 0 statt das Ergebnis der
# implementierenden Methode. Ueber den Klassentyp lief derselbe Aufruf.
#
# Ursache: das Interface wurde als GEWOEHNLICHE Klasse registriert (es hat
# Methoden, also Klassen-Layout), und weil seine Methodensignaturen weder
# `virtual` noch `abstract` tragen, erzeugte der Codegen fuer jede von ihnen
# einen Rumpf — und der ist leer, es gibt ja keinen. `I_Zeig` bestand damit aus
# Prolog, `xor rax,rax`, Epilog. Der Aufruf ueber die Interface-Variable fand
# keinen VMT-Slot (VMTSLOTS war 0) und landete statisch genau dort.
#
# Umgesetzt ueber SELEKTOREN: die Namen aller in Interfaces deklarierten
# Methoden bekommen je einen festen Slot, den jede Klasse an derselben Stelle
# fuehrt. Nur so trifft ein Aufruf, der bloss das Interface kennt, dieselbe
# Stelle wie einer ueber die Klasse. Die implementierende Methode braucht kein
# `virtual` — die Zusage steckt im `implements`.
#
# Geprueft wird der WERT. Ein Test auf Uebersetzbarkeit waere immer gruen
# gewesen, und einer, der nur "Interface-Variable ist nicht null" prueft,
# ebenfalls — die Zuweisung war nie das Problem.

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
out "Repro: Klassentyp, Interface-Variable, Parameter" "$K
type I = interface { fn Zeig(): int64; };
type P = class implements I { v: int64; fn Zeig(): int64 { return 7; } };
fn Ruf(x: I): int64 { return x.Zeig(); }
fn main(): int64 {
    var p: P := new P();
    PrintLn(p.Zeig());
    var i: I := p;
    PrintLn(i.Zeig());
    PrintLn(Ruf(p));
    return 0;
}" '7
7
7'

# Zwei Implementierungen: es muss die JEWEILIGE getroffen werden. Vorher
# lieferten beide 0 — es wurde also gar keine gewaehlt.
out "zwei Implementierungen, je eigene Methode" "$K
type I = interface { fn Zeig(): int64; };
type P = class implements I { v: int64; fn Zeig(): int64 { return 7; } };
type Q = class implements I { v: int64; fn Zeig(): int64 { return 9; } };
fn Ruf(x: I): int64 { return x.Zeig(); }
fn main(): int64 { PrintLn(Ruf(new P())); PrintLn(Ruf(new Q())); return 0; }" '7
9'

# Dieselbe Variable, nacheinander mit zwei Klassen belegt — der Dispatch haengt
# am Objekt, nicht am deklarierten Typ.
out "Interface-Variable neu belegt" "$K
type I = interface { fn Zeig(): int64; };
type P = class implements I { v: int64; fn Zeig(): int64 { return 7; } };
type Q = class implements I { v: int64; fn Zeig(): int64 { return 9; } };
fn main(): int64 { var i: I := new P(); PrintLn(i.Zeig()); i := new Q(); PrintLn(i.Zeig()); return 0; }" '7
9'

# --- Argumente und self --------------------------------------------------
out "Methode mit Argument, self bleibt richtig" "$K
type I = interface { fn Add(k: int64): int64; };
type P = class implements I { v: int64; fn Add(k: int64): int64 { return self.v + k; } };
fn Ruf(x: I, k: int64): int64 { return x.Add(k); }
fn main(): int64 {
    var p: P := new P(); p.v := 10;
    var i: I := p;
    PrintLn(i.Add(5));
    PrintLn(Ruf(p, 3));
    return 0;
}" '15
13'

out "zwei Methoden im Interface" "$K
type I = interface { fn A(): int64; fn B(): int64; };
type P = class implements I { v: int64; fn A(): int64 { return 1; } fn B(): int64 { return 2; } };
fn main(): int64 { var i: I := new P(); PrintLn(i.A()); PrintLn(i.B()); return 0; }" '1
2'

# Zwei Interfaces an derselben Klasse: jeder Slot muss fuer sich stimmen.
out "zwei Interfaces an einer Klasse" "$K
type I = interface { fn A(): int64; };
type J = interface { fn B(): int64; };
type P = class implements I, J { v: int64; fn A(): int64 { return 1; } fn B(): int64 { return 2; } };
fn RufI(x: I): int64 { return x.A(); }
fn RufJ(x: J): int64 { return x.B(); }
fn main(): int64 { var p: P := new P(); PrintLn(RufI(p)); PrintLn(RufJ(p)); return 0; }" '1
2'

# --- Zusammenspiel mit Vererbung -----------------------------------------
out "geerbte Interface-Methode" "$K
type I = interface { fn Zeig(): int64; };
type A = class implements I { v: int64; fn Zeig(): int64 { return 1; } };
type B = class extends A { fn X(): int64 { return 0; } };
fn main(): int64 { var b: B := new B(); var i: I := b; PrintLn(i.Zeig()); PrintLn(b.Zeig()); return 0; }" '1
1'

out "Kind ueberschreibt die Interface-Methode" "$K
type I = interface { fn Zeig(): int64; };
type A = class implements I { v: int64; fn Zeig(): int64 { return 1; } };
type B = class extends A { fn Zeig(): int64 { return 2; } };
fn main(): int64 {
    var i: I := new B();
    PrintLn(i.Zeig());
    var i2: I := new A();
    PrintLn(i2.Zeig());
    return 0;
}" '2
1'

out "virtual und Interface nebeneinander" "$K
type I = interface { fn Zeig(): int64; };
type A = class implements I { v: int64; fn Zeig(): int64 { return 1; } virtual fn Extra(): int64 { return 5; } };
type B = class extends A { override fn Extra(): int64 { return 6; } };
fn main(): int64 {
    var b: B := new B();
    var a: A := b;
    PrintLn(a.Extra());
    var i: I := b;
    PrintLn(i.Zeig());
    return 0;
}" '6
1'

# Ein Array mit Interface-Elementtyp: jeder Eintrag dispatcht fuer sich.
out "Array von Interface-Werten" "$K
type I = interface { fn Zeig(): int64; };
type P = class implements I { v: int64; fn Zeig(): int64 { return 7; } };
type Q = class implements I { v: int64; fn Zeig(): int64 { return 9; } };
fn main(): int64 {
    var a: I[2];
    a[0] := new P();
    a[1] := new Q();
    PrintLn(a[0].Zeig());
    PrintLn(a[1].Zeig());
    return 0;
}" '7
9'

# --- Gegenproben ---------------------------------------------------------
# Polymorphie ueber eine Basisklasse lief schon vorher und muss es weiter.
out "Basisklassen-Polymorphie unveraendert" "$K
type A = class { virtual fn Zeig(): int64 { return 0; } };
type P = class extends A { override fn Zeig(): int64 { return 7; } };
fn Ruf(x: A): int64 { return x.Zeig(); }
fn main(): int64 { PrintLn(Ruf(new P())); return 0; }" '7'

# Eine Klasse ohne Interface bleibt unberuehrt, auch wenn im Programm
# Interfaces vorkommen (alle Klassen tragen jetzt dieselbe Slot-Basis).
out "Klasse ohne Interface unveraendert" "$K
type I = interface { fn Zeig(): int64; };
type P = class implements I { v: int64; fn Zeig(): int64 { return 7; } };
type C = class { n: int64; fn Get(): int64 { return 42; } };
fn main(): int64 { var c: C := new C(); PrintLn(c.Get()); return 0; }" '42'

out "Klassen und Felder ohne Interface im Programm" "$K
type C = class { n: int64; fn Get(): int64 { return self.n + 1; } };
fn main(): int64 { var c: C := new C(); c.n := 41; PrintLn(c.Get()); return 0; }" '42'

# --- Die vorhandenen Vertragspruefungen bleiben --------------------------
fails "unbekanntes Interface meldet" "$K
type P = class implements Nope { v: int64; };
fn main(): int64 { return 0; }" "unknown interface"

fails "fehlende Interface-Methode meldet" "$K
type I = interface { fn Zeig(): int64; };
type P = class implements I { v: int64; };
fn main(): int64 { return 0; }" "missing interface method"

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
test "$FAIL" -eq 0
