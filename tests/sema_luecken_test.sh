#!/usr/bin/env bash
# tests/sema_luecken_test.sh — #1967 und #1952: Pruefungen, die nicht griffen.
#
# Drei Befunde aus der Nachpruefung geschlossener Issues, alle nachgemessen:
#
#   1. #1967 / #1883: die ZUWEISUNG ueber Enum-Grenzen wurde gemeldet, der
#      VERGLEICH nicht. `Fahrwerk.Ausgefahren == Triebwerk.Laeuft` uebersetzte
#      und war WAHR, weil beide Varianten denselben Ordinalwert tragen. Ein
#      Programm, das uebersetzt, laeuft und falsch entscheidet.
#
#      Woertlich dieselbe Klasse wie #1956 bei den Einheitentypen: dort fehlten
#      die Vergleichsoperatoren in der Aufzaehlung von _checkUtypeBinop.
#
#   2. #1967 / #1264: die Stelligkeitspruefung nimmt Builtins ausdruecklich
#      aus. `StrCharAt("abc")` mit einem Argument erzeugte einen
#      Speicherauszug — der fehlende Wert wird aus dem Register gelesen, in
#      dem gerade etwas anderes steht.
#
#   3. #1952: `@integrity` vor `unit`. SPEC.md nannte beide Modi einen No-op;
#      gemessen wirkt `scrubbed` und `software_lockstep` wird abgewiesen. Das
#      ist begruendet — hier festgehalten, damit es so bleibt.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

geht() {   # name, quelltext
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ( cd "$ROOT" && "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" ) >/dev/null 2>&1; then
    echo "PASS $1"; PASS=$((PASS+1))
  else
    echo "FAIL $1: wird abgewiesen, sollte aber gehen"; FAIL=$((FAIL+1))
    ( cd "$ROOT" && "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1 ) | grep -i error | head -1
  fi
}

meldet() {  # name, quelltext, erwartete meldung
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  got=$( cd "$ROOT" && "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1 )
  if ! echo "$got" | grep -q "$3"; then
    echo "FAIL $1: nicht gemeldet — '$(echo "$got"|grep -i error|head -1)'"; FAIL=$((FAIL+1)); return
  fi
  if [ -f "$TMP/c" ]; then
    echo "FAIL $1: gemeldet, aber trotzdem uebersetzt"; FAIL=$((FAIL+1)); return
  fi
  echo "PASS $1 (abgewiesen)"; PASS=$((PASS+1))
}

E='import std.io;
enum Fahrwerk  { Eingefahren, Ausgefahren }
enum Triebwerk { Aus, Laeuft }'

echo "--- #1967: Vergleich zweier verschiedener Enums ---"

meldet "Gleichheit ueber Enum-Grenzen" "$E
fn main(): int64 {
    if (Fahrwerk.Ausgefahren == Triebwerk.Laeuft) { PrintStrLn(\"x\"); }
    return 0;
}" "Vergleich zweier verschiedener Enums"

# Ungleichheit und Ordnung stellen dieselbe Typfrage. Eine Aufzaehlung, die nur
# == kennt, waere die Luecke von #1956 in neuer Gestalt.
meldet "Ungleichheit ebenso" "$E
fn main(): int64 {
    if (Fahrwerk.Ausgefahren != Triebwerk.Laeuft) { PrintStrLn(\"x\"); }
    return 0;
}" "Vergleich zweier verschiedener Enums"

meldet "Ordnungsvergleich ebenso" "$E
fn main(): int64 {
    if (Fahrwerk.Ausgefahren < Triebwerk.Laeuft) { PrintStrLn(\"x\"); }
    return 0;
}" "Vergleich zweier verschiedener Enums"

# Die Meldung muss den Ausweg nennen.
meldet "die Meldung nennt den Weg ueber int64" "$E
fn main(): int64 {
    if (Fahrwerk.Ausgefahren == Triebwerk.Laeuft) { PrintStrLn(\"x\"); }
    return 0;
}" "as int64"

# GEGENPROBEN. Ohne sie waere der Test auch von einer Fassung erfuellt, die
# jeden Enum-Vergleich abweist — und die haette den Bestand erschlagen.
geht "#1967: dasselbe Enum bleibt vergleichbar" "$E
fn main(): int64 {
    if (Fahrwerk.Eingefahren == Fahrwerk.Ausgefahren) { PrintStrLn(\"x\"); }
    return 0;
}"

geht "#1967: Variable gegen Variante desselben Enums" "$E
fn main(): int64 {
    var f: Fahrwerk := Fahrwerk.Ausgefahren;
    if (f == Fahrwerk.Eingefahren) { PrintStrLn(\"x\"); }
    return 0;
}"

geht "#1967: gegen eine Zahl bleibt erlaubt" "$E
fn main(): int64 {
    var f: Fahrwerk := Fahrwerk.Ausgefahren;
    if ((f as int64) == 1) { PrintStrLn(\"x\"); }
    return 0;
}"

geht "#1967: der Weg ueber as int64 bleibt offen" "$E
fn main(): int64 {
    if ((Fahrwerk.Ausgefahren as int64) == (Triebwerk.Laeuft as int64)) { PrintStrLn(\"x\"); }
    return 0;
}"

echo
echo "--- #1967: Mindeststelligkeit der Builtins ---"

B='import std.io;
import std.string;'

# Der Fall aus dem Issue.
meldet "StrConcat mit einem Argument" "$B
fn main(): int64 { var s: pchar := StrConcat(\"a\"); PrintStrLn(s); return 0; }" \
  "zu wenige Argumente"

# Der Fall, der ABSTUERZT — ein Speicherauszug, kein plausibles Ergebnis.
meldet "StrCharAt mit einem Argument" "$B
fn main(): int64 { PrintLn(IntToStr(StrCharAt(\"abc\"))); return 0; }" \
  "zu wenige Argumente"

meldet "StrSub mit zwei Argumenten" "$B
fn main(): int64 { PrintStrLn(StrSub(\"abcd\", 0)); return 0; }" \
  "zu wenige Argumente"

meldet "StrLen ohne Argument" "$B
fn main(): int64 { PrintLn(IntToStr(StrLen())); return 0; }" \
  "zu wenige Argumente"

# GEGENPROBE 1: die richtige Zahl geht durch.
geht "#1967: StrConcat mit zwei Argumenten" "$B
fn main(): int64 { PrintStrLn(StrConcat(\"a\", \"b\")); return 0; }"

geht "#1967: StrSub mit drei Argumenten" "$B
fn main(): int64 { PrintStrLn(StrSub(\"abcd\", 0, 2)); return 0; }"

# GEGENPROBE 2: UEBERZAEHLIGE Argumente bleiben erlaubt — und das ist keine
# Nachlaessigkeit, sondern gemessen: StrCopy nimmt eine UND zwei Formen, und
# `StrCopy(s, StrLen(s))` steht als Empfehlung in einer Meldung von sema. Wer
# hier eine Obergrenze zoege, wiese gueltigen Code ab.
geht "#1967: StrCopy mit einem Argument" "$B
fn main(): int64 { PrintStrLn(StrCopy(\"abc\")); return 0; }"

geht "#1967: StrCopy mit zwei Argumenten" "$B
fn main(): int64 { PrintStrLn(StrCopy(\"abc\", 3)); return 0; }"

echo
echo "--- #1952: @integrity vor unit ---"

# `scrubbed` WIRKT. Gemessen wird die WIRKUNG am Erzeugnis, nicht die
# Uebersetzbarkeit: die Hashtabelle traegt die Kennung METASAF2, und das
# Erzeugnis waechst um ein Vielfaches.
printf '@integrity(mode: scrubbed, interval: 100)\nunit main;\nfn main(): int64 { return 0; }\n' > "$TMP/s.lyx"
printf 'unit main;\nfn main(): int64 { return 0; }\n' > "$TMP/o.lyx"
( cd "$ROOT" && "$LYXC" --std-path="$ROOT" "$TMP/s.lyx" -o "$TMP/s" ) >/dev/null 2>&1
( cd "$ROOT" && "$LYXC" --std-path="$ROOT" "$TMP/o.lyx" -o "$TMP/o" ) >/dev/null 2>&1
if [ -f "$TMP/s" ] && grep -aq METASAF2 "$TMP/s"; then
  echo "PASS #1952: scrubbed vor unit erzeugt die Hashtabelle (METASAF2)"; PASS=$((PASS+1))
else
  echo "FAIL #1952: scrubbed vor unit wirkt nicht"; FAIL=$((FAIL+1))
fi
# GEGENPROBE: ohne das Attribut entsteht sie NICHT. Sonst pruefte die Zeile
# darueber nur, dass jedes Erzeugnis die Kennung traegt.
if [ -f "$TMP/o" ] && ! grep -aq METASAF2 "$TMP/o"; then
  echo "PASS #1952: ohne das Attribut entsteht sie nicht"; PASS=$((PASS+1))
else
  echo "FAIL #1952: die Kennung steht auch ohne das Attribut im Erzeugnis"; FAIL=$((FAIL+1))
fi
if [ -f "$TMP/s" ] && [ -f "$TMP/o" ]; then
  gs=$(stat -c%s "$TMP/s"); go=$(stat -c%s "$TMP/o")
  if [ "$gs" -gt $((go * 2)) ]; then
    echo "PASS #1952: das Erzeugnis waechst deutlich ($go -> $gs Byte)"; PASS=$((PASS+1))
  else
    echo "FAIL #1952: kaum Groessenunterschied ($go -> $gs Byte)"; FAIL=$((FAIL+1))
  fi
fi

# `software_lockstep` vor unit wird ABGEWIESEN — es vergleicht ein Ergebnis in
# einem Register, und eine Unit hat keines. Die Meldung sagt das.
meldet "#1952: software_lockstep vor unit wird abgewiesen" \
'@integrity(mode: software_lockstep)
unit main;
fn main(): int64 { return 0; }' "nicht an der Unit"

# GEGENPROBE: an einer FUNKTION bleibt derselbe Modus erlaubt.
geht "#1952: software_lockstep an einer Funktion bleibt erlaubt" \
'unit main;
@integrity(mode: software_lockstep)
fn rechne(a: int64): int64 { return a + 1; }
fn main(): int64 { return rechne(1) - 2; }'

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
