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
