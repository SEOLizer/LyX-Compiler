#!/usr/bin/env bash
# tests/enum_con_test.sh — #1507.
#
# `con MASK: int64 := P.Read as int64 | P.Write as int64;` ergab still 0 —
# genau die Schreibweise, die man fuer Flagmasken erwartet. Jede Pruefung
# `(wert & MASK) != 0` war damit immer falsch, ohne dass etwas darauf
# hindeutete. Als globaler var-Startwert wurde derselbe Ausdruck sogar
# abgewiesen ("Startwert ist zur Uebersetzungszeit nicht bekannt").
#
# URSACHE: zwei Luecken derselben Art. Die Konstantenauswertung kannte weder
# den CAST (`x as int64`) noch den Enum-ZUGRIFF (`P.Read`) — und die
# Enum-Tabelle entstand ohnehin erst im Hauptdurchlauf, also NACH den
# `con`-Zeilen. Nicht falsch gerechnet, sondern zu spaet vorhanden: dieselbe
# Reihenfolgefrage wie bei den Konstanten selbst (#1338) und den
# Struct-Layouts (#1451).
#
# GEPRUEFT WIRD DER WERT. Lokale Variablen und der direkte Ausdruck waren
# schon immer richtig — ein Test, der nur die prueft, waere vor dem Fix gruen
# gewesen.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/p.lyx"; rm -f "$TMP/p"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p" >/dev/null 2>&1; then
    no "$1" "uebersetzt nicht: $("$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p" 2>&1 | grep -i error | head -1)"
    return
  fi
  got="$(timeout 30 "$TMP/p" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then no "$1" "ABSTURZ (rc=$rc)"; return; fi
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1" "'$got' erwartet '$3'"; fi
}

# ===========================================================================
# Problem 1 — con mit Enum-Wert
# ===========================================================================

out "#1507: Repro aus der Meldung" 'import std.io;
enum P { Read = 1, Write = 2, Exec = 4 }
con C1: int64 := P.Read as int64;
con C2: int64 := P.Read as int64 | P.Write as int64;
con C3: int64 := 1 | 2;
fn main(): int64 {
  PrintStr(IntToStr(C1)); PrintStr(" ");
  PrintStr(IntToStr(C2)); PrintStr(" ");
  PrintLn(IntToStr(C3));
  return 0;
}' "1 3 3"

# Die Maske im Einsatz — der Fall, an dem der stille Nullwert weh tut.
out "#1507: Flagmaske greift" 'import std.io;
enum P { Read = 1, Write = 2, Exec = 4 }
con MASK: int64 := P.Read as int64 | P.Write as int64;
fn main(): int64 {
  var w: int64 := 2;
  if ((w & MASK) != 0) { PrintStr("treffer "); } else { PrintStr("nichts "); }
  var e: int64 := 4;
  if ((e & MASK) != 0) { PrintLn("treffer"); } else { PrintLn("nichts"); }
  return 0;
}' "treffer nichts"

# Der Enum steht UNTER der Konstante: die Vorwaertsreferenz muss auch hier
# gelten, sonst ist es nur die halbe Reihenfolge.
out "#1507: Enum unter der con-Zeile" 'import std.io;
con FRUEH: int64 := Q.Zwei as int64;
enum Q { Eins = 1, Zwei = 2 }
fn main(): int64 { PrintLn(IntToStr(FRUEH)); return 0; }' "2"

# Rechnen mit Enum-Werten, ohne Cast und mit Schiebung.
out "#1507: Verschiebung und Summe" 'import std.io;
enum B { A = 1, B = 2, C = 3 }
con S1: int64 := (B.C as int64) << 4;
con S2: int64 := B.A as int64 + B.B as int64 * 10;
fn main(): int64 {
  PrintStr(IntToStr(S1)); PrintStr(" "); PrintLn(IntToStr(S2));
  return 0;
}' "48 21"

# ===========================================================================
# Problem 2 — als globaler var-Startwert
# ===========================================================================

out "#1507: globaler var-Startwert mit Enum" 'import std.io;
enum Permission { Read = 0x01, Write = 0x02 }
var perms: int64 := Permission.Read as int64;
var beide: int64 := Permission.Read as int64 | Permission.Write as int64;
fn main(): int64 {
  PrintStr(IntToStr(perms)); PrintStr(" "); PrintLn(IntToStr(beide));
  return 0;
}' "1 3"

# ===========================================================================
# Gegenproben
# ===========================================================================

# Lokal und direkt im Ausdruck waren immer richtig und muessen es bleiben.
out "#1507: lokal und direkt unveraendert" 'import std.io;
enum P { Read = 1, Write = 2, Exec = 4 }
fn main(): int64 {
  var l1: int64 := P.Read as int64;
  var l2: int64 := P.Read as int64 | P.Write as int64;
  PrintStr(IntToStr(l1)); PrintStr(" ");
  PrintStr(IntToStr(l2)); PrintStr(" ");
  PrintLn(IntToStr(P.Exec as int64));
  return 0;
}' "1 3 4"

# Ein Ausdruck, der WIRKLICH nicht uebersetzungszeit-konstant ist, muss
# weiterhin abgewiesen werden — sonst waere aus der Meldung ein stiller
# Falschwert geworden.
printf 'import std.io;\nfn f(): int64 { return 7; }\nvar g: int64 := f();\nfn main(): int64 { PrintLn(IntToStr(g)); return 0; }\n' > "$TMP/nk.lyx"
if "$LYXC" --std-path="$ROOT" "$TMP/nk.lyx" -o "$TMP/nk" >/dev/null 2>&1; then
  no "#1507: nicht-konstanter Startwert wird weiterhin abgewiesen" "uebersetzt klaglos"
else
  meldung="$("$LYXC" --std-path="$ROOT" "$TMP/nk.lyx" -o "$TMP/nk" 2>&1 | grep -ci "uebersetzungszeit")"
  if [ "$meldung" -ge 1 ]; then ok "#1507: nicht-konstanter Startwert wird weiterhin abgewiesen"
  else no "#1507: nicht-konstanter Startwert wird weiterhin abgewiesen" "andere Meldung"; fi
fi

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
