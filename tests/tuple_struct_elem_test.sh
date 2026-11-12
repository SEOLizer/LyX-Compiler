#!/usr/bin/env bash
# tests/tuple_struct_elem_test.sh — #1122: Struct-Elemente in Tupeln.
#
# `var a, b := F();` mit `fn F(): (S, int64)` lieferte fuer `a.v` still `0`,
# waehrend das skalare Element korrekt ankam. Kein Muellwert wie bei #1121,
# sondern konstant 0 — und ohne jede Meldung.
#
# Der ZEIGER kam die ganze Zeit korrekt an (tests/wp04_geo_tuple.lyx prueft
# genau das und war gruen). Was fehlte, war der TYP am entpackten Namen: die
# Schreibweise `var a, b := F();` traegt keine Annotation, der Slot blieb also
# typlos, `cg_objClassIdx` fand keine Klasse, der Feldzugriff bekam Offset -1
# und `cg_genFieldLoad` nullte rax. Ein Musterfall von stillem Default.
#
# Behoben ueber eine Registry der Tupel-Elementtypen je Funktion bzw. je
# gemangelter Methode (`cg_registerTupleRet`/`cg_findTupleRet`), gefuellt im
# selben Vorabpass, der die uebrigen Rueckgabetypen sammelt.
#
# Geprueft wird der WERT des Feldes. Ein Test auf Uebersetzbarkeit oder auf
# "Zeiger ungleich null" waere die ganze Zeit gruen gewesen.

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
    *) echo "FAIL $1: Meldung ohne '$3'"; FAIL=$((FAIL+1)) ;;
  esac
}

K='import src.std.io;
type S = struct { v: int64; };'

# --- Der Repro aus dem Issue: jede Position ------------------------------
out "Repro: (S, int64)" "$K
fn F(): (S, int64) { var s: S; s.v := 3; return (s, 4); }
fn main(): int64 { var a, b := F(); PrintLn(a.v); PrintLn(b); return 0; }" '3
4'

out "(int64, S)" "$K
fn F(): (int64, S) { var s: S; s.v := 3; return (4, s); }
fn main(): int64 { var a, b := F(); PrintLn(a); PrintLn(b.v); return 0; }" '4
3'

out "(S, S)" "$K
fn F(): (S, S) { var s: S; s.v := 3; var t: S; t.v := 5; return (s, t); }
fn main(): int64 { var a, b := F(); PrintLn(a.v); PrintLn(b.v); return 0; }" '3
5'

# Mehrere Felder: die Offsets muessen stimmen, nicht nur das erste.
out "Struct mit zwei Feldern" "$K
type T2 = struct { v: int64; w: int64; };
fn F(): (T2, T2) { var s: T2; s.v := 3; s.w := 9; var t: T2; t.v := 5; t.w := 1; return (s, t); }
fn main(): int64 { var a, b := F(); PrintLn(a.v); PrintLn(a.w); PrintLn(b.v); PrintLn(b.w); return 0; }" '3
9
5
1'

# --- Klassen: Feld UND Methode auf dem entpackten Wert --------------------
out "Klasse im Tupel, Feld und Methode" "$K
type C = class { v: int64; fn G(): int64 { return self.v * 2; } };
fn F(): (C, int64) { var c: C := new C(); c.v := 3; return (c, 4); }
fn main(): int64 { var a, b := F(); PrintLn(a.v); PrintLn(a.G()); PrintLn(b); return 0; }" '3
6
4'

# Schreibzugriff auf dem entpackten Struct.
out "Schreiben auf dem entpackten Struct" "$K
fn F(): (S, int64) { var s: S; s.v := 3; return (s, 4); }
fn main(): int64 { var a, b := F(); a.v := 7; PrintLn(a.v); return 0; }" '7'

# --- Methoden als Quelle des Tupels (#1121) -------------------------------
out "Methode liefert (S, int64)" "$K
type C = class { n: int64; fn F(): (S, int64) { var s: S; s.v := 3; return (s, 4); } };
fn main(): int64 { var c: C := new C(); var a, b := c.F(); PrintLn(a.v); PrintLn(b); return 0; }" '3
4'

# Geerbte Methode: der Rueckgabetyp steht beim Elternteil (#1120).
out "geerbte Methode liefert (S, int64)" "$K
type A = class { n: int64; fn F(): (S, int64) { var s: S; s.v := 3; return (s, 4); } };
type B = class extends A { };
fn main(): int64 { var b: B := new B(); var x, y := b.F(); PrintLn(x.v); PrintLn(y); return 0; }" '3
4'

out "static-Methode liefert (S, int64)" "$K
type C = class { n: int64; static fn F(): (S, int64) { var s: S; s.v := 3; return (s, 4); } };
fn main(): int64 { var a, b := C.F(); PrintLn(a.v); PrintLn(b); return 0; }" '3
4'

# --- Gegenproben ---------------------------------------------------------
out "skalares Tupel unveraendert" "$K
fn F(): (int64, int64) { return (3, 6); }
fn main(): int64 { var a, b := F(); PrintLn(a); PrintLn(b); return 0; }" '3
6'

# Durchgereichtes Tupel: die Merkung darf den Weg nicht stoeren.
out "Tupel durchgereicht" "$K
fn F(a: int64, b: int64): (int64, int64) { return (a, b); }
fn G(): (int64, int64) { return F(3, 4); }
fn main(): int64 { var a, b := G(); PrintLn(a + b); return 0; }" '7'

out "Struct als gewoehnlicher Rueckgabewert unveraendert" "$K
fn F(): S { var s: S; s.v := 3; return s; }
fn main(): int64 { var s: S := F(); PrintLn(s.v); return 0; }" '3'

out "gemischt: pchar im Tupel" "$K
fn F(): (pchar, int64) { return (\"hi\"c, 7); }
fn main(): int64 { var s, n := F(); PrintStr(s); PrintLn(n); return 0; }" 'hi7'

# --- Stelligkeit: genau zwei (ebnf.md §7, §20.1) -------------------------
# Die Grammatik nannte bis 1.0.13P beliebig viele Elemente, der Compiler wies
# ab drei ab. Jetzt sagen beide dasselbe; die Meldung bleibt.
fails "drei Elemente werden abgewiesen" "$K
fn F(): (int64, int64, int64) { return (1, 2, 3); }
fn main(): int64 { var a, b := F(); PrintLn(a); return 0; }" "mehr als zwei Elementen"

fails "vier Elemente werden abgewiesen" "$K
fn F(): (int64, int64, int64, int64) { return (1, 2, 3, 4); }
fn main(): int64 { var a, b := F(); PrintLn(a); return 0; }" "mehr als zwei Elementen"

# Die eckige Schreibweise bleibt gueltig (der Bestand benutzt sie).
out "eckige Schreibweise unveraendert" "$K
fn F(): [int64, int64] { return [3, 6]; }
fn main(): int64 { var a, b := F(); PrintLn(a + b); return 0; }" '9'

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
test "$FAIL" -eq 0
