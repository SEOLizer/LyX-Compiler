#!/usr/bin/env bash
# tests/panic_uncatchable_test.sh — #1149: panic ist kein Ausnahmemechanismus.
#
# Bis 1.0.15A sprang `panic` in einen installierten Ausnahme-Handler: ein
# `try`/`catch` verschluckte den Abbruch, das Programm lief mit gebrochener
# Invariante weiter und endete mit Exit 0. Genau die Zusicherung, fuer die es
# `panic` gibt -- der kontrollierte Abbruch --, fiel damit im Fehlerfall aus.
#
# Geprueft wird beides: die AUSGABE (der catch-Block darf nicht laufen, der
# Code dahinter auch nicht) UND der EXIT-CODE. Ein Test, der nur auf die
# Meldung schaut, waere vor dem Fix gruen gewesen -- `panic` schrieb sie auch
# damals, bevor es in den Handler sprang.
#
# Dieselbe Klasse und derselbe Codepfad (cg_emitPanicBody): assert und die
# Bereichs-/Grenzpruefungen. Auch sie waren fangbar; sie sind mitgeprueft.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

runs() { # name, quelltext, erwartete ausgabe, erwarteter rc, [flags]
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! "$LYXC" --std-path="$ROOT" $5 "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    echo "FAIL $1: uebersetzt nicht"; FAIL=$((FAIL+1)); return
  fi
  got="$(timeout 10 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then echo "FAIL $1: ABSTURZ (rc=$rc)"; FAIL=$((FAIL+1)); return; fi
  if [ "$got" = "$3" ] && [ "$rc" -eq "$4" ]; then echo "PASS $1"; PASS=$((PASS+1))
  else echo "FAIL $1: '$got' rc=$rc — erwartet '$3' rc=$4"; FAIL=$((FAIL+1)); fi
}

# --- Der Repro aus dem Issue --------------------------------------------
# panic ueber zwei Aufrufebenen hinweg, umschlossen von try/catch.
runs "Repro: panic durchlaeuft catch, Exit 1" 'import src.std.io;
fn Tief():  int64 { panic("kaputt\n"c); return 0; }
fn Mitte(): int64 { return Tief(); }
fn main(): int64 {
    try { Mitte(); } catch (e) { PrintStrLn("verschluckt"); }
    PrintStrLn("laeuft weiter");
    return 0;
}' 'kaputt' 1

# --- finally laeuft nicht mehr an ---------------------------------------
# Die Doku (sprache/exception-handling.txt §6) sagt "beendet das Programm
# sofort" — also auch kein Aufraeumpfad. Das ist die Entscheidung, die der
# Issue offen gelassen hat; sie steht hier fest.
runs "finally laeuft nach panic nicht" 'import src.std.io;
fn main(): int64 {
    try { panic("stop\n"c); } catch (e) { PrintStrLn("verschluckt"); } finally { PrintStrLn("finally"); }
    PrintStrLn("weiter");
    return 0;
}' 'stop' 1

# --- Verschachtelte try-Bloecke halten es ebenso wenig auf --------------
runs "zwei verschachtelte try halten panic nicht auf" 'import src.std.io;
fn main(): int64 {
    try { try { panic("stop\n"c); } catch (a) { PrintStrLn("innen"); } } catch (b) { PrintStrLn("aussen"); }
    PrintStrLn("weiter");
    return 0;
}' 'stop' 1

# --- Die Gegenprobe aus dem Issue bleibt unveraendert -------------------
runs "panic ohne try unveraendert" 'import src.std.io;
fn main(): int64 {
    PrintStrLn("vor");
    panic("Invariante verletzt\n"c);
    PrintStrLn("nach");
    return 0;
}' 'vor
Invariante verletzt' 1

# --- assert gehoert zur selben Klasse (derselbe Codepfad) ---------------
runs "assert ist ebenso wenig fangbar" 'import src.std.io;
fn main(): int64 {
    try { assert(1 == 2); } catch (e) { PrintStrLn("verschluckt"); }
    PrintStrLn("weiter");
    return 0;
}' 'assertion failed' 1

runs "assertNotNull ist ebenso wenig fangbar" 'import src.std.io;
fn main(): int64 {
    var p: int64 := 0;
    try { assertNotNull(p); } catch (e) { PrintStrLn("verschluckt"); }
    PrintStrLn("weiter");
    return 0;
}' 'null pointer' 1

# --- Die Grenzpruefung ebenso -------------------------------------------
runs "Grenzpruefung ist nicht fangbar" 'import src.std.io;
fn main(): int64 {
    var a: int64[4];
    var i: int64 := 9;
    try { PrintLn(IntToStr(a[i])); } catch (e) { PrintStrLn("verschluckt"); }
    PrintStrLn("weiter");
    return 0;
}' 'index out of bounds' 1 --runtime-checks

# --- throw bleibt fangbar ------------------------------------------------
# Die Aenderung trifft NUR den Abbruchpfad. Ein gewoehnlicher throw wird
# weiterhin gefangen, sonst waere try/catch als Ganzes tot.
runs "throw bleibt fangbar" 'import src.std.io;
fn main(): int64 {
    try { throw 5; } catch (e: int64) { PrintLn(IntToStr(e)); }
    PrintStrLn("weiter");
    return 0;
}' '5
weiter' 0

runs "throw ueber Funktionsgrenzen bleibt fangbar" 'import src.std.io;
fn boom(): int64 { throw 7; return 0; }
fn main(): int64 {
    try { boom(); } catch (e: int64) { PrintLn(IntToStr(e)); } finally { PrintStrLn("finally"); }
    return 0;
}' '7
finally' 0

# --- panic nach einem gefangenen throw ----------------------------------
# Der Handler ist zu diesem Zeitpunkt zurueckgesetzt; auch ein spaeterer panic
# im selben Programm bricht ab, statt in einen alten Rahmen zu springen.
runs "panic nach gefangenem throw bricht ab" 'import src.std.io;
fn main(): int64 {
    try { throw 1; } catch (e: int64) { PrintStrLn("gefangen"); }
    panic("danach\n"c);
    PrintStrLn("nie");
    return 0;
}' 'gefangen
danach' 1

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
test "$FAIL" -eq 0
