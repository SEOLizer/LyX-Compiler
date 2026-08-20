#!/usr/bin/env bash
# tests/dangling_import_test.sh — Import auf ein nicht existierendes Modul.
#
# Vorher kehrte _sema_processImport kommentarlos zurück, wenn weder .lyx noch
# .lyu gefunden wurde. Der Import verschwand einfach, und der Fehler tauchte
# erst an der ERSTEN NUTZUNG als "undefined function" auf — was nach einem
# Tippfehler im Funktionsnamen aussieht, während die Ursache im Import-Pfad
# liegt. In std/cpu/dispatch.lyx zeigte die Meldung auf CpuFeatureDetect,
# während `import src.std.cpu.features` ins Leere lief (src/std/cpu/ gibt es
# nicht).
#
# Geprüft wird beides: dass der fehlende Import gemeldet wird UND dass die
# Meldung die gesuchten Pfade nennt — die Verwechslung `std.` ↔ `src.` ist
# genau der Fall, in dem man das braucht.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

run_expect_error() { # name, source, grep-muster
  printf "%s" "$2" > "$TMP/c.lyx"
  rm -f "$TMP/c"
  out=$(cd "$ROOT" && "$LYXC" --std-path=std "$TMP/c.lyx" -o "$TMP/c" 2>&1)
  if [ ! -f "$TMP/c" ] && echo "$out" | grep -q "$3"; then ok "$1"
  else no "$1" "erwartete '$3', bekam: $(echo "$out" | grep -vi warning | head -2 | tr '\n' ' ')"; fi
}

# --- fehlendes Modul muss gemeldet werden ---
run_expect_error "fehlendes std-Modul" \
  'import std.gibtesnicht;
fn main(): int64 { return 0; }' \
  "Modul nicht gefunden"

run_expect_error "fehlendes src-Modul" \
  'import src.std.gibtesnicht;
fn main(): int64 { return 0; }' \
  "Modul nicht gefunden"

run_expect_error "tief verschachtelter Pfad" \
  'import std.cloud.gibtes.nicht;
fn main(): int64 { return 0; }' \
  "Modul nicht gefunden"

# --- die Meldung muss den gesuchten Pfad nennen ---
run_expect_error "nennt den gesuchten Dateipfad" \
  'import std.gibtesnicht;
fn main(): int64 { return 0; }' \
  "std/gibtesnicht.lyx"

# --- der Fehler darf NICHT erst an der Nutzung auftauchen ---
printf '%s' 'import std.gibtesnicht;
fn main(): int64 { return IrgendeineFunktion(); }' > "$TMP/c.lyx"
out=$(cd "$ROOT" && "$LYXC" --std-path=std "$TMP/c.lyx" -o "$TMP/c" 2>&1)
if echo "$out" | grep -q "Modul nicht gefunden"; then
  ok "meldet den Import, nicht nur die Nutzung"
else
  no "meldet den Import, nicht nur die Nutzung" "nur Folgefehler gemeldet"
fi

# --- kein Fehlalarm: existierende Module ---
printf '%s' 'import std.text;
import std.strtype;
fn main(): int64 { return 0; }' > "$TMP/c.lyx"
rm -f "$TMP/c"
if (cd "$ROOT" && "$LYXC" --std-path=std "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1) && [ -f "$TMP/c" ]; then
  ok "existierende Module unverändert"
else
  no "existierende Module unverändert" "Fehlalarm bei gültigem Import"
fi

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
