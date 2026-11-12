#!/usr/bin/env bash
# tests/zuweisungsziel_test.sh — #2075: das Ziel einer Zuweisung muss etwas
# sein, in das sich schreiben laesst: ein Name, ein Feld oder ein Element
# (ebnf §12, AssignStmt = LValue ":=" Expr).
#
# Geprueft wurde das nie. `(a, b) := f();`, `f() := 3;`, `1 := 2;` und
# `a + b := 1;` uebersetzten fehlerfrei, und beide Codewege liessen die
# Zuweisung still fallen — ihre Kette kannte nur Name, Feld und Element und
# hatte kein `else`. `(t0, t1) := tupel();` liess t0 und t1 auf 0.
#
# Beide Seiten: jede andere Form wird abgewiesen, UND jede gueltige Form
# uebersetzt und SCHREIBT (gemessen am Wert, nicht am Uebersetzen).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

KOPF='unit main;
fn f(): int64 { return 1; }
fn f2(): [int64, int64] { return (1, 2); }'

abgewiesen() {  # $1 Anweisung, $2 erwarteter Meldungsteil
  printf '%s\nfn main(): int64 { var a: int64 := 0; var b: int64 := 0; %s return a; }\n' "$KOPF" "$1" > "$TMP/x.lyx"
  rm -f "$TMP/x"
  local msg; msg="$(cd "$ROOT" && "$LYXC" --std-path="$ROOT" "$TMP/x.lyx" -o "$TMP/x" 2>&1)"
  if [ -f "$TMP/x" ]; then nok "[$1] uebersetzt, statt abgewiesen zu werden"; return; fi
  case "$msg" in
    *"$2"*) ok "[$1] abgewiesen: $2" ;;
    *) nok "[$1] abgewiesen, aber ohne '$2': $(echo "$msg" | grep -m1 -i error)" ;;
  esac
}

echo "--- jede andere Form wird abgewiesen ---"
abgewiesen '(a, b) := f2();' 'Tupelform ist kein Zuweisungsziel'
abgewiesen '[a, b] := f2();' 'Tupelform ist kein Zuweisungsziel'
abgewiesen 'f() := 3;'       'Zuweisungsziel muss ein Name, ein Feld oder ein Element sein'
abgewiesen '1 := 2;'         'Zuweisungsziel muss ein Name, ein Feld oder ein Element sein'
abgewiesen 'a + b := 1;'     'Zuweisungsziel muss ein Name, ein Feld oder ein Element sein'
abgewiesen '"x" := 1;'       'Zuweisungsziel muss ein Name, ein Feld oder ein Element sein'

echo
echo "--- jede gueltige Form schreibt ---"
cat > "$TMP/gut.lyx" <<'EOF'
unit main;
import std.io;
type S = struct { x: int64; };
type K = class { w: int64;
  pub fn Setz(v: int64) { self.w := v; } };
var g: int64 := 0;
fn main(): int64 {
  var a: int64 := 0;
  a := 1;                       PrintLn(IntToStr(a));
  (a) := 2;                     PrintLn(IntToStr(a));   // geklammerter Name ist ein Name
  a += 5;                       PrintLn(IntToStr(a));
  g := 9;                       PrintLn(IntToStr(g));
  var s: S; s.x := 11;          PrintLn(IntToStr(s.x));
  var k: K := new K(); k.Setz(12); PrintLn(IntToStr(k.w));
  var arr: int64[3]; arr[1] := 13; PrintLn(IntToStr(arr[1]));
  var t0, t1 := (14, 15);       PrintLn(IntToStr(t0)); PrintLn(IntToStr(t1));
  return 0;
}
EOF
if ( cd "$ROOT" && "$LYXC" --std-path="$ROOT" "$TMP/gut.lyx" -o "$TMP/gut" ) >"$TMP/gut.log" 2>&1; then
  ist="$("$TMP/gut" | tr '\n' '|')"
  soll="1|2|7|9|11|12|13|14|15|"
  if [ "$ist" = "$soll" ]; then ok "Name, (Name), +=, Modulvariable, Feld, self.feld, Element, Entpacken: $soll"
  else nok "gueltige Formen: [$ist] statt [$soll]"; fi
else
  nok "gueltige Formen uebersetzen nicht: $(grep -m1 -i error "$TMP/gut.log")"
fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
