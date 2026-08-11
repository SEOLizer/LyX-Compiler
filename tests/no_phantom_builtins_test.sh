#!/usr/bin/env bash
# tests/no_phantom_builtins_test.sh — sema darf nichts als Builtin ausgeben,
# das kein Backend implementiert.
#
# PrintStrLn, PrintIntLn, StrCmp, StrNCmp, StrToInt und StrToFloat waren in sema
# als Builtins registriert, ohne dass irgendein Backend sie emittieren konnte.
# Folge: ein Aufruf OHNE passenden Import bestand sema und starb erst im Codegen
# mit "no codegen implementation found" — an der Aufrufstelle, ohne jeden Hinweis
# auf den fehlenden Import. Das verdeckte reale Fehler: std/db/sqlite.lyx rief
# StrCmp ohne `import std.string` auf und galt trotzdem als übersetzbar.
#
# Geprüft wird beides: ohne Import meldet sema sauber "undefined function"
# (nicht der Codegen), und mit Import funktionieren die Funktionen.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# ohne Import: sema-Fehler, NICHT der Codegen-Fehler
sema_rejects() { # name, quelltext, symbol
  printf "%s" "$2" > "$TMP/c.lyx"
  rm -f "$TMP/c"
  out=$(cd "$ROOT" && "$LYXC" "$TMP/c.lyx" -o "$TMP/c" 2>&1)
  if echo "$out" | grep -q "sema error.*undefined function '$3'"; then
    ok "$1 (sema meldet)"
  elif echo "$out" | grep -q "no codegen implementation"; then
    no "$1" "Codegen-Fehler statt sema — Phantom-Builtin wieder registriert?"
  else
    no "$1" "unerwartet: $(echo "$out" | grep -vi warning | head -1)"
  fi
}

sema_rejects "PrintStrLn ohne Import" 'fn main(): int64 { PrintStrLn("x"); return 0; }' "PrintStrLn"
sema_rejects "PrintIntLn ohne Import" 'fn main(): int64 { PrintIntLn(1); return 0; }' "PrintIntLn"
sema_rejects "StrCmp ohne Import"     'fn main(): int64 { return StrCmp("a","a"); }' "StrCmp"
sema_rejects "StrToInt ohne Import"   'fn main(): int64 { return StrToInt("42"); }' "StrToInt"
sema_rejects "StrNCmp (existiert nicht)"   'fn main(): int64 { return StrNCmp("a","a",1); }' "StrNCmp"
sema_rejects "StrToFloat (existiert nicht)" 'fn main(): int64 { return StrToFloat("1.5"); }' "StrToFloat"

# mit Import: funktionieren
runs() { # name, quelltext, erwarteter exit
  printf "%s" "$2" > "$TMP/c.lyx"
  rm -f "$TMP/c"
  if ! (cd "$ROOT" && "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1); then
    no "$1" "compile fehlgeschlagen"; return
  fi
  timeout 5 "$TMP/c" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq "$3" ]; then ok "$1 (=$rc)"; else no "$1" "exit=$rc erwartet $3"; fi
}

runs "PrintIntLn mit std.io" 'import std.io;
fn main(): int64 { PrintIntLn(7); return 0; }' 0

runs "StrCmp mit std.string" 'import std.string;
fn main(): int64 { if (StrCmp("a","a") == 0 && StrCmp("a","b") < 0) { return 42; } return 1; }' 42

runs "StrToInt mit std.string" 'import std.string;
fn main(): int64 { return StrToInt("42abc"); }' 42

runs "StrToInt negativ" 'import std.string;
fn main(): int64 { return StrToInt("  -8") + 50; }' 42

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
