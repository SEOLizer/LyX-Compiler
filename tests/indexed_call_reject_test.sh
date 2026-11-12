#!/usr/bin/env bash
# tests/indexed_call_reject_test.sh — Aufruf über einen indizierten Ausdruck
# (Issue #1053, seit #1505 zum Teil erlaubt).
#
# `handlers[0](x)` sah aus wie ein Aufruf, war aber keiner: ein Aufruf hängt in
# Lyx am NAMEN. Der Parser hatte für `(` nach einem Postfix-Ausdruck gar keinen
# Zweig, weshalb es je nach Argumentzahl unterschiedlich schieflief:
#
#   ein Argument   → `(x)` wurde als geklammerter Ausdruck verschluckt, das
#                    Programm übersetzte und rechnete STILL FALSCH
#                    (`arr[0](21)` ergab 12 statt 42)
#   zwei Argumente → unverständliche Meldung über ein fehlendes ')'
#
# Der stille Fall ist der gefährlichere. #1053 hat die Form deshalb erst einmal
# abgewiesen — eine ehrliche Zwischenstufe, kein Ziel.
#
# SEIT #1505 IST SIE UMGESETZT: `tabelle[i](args)` ruft über den berechneten
# Zeiger. Dieser Test misst seither die WIRKUNG (welcher Handler läuft, was er
# zurückgibt), nicht mehr die Ablehnung. Die Einzelheiten stehen in
# tests/sprache_z16_test.sh.
#
# Dieselbe Lücke traf den generischen Aufruf in eckiger Schreibweise
# `max[int64](10, 20)` — ebnf.md führte ihn fälschlich, der Compiler kannte nur
# `max<int64>(10, 20)`. Die Grammatik ist mit #1053 richtiggestellt.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

rejects() { # name, quelltext
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  got=$("$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)
  if echo "$got" | grep -qE "Aufruf ueber einen indizierten Ausdruck|eckige Klammern indizieren"; then
    echo "PASS $1 (abgewiesen)"; PASS=$((PASS+1))
  else
    echo "FAIL $1: nicht abgewiesen — $(echo "$got" | grep -i error | head -1)"; FAIL=$((FAIL+1))
  fi
}

runs() { # name, quelltext, erwarteter exit
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    echo "FAIL $1: uebersetzt nicht"; FAIL=$((FAIL+1)); return
  fi
  timeout 5 "$TMP/c" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq "$3" ]; then echo "PASS $1"; PASS=$((PASS+1))
  else echo "FAIL $1: exit=$rc erwartet $3"; FAIL=$((FAIL+1)); fi
}

# Der stille Fall: EIN Argument. Vorher uebersetzte das und lieferte 12.
runs "fn-Zeiger aus Array, ein Argument (#1505)" 'type H = fn(int64): int64;
fn dbl(x: int64): int64 { return x * 2; }
fn main(): int64 { var arr: [4]H; arr[0] := dbl; return arr[0](21); }' 42

runs "fn-Zeiger aus Array, zwei Argumente (#1505)" 'type H = fn(int64, int64): int64;
fn add(a: int64, b: int64): int64 { return a + b; }
fn main(): int64 { var arr: [4]H; arr[0] := add; return arr[0](20, 22); }' 42

rejects "generischer Aufruf in eckiger Schreibweise" 'fn mx<T>(a: T, b: T): T { return a; }
fn main(): int64 { return mx[int64](10, 42); }'

# Gegenproben: was gueltig ist, muss unveraendert laufen.
runs "gewoehnliche Indizierung" 'fn main(): int64 { var a: [4]int64; a[0] := 42; return a[0]; }' 42

runs "fn-Zeiger ueber eine Variable" 'type H = fn(int64): int64;
fn dbl(x: int64): int64 { return x * 2; }
fn main(): int64 { var f: H := dbl; return f(21); }' 42

runs "Indizierung als Argument" 'fn dbl(x: int64): int64 { return x * 2; }
fn main(): int64 { var a: [4]int64; a[1] := 21; return dbl(a[1]); }' 42

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
