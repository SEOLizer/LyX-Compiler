#!/usr/bin/env bash
# tests/decl_checks_test.sh — #1135, zweite Stufe: Deklarationsprüfungen.
#
# Drei Luecken aus der Tabelle des Issues, alle mit demselben Muster: der
# Compiler nahm etwas an und tat stillschweigend das Naheliegende.
#
#   Funktion mit Rueckgabetyp ohne return  -> lieferte 0 (der Codegen setzt am
#                                             Funktionsende `xor rax,rax`)
#   Variable zweimal im selben Block       -> die zweite gewann
#   Zwei Funktionen gleichen Namens        -> die erste gewann, die zweite war
#                                             toter Text
#
# Die return-Pruefung ist BEWUSST keine Flussanalyse: gemeldet wird nur, wenn
# im Rumpf ueberhaupt kein Ausgang vorkommt (`return`, `throw`, `panic`).
# `if (a > 0) { return 1; }` ohne weiteren Ausgang bliebe damit unbemerkt --
# das zu beurteilen braucht eine Pfadbetrachtung, und ein Fehlalarm waere
# schlimmer als die Luecke.
#
# NICHT umgesetzt, mit Begruendung: Arithmetik auf `pchar`. Sie ist im Bestand
# legitim -- `pchar` IST ein Zeiger, und `peek8(src + i)` mit `src: pchar` ist
# die uebliche zeichenweise Iteration (std/db/sqlite.lyx u.a.). Eine Meldung
# waere ein Fehlalarm; der Test haelt das ausdruecklich fest.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

fails() { # name, quelltext, erwarteter meldungsteil
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  msg="$("$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)"
  if [ -f "$TMP/c" ]; then echo "FAIL $1: uebersetzt, statt zu melden"; FAIL=$((FAIL+1)); return; fi
  case "$msg" in
    *"$3"*) echo "PASS $1"; PASS=$((PASS+1)) ;;
    *) echo "FAIL $1: Meldung ohne '$3'"; FAIL=$((FAIL+1)) ;;
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

K='import src.std.io;'

# --- Funktion mit Rueckgabetyp ohne return -------------------------------
fails "Repro: Funktion ohne return" "$K
fn F(): int64 { var y: int64 := 1; }
fn main(): int64 { PrintLn(F()); return 0; }" "Funktion ohne return"

fails "Rueckgabetyp pchar ohne return" "$K
fn F(): pchar { var y: int64 := 1; }
fn main(): int64 { PrintStrLn(F()); return 0; }" "Funktion ohne return"

# Methoden laufen einen eigenen Weg: die volle Rumpfpruefung greift nur bei
# capability-annotierten Klassen, diese Frage muss aber ueberall gestellt
# werden (wie bei #1090 fuer `static`).
fails "Methode ohne return" "$K
type C = class { v: int64; fn G(): int64 { var y: int64 := 1; } };
fn main(): int64 { var c: C := new C(); PrintLn(c.G()); return 0; }" "Methode ohne return"

out "void ohne return bleibt zulaessig" "$K
fn F(): void { PrintStrLn(\"x\"); }
fn main(): int64 { F(); return 0; }" 'x'

out "return im Zweig genuegt" "$K
fn F(a: int64): int64 { if (a > 0) { return 1; } return 0; }
fn main(): int64 { PrintLn(F(5)); PrintLn(F(0)); return 0; }" '1
0'

# `throw` verlaesst die Funktion ebenso — kein Fehlalarm.
out "throw statt return" "$K
fn F(): int64 { throw 1; }
fn main(): int64 { PrintStrLn(\"start\"); return 0; }" 'start'

# `exit(...)` verlaesst das Programm — ebenfalls ein Ausgang.
out "exit statt return" "$K
fn main(): int64 { PrintStrLn(\"fertig\"); exit(0); }" 'fertig'

# --- Variable zweimal im selben Block ------------------------------------
fails "Repro: Doppeldeklaration" "$K
fn main(): int64 { var x: int64 := 1; var x: int64 := 2; PrintLn(x); return 0; }" "im selben Block bereits deklariert"

fails "Doppeldeklaration mit anderem Typ" "$K
fn main(): int64 { var x: int64 := 1; var x: pchar := \"a\"; PrintStrLn(x); return 0; }" "im selben Block bereits deklariert"

# Verdecken in einem INNEREN Block bleibt erlaubt — das ist eine andere Frage.
out "innerer Block darf verdecken" "$K
fn main(): int64 {
    var x: int64 := 1;
    if (1 == 1) { var x: int64 := 2; PrintLn(x); }
    PrintLn(x);
    return 0;
}" '2
1'

out "getrennte Bloecke, gleicher Name" "$K
fn main(): int64 {
    if (1 == 1) { var x: int64 := 1; PrintLn(x); }
    var x: int64 := 2;
    PrintLn(x);
    return 0;
}" '1
2'

out "gleicher Name in zwei Funktionen" "$K
fn A(): int64 { var x: int64 := 1; return x; }
fn B(): int64 { var x: int64 := 2; return x; }
fn main(): int64 { PrintLn(A()); PrintLn(B()); return 0; }" '1
2'

# --- Zwei Funktionen gleichen Namens -------------------------------------
fails "Repro: zwei gleiche Funktionen" "$K
fn F(): int64 { return 1; }
fn F(): int64 { return 2; }
fn main(): int64 { PrintLn(F()); return 0; }" "Funktion bereits deklariert"

fails "gleicher Name, andere Signatur" "$K
fn F(): int64 { return 1; }
fn F(a: int64): int64 { return a; }
fn main(): int64 { PrintLn(F(3)); return 0; }" "Funktion bereits deklariert"

out "verschiedene Namen unveraendert" "$K
fn F(): int64 { return 1; }
fn G(): int64 { return 2; }
fn main(): int64 { PrintLn(F()); PrintLn(G()); return 0; }" '1
2'

# Gleichnamige METHODEN in verschiedenen Klassen sind kein Fehler.
out "gleichnamige Methoden in zwei Klassen" "$K
type A = class { v: int64; fn Get(): int64 { return 1; } };
type B = class { v: int64; fn Get(): int64 { return 2; } };
fn main(): int64 { var a: A := new A(); var b: B := new B(); PrintLn(a.Get()); PrintLn(b.Get()); return 0; }" '1
2'

# --- Arithmetik auf pchar bleibt zulaessig (bewusst) ---------------------
# `pchar` IST ein Zeiger; `peek8(src + i)` ist die uebliche zeichenweise
# Iteration und steht so in der stdlib. Eine Meldung waere ein Fehlalarm.
out "Zeigerarithmetik auf pchar" "$K
fn Laenge(src: pchar): int64 {
    var i: int64 := 0;
    while (peek8(src + i) != 0) { i := i + 1; }
    return i;
}
fn main(): int64 { PrintLn(Laenge(\"abcd\")); return 0; }" '4'

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
test "$FAIL" -eq 0
