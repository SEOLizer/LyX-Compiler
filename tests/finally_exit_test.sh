#!/usr/bin/env bash
# tests/finally_exit_test.sh — #1148: finally laeuft auch beim vorzeitigen
# Verlassen des try-Blocks.
#
# `return` aus dem try-Block sprang bis 1.0.15A direkt in den Epilog: der
# finally-Block wurde uebersprungen, die Freigabe unterblieb lautlos. Dasselbe
# galt fuer `break` und `continue` — der Issue-Text hielt sie fuer in Ordnung,
# weil im dortigen Beispiel eine ANDERE Schleifenrunde das erwartete `F`
# druckte. Ein Ergebnistest mit nur einer Runde waere also gruen gewesen; die
# Tests hier zaehlen deshalb die Durchlaeufe (`F` je Runde) statt nur zu
# schauen, ob `F` ueberhaupt vorkommt.
#
# Zweite, unsichtbare Haelfte desselben Defekts: der beim `try` installierte
# Ausnahme-Handler blieb bei `return` stehen. Er zeigte danach auf den Rahmen
# einer bereits verlassenen Funktion — ein spaeterer `throw` sprang dorthin.
# Der letzte Abschnitt prueft, dass er zurueckgesetzt wird.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
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

# --- Der Repro aus dem Issue --------------------------------------------
out "Repro: return aus dem try-Block laesst finally laufen" 'import src.std.io;
fn F(): int64 {
    try {
        PrintStrLn("A");
        return 1;
    } finally {
        PrintStrLn("F");
    }
    return 0;
}
fn main(): int64 { PrintLn(IntToStr(F())); return 0; }' 'A
F
1'

# Der Rueckgabewert ueberlebt den finally-Rumpf — auch wenn dieser selbst
# rechnet und Aufrufe macht (der Wert steht in rax und wird gerettet).
out "Rueckgabewert ueberlebt einen rechnenden finally-Rumpf" 'import src.std.io;
fn F(): int64 {
    var k: int64 := 20;
    try { return k + 2; } finally { PrintLn(IntToStr(k * 3)); }
    return 0;
}
fn main(): int64 { PrintLn(IntToStr(F())); return 0; }' '60
22'

# --- break und continue --------------------------------------------------
# Drei Runden, Abbruch in der zweiten: erwartet werden ZWEI finally-Laeufe.
out "break aus dem try-Block: finally je Runde" 'import src.std.io;
fn main(): int64 {
    var i: int64 := 0;
    while (i < 3) {
        try { if (i == 1) { break; } PrintStrLn("i"); } finally { PrintStrLn("F"); }
        i := i + 1;
    }
    PrintStrLn("danach");
    return 0;
}' 'i
F
F
danach'

out "continue aus dem try-Block: finally je Runde" 'import src.std.io;
fn main(): int64 {
    var i: int64 := 0;
    while (i < 3) {
        i := i + 1;
        try { if (i == 2) { continue; } PrintLn(IntToStr(i)); } finally { PrintStrLn("F"); }
    }
    return 0;
}' '1
F
F
3
F'

# --- Verschachtelte try-Bloecke -----------------------------------------
# Ein return aus dem inneren Block raeumt beide ab, von innen nach aussen.
out "return aus verschachteltem try: beide finally, innen zuerst" 'import src.std.io;
fn F(): int64 {
    try {
        try { return 5; } finally { PrintStrLn("innen"); }
    } finally { PrintStrLn("aussen"); }
    return 0;
}
fn main(): int64 { PrintLn(IntToStr(F())); return 0; }' 'innen
aussen
5'

# --- return aus dem catch-Block -----------------------------------------
out "return aus dem catch-Block laesst finally laufen" 'import src.std.io;
fn F(): int64 {
    try { throw 3; } catch (e: int64) { return e + 1; } finally { PrintStrLn("F"); }
    return 0;
}
fn main(): int64 { PrintLn(IntToStr(F())); return 0; }' 'F
4'

# --- return IM finally-Rumpf --------------------------------------------
# Er darf sich nicht selbst noch einmal ausloesen (im Codegen waere das eine
# endlose Rekursion) und bestimmt den Rueckgabewert.
out "return im finally-Rumpf laeuft genau einmal" 'import src.std.io;
fn F(): int64 {
    try { return 1; } finally { PrintStrLn("F"); return 9; }
    return 0;
}
fn main(): int64 { PrintLn(IntToStr(F())); return 0; }' 'F
9'

# --- Die Gegenproben aus dem Issue bleiben in Ordnung --------------------
out "ohne vorzeitigen Ausstieg unveraendert" 'import src.std.io;
fn main(): int64 {
    try { PrintStrLn("A"); } finally { PrintStrLn("F"); }
    return 0;
}' 'A
F'

out "finally laeuft genau einmal, nicht doppelt" 'import src.std.io;
fn F(): int64 {
    var n: int64 := 0;
    try { n := 1; } finally { PrintStrLn("F"); }
    return n;
}
fn main(): int64 { PrintLn(IntToStr(F())); return 0; }' 'F
1'

# --- defer im try-Block laeuft weiterhin vor finally (#1118) ------------
out "defer vor finally, Reihenfolge unveraendert" 'import src.std.io;
fn F(): int64 {
    try { defer PrintStrLn("defer"); return 1; } finally { PrintStrLn("F"); }
    return 0;
}
fn main(): int64 { PrintLn(IntToStr(F())); return 0; }' 'defer
F
1'

# --- Der Ausnahme-Handler wird beim return zurueckgesetzt ---------------
# Ohne das zeigte er nach der Rueckkehr in den Rahmen einer toten Funktion:
# ein spaeterer `throw` sprang dorthin, statt das Programm mit 1 zu beenden.
# Geprueft wird der WEG (Beendigung mit Code 1 nach der Marke), nicht nur eine
# Ausgabe -- ein Sprung in den toten Rahmen faellt sonst nicht auf.
printf 'import src.std.io;\nfn F(): int64 { try { return 1; } finally { PrintStrLn("F"); } return 0; }\nfn main(): int64 {\n  PrintLn(IntToStr(F()));\n  PrintStrLn("vor throw");\n  throw 7;\n  PrintStrLn("nie");\n  return 0;\n}\n' > "$TMP/h.lyx"; rm -f "$TMP/h"
if "$LYXC" --std-path="$ROOT" "$TMP/h.lyx" -o "$TMP/h" >/dev/null 2>&1; then
  got="$(timeout 10 "$TMP/h" 2>&1)"; rc=$?
  if [ "$got" = "F
1
vor throw" ] && [ "$rc" -eq 1 ]; then
    echo "PASS Handler nach return zurueckgesetzt"; PASS=$((PASS+1))
  else
    echo "FAIL Handler nach return zurueckgesetzt: '$got' rc=$rc"; FAIL=$((FAIL+1))
  fi
else
  echo "FAIL Handler nach return zurueckgesetzt: uebersetzt nicht"; FAIL=$((FAIL+1))
fi

# Und der Handler des UMSCHLIESSENDEN try lebt weiter: kehrt eine gerufene
# Funktion aus ihrem eigenen try zurueck, faengt das aeussere try danach noch.
out "aeusseres try faengt nach return aus fremdem try" 'import src.std.io;
fn F(): int64 { try { return 1; } finally { PrintStrLn("F"); } return 0; }
fn main(): int64 {
    try {
        PrintLn(IntToStr(F()));
        throw 7;
    } catch (e: int64) { PrintLn(IntToStr(e)); }
    PrintStrLn("danach");
    return 0;
}' 'F
1
7
danach'

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
test "$FAIL" -eq 0
