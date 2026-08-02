#!/usr/bin/env bash
# tests/oop_super_abstract_test.sh — #1091: `super.M()` und blockloses
# `abstract fn F(): T;`.
#
# Beide sind in ebnf.md spezifiziert (§15 SuperExpr, §9 „Block durch ';'
# ersetzt") und wurden vom Parser abgewiesen. Vererbung war damit nutzbar,
# aber das übliche Muster „erweitern statt ersetzen" nicht ausdrückbar.
#
# `super.M()` wird als Methodenaufruf mit eigenem Marker gebaut und im Codegen
# DIREKT auf die Implementierung der Elternklasse geführt — nicht über die
# VMT. Genau daran hängt der wichtigste Testfall: `super.F()` innerhalb eines
# `override fn F()`. Über die VMT riefe es sich selbst, endlos. Ein Test, der
# `super` nur außerhalb eines override prüft, hätte das nicht gezeigt.
#
# Beim blocklosen `fn` prüft der Test auch die Gegenrichtung: ohne `abstract`
# muss ein Rumpf her, sonst wäre die Regel zu großzügig.

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
  if [ "$rc" -ge 124 ]; then echo "FAIL $1: Abbruch/Endlosschleife (rc=$rc)"; FAIL=$((FAIL+1)); return; fi
  if [ "$got" = "$3" ]; then echo "PASS $1"; PASS=$((PASS+1))
  else echo "FAIL $1: '$got' erwartet '$3'"; FAIL=$((FAIL+1)); fi
}

rejects() { # name, quelltext, erwartete meldung
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  got=$("$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)
  if echo "$got" | grep -q "$3"; then echo "PASS $1 (abgewiesen)"; PASS=$((PASS+1))
  else echo "FAIL $1: nicht abgewiesen — '$(echo "$got" | tail -1)'"; FAIL=$((FAIL+1)); fi
}

# --- super.Method() ------------------------------------------------------
out "Repro: super.Method()" 'import std.io;
type A = class { v: int64; fn Init(): int64 { return 1; } };
type B = class extends A { fn I2(): int64 { return super.Init() + 1; } };
fn main(): int64 {
    var b: B := new B();
    PrintLn(IntToStr(b.I2()));
    return 0;
}' '2'

# Der entscheidende Fall: super im override. Ueber die VMT wuerde der Aufruf
# sich selbst treffen und endlos laufen — deshalb der Direktaufruf.
out "super im override ruft die Basis, nicht sich selbst" 'import std.io;
type A = class { v: int64; virtual fn F(): int64 { return 10; } };
type B = class extends A { override fn F(): int64 { return super.F() + 5; } };
fn main(): int64 {
    var b: B := new B();
    PrintLn(IntToStr(b.F()));
    return 0;
}' '15'

out "super mit Argumenten" 'import std.io;
type A = class { v: int64; fn Add(a: int64, b: int64): int64 { return a + b; } };
type B = class extends A { fn Sum(): int64 { return super.Add(40, 2); } };
fn main(): int64 {
    var b: B := new B();
    PrintLn(IntToStr(b.Sum()));
    return 0;
}' '42'

out "super mit einem Argument" 'import std.io;
type A = class { v: int64; fn One(a: int64): int64 { return a; } };
type B = class extends A { fn S(): int64 { return super.One(7); } };
fn main(): int64 {
    var b: B := new B();
    PrintLn(IntToStr(b.S()));
    return 0;
}' '7'

# super laeuft auf DERSELBEN Instanz — ererbte Felder muessen sichtbar sein.
out "super arbeitet auf derselben Instanz" 'import std.io;
type A = class { v: int64; virtual fn Get(): int64 { return self.v; } };
type B = class extends A { override fn Get(): int64 { return super.Get() * 2; } };
fn main(): int64 {
    var b: B := new B();
    b.v := 21;
    PrintLn(IntToStr(b.Get()));
    return 0;
}' '42'

# --- abstract fn ohne Rumpf ---------------------------------------------
out "Repro: abstract fn ohne Rumpf" 'import std.io;
type A = abstract class {
    v: int64;
    abstract fn F(): int64;
    virtual fn G(): int64 { return 7; }
};
type B = class extends A {
    override fn F(): int64 { return 42; }
};
fn main(): int64 {
    var b: B := new B();
    PrintLn(IntToStr(b.F()));
    PrintLn(IntToStr(b.G()));
    return 0;
}' '42
7'

out "mehrere abstrakte Methoden" 'import std.io;
type A = abstract class {
    v: int64;
    abstract fn F(): int64;
    abstract fn G(): int64;
};
type B = class extends A {
    override fn F(): int64 { return 1; }
    override fn G(): int64 { return 2; }
};
fn main(): int64 {
    var b: B := new B();
    PrintLn(IntToStr(b.F() * 10 + b.G()));
    return 0;
}' '12'

# Gegenprobe: ohne `abstract` gehoert ein Rumpf dahinter. Die frueher gemeldete
# Stelle war „expected IDENT, got ;" — eine Meldung, die mit der Ursache
# nichts zu tun hatte.
rejects "fn ohne Rumpf und ohne abstract" 'type A = class { fn F(): int64; };
fn main(): int64 { return 0; }' "Methode ohne Rumpf muss abstract sein"

# --- Gegenproben: der Bestand bleibt unveraendert -----------------------
out "override ohne super unveraendert" 'import std.io;
type A = class { v: int64; virtual fn F(): int64 { return 1; } };
type B = class extends A { override fn F(): int64 { return 2; } };
fn main(): int64 {
    var b: B := new B();
    PrintLn(IntToStr(b.F()));
    return 0;
}' '2'

out "self auf ererbtes Feld unveraendert" 'import std.io;
type A = class { v: int64; };
type B = class extends A { fn G(): int64 { return self.v; } };
fn main(): int64 {
    var b: B := new B();
    b.v := 5;
    PrintLn(IntToStr(b.G()));
    return 0;
}' '5'

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
