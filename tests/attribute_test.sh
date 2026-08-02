#!/usr/bin/env bash
# tests/attribute_test.sh — #1099: Attribute prüfen und benennen.
#
# Ein erfundenes Attribut wurde stillschweigend angenommen: der Name fiel auf
# Flag 0, die Argumente wurden über Klammerzählung verworfen. Ein vertipptes
# `@stack_limt(512)` übersetzte damit fehlerfrei — die Zusicherung, die man
# gesetzt zu haben glaubte, gab es nicht.
#
# Zwei Dinge werden gemessen:
#
# 1. Name und Argumentform werden geprüft. Der Test deckt beide Richtungen ab:
#    das erfundene Attribut muss abgewiesen werden UND jedes echte weiter
#    übersetzen. Ohne die zweite Hälfte wäre eine Prüfung, die ALLES abweist,
#    ebenso grün — und die stdlib benutzt @description/@author/@copyright
#    340-fach.
#
# 2. Attribute, deren Zusicherung der Compiler NICHT nachweist (@wcet,
#    @stack_limit, @integrity, @flight_crit, @dal, @critical), melden das.
#    Sie bleiben gültig — abweisen hieße, sie aus der Sprache zu nehmen —,
#    aber sie sind nicht mehr stumm. Ein Safety-Attribut, das schweigend nichts
#    tut, täuscht einen Nachweis vor, den es nicht gibt.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

rejects() { # name, quelltext, erwartete meldung
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  got=$("$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)
  if [ -f "$TMP/c" ]; then
    echo "FAIL $1: uebersetzt trotzdem"; FAIL=$((FAIL+1)); return
  fi
  if echo "$got" | grep -q "$3"; then echo "PASS $1 (abgewiesen)"; PASS=$((PASS+1))
  else echo "FAIL $1: falsche Meldung — '$(echo "$got" | grep -i 'error' | head -1)'"; FAIL=$((FAIL+1)); fi
}

accepts() { # name, quelltext
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  got=$("$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)
  if [ ! -f "$TMP/c" ]; then
    echo "FAIL $1: uebersetzt nicht — '$(echo "$got" | grep -iE 'error' | head -1)'"; FAIL=$((FAIL+1)); return
  fi
  echo "PASS $1"; PASS=$((PASS+1))
}

warns() { # name, quelltext, erwarteter meldungsteil
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  got=$("$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)
  if [ ! -f "$TMP/c" ]; then
    echo "FAIL $1: uebersetzt nicht"; FAIL=$((FAIL+1)); return
  fi
  if echo "$got" | grep -q "$3"; then echo "PASS $1 (gemeldet)"; PASS=$((PASS+1))
  else echo "FAIL $1: keine Meldung — das Attribut bleibt stumm"; FAIL=$((FAIL+1)); fi
}

# --- 1. Erfundene Attribute ----------------------------------------------
rejects "Repro: erfundenes Attribut" 'import std.io;
@zzz_erfunden
fn Ziel(): int64 { return 1; }
fn main(): int64 { return Ziel(); }' "unbekanntes Attribut"

rejects "erfundenes Attribut mit Argument" 'import std.io;
@zzz_erfunden(42)
fn Ziel(): int64 { return 1; }
fn main(): int64 { return Ziel(); }' "unbekanntes Attribut"

# Der Fall, um den es geht: der Tippfehler in einem echten Attributnamen.
rejects "Tippfehler im Attributnamen" 'import std.io;
@stack_limt(512)
fn Ziel(): int64 { return 1; }
fn main(): int64 { return Ziel(); }' "unbekanntes Attribut"

# --- 2. Argumentform ------------------------------------------------------
rejects "Argument an einem Attribut ohne Argument" 'import std.io;
@critical(3)
fn F(): int64 { return 1; }
fn main(): int64 { return F(); }' "nimmt kein Argument"

rejects "fehlendes Argument" 'import std.io;
@wcet
fn F(): int64 { return 1; }
fn main(): int64 { return F(); }' "verlangt ein Argument"

rejects "Zeichenkette statt Ganzzahl" 'import std.io;
@stack_limit("viel"c)
fn F(): int64 { return 1; }
fn main(): int64 { return F(); }' "verlangt eine Ganzzahl"

rejects "Ganzzahl statt Zeichenkette" 'import std.io;
@description(5)
fn F(): int64 { return 1; }
fn main(): int64 { return F(); }' "verlangt eine Zeichenkette"

rejects "erfundene DAL-Stufe" 'import std.io;
@dal(Z)
fn F(): int64 { return 1; }
fn main(): int64 { return F(); }' "Stufe muss A, B, C oder D sein"

# --- 3. Die echten Attribute muessen weiter uebersetzen ------------------
# Ohne diese Haelfte waere eine Pruefung, die alles abweist, ebenso gruen.
accepts "@volatile an einer Variablen" 'import std.io;
fn main(): int64 {
    @volatile var v: int64 := 3;
    return v - 3;
}'

accepts "@energy(3)" 'import std.io;
@energy(3)
fn F(): int64 { return 1; }
fn main(): int64 { return F(); }'

accepts "@dal(A) mit gueltiger Stufe" 'import std.io;
@dal(A)
fn F(): int64 { return 1; }
fn main(): int64 { return F(); }'

accepts "@critical ohne Argument" 'import std.io;
@critical
fn F(): int64 { return 1; }
fn main(): int64 { return F(); }'

accepts "@stack_limit(512) mit Ganzzahl" 'import std.io;
@stack_limit(512)
fn F(): int64 { return 1; }
fn main(): int64 { return F(); }'

# Die Modul-Attribute: 340-fach im Bestand. Ohne sie in der bekannten Liste
# waere die ganze stdlib nicht mehr uebersetzbar.
accepts "@description/@author/@copyright am Modulkopf" '@description("Test"c)
@author("Andreas"c)
@copyright("2026"c)
import std.io;
fn main(): int64 { return 0; }'

accepts "@redundant an einer Variablen" 'import std.io;
@redundant
var k: int64 := 5;
fn main(): int64 { return k - 5; }'

accepts "@packed an einer Struktur" 'import std.io;
@packed
type P = struct { a: int64; b: int64; };
fn main(): int64 { return 0; }'

accepts "@big_endian an einer Struktur" 'import std.io;
@big_endian
type P = struct { a: int64; };
fn main(): int64 { return 0; }'

# --- 4. Die Zusicherungen ohne Nachweis melden sich ----------------------
warns "@wcet meldet den fehlenden Nachweis" 'import std.io;
@wcet(10)
fn F(): int64 { var i: int64 := 0; while (i < 1000000) { i := i + 1; } return i; }
fn main(): int64 { return 0; }' "NICHT nachgewiesen"

warns "@stack_limit meldet den fehlenden Nachweis" 'import std.io;
@stack_limit(8)
fn F(n: int64): int64 { if (n <= 0) { return 0; } return F(n-1); }
fn main(): int64 { return 0; }' "NICHT nachgewiesen"

warns "@flight_crit meldet den fehlenden Nachweis" 'import std.io;
@flight_crit
fn F(): int64 { return 1; }
fn main(): int64 { return F(); }' "NICHT nachgewiesen"

warns "@dal meldet den fehlenden Nachweis" 'import std.io;
@dal(A)
fn F(): int64 { return 1; }
fn main(): int64 { return F(); }' "NICHT nachgewiesen"

warns "@integrity meldet den fehlenden Nachweis" 'import std.io;
@integrity(mode: software_lockstep)
fn F(): int64 { return 1; }
fn main(): int64 { return F(); }' "NICHT nachgewiesen"

# Gegenprobe: ein Attribut, das WIRKT, meldet nichts — sonst waere die
# Unterscheidung zwischen "wirkt" und "nur vermerkt" wertlos.
quiet() { # name, quelltext
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  got=$("$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)
  if [ ! -f "$TMP/c" ]; then echo "FAIL $1: uebersetzt nicht"; FAIL=$((FAIL+1)); return; fi
  if echo "$got" | grep -q "NICHT nachgewiesen"; then
    echo "FAIL $1: meldet fehlenden Nachweis, obwohl das Attribut wirkt"; FAIL=$((FAIL+1))
  else echo "PASS $1 (keine Meldung)"; PASS=$((PASS+1)); fi
}

quiet "@energy meldet nichts" 'import std.io;
@energy(3)
fn F(): int64 { return 1; }
fn main(): int64 { return F(); }'

quiet "@redundant meldet nichts" 'import std.io;
@redundant
var k: int64 := 5;
fn main(): int64 { return k - 5; }'

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
