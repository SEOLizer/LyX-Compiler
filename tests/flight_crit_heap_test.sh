#!/usr/bin/env bash
# tests/flight_crit_heap_test.sh — #1529.
#
# `@flight_crit` verspricht laut Doku, dynamische Speicheranforderung in der
# Funktion zu unterbinden. Geprüft wurde das nie: `new`, `alloc()` und lokale
# Felder gingen klaglos durch.
#
# Der dritte Fall ist der unauffälligste und der teuerste: ein lokales Feld
# entsteht im Codegen per `mmap`, nicht auf dem Stapel. `var p: int64[100000]`
# fordert 800 KB an — bei JEDEM Aufruf, mitten im Regelzyklus. `@stack_limit`
# sieht davon nichts, weil es den Rahmen misst und der bleibt klein.
#
# GEPRÜFT WIRD DIE MELDUNG, nicht nur „übersetzt nicht": ein Test auf
# Fehlschlag wäre auch bei einem Tippfehler im Programm grün. Und neben jedem
# verbotenen Fall steht der erlaubte — sonst wäre eine Prüfung, die einfach
# jede `@flight_crit`-Funktion abweist, ebenfalls grün.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

meldet() { # name, quelltext, textstueck, erwartete anzahl
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  msg="$(timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then no "$1" "uebersetzt klaglos"; return; fi
  n="$(echo "$msg" | grep -cF "$3")"
  if [ "$n" -eq "${4:-1}" ]; then ok "$1"
  else no "$1" "$n Meldungen statt ${4:-1}: $(echo "$msg"|grep -i error|head -1)"; fi
}

laeuft() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    no "$1" "uebersetzt nicht: $(timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1|grep -i error|head -1)"
    return
  fi
  got="$(timeout 20 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then no "$1" "ABSTURZ rc=$rc"; return; fi
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1" "'$got' erwartet '$3'"; fi
}

# ===========================================================================
# Die drei Fälle aus der Meldung
# ===========================================================================

meldet "#1529: alloc() wird abgewiesen" 'import std.io;
import std.alloc;
@flight_crit
fn Regelzyklus(): int64 {
  var p: int64 := alloc(1024);
  poke64(p, 42);
  return peek64(p);
}
fn main(): int64 { PrintLn(IntToStr(Regelzyklus())); return 0; }' \
  "Speicheranforderung unter @flight_crit nicht erlaubt" 1

meldet "#1529: new wird abgewiesen" 'import std.io;
@flight_crit
fn Regelzyklus(): int64 {
  var q: int64 := new int64[10] as int64;
  return q;
}
fn main(): int64 { PrintLn(IntToStr(Regelzyklus())); return 0; }' \
  "new ist unter @flight_crit nicht erlaubt" 1

meldet "#1529: lokales Feld wird abgewiesen" 'import std.io;
@flight_crit
fn Regelzyklus(x: int64): int64 {
  var puffer: int64[1000];
  puffer[0] := x;
  return puffer[0];
}
fn main(): int64 { PrintLn(IntToStr(Regelzyklus(7))); return 0; }' \
  "lokales Feld unter @flight_crit nicht erlaubt" 1

# Jeder Fall genau EINMAL: der erste Anlauf lief zweimal ueber jeden Knoten
# (Kinder rekursiv UND die next-Kette) und meldete alles doppelt.
meldet "#1529: jede Stelle wird genau einmal gemeldet" 'import std.io;
import std.alloc;
@flight_crit
fn F(): int64 {
  var a: int64 := alloc(8);
  var b: int64 := alloc(8);
  return a + b;
}
fn main(): int64 { PrintLn(IntToStr(F())); return 0; }' \
  "Speicheranforderung unter @flight_crit nicht erlaubt" 2

# Auch tief im Rumpf, nicht nur auf oberster Ebene.
meldet "#1529: auch in Schleife und Verzweigung" 'import std.io;
import std.alloc;
@flight_crit
fn F(n: int64): int64 {
  var s: int64 := 0;
  var i: int64 := 0;
  while (i < n) {
    if (i > 2) {
      var p: int64 := alloc(16);
      s := s + p;
    }
    i := i + 1;
  }
  return s;
}
fn main(): int64 { PrintLn(IntToStr(F(5))); return 0; }' \
  "Speicheranforderung unter @flight_crit nicht erlaubt" 1

# ===========================================================================
# Was erlaubt bleiben MUSS
# ===========================================================================

# Ohne Speicheranforderung ist eine @flight_crit-Funktion voellig normal —
# sonst waere eine Pruefung, die pauschal abweist, auch "gruen".
laeuft "#1529: Rechnen ohne Heap geht durch" 'import std.io;
@flight_crit
fn Rechne(x: int64, y: int64): int64 {
  var s: int64 := x + y;
  var i: int64 := 0;
  while (i < 3) { s := s * 2; i := i + 1; }
  return s;
}
fn main(): int64 { PrintLn(IntToStr(Rechne(3, 4))); return 0; }' "56"

# Skalare Locals, Parameter und Rueckgaben bleiben unberuehrt.
laeuft "#1529: skalare Locals unveraendert" 'import std.io;
@flight_crit
fn F(a: f64, b: f64): f64 {
  var q: f64 := a * b;
  var r: int64 := 7;
  return q + r;
}
fn main(): int64 { PrintLn(FloatToStr(F(2.0, 3.0), 2)); return 0; }' "13.00"

# Der Fliesskomma-Teil des Attributs (#1140) muss weiter greifen: Division
# durch null bricht zur Laufzeit ab. Das ist der Teil, der laut Meldung
# funktionierte — er darf durch die neue Pruefung nicht verlorengehen.
cat > "$TMP/fpe.lyx" <<'LYXEOF'
import std.io;
@flight_crit
fn D(a: f64, b: f64): f64 { return a / b; }
fn main(): int64 {
  PrintLn(FloatToStr(D(1.0, 0.0), 2));
  return 0;
}
LYXEOF
if timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/fpe.lyx" -o "$TMP/fpe" >/dev/null 2>&1; then
  meldung="$(timeout 20 "$TMP/fpe" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ] && echo "$meldung" | grep -qi "flight_crit"; then
    ok "#1529: FPU-Pruefung des Attributs bleibt wirksam"
  else
    no "#1529: FPU-Pruefung des Attributs bleibt wirksam" "rc=$rc '$meldung'"
  fi
else
  no "#1529: FPU-Pruefung des Attributs bleibt wirksam" "uebersetzt nicht"
fi

# OHNE das Attribut ist alles davon erlaubt — die Pruefung darf nicht auf
# gewoehnliche Funktionen durchschlagen.
laeuft "#1529: ohne Attribut bleibt alles erlaubt" 'import std.io;
import std.alloc;
fn F(): int64 {
  var p: int64 := alloc(64);
  poke64(p, 5);
  var feld: int64[10];
  feld[0] := peek64(p);
  var q: int64 := new int64[4] as int64;
  return feld[0] + (q - q);
}
fn main(): int64 { PrintLn(IntToStr(F())); return 0; }' "5"

# Eine andere Funktion darf weiterhin allokieren, auch wenn sie von einer
# @flight_crit-Funktion gerufen wird: die Pruefung sieht nur diesen Rumpf.
# Das ist eine bewusste Grenze und steht so im Quelltext.
laeuft "#1529: Aufruf einer fremden Funktion bleibt unbeanstandet" 'import std.io;
import std.alloc;
fn Hilf(): int64 {
  var p: int64 := alloc(8);
  poke64(p, 9);
  return peek64(p);
}
@flight_crit
fn Regel(): int64 { return Hilf(); }
fn main(): int64 { PrintLn(IntToStr(Regel())); return 0; }' "9"

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
