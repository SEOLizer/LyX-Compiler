#!/usr/bin/env bash
# tests/ebnf_claims_test.sh — #1232, #1234 und #1245.
#
# ebnf.md sagte an drei Stellen etwas anderes zu, als der Compiler traegt. Das
# ist keine Kleinigkeit: wer nachschlaegt, richtet sich danach. In einem der
# Faelle hatte sich der Bestand bereits nach dem Compiler gerichtet und schrieb
# ueberall Bloecke, waehrend die Grammatik eine Anweisungsfolge versprach.
#
# #1232 (a) SwitchCase/SwitchDefault verlangen einen BLOCK, nicht `{ Statement }`.
#       (b) ConstPipeExpr gibt es nicht — der Pipe-Operator ist im
#           Konstantenausdruck ausdruecklich gesperrt.
# #1234 `check(...)` existiert nicht; `panic` und
# (`VerifyIntegrity()` gab es damals ebenfalls nicht — seit #1363 schon.)
#       `assert` dagegen schon.
# #1245 `public` ist eine gleichwertige Schreibweise zu `pub`. Sie war bei
#       MemberVisibility verzeichnet, bei Visibility nicht.
#
# Der Test misst die Zusagen der Grammatik am Compiler. Eine Doku-Korrektur
# ohne solchen Test verrottet beim naechsten Sprachschritt genauso wie die
# Angaben, die hier gerade richtiggestellt wurden.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
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
  got="$(timeout 20 "$TMP/c" 2>&1)"; rc=$?
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

# --- Die Grammatik enthaelt die Korrekturen ------------------------------
# Ohne diese Pruefungen koennte der Text wieder auseinanderlaufen, ohne dass
# es jemandem auffaellt.

grep -q 'SwitchCase          = "case" ConstExpr ":" Block ;' "$ROOT/ebnf.md" \
  && ok "ebnf.md: SwitchCase verlangt einen Block" \
  || no "ebnf.md SwitchCase" "Regel nicht wie erwartet"

grep -q 'ConstExpr                 = ConstNullCoalesceExpr ;' "$ROOT/ebnf.md" \
  && ok "ebnf.md: ConstExpr ohne Pipe" \
  || no "ebnf.md ConstExpr" "Regel nicht wie erwartet"

if grep -qE '^CheckExpr|^VerifyIntegrityCall' "$ROOT/ebnf.md"; then
  no "ebnf.md BuiltinCall" "check/VerifyIntegrity stehen noch als Regel"
else
  ok "ebnf.md: check und VerifyIntegrity sind nicht mehr verzeichnet"
fi

grep -q 'Visibility          = ( "pub" | "public" ) ;' "$ROOT/ebnf.md" \
  && ok "ebnf.md: Visibility kennt public" \
  || no "ebnf.md Visibility" "Regel nicht wie erwartet"

# --- #1232a: case verlangt einen Block -----------------------------------

rejects "case ohne Block wird abgewiesen" 'import std.io;
fn main(): int64 {
  var x: int64 := 1;
  switch (x) { case 1: PrintLn("a"); break; default: break; }
  return 0;
}' "expected {"

out "case mit Block laeuft" 'import std.io;
fn main(): int64 {
  var x: int64 := 2;
  switch (x) {
    case 1: { PrintLn("eins"); break; }
    case 2: { PrintLn("zwei"); break; }
    default: { PrintLn("sonst"); break; }
  }
  return 0;
}' "zwei"

# --- #1232b: kein Pipe im Konstantenausdruck -----------------------------

rejects "Pipe im Konstantenausdruck wird abgewiesen" 'import std.io;
fn Dbl(v: int64): int64 { return v * 2; }
con C: int64 := 5 |> Dbl;
fn main(): int64 { PrintLn(IntToStr(C)); return 0; }' "pipe-forward not allowed in const expression"

# Gegenprobe: zur Laufzeit gibt es den Operator unveraendert.
out "Pipe zur Laufzeit unveraendert" 'import std.io;
fn Dbl(v: int64): int64 { return v * 2; }
fn main(): int64 { PrintLn(IntToStr(5 |> Dbl)); return 0; }' "10"

# --- #1234: check und VerifyIntegrity gibt es nicht ----------------------

rejects "check() gibt es nicht" 'import std.io;
fn main(): int64 { check(1 == 1); return 0; }' "undefined function .check."

# #1363: VerifyIntegrity() GIBT es seit 1.0.17J. Als #1234 aufgenommen wurde,
# war der Builtin nicht angebunden und die Grammatik versprach ihn trotzdem —
# die Korrektur bestand damals darin, die Zusage zu streichen. Jetzt ist der
# Weg andersherum gegangen: der Builtin ist verdrahtet (er prueft die
# @redundant-Globalen ueber ihren Voter), also darf der Aufruf nicht mehr
# abgewiesen werden. Die Grammatik fuehrt ihn weiterhin nicht als eigene Regel —
# er ist ein gewoehnlicher Aufruf, kein Sprachkonstrukt.
out "VerifyIntegrity() ist aufrufbar und meldet Uebereinstimmung" 'import std.io;
@redundant var t: int64;
fn main(): int64 { t := 5; PrintLn(IntToStr(VerifyIntegrity())); return 0; }' "0"

# Gegenprobe: panic und assert sind vorhanden — die Grammatik fuehrt sie zu
# Recht, und die Korrektur darf sie nicht mit entfernt haben.
out "assert und panic sind vorhanden" 'import std.io;
fn main(): int64 {
  assert(1 == 1);
  PrintLn("assert ok");
  return 0;
}' "assert ok"

# --- #1245: public ist gleichwertig zu pub -------------------------------

out "public fn auf oberster Ebene" 'import std.io;
public fn f(): int64 { return 3; }
pub fn g(): int64 { return 4; }
fn main(): int64 {
  PrintLn(IntToStr(f()));
  PrintLn(IntToStr(g()));
  return 0;
}' "3
4"

echo
echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
