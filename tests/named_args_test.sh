#!/usr/bin/env bash
# tests/named_args_test.sh — #1087: benannte Argumente.
#
# Der Parser legte sie als eigene Knoten ab, ausgewertet wurde danach aber rein
# POSITIONELL. `F(b: 3, a: 10)` rechnete mit a=3, b=10 — still und mit
# falschem Ergebnis. Erfundene Parameternamen fielen gar nicht auf.
#
# Das ist die unangenehmste Form eines stillen Fehlschlags: der Aufrufer
# schreibt die Namen gerade deshalb hin, um sich NICHT auf die Reihenfolge
# verlassen zu müssen.
#
# Der Test prüft deshalb das RECHENERGEBNIS bei vertauschter Reihenfolge. Die
# Probe mit richtiger Reihenfolge wäre schon vor dem Fix grün gewesen — sie ist
# als Gegenprobe trotzdem dabei, aber sie allein hätte nichts belegt.
#
# Zweiter Teil: wo die Deklaration nicht herangezogen werden kann (importiert,
# extern, variadisch, generisch), lassen sich Namen nicht zuordnen. Dort wird
# gemeldet statt stillschweigend positionell weitergemacht.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    echo "FAIL $1: uebersetzt nicht"; FAIL=$((FAIL+1)); return
  fi
  got="$(timeout 10 "$TMP/c" 2>&1)"
  if [ "$got" = "$3" ]; then echo "PASS $1"; PASS=$((PASS+1))
  else echo "FAIL $1: '$got' erwartet '$3'"; FAIL=$((FAIL+1)); fi
}

rejects() { # name, quelltext, erwartete meldung
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  got=$("$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)
  if echo "$got" | grep -q "$3"; then echo "PASS $1 (abgewiesen)"; PASS=$((PASS+1))
  else echo "FAIL $1: nicht abgewiesen — '$(echo "$got" | tail -1)'"; FAIL=$((FAIL+1)); fi
}

# --- Der Repro: vertauschte Reihenfolge muss stimmen ---------------------
out "Repro: vertauschte Reihenfolge" 'import std.io;
fn F(a: int64, b: int64): int64 { return a - b; }
fn main(): int64 {
    PrintLn(IntToStr(F(b: 3, a: 10)));
    return 0;
}' '7'

# Gegenprobe — waere schon vor dem Fix gruen gewesen, belegt also allein nichts.
out "richtige Reihenfolge weiterhin richtig" 'import std.io;
fn F(a: int64, b: int64): int64 { return a - b; }
fn main(): int64 {
    PrintLn(IntToStr(F(a: 10, b: 3)));
    return 0;
}' '7'

out "rein positionell unveraendert" 'import std.io;
fn F(a: int64, b: int64): int64 { return a - b; }
fn main(): int64 {
    PrintLn(IntToStr(F(10, 3)));
    return 0;
}' '7'

# Gemischt: positionell zuerst, dann benannt.
out "positionell und benannt gemischt" 'import std.io;
fn F(a: int64, b: int64): int64 { return a - b; }
fn main(): int64 {
    PrintLn(IntToStr(F(10, b: 3)));
    return 0;
}' '7'

# Drei Parameter, vollstaendig umgedreht — mit zwei Parametern koennte eine
# Vertauschung noch zufaellig stimmen.
out "drei Parameter, umgedreht" 'import std.io;
fn G(a: int64, b: int64, c: int64): int64 { return a * 100 + b * 10 + c; }
fn main(): int64 {
    PrintLn(IntToStr(G(c: 3, b: 2, a: 1)));
    return 0;
}' '123'

# Ausgewertet wird in PARAMETERREIHENFOLGE, nicht in der geschriebenen. Das
# ist eine Festlegung, keine Nebenwirkung: die Argumentliste wird auf die
# Parameterreihenfolge umgehaengt, und der Codegen laeuft sie von vorn ab.
# ebnf.md §20.1 haelt die Regel fest. Geprueft wird sie ueber einen
# Seiteneffekt — am WEG statt am Ergebnis, sonst bliebe sie unbelegt.
out "Auswertung folgt der Parameterreihenfolge" 'import std.io;
var log: pchar := ""c;
fn eins(): int64 { log := StrConcat(log, "1"c); return 1; }
fn zwei(): int64 { log := StrConcat(log, "2"c); return 2; }
fn H(a: int64, b: int64): int64 { return a * 10 + b; }
fn main(): int64 {
    var r: int64 := H(b: zwei(), a: eins());
    PrintLn(IntToStr(r));
    PrintLn(log);
    return 0;
}' '12
12'

# --- Fehlerfaelle --------------------------------------------------------
rejects "unbekannter Parametername" 'import std.io;
fn F(a: int64, b: int64): int64 { return a - b; }
fn main(): int64 { PrintLn(IntToStr(F(zzz: 3, qqq: 10))); return 0; }' "unbekannter Parametername"

rejects "Parameter doppelt belegt" 'import std.io;
fn F(a: int64, b: int64): int64 { return a - b; }
fn main(): int64 { PrintLn(IntToStr(F(a: 3, a: 10))); return 0; }' "doppelt belegt"

rejects "positionell nach benannt" 'import std.io;
fn F(a: int64, b: int64): int64 { return a - b; }
fn main(): int64 { PrintLn(IntToStr(F(a: 3, 10))); return 0; }' "positionelles Argument nach benanntem"

# Wo die Deklaration nicht herangezogen werden kann, wird gemeldet statt
# stillschweigend positionell zu rechnen.
rejects "benannt bei nicht aufloesbarem Aufruf" 'import std.io;
fn main(): int64 { PrintLn(IntToStr(StrLen(s: "abc"c))); return 0; }' "nicht unterstuetzt"

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
