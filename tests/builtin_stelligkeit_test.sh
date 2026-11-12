#!/usr/bin/env bash
# tests/builtin_stelligkeit_test.sh — #2088, #2012, #2086: Aufrufe, die sema
# klaglos durchliess und die zur Laufzeit abstuerzten oder das Falsche taten.
#
#   #2088  Builtins ausserhalb der Zeichenketten-Familie hatten keine
#          Stelligkeitspruefung: `ArgvGet(1)` uebersetzte und stuerzte ab,
#          `GetArgC(7)` verwarf die 7 still. Die Tabelle in sema
#          (_builtinMinArity, _builtinIstNullstellig) wird hier EINTRAG FUER
#          EINTRAG gemessen — ein neuer Eintrag ist damit automatisch geprueft.
#   #2012  Ein Name, den es als Builtin UND als pub fn gibt (StrTrim, StrFind,
#          StrSplit, FloatToStr, ...), entging beiden Pruefungen.
#   #2086  `var alloc: int64 := 0; alloc(64)` uebersetzte — ein Wert ist keine
#          Funktion; der Codegen las {fnPtr, env} ab Adresse 0.
#
# Beide Seiten werden gemessen: die falsche Form wird abgewiesen, die richtige
# uebersetzt UND liefert den richtigen Wert.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

uebersetze() {  # quelltext -> rc; Meldungen in $TMP/log
  printf '%s\n' "$1" > "$TMP/c.lyx"; rm -f "$TMP/c"
  ( cd "$ROOT" && timeout 120 "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" ) >"$TMP/log" 2>&1
}

meldet() {  # name, quelltext, erwartete meldung
  if uebersetze "$2"; then nok "$1: uebersetzt, sollte abgewiesen werden"; return; fi
  if grep -q "$3" "$TMP/log"; then ok "$1 (abgewiesen)"
  else nok "$1: abgewiesen, aber nicht mit '$3': $(grep -m1 -i error "$TMP/log")"; fi
}

liefert() {  # name, quelltext, erwartete ausgabe (Zeilen mit |), [argumente]
  if ! uebersetze "$2"; then nok "$1: wird abgewiesen: $(grep -m1 -i error "$TMP/log")"; return; fi
  local ist; ist="$( (cd "$TMP" && timeout 10 ./c ${4:-} 2>&1) | tr '\n' '|')"
  if [ "$ist" = "$3" ]; then ok "$1 = $3"; else nok "$1: [$ist] statt [$3]"; fi
}

echo "--- #2088: die Faelle aus dem Issue ---"
meldet "ArgvGet(1)" 'fn main(): int64 { var a: pchar := ArgvGet(1); return 0; }' "zu wenige Argumente im Aufruf von 'ArgvGet'"
meldet "GetArgC(7)" 'fn main(): int64 { var b: int64 := GetArgC(7); return 0; }' "falsche Argument-Anzahl im Aufruf von 'GetArgC'"
liefert "ArgvGet(GetArgV(), 1) und GetArgC() mit zwei Argumenten" 'import std.io;
fn main(): int64 {
  var a: pchar := ArgvGet(GetArgV(), 1); var b: pchar := ArgvGet(GetArgV(), 2);
  PrintLn(a); PrintLn(b); PrintLn(IntToStr(GetArgC()));
  return 0;
}' "hallo|welt|3|" "hallo welt"

echo
echo "--- #2088: jeder Eintrag der Tabelle, beide Seiten ---"
# Die Tabelle wird aus sema gelesen. Zu wenige Argumente: gemeldet. Genau die
# Mindestzahl: keine Stelligkeitsmeldung fuer diesen Namen. Ein Eintrag, der
# gueltigen Code abwiese, faellt damit hier auf — nicht erst im Bestand.
TAB="$(awk '/fn _builtinMinArity/,/^  }/' "$ROOT/src/sema.lyx" | grep -oE '"[A-Za-z_0-9]+"c, [0-9]+\)\)[[:space:]]*\{ return [0-9]+' | sed -E 's/"([^"]+)"c, [0-9]+\)\)[[:space:]]*\{ return ([0-9]+)/\1 \2/')"
n=0; tf=0
args() { local k="$1" s="" i=0; while [ "$i" -lt "$k" ]; do [ -n "$s" ] && s="$s, "; s="${s}0"; i=$((i+1)); done; echo "$s"; }
while read -r name min; do
  [ -z "$name" ] && continue
  n=$((n+1))
  if [ "$min" -gt 0 ]; then
    if uebersetze "fn main(): int64 { $name($(args $((min-1)))); return 0; }" || ! grep -q "zu wenige Argumente im Aufruf von '$name'" "$TMP/log"; then
      nok "$name mit $((min-1)) statt $min Argumenten wird nicht gemeldet"; tf=$((tf+1))
    fi
  fi
  uebersetze "fn main(): int64 { if (GetArgC() > 99) { $name($(args "$min")); } return 0; }"
  if grep -q "Argumente im Aufruf von '$name'\|Argument-Anzahl im Aufruf von '$name'" "$TMP/log"; then
    nok "$name mit $min Argumenten wird abgewiesen"; tf=$((tf+1))
  fi
done <<< "$TAB"
if [ "$n" -lt 100 ]; then nok "Tabelle nicht gelesen ($n Eintraege)"
elif [ "$tf" -eq 0 ]; then ok "$n Eintraege: zu wenige gemeldet, genau genug uebersetzt"; fi

NULL="$(awk '/fn _builtinIstNullstellig/,/^  }/' "$ROOT/src/sema.lyx" | grep -oE '"[A-Za-z_0-9]+"c' | tr -d '"' | sed 's/c$//')"
n=0; tf=0
for name in $NULL; do
  n=$((n+1))
  if uebersetze "fn main(): int64 { $name(1); return 0; }" || ! grep -q "Argument-Anzahl im Aufruf von '$name'" "$TMP/log"; then
    nok "$name(1) wird nicht gemeldet"; tf=$((tf+1))
  fi
  uebersetze "fn main(): int64 { if (GetArgC() > 99) { $name(); } return 0; }"
  if grep -q "Argument-Anzahl im Aufruf von '$name'" "$TMP/log"; then nok "$name() wird abgewiesen"; tf=$((tf+1)); fi
done
if [ "$n" -lt 8 ]; then nok "Nullstellige nicht gelesen ($n)"
elif [ "$tf" -eq 0 ]; then ok "$n nullstellige Builtins: mit Argument gemeldet, ohne uebersetzt"; fi

# Ueberzaehlige Argumente bleiben erlaubt (#1967) — StrCopy(s, n) ist Bestand.
liefert "StrCopy mit zwei Argumenten bleibt erlaubt" 'import std.io;
fn main(): int64 { PrintLn(StrCopy("abc", 3)); return 0; }' "abc|"

echo
echo "--- #2012: Doppelname Builtin + pub fn ---"
S='import std.io;
import std.string;'
meldet "StrTrim() ohne Argument" "$S
fn main(): int64 { var t: pchar := StrTrim(); return 0; }" "falsche Argument-Anzahl im Aufruf von 'StrTrim'"
meldet "StrFind mit einem Argument" "$S
fn main(): int64 { var t: int64 := StrFind(\"a\"); return 0; }" "falsche Argument-Anzahl im Aufruf von 'StrFind'"
meldet "StrSplit mit einem Argument" "$S
fn main(): int64 { var t: int64 := StrSplit(\"a\"); return 0; }" "falsche Argument-Anzahl im Aufruf von 'StrSplit'"
meldet "FloatToStr ohne Argument" "$S
fn main(): int64 { PrintLn(FloatToStr()); return 0; }" "Argument"
# Gegenseite: jede gueltige Fassung geht und liefert ihren Wert.
liefert "StrTrim(s) — Builtin-Form" "$S
fn main(): int64 { PrintLn(\"[\" + StrTrim(\"  ab  \") + \"]\"); return 0; }" "[ab]|"
liefert "StrFind(h, n) — Builtin-Form" "$S
fn main(): int64 { PrintLn(IntToStr(StrFind(\"abcde\", \"cd\"))); return 0; }" "2|"
liefert "StrSplit mit vier Argumenten — Unit-Funktion aus std/string.lyx" "$S
import std.alloc;
fn main(): int64 { var out: int64 := alloc(80); PrintLn(IntToStr(StrSplit(\"a,b,c\", \",\", out, 10))); return 0; }" "3|"
# Gegenprobe aus dem Issue: die reine pub fn bleibt gemeldet bzw. erlaubt.
meldet "StrTrimWhitespace mit einem Argument (nur pub fn)" "$S
fn main(): int64 { var t: pchar := StrTrimWhitespace(\"a\"); return 0; }" "falsche Argument-Anzahl im Aufruf von 'StrTrimWhitespace'"
liefert "StrTrimWhitespace(d, s) bleibt erlaubt" "$S
import std.alloc;
fn main(): int64 { var d: pchar := alloc(16) as pchar; PrintLn(\"[\" + StrTrimWhitespace(d, \" x \") + \"]\"); return 0; }" "[x]|"

echo
echo "--- #2086: Aufruf eines Wertes ---"
meldet "int64-Variable verdeckt alloc (Fall aus dem Issue)" 'import std.alloc;
fn f(): int64 {
  var alloc: int64 := 0;
  var p: int64 := alloc(64);
  return p;
}
fn main(): int64 { PrintInt(f()); return 0; }' "Aufruf eines Wertes, der keine Funktion ist: 'alloc'"
meldet "int64-Parameter wird gerufen" 'fn g(n: int64): int64 { return n(3); }
fn main(): int64 { return g(1); }' "Aufruf eines Wertes, der keine Funktion ist: 'n'"
meldet "pchar-Variable wird gerufen" 'fn main(): int64 { var s: pchar := "x"; s(); return 0; }' "Aufruf eines Wertes, der keine Funktion ist: 's'"
# Gegenseite: Funktionszeiger, Closure und der umbenannte Fall rufen weiter.
liefert "Funktionszeiger, Closure und umbenannte Variable" 'import std.io;
import std.alloc;
type F = fn(x: int64): int64;
fn plus1(x: int64): int64 { return x + 1; }
fn nimm(f: F): int64 { return f(40); }
fn main(): int64 {
  var g: F := plus1;
  var k: int64 := 5;
  var c := fn(x: int64): int64 { return x + k; };
  var n: int64 := 0;
  var p: int64 := alloc(64);
  PrintLn(IntToStr(g(1))); PrintLn(IntToStr(nimm(plus1))); PrintLn(IntToStr(c(2)));
  if (p != 0) { PrintLn("alloc"); }
  return n;
}' "2|41|7|alloc|"

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
