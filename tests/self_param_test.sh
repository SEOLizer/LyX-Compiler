#!/usr/bin/env bash
# tests/self_param_test.sh — #1144: 'self'/'super' als Parametername.
#
# `self` ist der IMPLIZITE Empfaenger einer Methode. Als Parametername liess
# der Parser es durch (als Variablenname wies er es seit BUG-8 zurueck); der
# Parameter verdeckte die Bindung, jeder Feldzugriff griff ins Leere und das
# Programm starb mit SIGSEGV -- ohne jede Meldung.
#
# Geprueft wird der WEG, nicht nur das Ergebnis: dass die Uebersetzung
# ABBRICHT und die Meldung den Grund nennt. Ein reiner Ergebnistest waere
# schon vor dem Fix "rot" gewesen (Segfault), haette aber nicht belegt, dass
# die Ursache erkannt wird statt nur zufaellig anders zu krachen.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

fails() { # name, quelltext, erwarteter meldungsteil
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  msg="$("$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)"
  if [ -f "$TMP/c" ]; then echo "FAIL $1: uebersetzt, statt zu melden"; FAIL=$((FAIL+1)); return; fi
  case "$msg" in
    *"$3"*) echo "PASS $1"; PASS=$((PASS+1)) ;;
    *) echo "FAIL $1: Meldung ohne '$3': $msg"; FAIL=$((FAIL+1)) ;;
  esac
}

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

# --- Der Repro aus dem Issue --------------------------------------------
fails "Repro: fn Get(self: P)" 'import src.std.io;

type P = class {
    a: int64;
    fn Get(self: P): int64 { return self.a; }
};

fn main(): int64 {
    var p: P := new P();
    p.a := 7;
    PrintLn(IntToStr(p.Get()));
    return 0;
}' "reserved keyword"

fails "Repro nennt den Parameternamen" 'import src.std.io;
type P = class { a: int64; fn Get(self: P): int64 { return self.a; } };
fn main(): int64 { return 0; }' "parameter name"

# --- Schreibender Fall aus dem Issue ------------------------------------
fails "fn Setze(self: P, v: int64)" 'import src.std.io;
type P = class { a: int64; fn Setze(self: P, v: int64) { self.a := v; } };
fn main(): int64 { return 0; }' "reserved keyword"

# --- Nicht nur an erster Stelle -----------------------------------------
fails "self als zweiter Parameter" 'import src.std.io;
type P = class { a: int64; fn F(v: int64, self: P): int64 { return v; } };
fn main(): int64 { return 0; }' "reserved keyword"

fails "con self: P" 'import src.std.io;
type P = class { a: int64; fn F(con self: P): int64 { return 1; } };
fn main(): int64 { return 0; }' "reserved keyword"

# --- Auch ausserhalb von Klassen: freie Funktion ------------------------
# Der Name ist reserviert, nicht kontextabhaengig -- eine freie Funktion mit
# Parameter `self` schreibt jemand, der die Signatur aus Python uebernimmt.
fails "freie Funktion mit self-Parameter" 'import src.std.io;
fn F(self: int64): int64 { return self; }
fn main(): int64 { return 0; }' "reserved keyword"

# --- super ist ein eigenes Token ----------------------------------------
# Das Issue vermutete denselben Defekt fuer `super`. Er besteht nicht: `super`
# ist ein eigener Token-Typ, den Expect(TK_IDENT) schon in der Parameterliste
# abweist. Der Test haelt das fest, damit ein spaeterer Umbau von `super` zum
# weichen Schluesselwort die Luecke nicht unbemerkt aufreisst.
fails "super als Parametername" 'import src.std.io;
type P = class { a: int64; fn F(super: int64): int64 { return 1; } };
fn main(): int64 { return 0; }' "expected IDENT"

fails "super in freier Funktion" 'import src.std.io;
fn F(super: int64): int64 { return 1; }
fn main(): int64 { return 0; }' "expected IDENT"

# --- var-Fall bleibt wie er war (BUG-8) ----------------------------------
fails "self als Variablenname (BUG-8)" 'import src.std.io;
fn main(): int64 { var self: int64 := 1; return self; }' "variable name"

# --- Der Bestand bleibt uebersetzbar -------------------------------------
# Die Methode OHNE den Parameter ist die richtige Schreibweise und muss
# weiterhin laufen -- der Repro des Issues, korrekt geschrieben.
out "Methode ohne self-Parameter laeuft" 'import src.std.io;

type P = class {
    a: int64;
    fn Get(): int64 { return self.a; }
};

fn main(): int64 {
    var p: P := new P();
    p.a := 7;
    PrintLn(IntToStr(p.Get()));
    return 0;
}' '7'

# Namen, die self/super nur als Praefix tragen, bleiben zugelassen -- der
# Vergleich ist auf ganze Bezeichner zu fuehren, nicht auf Anfaenge.
out "selfish/superb bleiben gueltige Parameternamen" 'import src.std.io;
fn F(selfish: int64, superb: int64): int64 { return selfish + superb; }
fn main(): int64 { PrintLn(IntToStr(F(3, 4))); return 0; }' '7'

out "Feld namens self bleibt unberuehrt" 'import src.std.io;
fn F(a: int64): int64 { return a; }
fn main(): int64 { PrintLn(IntToStr(F(5))); return 0; }' '5'

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
test "$FAIL" -eq 0
