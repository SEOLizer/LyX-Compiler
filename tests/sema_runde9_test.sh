#!/usr/bin/env bash
# tests/sema_runde9_test.sh — #1633 und #1628.
#
# Zwei Luecken in derselben Ecke: was sema ueber eine Unit-Grenze hinweg noch
# nachschlagen kann, und was es im eigenen Methodenrumpf ueberhaupt prueft.
# Beide waren still — der Code uebersetzte, lief und rechnete falsch.
#
# GEPRUEFT WIRD DER WEG: an der Meldung selbst, jeweils mit Gegenprobe. Ein
# Ergebnistest waere bei #1633 nicht aussagekraeftig, weil der fehlende
# Parameter zufaellig auch 0 sein kann.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

weist_ab() {
  local name="$1" muster="$2" quelle="$3"
  printf '%s\n' "$quelle" > "$TMP/t.lyx"
  local msg; msg="$(timeout 300 "$LYXC" --std-path="$ROOT" -I "$TMP" "$TMP/t.lyx" -o "$TMP/t" 2>&1)"
  if echo "$msg" | grep -q "$muster"; then ok "$name"; else
    no "$name" "Muster '$muster' fehlt — $(echo "$msg"|grep -iE 'error'|head -1)"
  fi
}

laeuft() {
  local name="$1" erwartet="$2" quelle="$3"
  printf '%s\n' "$quelle" > "$TMP/t.lyx"
  if ! timeout 300 "$LYXC" --std-path="$ROOT" -I "$TMP" "$TMP/t.lyx" -o "$TMP/t" >"$TMP/c.log" 2>&1; then
    no "$name" "uebersetzt nicht: $(grep -m1 -iE 'sema error|codegen error' "$TMP/c.log")"
    return
  fi
  local got; got="$(timeout 60 "$TMP/t" 2>&1 | tr -d '\r' \
    | grep -vE 'Capabilit|^===|^Programm:|^  o |^  [A-Za-z-]+ |^$|^Runtime')"
  [ "$got" = "$erwartet" ] && ok "$name" || no "$name" "erwartet [$erwartet], bekam [$got]"
}

# ===========================================================================
# #1633 — Konstruktor einer IMPORTIERTEN Klasse
# ===========================================================================
mkdir -p "$TMP/Demo"
cat > "$TMP/Demo/M3.lyx" <<'EOF'
unit Demo.M3;
pub type TThing = class {
  A: int64;
  fn Create(a: int64): void { self.A := a; }
}
pub type TMitVorgabe = class {
  A: int64;
  fn Create(a: int64, b: int64): void { self.A := a + b; }
}
EOF

weist_ab "#1633: zu wenige Argumente an einem importierten Konstruktor" \
  "falsche Argument-Anzahl fuer den Konstruktor von 'TThing'" 'import Demo.M3;
fn main(): int64 { var t: TThing := new TThing(); return t.A; }'

weist_ab "#1633: zu viele Argumente an einem importierten Konstruktor" \
  "falsche Argument-Anzahl fuer den Konstruktor von 'TThing'" 'import Demo.M3;
fn main(): int64 { var t: TThing := new TThing(1, 2, 3); return t.A; }'

laeuft "#1633: der richtige Aufruf geht weiterhin durch" '42' 'import std.io;
import Demo.M3;
fn main(): int64 {
  var t: TThing := new TThing(42);
  PrintLn(IntToStr(t.A));
  return 0;
}'

laeuft "#1633: zwei Parameter, richtig uebergeben" '7' 'import std.io;
import Demo.M3;
fn main(): int64 {
  var t: TMitVorgabe := new TMitVorgabe(3, 4);
  PrintLn(IntToStr(t.A));
  return 0;
}'

# Gegenprobe: eine LOKALE Klasse wurde seit #1236 geprueft und wird es weiter.
weist_ab "#1633: lokale Klasse unveraendert geprueft" \
  "falsche Argument-Anzahl fuer den Konstruktor" 'type L = class { v: int64; fn Create(x: int64): void { self.v := x; } }
fn main(): int64 { var l: L := new L(); return l.v; }'

# ===========================================================================
# #1628 — unbekanntes Feld am eigenen self
# ===========================================================================
weist_ab "#1628: self.gibtsNicht wird gemeldet" \
  "unknown field 'gibtsNicht'" 'type T = class {
  a: int64;
  fn M(): int64 { return self.gibtsNicht; }
}
fn main(): int64 { var t: T := new T(); return t.M(); }'

# Schreibend ist es der gefaehrlichere Fall: Offset 0 trifft den VMT-Zeiger.
weist_ab "#1628: auch schreibend gemeldet" \
  "unknown field 'vertippt'" 'type T = class {
  a: int64;
  fn Setz(): void { self.vertippt := 5; }
}
fn main(): int64 { var t: T := new T(); t.Setz(); return 0; }'

# Gegenproben — nichts Gueltiges darf durchfallen.
laeuft "#1628: eigenes und GEERBTES Feld gehen durch" '3' 'import std.io;
type B = class { basisFeld: int64; }
type T = class extends B {
  a: int64;
  fn M(): int64 { return self.a + self.basisFeld; }
  fn Setz(): void { self.a := 1; self.basisFeld := 2; }
}
fn main(): int64 {
  var t: T := new T();
  t.Setz();
  PrintLn(IntToStr(t.M()));
  return 0;
}'

laeuft "#1628: ueber zwei Vererbungsstufen" '9' 'import std.io;
type A1 = class { tief: int64; }
type B1 = class extends A1 { }
type C1 = class extends B1 {
  fn Setz(): void { self.tief := 9; }
  fn Hol(): int64 { return self.tief; }
}
fn main(): int64 {
  var c: C1 := new C1();
  c.Setz();
  PrintLn(IntToStr(c.Hol()));
  return 0;
}'

# Eine Basisklasse aus einer ANDEREN Unit ist hier nicht entscheidbar — dort
# darf nichts gemeldet werden, sonst gaelte jedes geerbte Feld als Tippfehler.
cat > "$TMP/Demo/M4.lyx" <<'EOF'
unit Demo.M4;
pub type TBasis = class { geerbt: int64; }
EOF
laeuft "#1628: geerbtes Feld aus einer importierten Basisklasse faellt nicht durch" '4' 'import std.io;
import Demo.M4;
type TAbleitung = class extends TBasis {
  fn Setz(): void { self.geerbt := 4; }
  fn Hol(): int64 { return self.geerbt; }
}
fn main(): int64 {
  var t: TAbleitung := new TAbleitung();
  t.Setz();
  PrintLn(IntToStr(t.Hol()));
  return 0;
}'

echo
echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
