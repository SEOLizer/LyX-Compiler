#!/usr/bin/env bash
# tests/generics_typeparam_test.sh — Typparameter werden aufgelöst (Issue #1009).
#
# `fn max<T>(a: T, b: T): T` wurde von sema mit "unknown param type" abgewiesen:
# der Parser legt die Typparameter in c3 des Deklarationsknotens ab,
# _checkFuncDecl las diesen Slot aber nie. Die Monomorphisierung dahinter war
# vorhanden und funktionsfähig — es fehlte nur der Weg vom Parameter zum Typ.
#
# Geprüft wird beides: dass Vorlagen jetzt übersetzen UND dass echte Tippfehler
# weiterhin gemeldet werden. Eine Ausnahme, die zu breit greift, macht aus einem
# Fehler ein stilles Falschverhalten — deshalb die Gegenproben.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

runs() { # name, quelltext, erwarteter exit
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    echo "FAIL $1: uebersetzt nicht"; FAIL=$((FAIL+1)); return
  fi
  timeout 5 "$TMP/c" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq "$3" ]; then echo "PASS $1"; PASS=$((PASS+1))
  else echo "FAIL $1: exit=$rc erwartet $3"; FAIL=$((FAIL+1)); fi
}

# #1117: Ausgabe pruefen, nicht nur den Exit-Code — eine Weitergabe, die den
# falschen Typ instanziiert, wuerde sonst durchgehen.
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

rejects() { # name, quelltext, erwartete meldung
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  got=$("$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)
  if echo "$got" | grep -q "$3"; then echo "PASS $1 (abgewiesen)"; PASS=$((PASS+1))
  else echo "FAIL $1: nicht abgewiesen"; FAIL=$((FAIL+1)); fi
}

# --- Vorlagen übersetzen und rechnen richtig ----------------------------
runs "Repro aus dem Issue" 'fn max<T>(a: T, b: T): T { if (a > b) { return a; } return b; }
fn main(): int64 { return max<int64>(40, 2); }' 40

runs "ein Typparameter, ein Argument" 'fn id<T>(x: T): T { return x; }
fn main(): int64 { return id<int64>(42); }' 42

runs "mehrere Instanziierungen" 'fn id<T>(x: T): T { return x; }
fn main(): int64 { var a: int64 := id<int64>(40); var b: int64 := id<int64>(2); return a + b; }' 42

runs "Typparameter nur als Rueckgabetyp" 'fn zero<T>(x: int64): T { return x as T; }
fn main(): int64 { return zero<int64>(42); }' 42

# --- Gegenproben: echte Fehler bleiben Fehler ---------------------------
rejects "unbekannter Parametertyp" 'fn f(a: Unbekannt): int64 { return 1; }
fn main(): int64 { return 0; }' "unknown param type"

rejects "unbekannter Rueckgabetyp" 'fn f(a: int64): Unbekannt { return 1; }
fn main(): int64 { return 0; }' "unknown return type"

# Der Typparameter gilt NUR in seiner Vorlage — sonst waere die Ausnahme ein
# Freibrief fuer jeden Tippfehler, der zufaellig wie ein Typparameter heisst.
rejects "T ausserhalb seiner Vorlage" 'fn g<T>(x: T): T { return x; }
fn h(y: T): int64 { return 1; }
fn main(): int64 { return 0; }' "unknown param type"

# --- #1117: Typparameter als TYPARGUMENT weiterreichen -------------------
# `T` war als Parameter- und Rueckgabetyp gueltig, im Typargument eines
# Aufrufs aber nicht ("unknown type in generic arguments 'T'"). Der Aufruf ohne
# Typargument war der Workaround; die explizite Weitergabe ist die natuerliche
# Schreibweise, gerade wenn die Inferenz nicht eindeutig ist.
#
# Geprueft wird der WERT, nicht nur die Uebersetzbarkeit: eine Weitergabe, die
# den falschen Typ instanziiert, wuerde sonst durchgehen.
out "Typparameter weiterreichen" 'import src.std.io;
fn Id<T>(x: T): T { return x; }
fn Twice<T>(x: T): T { return Id<T>(Id<T>(x)); }
fn main(): int64 { PrintLn(Twice<int64>(5)); return 0; }' '5'

out "zwei Instanziierungen derselben Vorlage" 'import src.std.io;
fn Id<T>(x: T): T { return x; }
fn Twice<T>(x: T): T { return Id<T>(Id<T>(x)); }
fn main(): int64 {
    PrintLn(Twice<int64>(5));
    PrintLn(Twice<int64>(42));
    return 0;
}' '5
42'

out "Struct-Typ durchgereicht" 'import src.std.io;
type P = struct { v: int64; };
fn Id<T>(x: T): T { return x; }
fn Twice<T>(x: T): T { return Id<T>(Id<T>(x)); }
fn main(): int64 {
    var p: P; p.v := 7;
    var q: P := Twice<P>(p);
    PrintLn(q.v);
    return 0;
}' '7'

out "zwei Typparameter" 'import src.std.io;
fn Id<T>(x: T): T { return x; }
fn Pair<A, B>(a: A, b: B): A { return Id<A>(a); }
fn main(): int64 { PrintLn(Pair<int64, int64>(3, 9)); return 0; }' '3'

# Gegenproben: die Ausnahme gilt NUR fuer echte Typparameter der umgebenden
# Funktion — sonst waere sie ein Freibrief fuer jeden Tippfehler im Typargument.
rejects "erfundener Typ im Typargument (in generischer Fn)" 'fn Id<T>(x: T): T { return x; }
fn Bad<T>(x: T): T { return Id<ZZZ>(x); }
fn main(): int64 { return 0; }' "unknown type in generic arguments"

rejects "erfundener Typ im Typargument (ausserhalb)" 'fn Id<T>(x: T): T { return x; }
fn main(): int64 { var r: int64 := Id<ZZZ>(1); return 0; }' "unknown type in generic arguments"

rejects "T im Typargument ausserhalb seiner Vorlage" 'fn Id<T>(x: T): T { return x; }
fn main(): int64 { var r: int64 := Id<T>(1); return 0; }' "unknown type in generic arguments"

# --- extern fn: c3 traegt dort den link-String, keinen Typparameter -----
# Ohne Sonderbehandlung las die Typparameter-Schleife den gepackten int64-Wert
# ((len << 32) | offset) als Knotenindex, griff weit ausserhalb der Knotenarena
# und brachte den COMPILER zum Absturz — beim ersten Anlauf fielen dadurch 24
# Tests der Vollsuite aus.
printf 'extern fn getpid(): int64 link "libc.so.6";\nfn main(): int64 { return 42; }\n' > "$TMP/e.lyx"
"$LYXC" --std-path="$ROOT" "$TMP/e.lyx" -o "$TMP/e" >/dev/null 2>&1
rc=$?
if [ "$rc" -ge 128 ]; then
  echo "FAIL extern fn bringt den Compiler zum Absturz (rc=$rc)"; FAIL=$((FAIL+1))
else
  # Die FFI-Sandbox weist den Aufruf ohne @capabilities zu Recht ab; geprueft
  # wird hier nur, dass der Compiler dabei nicht abstuerzt.
  echo "PASS extern fn stuerzt den Compiler nicht ab"; PASS=$((PASS+1))
fi

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
