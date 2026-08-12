#!/usr/bin/env bash
# tests/grammar_hints_test.sh — #1353, #1354, #1350, #1356, #1357.
#
# Fünf Meldungen, die alle aus derselben Quelle stammen: gemessen wurde gegen
# eine ALTE Fassung der Grammatik (lyx-os/doku/ebnf.md, Version v0.9.3A,
# "Status: Draft"). Verbindlich ist ebnf.md in diesem Repository — sie trägt
# die Compiler-Version und ist gegen den Compiler geprüft.
#
# Die Sprachmittel gibt es, nur anders geschrieben:
#   #1353  Typparameter in SPITZEN Klammern, nicht in eckigen
#   #1354  Auffangfall heisst `case _ =>`, nicht `default =>`
#   #1350  StrNew(n) belegt n Byte; eine Kopie macht StrCopy(s, StrLen(s))
#   #1356  free(ptr, size) hat ZWEI Argumente; statt Hash* gibt es Map<K,V>
#   #1357  die Closure ist das Lambda; die nested fn bekommt keinen Static Link
#
# Dieser Test hält beides fest: dass die gültige Form trägt UND dass die
# ungültige eine Meldung bekommt, die den Weg nennt. Eine blosse
# Ablehnung ("expected (, got [") schickt den Leser sonst an die falsche
# Stelle — genau das ist fünfmal passiert.

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

hint() { # name, quelltext, erwartetes Textstueck der Meldung
  printf '%s\n' "$2" > "$TMP/r.lyx"; rm -f "$TMP/r"
  msg="$("$LYXC" --std-path="$ROOT" "$TMP/r.lyx" -o "$TMP/r" 2>&1)"
  if [ -f "$TMP/r" ]; then no "$1" "uebersetzt, statt zu melden"; return; fi
  case "$msg" in *"$3"*) ok "$1" ;; *) no "$1" "Meldung nennt '$3' nicht: $msg" ;; esac
}

# --- #1353 Generics ----------------------------------------------------------
out "generische Funktion mit spitzen Klammern" 'fn maxi<T>(a: T, b: T): T { if (a > b) { return a; } return b; }
fn main(): int64 { PrintInt(maxi<int64>(10, 20)); PrintLn(""); return 0; }' "20"

hint "eckige Typparameter nennen die spitze Form" 'fn maxi[T](a: T, b: T): T { return a; }
fn main(): int64 { return 0; }' "SPITZEN Klammern"

# --- #1354 match-Auffangfall -------------------------------------------------
out "case _ faengt auf" 'fn c(n: int64): int64 {
  match n {
    case 0 => { return 100; }
    case _ => { return 300; }
  }
  return 0;
}
fn main(): int64 { PrintInt(c(9)); PrintLn(""); return 0; }' "300"

hint "default nennt case _" 'fn c(n: int64): int64 {
  match n {
    case 0 => { return 100; }
    default => { return 300; }
  }
  return 0;
}
fn main(): int64 { return 0; }' "case _ =>"

# --- #1350 StrNew ------------------------------------------------------------
out "StrNew(n) belegt n Byte" 'fn main(): int64 {
  var a: pchar := StrNew(16);
  StrSetChar(a, 0, 72); StrSetChar(a, 1, 105); StrSetChar(a, 2, 0);
  PrintStr(a); PrintLn("");
  PrintInt(StrLen(a)); PrintLn("");
  return 0;
}' "Hi
2"

hint "Zeichenkette als Groesse wird gemeldet" 'fn main(): int64 { var a: pchar := StrNew("hello"); return StrLen(a); }' "Groesse in Byte"

# --- #1356 free / Map --------------------------------------------------------
out "free nimmt Adresse und Groesse" 'import std.alloc;
import std.io;
fn main(): int64 { var p: int64 := alloc(16); poke64(p, 7); PrintLn(IntToStr(peek64(p))); free(p, 16); return 0; }' "7"

hint "free mit einem Argument wird gemeldet" 'import std.alloc;
fn main(): int64 { var p: int64 := alloc(16); free(p); return 0; }' "falsche Argument-Anzahl"

out "Map<K,V> ist das Woerterbuch der Sprache" 'import std.io;
fn main(): int64 {
  var m: Map<int64, int64>;
  m[1] := 42;
  PrintLn(IntToStr(m[1]));
  PrintLn(IntToStr(len(m)));
  return 0;
}' "42
1"

# --- #1357 Closure -----------------------------------------------------------
out "Lambda liest die umgebende Variable" 'fn outer(): int64 {
  var x: int64 := 42;
  var inner := fn(): int64 { return x + 1; };
  return inner();
}
fn main(): int64 { PrintInt(outer()); PrintLn(""); return 0; }' "43"

# Die verschachtelte `fn` bekommt keinen Static Link — sie wird als gewoehnliche
# Funktion emittiert. Das wird gemeldet statt still 0 zu liefern; die Meldung
# ist der Beleg, dass hier NICHT falsch gerechnet wird.
hint "verschachtelte fn ohne Static Link wird gemeldet" 'fn outer(): int64 {
  var x: int64 := 42;
  fn inner(): int64 { return x + 1; }
  return inner();
}
fn main(): int64 { return outer(); }' "verschachtelte Funktion darf keine lokale Variable"

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
