#!/usr/bin/env bash
# tests/verify_tmr_test.sh — #1141: `@redundant` an Globals + `--verify-tmr`.
#
# Bis 1.0.14M lag die Sache zweigeteilt:
#
#   LOKAL   funktionierte TMR (drei Kopien im Rahmen, Lesen ueber die
#           Mehrheitsentscheidung, Schreiben in alle drei -- WP-B1).
#   GLOBAL  wirkte `@redundant` GAR NICHT: die Variable bekam acht Byte im
#           Datensegment, keinen Voter, keine Kopien. Auf Modulebene war das
#           Attribut ein stiller Default -- und der Repro des Issues ist genau
#           so eine globale Variable.
#   `--verify-tmr` gab es nicht (das Flag fiel unter #1098, unbekannte Flags
#           werden stillschweigend ignoriert).
#
# Jetzt: Globals bekommen drei Zellen (A = doff, B, C) samt Anfangswert in
# allen dreien; jeder Lese- und Schreibzugriff laeuft ueber dieselben zwei
# Stellen im Codegen, die auch die Bilanz zaehlen.
#
# `--verify-tmr` ist KEIN blosser Bericht: geht auch nur ein Zugriff am Voter
# vorbei, schlaegt der Lauf mit Exit 1 fehl und es entsteht keine Binary. Der
# einzige solche Weg ist die Adresse-von-Form `@x` -- sie liefert die Adresse
# EINER Kopie, ein Schreibzugriff darueber geht beim naechsten
# Mehrheitsentscheid verloren. Ohne das Flag wird derselbe Fall gewarnt.
#
# Geprueft wird das VERHALTEN: die Selbstheilung (eine verfaelschte Kopie wird
# ueberstimmt UND korrigiert), die Bilanzzahlen und der Fehlschlag.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

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

# uebersetzt mit --verify-tmr und vergleicht die Bilanzzeile
bilanz() { # name, quelltext, erwarteter teil der bilanz
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  msg="$("$LYXC" --std-path="$ROOT" --verify-tmr "$TMP/c.lyx" -o "$TMP/c" 2>&1)"
  case "$msg" in
    *"$3"*) echo "PASS $1"; PASS=$((PASS+1)) ;;
    *) echo "FAIL $1: Bilanz ohne '$3' — war: $(printf '%s' "$msg" | grep 'TMR:' || echo 'keine TMR-Zeile')"; FAIL=$((FAIL+1)) ;;
  esac
}

# muss unter --verify-tmr fehlschlagen: Exit 1 und KEINE Binary
scheitert() { # name, quelltext, erwarteter meldungsteil
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  msg="$("$LYXC" --std-path="$ROOT" --verify-tmr "$TMP/c.lyx" -o "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -ne 1 ]; then echo "FAIL $1: Exit $rc erwartet 1"; FAIL=$((FAIL+1)); return; fi
  if [ -f "$TMP/c" ]; then echo "FAIL $1: Binary trotz Fehlschlag entstanden"; FAIL=$((FAIL+1)); return; fi
  case "$msg" in
    *"$3"*) echo "PASS $1"; PASS=$((PASS+1)) ;;
    *) echo "FAIL $1: Meldung ohne '$3'"; FAIL=$((FAIL+1)) ;;
  esac
}

K='import src.std.io;'

# --- Der Repro aus dem Issue: eine GLOBALE @redundant-Variable -----------
out "Repro: globale @redundant-Variable haelt ihren Wert" "$K
@redundant
var kritisch: int64 := 5;
fn main(): int64 {
    PrintLn(kritisch);
    kritisch := 7;
    PrintLn(kritisch);
    return 0;
}" '5
7'

# Der Anfangswert muss in ALLEN drei Zellen stehen. Stuende er nur in der
# ersten, waere die Mehrheit beim ersten Lesen 0 und der Initialisierer
# verloren -- der Fall ist am Ergebnis 5 oben schon mit abgedeckt, hier noch
# einmal ohne vorherige Zuweisung.
out "Anfangswert steht in allen drei Kopien" "$K
@redundant
var g: int64 := 42;
fn Lies(): int64 { return g; }
fn main(): int64 { PrintLn(Lies()); return 0; }" '42'

# --- Selbstheilung: eine verfaelschte Kopie wird ueberstimmt --------------
# Das ist der Zweck von TMR. Die drei Zellen liegen hintereinander; ueber die
# Adresse der ersten wird gezielt EINE verfaelscht. Der Voter muss den
# richtigen Wert liefern UND die Minderheit korrigieren.
out "verfaelschte Kopie wird ueberstimmt und geheilt" "$K
fn main(): int64 {
    @redundant
    var v: int64 := 3;
    var p: int64 := @v;
    poke64(p, 999);          // nur Kopie A verfaelschen
    PrintLn(v);              // Mehrheit B/C -> 3, A wird geheilt
    PrintLn(peek64(p));      // A traegt wieder 3
    return 0;
}" '3
3'

# --- Bilanz unter --verify-tmr -------------------------------------------
bilanz "Bilanz zaehlt Variable, Lese- und Schreibzugriffe" "$K
@redundant
var g: int64 := 5;
fn main(): int64 { PrintLn(g); g := 7; PrintLn(g); return 0; }" \
  "TMR: 1 @redundant-Variable(n), 2 gevotete(r) Lesezugriff(e), 1 dreifache(r) Schreibzugriff(e), 0 am Voter vorbei"

bilanz "lokale und globale Variablen zaehlen zusammen" "$K
@redundant
var g: int64 := 1;
fn main(): int64 {
    @redundant
    var l: int64 := 2;
    PrintLn(g + l);
    return 0;
}" "TMR: 2 @redundant-Variable(n)"

# Ohne @redundant zaehlt nichts -- sonst wuerde die Bilanz etwas ausweisen,
# das es nicht gibt.
bilanz "Programm ohne @redundant meldet Null" "$K
var g: int64 := 1;
fn main(): int64 { PrintLn(g); return 0; }" \
  "TMR: 0 @redundant-Variable(n), 0 gevotete(r) Lesezugriff(e), 0 dreifache(r) Schreibzugriff(e), 0 am Voter vorbei"

# Die Bilanz erscheint GENAU EINMAL. cg_genFile laeuft je importierter Einheit
# erneut; von dort gedruckt gaebe es eine Zeile je Import.
printf '%s\n' "$K
@redundant
var g: int64 := 1;
fn main(): int64 { PrintLn(g); return 0; }" > "$TMP/n.lyx"
anz="$("$LYXC" --std-path="$ROOT" --verify-tmr "$TMP/n.lyx" -o "$TMP/n" 2>&1 | grep -c 'TMR:')"
if [ "$anz" = "1" ]; then echo "PASS Bilanz erscheint genau einmal"; PASS=$((PASS+1))
else echo "FAIL Bilanz erscheint genau einmal: $anz Zeilen"; FAIL=$((FAIL+1)); fi

# --- Der Fehlschlag ------------------------------------------------------
# Abnahmekriterium des Issues: ein Programm, das ueber einen Zeiger schreibt,
# muss unter --verify-tmr fehlschlagen.
scheitert "Adresse-von laesst --verify-tmr fehlschlagen" "$K
fn main(): int64 {
    @redundant
    var v: int64 := 3;
    var p: int64 := @v;
    poke64(p, 99);
    PrintLn(v);
    return 0;
}" "die Redundanz ist nicht durchgehend"

scheitert "die Meldung nennt die Variable" "$K
fn main(): int64 {
    @redundant
    var geheim: int64 := 3;
    var p: int64 := @geheim;
    PrintLn(peek64(p));
    return 0;
}" "@geheim: Adresse-von umgeht die TMR-Mehrheitsentscheidung"

# Die Bilanz weist den Umgeher aus, statt ihn nur zu zaehlen.
bilanz "Bilanz weist den Umgeher aus" "$K
fn main(): int64 {
    @redundant
    var v: int64 := 3;
    var p: int64 := @v;
    PrintLn(peek64(p));
    return 0;
}" "1 am Voter vorbei"

# --- Ohne das Flag: Warnung statt Fehler ---------------------------------
# Stillschweigend durchlassen waere das Gegenteil dessen, was das Attribut
# zusagt; abbrechen ohne ausdrueckliche Pruefbitte waere zu scharf.
printf '%s\n' "$K
fn main(): int64 {
    @redundant
    var v: int64 := 3;
    var p: int64 := @v;
    PrintLn(peek64(p));
    return 0;
}" > "$TMP/w.lyx"
rm -f "$TMP/w"
wmsg="$("$LYXC" --std-path="$ROOT" "$TMP/w.lyx" -o "$TMP/w" 2>&1)"
if [ ! -f "$TMP/w" ]; then
  echo "FAIL ohne Flag wird uebersetzt: keine Binary"; FAIL=$((FAIL+1))
else
  case "$wmsg" in
    *"warning: @v: Adresse-von umgeht"*) echo "PASS ohne Flag: Warnung, aber uebersetzt"; PASS=$((PASS+1)) ;;
    *) echo "FAIL ohne Flag: Warnung fehlt"; FAIL=$((FAIL+1)) ;;
  esac
fi

# Ohne das Flag erscheint auch keine Bilanz -- sie ist an die Pruefbitte
# gebunden.
case "$wmsg" in
  *"TMR:"*) echo "FAIL ohne Flag keine Bilanz: steht trotzdem da"; FAIL=$((FAIL+1)) ;;
  *) echo "PASS ohne Flag keine Bilanz"; PASS=$((PASS+1)) ;;
esac

# --- Gegenproben ---------------------------------------------------------
# Ein sauberes Programm laeuft unter --verify-tmr durch (Exit 0, Binary da).
printf '%s\n' "$K
@redundant
var g: int64 := 5;
fn main(): int64 { g := g + 1; PrintLn(g); return 0; }" > "$TMP/o.lyx"
rm -f "$TMP/o"
"$LYXC" --std-path="$ROOT" --verify-tmr "$TMP/o.lyx" -o "$TMP/o" >/dev/null 2>&1; orc=$?
if [ "$orc" -eq 0 ] && [ -f "$TMP/o" ] && [ "$(timeout 10 "$TMP/o" 2>&1)" = "6" ]; then
  echo "PASS sauberes Programm laeuft unter --verify-tmr durch"; PASS=$((PASS+1))
else
  echo "FAIL sauberes Programm laeuft unter --verify-tmr durch (rc=$orc)"; FAIL=$((FAIL+1))
fi

# Die Adresse-von-Form an einer GEWOEHNLICHEN Variablen bleibt unberuehrt --
# sie ist der uebliche Weg zu einem Ausgabeparameter (#1061).
out "Adresse-von ohne @redundant unveraendert" "$K
fn Setze(p: int64) { poke64(p, 42); }
fn main(): int64 {
    var v: int64 := 0;
    Setze(@v);
    PrintLn(v);
    return 0;
}" '42'

bilanz "gewoehnliche Adresse-von zaehlt nicht als Umgehung" "$K
fn main(): int64 {
    var v: int64 := 1;
    var p: int64 := @v;
    PrintLn(peek64(p));
    return 0;
}" "0 am Voter vorbei"

# Mehrere globale @redundant-Variablen bekommen getrennte Zellen -- ohne die
# 16 zusaetzlichen Byte je Variable liefe die naechste in dieselben Zellen.
out "zwei globale @redundant-Variablen stoeren einander nicht" "$K
@redundant
var a: int64 := 11;
@redundant
var b: int64 := 22;
fn main(): int64 { a := a + 1; PrintLn(a); PrintLn(b); return 0; }" '12
22'

out "gewoehnliche Globals neben redundanten" "$K
@redundant
var a: int64 := 1;
var b: int64 := 2;
@redundant
var c: int64 := 3;
fn main(): int64 { b := b + 10; PrintLn(a); PrintLn(b); PrintLn(c); return 0; }" '1
12
3'

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
test "$FAIL" -eq 0
