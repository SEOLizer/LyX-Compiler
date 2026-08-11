#!/usr/bin/env bash
# tests/class_lifecycle_test.sh — #1235, #1236 und #1288.
#
# Drei Luecken im Lebenszyklus eines Objekts: beim Erzeugen, beim Ueberschreiben
# und beim Freigeben.
#
# #1235 `dispose` war ein No-op. Im Codegen stand woertlich
#       "dispose obj: call munmap? Skip for bootstrap." — der Ausdruck wurde
#       ausgewertet und sonst nichts getan. `new` ruft Create korrekt, `dispose`
#       rief Destroy also nie. Wer einen Destruktor schreibt, tut das wegen
#       seiner Wirkung; dass sie ausblieb, war am Programm nicht zu sehen.
#
# #1236 `new L()` bei `Create(x: int64)` uebersetzte klaglos. Create las als x,
#       was zufaellig im Register stand, und das Feld trug danach einen
#       Speicherrest (beobachtet: 4096). Fuer freie Funktionen greift die
#       Zaehlung seit WP-ARITY laengst — der Konstruktor war die Luecke.
#
# #1288 Implementiert eine Unterklasse eine ABSTRAKTE Methode ohne `override`,
#       galt sie als eigene, neue Methode. Der geerbte VMT-Eintrag blieb leer,
#       der Aufruf sprang eine Null an: SIGSEGV, ohne jede Meldung beim
#       Uebersetzen. Mit `override` lief dasselbe Programm. Die Pruefstelle
#       existierte, war aber leer ("full method signature check deferred").
#
# Zu jedem Fall gehoert die Gegenprobe: der richtige Aufruf, das richtige
# Schluesselwort und die Klasse OHNE das jeweilige Merkmal muessen unveraendert
# durchlaufen. Ohne sie waere eine zu weit gefasste Pruefung ebenfalls gruen.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    no "$1" "uebersetzt nicht"; return
  fi
  got="$(timeout 30 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then no "$1" "ABSTURZ (rc=$rc)"; return; fi
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1" "'$got' erwartet '$3'"; fi
}

rejects() { # name, quelltext, erwartete meldung
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  got=$("$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then no "$1" "Exit 0 — nicht abgewiesen"; return; fi
  if echo "$got" | grep -q "$3"; then ok "$1 (abgewiesen)"
  else no "$1" "andere Meldung — '$(echo "$got" | tail -1)'"; fi
}

# ===========================================================================
# #1235 — dispose ruft den Destruktor
# ===========================================================================

out "dispose ruft Destroy" 'import std.io;
pub type L = class { v: int64;
  pub fn Create(x: int64) { self.v := x; }
  pub fn Destroy() { PrintLn("Destroy lief"); } };
fn main(): int64 {
  var o: L := new L(5);
  PrintLn(IntToStr(o.v));
  dispose o;
  PrintLn("nach dispose");
  return 0;
}' "5
Destroy lief
nach dispose"

# Gegenprobe: eine Klasse ohne Destruktor darf sich nicht mitveraendern — vor
# allem darf dispose dort nicht ins Leere springen.
out "Klasse ohne Destroy bleibt unveraendert" 'import std.io;
pub type L = class { v: int64;
  pub fn Create(x: int64) { self.v := x; } };
fn main(): int64 {
  var o: L := new L(5);
  dispose o;
  PrintLn("nach dispose");
  return 0;
}' "nach dispose"

# Zwei Objekte: jeder Destruktor muss genau einmal laufen.
out "zwei Objekte, zwei Destruktoraufrufe" 'import std.io;
pub type L = class { v: int64;
  pub fn Create(x: int64) { self.v := x; }
  pub fn Destroy() { PrintLn(IntToStr(self.v)); } };
fn main(): int64 {
  var a: L := new L(1);
  var b: L := new L(2);
  dispose a;
  dispose b;
  return 0;
}' "1
2"

# ===========================================================================
# #1236 — new gegen den Konstruktor zaehlen
# ===========================================================================

rejects "new ohne Argument bei Create(x)" 'import std.io;
pub type L = class { v: int64;
  pub fn Create(x: int64) { self.v := x; } };
fn main(): int64 { var o: L := new L(); return o.v; }' "falsche Argument-Anzahl fuer den Konstruktor"

rejects "new mit zu vielen Argumenten" 'import std.io;
pub type L = class { v: int64;
  pub fn Create(x: int64) { self.v := x; } };
fn main(): int64 { var o: L := new L(1, 2); return o.v; }' "falsche Argument-Anzahl fuer den Konstruktor"

# Gegenproben: die richtige Zahl, ein Konstruktor ohne Parameter und eine
# Klasse ganz ohne Create muessen weiterhin durchlaufen.
out "die richtige Argumentzahl unveraendert" 'import std.io;
pub type L = class { v: int64;
  pub fn Create(x: int64) { self.v := x; } };
fn main(): int64 { var o: L := new L(5); PrintLn(IntToStr(o.v)); return 0; }' "5"

out "Konstruktor ohne Parameter und Klasse ohne Create" 'import std.io;
pub type A = class { v: int64; pub fn Create() { self.v := 7; } };
pub type B = class { v: int64; };
fn main(): int64 {
  var a: A := new A();
  var b: B := new B();
  PrintLn(IntToStr(a.v));
  PrintLn("B erzeugt");
  return 0;
}' "7
B erzeugt"

# ===========================================================================
# #1288 — abstrakte Methode braucht override
# ===========================================================================
# Geprueft wird die Meldung UND der Exit-Code: ein Compiler, der meldet und
# trotzdem ein Binary hinlegt, waere sonst ebenso gruen — und genau dieses
# Binary stuerzte ab.

rejects "abstrakte Methode ohne override" 'import src.std.io;
type Animal = class { abstract fn Speak(): int64; };
type Dog = class extends Animal { fn Speak(): int64 { return 1; } };
fn main(): int64 { var d: Dog := new Dog(); return d.Speak(); }' "braucht dafuer aber .override."

out "mit override laeuft es" 'import src.std.io;
type Animal = class { abstract fn Speak(): int64; };
type Dog = class extends Animal { override fn Speak(): int64 { return 1; } };
fn main(): int64 { var d: Dog := new Dog(); PrintLn(IntToStr(d.Speak())); return 0; }' "1"

# Gegenprobe: eine neue Methode ohne Vorbild in der Oberklasse braucht KEIN
# override und darf nicht mit abgewiesen werden.
out "neue Methode ohne Vorbild bleibt erlaubt" 'import src.std.io;
type Animal = class { abstract fn Speak(): int64; };
type Dog = class extends Animal {
  override fn Speak(): int64 { return 1; }
  fn Extra(): int64 { return 9; } };
fn main(): int64 { var d: Dog := new Dog(); PrintLn(IntToStr(d.Extra())); return 0; }' "9"

# Gegenprobe: eine NICHT abstrakte Methode der Oberklasse zu verdecken bleibt
# erlaubt — die Pruefung gilt ausdruecklich nur fuer abstrakte.
out "nicht abstrakte Methode verdecken bleibt erlaubt" 'import src.std.io;
type Base = class { x: int64; fn M(): int64 { return 1; } };
type Sub = class extends Base { fn M(): int64 { return 2; } };
fn main(): int64 { var s: Sub := new Sub(); PrintLn(IntToStr(s.M())); return 0; }' "2"

echo
echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
