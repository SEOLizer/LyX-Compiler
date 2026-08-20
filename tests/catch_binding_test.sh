#!/usr/bin/env bash
# tests/catch_binding_test.sh — #1147: der geworfene Wert ist im catch lesbar.
#
# Bis 1.0.15A war er es in KEINER Schreibweise:
#   a) `catch (e: int64)` — die Form aus ebnf.md §12 — wies der Parser ab
#      ("expected ), got :"),
#   b) `catch (e)` parste, band aber nichts ("undefined symbol 'e'"),
#   c) gab es aussen ein gleichnamiges `e`, uebersetzte es und lief -- und las
#      still den ALTEN Wert. Das ist der gefaehrliche Fall: kein Fehler, nur
#      ein falsches Ergebnis.
#
# Geprueft wird der WEG: dass die Bindung den GEWORFENEN Wert traegt und nicht
# zufaellig denselben wie eine aeussere Variable. Deshalb tragen die aeussere
# Variable und der geworfene Wert ueberall verschiedene Zahlen -- ein Test mit
# `var e := 0; throw 0` waere vor dem Fix gruen gewesen.
#
# NICHT enthalten: Auswahl der Klausel nach Typ. Der geworfene Wert ist ein
# rohes Maschinenwort ohne Typkennung; mehrere catch-Klauseln liefen deshalb
# alle nacheinander. Seit #1147 wird das gemeldet statt still getan -- der
# letzte Abschnitt haelt das fest.

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

fails() { # name, quelltext, erwarteter meldungsteil
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  msg="$("$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)"
  if [ -f "$TMP/c" ]; then echo "FAIL $1: uebersetzt, statt zu melden"; FAIL=$((FAIL+1)); return; fi
  case "$msg" in
    *"$3"*) echo "PASS $1"; PASS=$((PASS+1)) ;;
    *) echo "FAIL $1: Meldung ohne '$3': $msg"; FAIL=$((FAIL+1)) ;;
  esac
}

# --- a) Die Form aus der Grammatik uebersetzt und bindet -----------------
out "catch (e: int64) bindet den geworfenen Wert" 'import src.std.io;
fn main(): int64 {
    try { throw 5; } catch (e: int64) { PrintLn(IntToStr(e)); }
    return 0;
}' '5'

# --- b) Ohne Typangabe ebenso -------------------------------------------
# Der Wert ist dann das rohe Maschinenwort; als int64 gebunden.
out "catch (e) ohne Typangabe bindet ebenfalls" 'import src.std.io;
fn main(): int64 {
    try { throw 5; } catch (e) { PrintLn(IntToStr(e)); }
    return 0;
}' '5'

# --- c) Der stille Fall: aeussere Variable gleichen Namens ---------------
# Der Repro aus dem Issue. Vor dem Fix gab er 0 aus.
out "Repro: aeusseres e wird verdeckt, nicht gelesen" 'import src.std.io;
fn main(): int64 {
    var e: int64 := 0;
    try { throw 5; } catch (e) { PrintLn(IntToStr(e)); }
    return 0;
}' '5'

# Und die Gegenrichtung: nach dem catch-Block gilt wieder die aeussere.
out "aeusseres e lebt nach dem catch-Block weiter" 'import src.std.io;
fn main(): int64 {
    var e: int64 := 3;
    try { throw 5; } catch (e: int64) { PrintLn(IntToStr(e)); }
    PrintLn(IntToStr(e));
    return 0;
}' '5
3'

# Die Bindung ist schreibbar wie eine gewoehnliche lokale Variable, und der
# aeussere Wert bleibt davon unberuehrt.
out "Schreiben in die Bindung beruehrt das aeussere e nicht" 'import src.std.io;
fn main(): int64 {
    var e: int64 := 3;
    try { throw 5; } catch (e: int64) { e := e + 1; PrintLn(IntToStr(e)); }
    PrintLn(IntToStr(e));
    return 0;
}' '6
3'

# --- pchar wird ebenso geworfen wie int64 --------------------------------
out "geworfener pchar ist als Text lesbar" 'import src.std.io;
fn boom(): int64 { throw "kaputt"c; return 0; }
fn main(): int64 {
    try { boom(); } catch (m: pchar) { PrintStrLn(m); }
    return 0;
}' 'kaputt'

# --- ueber Funktionsgrenzen ---------------------------------------------
out "Wert aus einer gerufenen Funktion kommt an" 'import src.std.io;
fn boom(): int64 { throw 42; return 0; }
fn main(): int64 {
    try { boom(); } catch (e: int64) { PrintLn(IntToStr(e)); }
    return 0;
}' '42'

# --- Verschachtelung und Rethrow ----------------------------------------
# Jedes try hat seine eigene Bindung; der Rethrow traegt seinen eigenen Wert.
out "verschachtelt: innere und aeussere Bindung getrennt" 'import src.std.io;
fn main(): int64 {
    try {
        try { throw 3; } catch (e: int64) { PrintLn(IntToStr(e)); throw 9; }
    } catch (o: int64) { PrintLn(IntToStr(o)); }
    return 0;
}' '3
9'

# --- Der Kein-Wurf-Pfad bleibt unberuehrt --------------------------------
out "ohne throw laeuft der catch-Block nicht" 'import src.std.io;
fn main(): int64 {
    try { PrintStrLn("try"); } catch (e: int64) { PrintStrLn("catch"); }
    PrintStrLn("danach");
    return 0;
}' 'try
danach'

# --- finally laeuft auf beiden Pfaden weiter -----------------------------
out "finally nach dem catch mit Bindung" 'import src.std.io;
fn main(): int64 {
    try { throw 5; } catch (e: int64) { PrintLn(IntToStr(e)); } finally { PrintStrLn("finally"); }
    return 0;
}' '5
finally'

# --- Unbekannter Typ in der Klausel wird gemeldet ------------------------
fails "unbekannter Typ in der catch-Klausel" 'import src.std.io;
fn main(): int64 {
    try { throw 1; } catch (e: Nix) { PrintLn(IntToStr(e)); }
    return 0;
}' "unknown type in catch clause"

# --- Mehrere Klauseln: gemeldet, nicht still alle ausgefuehrt ------------
# Der geworfene Wert traegt keine Typkennung, es kann also nicht ausgewaehlt
# werden. Vor #1147 liefen alle Klauseln nacheinander -- klassischer stiller
# Fehlgriff, den die neue Typangabe erst recht nahelegt.
fails "zwei catch-Klauseln werden gemeldet" 'import src.std.io;
fn main(): int64 {
    try { throw 1; } catch (a: int64) { PrintStrLn("a"); } catch (b: pchar) { PrintStrLn("b"); }
    return 0;
}' "mehrere catch-Klauseln"

# --- Die Bindung gilt nur im catch-Block ---------------------------------
fails "Bindung ausserhalb des catch-Blocks unbekannt" 'import src.std.io;
fn main(): int64 {
    try { throw 5; } catch (e: int64) { PrintLn(IntToStr(e)); }
    PrintLn(IntToStr(e));
    return 0;
}' "undefined symbol"

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
test "$FAIL" -eq 0
