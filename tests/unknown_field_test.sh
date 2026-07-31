#!/usr/bin/env bash
# tests/unknown_field_test.sh — sema akzeptierte jeden Feldnamen auf jeder Basis.
#
# `p.lenght` statt `p.length` uebersetzte klaglos und lieferte zur Laufzeit 0;
# ein Tippfehler in einem Feldnamen war damit unsichtbar. Ebenso ging
# `x.irgendwas` auf einem int64 durch. Aufgefallen an std/qt5_egl.lyx, wo ein
# Beispiel `disp.display` auf einem `pub type EGLDisplay = int64` schrieb --
# einem Typ ganz ohne Felder.
#
# Die Pruefung ist bewusst konservativ: sie meldet nur, wenn sich der Typ der
# Basis eindeutig zu einer Struct-/Klassendeklaration mit Feldern aufloesen
# laesst. Dieser Test deckt beide Richtungen ab -- Tippfehler werden gemeldet,
# gueltiger Code (auch ueber Vererbung) laeuft unveraendert durch.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

rejects() { # name, quelltext, feldname
  printf "%s" "$2" > "$TMP/c.lyx"
  out=$(cd "$ROOT" && "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)
  if echo "$out" | grep -q "unknown field '$3'"; then
    ok "$1"
  else
    no "$1" "nicht gemeldet: $(echo "$out" | grep -iE 'error' | head -1)"
  fi
}

runs() { # name, quelltext, erwarteter exit
  printf "%s" "$2" > "$TMP/c.lyx"
  rm -f "$TMP/c"
  out=$(cd "$ROOT" && "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)
  if [ ! -f "$TMP/c" ]; then
    no "$1" "compile fehlgeschlagen: $(echo "$out" | grep -iE 'error' | head -1)"; return
  fi
  timeout 5 "$TMP/c" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq "$3" ]; then ok "$1 (=$rc)"; else no "$1" "exit=$rc erwartet $3"; fi
}

# --- wird gemeldet ---------------------------------------------------------
rejects "Tippfehler im Struct-Feld" 'type P = struct { x: int64; y: int64; };
fn main(): int64 { var p: P; p.zzz := 99; return p.zzz; }' "zzz"

rejects "unbekanntes Feld ueber Vererbung" 'type Base = class { a: int64; };
type Derived = class extends Base { b: int64; };
fn main(): int64 { var d: Derived; return d.nichtDa; }' "nichtDa"

# --- laeuft weiterhin durch ------------------------------------------------
runs "gueltige Struct-Felder" 'type P = struct { x: int64; y: int64; };
fn main(): int64 { var p: P; p.x := 40; p.y := 2; return p.x + p.y; }' 42

runs "geerbtes Feld" 'type Base = class { a: int64; };
type Derived = class extends Base { b: int64; };
fn main(): int64 { var d: Derived; d.a := 40; d.b := 2; return d.a + d.b; }' 42

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
