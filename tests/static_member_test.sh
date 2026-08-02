#!/usr/bin/env bash
# tests/static_member_test.sh — #1090: `static` an Klassenmitgliedern.
#
# `ebnf.md` §9 führt `static` sowohl als Methoden-Modifier als auch für Felder.
# Der Parser lehnte beides mit „expected IDENT, got static" ab.
#
# Bei den METHODEN fehlte nur das Wort: der Aufruf über den Typnamen — `A.F()`
# — funktionierte längst, der Codegen übergibt dort self = 0. Mit der
# Markierung wird daraus eine Zusicherung, und die wird geprüft: eine
# `static`-Methode darf `self` nicht anfassen, sonst dereferenziert sie null.
#
# Die Prüfung sitzt bewusst NICHT in der allgemeinen Rumpfprüfung. Die läuft
# aus Rücksicht auf Altbestand nur für capability-annotierte Klassen (WP-L8);
# eine Zusicherung, die nur bei annotierten Klassen gilt, wäre keine.
#
# Die FELDER werden weiterhin abgewiesen — aber mit einer Meldung, die den
# Grund nennt: `A.v` bezeichnet in Lyx den Byte-Offset des Feldes (std/string.lyx
# nutzt das, etwa `StringBuilder.capacity`). Welche der beiden Bedeutungen
# gelten soll, ist eine Sprachentscheidung, kein Fehler nebenbei.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
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

# --- static-Methoden -----------------------------------------------------
out "Repro: static-Methode uebersetzt und laeuft" 'import std.io;
type A = class { v: int64; static fn F(): int64 { return 42; } };
fn main(): int64 {
    PrintLn(IntToStr(A.F()));
    return 0;
}' '42'

out "static-Methode mit Argumenten" 'import std.io;
type A = class { v: int64; static fn Add(a: int64, b: int64): int64 { return a + b; } };
fn main(): int64 {
    PrintLn(IntToStr(A.Add(40, 2)));
    return 0;
}' '42'

out "static neben gewoehnlicher Methode" 'import std.io;
type A = class {
    v: int64;
    static fn Zero(): int64 { return 0; }
    fn Get(): int64 { return self.v; }
};
fn main(): int64 {
    var a: A := new A();
    a.v := 7;
    PrintLn(IntToStr(A.Zero()));
    PrintLn(IntToStr(a.Get()));
    return 0;
}' '0
7'

out "static mit pub" 'import std.io;
type A = class { v: int64; pub static fn F(): int64 { return 5; } };
fn main(): int64 {
    PrintLn(IntToStr(A.F()));
    return 0;
}' '5'

# --- Die Zusicherung wird eingeloest -------------------------------------
rejects "static-Methode darf self nicht lesen" 'import std.io;
type A = class { v: int64; static fn F(): int64 { return self.v; } };
fn main(): int64 { return 0; }' "statische Methode darf self nicht verwenden"

rejects "static-Methode darf self nicht schreiben" 'import std.io;
type A = class { v: int64; static fn F(): int64 { self.v := 1; return 0; } };
fn main(): int64 { return 0; }' "statische Methode darf self nicht verwenden"

# Auch tief im Rumpf, nicht nur in der ersten Anweisung.
rejects "self tief im Rumpf" 'import std.io;
type A = class {
    v: int64;
    static fn F(n: int64): int64 {
        var i: int64 := 0;
        while (i < n) {
            if (i == 3) { return self.v; }
            i := i + 1;
        }
        return 0;
    }
};
fn main(): int64 { return 0; }' "statische Methode darf self nicht verwenden"

# --- Gegenproben ---------------------------------------------------------
# Eine gewoehnliche Methode darf self selbstverstaendlich benutzen — sonst
# waere die Regel zu breit.
out "gewoehnliche Methode darf self" 'import std.io;
type A = class { v: int64; fn Get(): int64 { return self.v; } };
fn main(): int64 {
    var a: A := new A();
    a.v := 9;
    PrintLn(IntToStr(a.Get()));
    return 0;
}' '9'

# Die uebrigen Modifier bleiben unveraendert.
out "virtual unveraendert" 'import std.io;
type A = class { v: int64; virtual fn F(): int64 { return 1; } };
fn main(): int64 {
    var a: A := new A();
    PrintLn(IntToStr(a.F()));
    return 0;
}' '1'

# --- static-Felder: abgewiesen, aber mit Begruendung ---------------------
rejects "static-Feld nennt den Grund" 'type A = class { static v: int64; };
fn main(): int64 { return 0; }' "statische Felder werden nicht unterstuetzt"

# Das Muster, das die Schreibweise belegt, muss weiter funktionieren.
out "TypeName.feld bleibt der Byte-Offset" 'import std.io;
type P = struct { a: int64; b: int64; };
fn main(): int64 {
    PrintLn(IntToStr(P.b));
    return 0;
}' '8'

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
