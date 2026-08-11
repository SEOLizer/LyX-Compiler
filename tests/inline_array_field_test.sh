#!/usr/bin/env bash
# tests/inline_array_field_test.sh — statisches Array als Struct-Feld (Issue #1052).
#
# `feld: [N]T` in einer Struktur war nur halb umgesetzt: das Layout gab dem Feld
# einen einzigen 8-Byte-Slot, und beim Indizieren wurde der FELDINHALT als
# Zieladresse genommen. Bei genulltem Speicher hiess das Adresse 0 — jedes
# Schreiben segfaultete, das Folgefeld lag ausserdem auf den Arraydaten.
#
# Ein inline liegendes Array hat keinen Zeiger: sein Feldname bezeichnet die
# ADRESSE. Geprüft wird deshalb beides — dass Schreiben und Lesen zusammen
# passen, und dass die Nachbarfelder unberührt bleiben. Ein Test, der nur
# schreibt und zurückliest, würde eine Überlappung nicht bemerken.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

run() { # name, quelltext, erwarteter exit
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    echo "FAIL $1: uebersetzt nicht"; FAIL=$((FAIL+1)); return
  fi
  timeout 5 "$TMP/c" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq "$3" ]; then echo "PASS $1"; PASS=$((PASS+1))
  else echo "FAIL $1: exit=$rc erwartet $3"; FAIL=$((FAIL+1)); fi
}

run "schreiben und zuruecklesen" 'type P = struct { count: int64; items: [4]int64; };
fn main(): int64 { var p: P;
  p.items[0] := 7; p.items[3] := 9;
  if (p.items[0] != 7) { return 1; }
  if (p.items[3] != 9) { return 2; }
  return 42; }' 42

# Der eigentliche Layout-Nachweis: das Feld HINTER dem Array darf nicht
# ueberschrieben werden. Mit dem alten 8-Byte-Slot lag `tail` auf items[1].
run "Folgefeld bleibt unberuehrt" 'type P = struct { count: int64; items: [4]int64; tail: int64; };
fn main(): int64 { var p: P;
  p.count := 1; p.tail := 5;
  p.items[0] := 7; p.items[1] := 8; p.items[2] := 9; p.items[3] := 10;
  if (p.count != 1) { return 1; }
  if (p.tail != 5) { return 2; }
  if (p.items[1] != 8) { return 3; }
  return 42; }' 42

run "Klassenzeiger als Element" 'type Node = class { value: int64; };
type Pool = struct { count: int64; items: [4]Node; };
fn main(): int64 { var n: Node := new Node(); n.value := 42;
  var p: Pool; p.items[0] := n; p.count := 1;
  var q: Node := p.items[0];
  if (p.count != 1) { return 1; }
  return q.value; }' 42

# Schmale Elementbreiten: Schrittweite und Zugriffsbreite muessen zusammenpassen.
run "uint8-Elemente" 'type B = struct { n: int64; bytes: [8]uint8; tail: int64; };
fn main(): int64 { var b: B;
  b.n := 3; b.tail := 4;
  b.bytes[0] := 200; b.bytes[7] := 5;
  if (b.bytes[0] != 200) { return 1; }
  if (b.bytes[7] != 5) { return 2; }
  if (b.tail != 4) { return 3; }
  return 42; }' 42

run "uint16-Elemente" 'type W = struct { w: [4]uint16; tail: int64; };
fn main(): int64 { var x: W;
  x.tail := 9;
  x.w[0] := 65000; x.w[3] := 1234;
  if (x.w[0] != 65000) { return 1; }
  if (x.w[3] != 1234) { return 2; }
  if (x.tail != 9) { return 3; }
  return 42; }' 42

# Ein gewoehnliches Zeigerfeld darf NICHT als inline-Array behandelt werden.
run "Array<T>-Feld unveraendert" 'import std.alloc;
type H = struct { data: int64; };
fn main(): int64 { var h: H;
  h.data := alloc(64);
  poke64(h.data, 42);
  return peek64(h.data); }' 42

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
