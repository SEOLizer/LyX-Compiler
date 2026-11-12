#!/usr/bin/env bash
# tests/frontend_calls_patterns_test.sh — #1249, #1250, #1252, #1253.
#
# Vier Lücken im Frontend, drei davon Fälle, in denen der Compiler etwas
# anderes tat als die eigene Doku versprach.
#
# #1249: Ein Lambda segfaultete, sobald es über einen ausgeschriebenen
# `fn`-Typ lief. Zwei Aufrufkonventionen standen nebeneinander — Closure
# ({fnPtr,env} auf dem Heap, Umgebung verdeckt in rdi) und dünner Zeiger
# (blanke Adresse, keine Verschiebung) —, und welche galt, entschied der
# DEKLARIERTE Typ statt der Wert. Ein Lambda ohne Einfangen ist jetzt eine
# gewöhnliche Funktion; mit Einfangen wird der Übergang gemeldet.
#
# #1250: `case (1, 2)` steht in ebnf.md §14 und wurde mit `expected =>, got (`
# abgewiesen — die Meldung nannte die Klammer statt der fehlenden Sache. Ein
# Tupel-Ausdruck hat dieselbe Ablage wie ein Array-Literal ({cap,len}-Kopf,
# dann die Elemente); das Muster prüft deshalb Länge und Elemente.
#
# #1252: Sobald ein Aufruf irgendein benanntes Argument trug, griffen
# Vorgabewerte nicht mehr. `G(1, c: 9)` — hinten setzen, Mitte auf Vorgabe —
# ist der beworbene Zweck benannter Argumente und scheiterte.
#
# #1253: `50 |> Clamp(0, 30)` reichte den Wert nicht weiter; benutzbar war `|>`
# nur ohne Argumente oder mit ausdrücklichem `?`.
#
# Geprüft wird jeweils die ganze Matrix aus dem Bericht, nicht nur der eine
# Repro: bei #1252 die Kombinationen aus positionell/benannt/Vorgabe, bei
# #1249 auch die Fälle, die vorher schon liefen (sie dürfen nicht kippen).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    no "$1" "uebersetzt nicht"; return
  fi
  got="$(timeout 30 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then no "$1" "ABSTURZ (rc=$rc)"; return; fi
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1" "'$got' erwartet '$3'"; fi
}

rejects() { # name, quelltext, erwartetes Textstueck der Meldung
  printf '%s\n' "$2" > "$TMP/r.lyx"; rm -f "$TMP/r"
  msg="$("$LYXC" --std-path="$ROOT" "$TMP/r.lyx" -o "$TMP/r" 2>&1)"
  if [ -f "$TMP/r" ]; then no "$1" "uebersetzt, statt zu melden"; return; fi
  case "$msg" in *"$3"*) ok "$1" ;; *) no "$1" "Meldung nennt '$3' nicht: $msg" ;; esac
}

# ===========================================================================
# #1249 — Lambda und ausgeschriebener fn-Typ
# ===========================================================================

KOPF='import std.io;
fn A(f: fn(int64): int64, x: int64): int64 { return f(x); }
fn Named(x: int64): int64 { return x * 3; }
fn Macher(): fn(int64): int64 { var n: int64 := 40; return fn(x: int64): int64 { return x + n; }; }'

# Der Repro aus dem Bericht: Lambda an einen fn-Typ-Parameter.
out "Lambda an fn-Typ-Parameter" "$KOPF
fn main(): int64 { PrintLn(IntToStr(A(fn(x: int64): int64 { return x * 3; }, 7))); return 0; }" "21"

out "Lambda in Variable mit ausgeschriebenem fn-Typ" "$KOPF
fn main(): int64 {
  var h: fn(int64): int64 := fn(x: int64): int64 { return x * 3; };
  PrintLn(IntToStr(h(7)));
  return 0;
}" "21"

# Die Konvention haengt am WERT und muss bei der Kopie mitwandern.
out "Kopie eines Lambdas in eine zweite Variable" "$KOPF
fn main(): int64 {
  var f := fn(x: int64): int64 { return x * 3; };
  var g := f;
  PrintLn(IntToStr(g(7)));
  return 0;
}" "21"

out "Lambda mit Typinferenz (lief vorher schon)" "$KOPF
fn main(): int64 {
  var f := fn(x: int64): int64 { return x * 3; };
  PrintLn(IntToStr(f(7)));
  return 0;
}" "21"

out "benannte Funktion ueber denselben fn-Typ (lief vorher schon)" "$KOPF
fn main(): int64 {
  var k: fn(int64): int64 := Named;
  PrintLn(IntToStr(k(7) + A(Named, 7)));
  return 0;
}" "42"

# Einfangende Lambdas bleiben Closures — dieser Weg darf nicht kippen.
out "einfangendes Lambda in inferierter Variable" "$KOPF
fn main(): int64 {
  var n: int64 := 100;
  var cap := fn(x: int64): int64 { return x + n; };
  PrintLn(IntToStr(cap(5)));
  return 0;
}" "105"

out "einfangendes Lambda als Rueckgabewert" "$KOPF
fn main(): int64 { var m := Macher(); PrintLn(IntToStr(m(2))); return 0; }" "42"

# In ein fn(...)-Ziel passt es nicht: acht Byte tragen keine Umgebung.
rejects "einfangendes Lambda an fn-Typ-Variable wird gemeldet" "$KOPF
fn main(): int64 {
  var n: int64 := 100;
  var h: fn(int64): int64 := fn(x: int64): int64 { return x + n; };
  return h(5);
}" "#1249"

rejects "einfangendes Lambda als Argument wird gemeldet" "$KOPF
fn main(): int64 {
  var n: int64 := 100;
  return A(fn(x: int64): int64 { return x + n; }, 5);
}" "#1249"

# ===========================================================================
# #1250 — Tupel-Muster und Tupel-Werte
# ===========================================================================

out "Tupel-Muster trifft den richtigen Zweig" 'import std.io;
fn main(): int64 {
  var t: (int64, int64) := (1, 2);
  var a: pchar := match (t) { case (9, 9) => "x"; case (1, 2) => "a"; case _ => "b"; };
  PrintLn(a);
  return 0;
}' "a"

# Ohne die Laengenpruefung passte ein zweiteiliges Muster auf ein dreiteiliges
# Tupel — der Fall faellt bei blossem Elementvergleich nicht auf.
out "Laenge wird mitgeprueft" 'import std.io;
fn main(): int64 {
  var w := (1, 2, 3);
  var g: pchar := match (w) { case (1, 2) => "zu-kurz"; case _ => "laenge-geprueft"; };
  PrintLn(g);
  return 0;
}' "laenge-geprueft"

out "Platzhalter, negatives Literal und con im Tupel-Muster" 'import std.io;
con NEUN: int64 := 9;
fn main(): int64 {
  var u := (3, 4);
  var c: pchar := match (u) { case (1, 2) => "a"; case (3, _) => "c"; case _ => "b"; };
  PrintLn(c);
  var e: pchar := match (u) { case (-1, 4) => "neg"; case (3, 4) => "e"; case _ => "b"; };
  PrintLn(e);
  var v := (9, 1);
  var f: pchar := match (v) { case (NEUN, 1) => "con"; case _ => "b"; };
  PrintLn(f);
  return 0;
}' "c
e
con"

out "kein passendes Tupel-Muster faellt an den Wildcard" 'import std.io;
fn main(): int64 {
  var u := (3, 4);
  var d: pchar := match (u) { case (3, 5) => "d"; case (2, 4) => "z"; case _ => "kein-treffer"; };
  PrintLn(d);
  return 0;
}' "kein-treffer"

rejects "einteiliges Tupel-Muster wird gemeldet" 'import std.io;
fn main(): int64 {
  var u := (3, 4);
  var d: pchar := match (u) { case (3) => "d"; case _ => "b"; };
  return 0;
}' "mindestens zwei Teilmuster"

# Gegenprobe: die EINE umgesetzte Rolle des Tupels bleibt gueltig.
out "zwei Rueckgabewerte bleiben entnehmbar" 'import std.io;
fn P(): (int64, int64) { return (7, 9); }
fn main(): int64 { var c, d := P(); PrintLn(IntToStr(c * 10 + d)); return 0; }' "79"

# ===========================================================================
# #1252 — benannte Argumente und Vorgabewerte
# ===========================================================================

FKOPF='import std.io;
fn F(a: int64, b: int64 = 5): int64 { return a - b; }
fn G(a: int64, b: int64 = 2, c: int64 = 3): int64 { return a * 100 + b * 10 + c; }'

out "benanntes Argument, hinterer Parameter per Vorgabe" "$FKOPF
fn main(): int64 { PrintLn(IntToStr(F(a: 10))); return 0; }" "5"

out "mittlerer Parameter bleibt auf seinem Vorgabewert" "$FKOPF
fn main(): int64 { PrintLn(IntToStr(G(1, c: 9))); PrintLn(IntToStr(G(a: 1, c: 9))); return 0; }" "129
129"

# Gegenproben: alles, was vorher lief, liefert dasselbe.
out "positionell, gemischt und vollstaendig benannt unveraendert" "$FKOPF
fn main(): int64 {
  PrintLn(IntToStr(F(10)));
  PrintLn(IntToStr(F(10, b: 3)));
  PrintLn(IntToStr(F(a: 10, b: 3)));
  PrintLn(IntToStr(F(b: 3, a: 10)));
  PrintLn(IntToStr(G(1)));
  PrintLn(IntToStr(G(1, 5, 9)));
  PrintLn(IntToStr(G(1, b: 5)));
  return 0;
}" "5
7
7
7
123
159
153"

# Beim Testen von #1252 aufgefallen: der Pfad fuer SIEBEN und mehr Argumente
# setzte Vorgabewerte ueberhaupt nicht ein — die Werte lagen verschoben.
out "Vorgabewerte auch jenseits von sechs Argumenten" 'import std.io;
fn H(a: int64, b: int64, c: int64, d: int64, e: int64, f: int64, g: int64 = 7, h: int64 = 8): int64 {
  return a*10000000 + b*1000000 + c*100000 + d*10000 + e*1000 + f*100 + g*10 + h;
}
fn main(): int64 {
  PrintLn(IntToStr(H(1,2,3,4,5,6)));
  PrintLn(IntToStr(H(1,2,3,4,5,6, h: 9)));
  return 0;
}' "12345678
12345679"

# Ein Parameter OHNE Vorgabewert bleibt Pflicht — sonst waere die Pruefung weg.
# Genannt wird hier der Parameter MIT Vorgabewert; die Stelligkeit passt damit
# (ein Argument, Mindestzahl eins), und offen bleibt `a`, das keinen hat. Nur so
# erreicht der Fall ueberhaupt die Namenspruefung.
rejects "fehlender Parameter ohne Vorgabewert wird weiterhin gemeldet" 'import std.io;
fn F3(a: int64, b: int64 = 5): int64 { return a + b; }
fn main(): int64 { return F3(b: 3); }' "Parameter ohne Argument"

# Und die Stelligkeit bleibt davor: zu wenige Argumente fuer Parameter ohne
# Vorgabewert werden weiterhin abgewiesen.
rejects "zu wenige Argumente bleiben ein Fehler" 'import std.io;
fn F2(a: int64, b: int64): int64 { return a + b; }
fn main(): int64 { return F2(a: 1); }' "falsche Argument-Anzahl"

# ===========================================================================
# #1253 — Pipe mit weiteren Argumenten
# ===========================================================================

PKOPF='import std.io;
fn Clamp(v: int64, lo: int64, hi: int64): int64 { if (v < lo) { return lo; } if (v > hi) { return hi; } return v; }
fn Add(a: int64, b: int64): int64 { return a + b; }
fn Sub(a: int64, b: int64): int64 { return a - b; }
fn Double(x: int64): int64 { return x * 2; }'

out "gepipter Wert wird vorangestellt" "$PKOPF
fn main(): int64 { PrintLn(IntToStr(50 |> Clamp(0, 30))); PrintLn(IntToStr(10 |> Add(5))); return 0; }" "30
15"

# Gegenproben: Platzhalter und argumentlose Form unveraendert — sonst waere ein
# IMMER vorangestellter Wert ebenfalls gruen.
out "Platzhalter bestimmt weiterhin die Stelle" "$PKOPF
fn main(): int64 {
  PrintLn(IntToStr(100 |> Sub(?, 40)));
  PrintLn(IntToStr(40 |> Sub(100, ?)));
  PrintLn(IntToStr(10 |> Add(?, 5)));
  return 0;
}" "60
60
15"

out "Kette ohne Argumente unveraendert" "$PKOPF
fn main(): int64 { PrintLn(IntToStr(3 |> Double() |> Double())); return 0; }" "12"

out "Kette mit Argumenten am spaeteren Glied" "$PKOPF
fn main(): int64 { PrintLn(IntToStr(3 |> Double() |> Add(1))); return 0; }" "7"

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
