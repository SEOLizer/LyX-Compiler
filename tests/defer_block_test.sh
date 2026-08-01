#!/usr/bin/env bash
# tests/defer_block_test.sh — defer läuft am Ende seines Blocks (Issue #1006).
#
# Vorher sammelte der Codegen in einem Vorab-Lauf (`cg_collectDefers`) ALLE
# defer-Knoten einer Funktion in einen Puffer und emittierte sie geschlossen an
# den Funktionsausgängen. Die Blockgrenze kam darin überhaupt nicht vor:
#
#     { defer PrintLn("B"); PrintLn("A"); }
#     PrintLn("C");                          --> A C B statt A B C
#
# Jetzt wird ein defer an der Stelle vorgemerkt, an der es im Quelltext steht,
# und am Ende des umschließenden Blocks abgearbeitet (LIFO). Ein `return` führt
# weiterhin alle noch offenen defers aus, `break`/`continue` die des
# Schleifenrumpfes.
#
# Geprüft wird die REIHENFOLGE der Ausgaben, nicht nur, dass etwas läuft — der
# alte Zustand gab dieselben Zeilen aus, bloß in der falschen Folge.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

run() { # name, rumpf von main, erwartete ausgabe (zeilen mit | getrennt)
  cat > "$TMP/c.lyx" <<EOF
import std.io;
fn main(): int64 {
$2
  return 0;
}
EOF
  rm -f "$TMP/c"
  if ! (cd "$ROOT" && "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1); then
    no "$1" "compile fehlgeschlagen"; return
  fi
  got=$(timeout 5 "$TMP/c" 2>&1 | tr '\n' '|'); rc=$?
  if [ "$rc" -ne 0 ]; then no "$1" "Laufzeit rc=$rc"; return; fi
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1" "'$got' erwartet '$3'"; fi
}

# Der Fall aus dem Issue.
run "Block: defer vor dem Folgestatement" '
  {
    defer PrintLn("B");
    PrintLn("A");
  }
  PrintLn("C");' 'A|B|C|'

# Mehrere defers im selben Block laufen LIFO.
run "LIFO im Block" '
  {
    defer PrintLn("1");
    defer PrintLn("2");
    PrintLn("0");
  }
  PrintLn("E");' '0|2|1|E|'

# Verschachtelte Blöcke: innerer zuerst, äußerer danach.
run "verschachtelt: innen vor aussen" '
  {
    defer PrintLn("aussen");
    {
      defer PrintLn("innen");
      PrintLn("kern");
    }
    PrintLn("dazwischen");
  }
  PrintLn("ende");' 'kern|innen|dazwischen|aussen|ende|'

# Auf Funktionsebene bleibt es beim Funktionsende.
run "Funktionsebene unveraendert" '
  defer PrintLn("Z");
  PrintLn("A");' 'A|Z|'

# if-Zweig ist ein Block.
run "if-Zweig als Block" '
  if (1 == 1) {
    defer PrintLn("i");
    PrintLn("h");
  }
  PrintLn("j");' 'h|i|j|'

# Schleifenrumpf: pro Iteration, nicht gesammelt am Funktionsende.
run "Schleifenrumpf pro Iteration" '
  var i: int64 := 0;
  while (i < 2) {
    defer PrintLn("d");
    PrintLn("k");
    i := i + 1;
  }
  PrintLn("fertig");' 'k|d|k|d|fertig|'

# break verlässt den Rumpf — der defer dieser Iteration muss trotzdem laufen.
run "break fuehrt defer aus" '
  var i: int64 := 0;
  while (i < 5) {
    defer PrintLn("d");
    i := i + 1;
    if (i == 1) { break; }
  }
  PrintLn("nach");' 'd|nach|'

# continue ebenso.
run "continue fuehrt defer aus" '
  var i: int64 := 0;
  while (i < 2) {
    defer PrintLn("d");
    i := i + 1;
    continue;
  }
  PrintLn("nach");' 'd|d|nach|'

# for .. to
run "for-Schleife pro Iteration" '
  for i := 1 to 2 {
    defer PrintLn("d");
    PrintLn("b");
  }
  PrintLn("nach");' 'b|d|b|d|nach|'

# for .. in range
run "range-Schleife pro Iteration" '
  for i in range(2) {
    defer PrintLn("d");
    PrintLn("b");
  }
  PrintLn("nach");' 'b|d|b|d|nach|'

# Vorzeitiges return führt die defers aller offenen Blöcke aus, äußere zuletzt.
cat > "$TMP/r.lyx" <<'EOF'
import std.io;
fn f(): int64 {
  defer PrintLn("f-aussen");
  {
    defer PrintLn("f-innen");
    PrintLn("vor return");
    return 7;
  }
}
fn main(): int64 {
  var v: int64 := f();
  PrintLn(v);
  return 0;
}
EOF
rm -f "$TMP/r"
if (cd "$ROOT" && "$LYXC" --std-path="$ROOT" "$TMP/r.lyx" -o "$TMP/r" >/dev/null 2>&1); then
  got=$(timeout 5 "$TMP/r" 2>&1 | tr '\n' '|')
  want='vor return|f-innen|f-aussen|7|'
  if [ "$got" = "$want" ]; then ok "return fuehrt alle offenen defers aus"
  else no "return fuehrt alle offenen defers aus" "'$got' erwartet '$want'"; fi
else
  no "return fuehrt alle offenen defers aus" "compile fehlgeschlagen"
fi

# --- Argument-Zeitpunkt (#1030) -----------------------------------------
# Die Argumente werden bei der VORMERKUNG ausgewertet, nicht am Blockende.
# Ohne das sah `defer f(i)` in einer Schleife das bereits erhoehte i.
run "Schleife: Argument zur defer-Zeit" '
  var i: int64 := 0;
  while (i < 3) {
    defer PrintLn(10 + i);
    PrintLn(i);
    i := i + 1;
  }' '0|10|1|11|2|12|'

run "spaetere Zuweisung aendert das Argument nicht" '
  var v: int64 := 5;
  {
    defer PrintLn(v);
    v := 99;
  }
  PrintLn(v);' '5|99|'

run "Zeichenkette wird zur defer-Zeit gebunden" '
  var s: pchar := "alt"c;
  {
    defer PrintLn(s);
    s := "neu"c;
  }
  PrintLn(s);' 'alt|neu|'

# Ein Argument mit Nebenwirkung darf GENAU EINMAL laufen, und zwar sofort.
cat > "$TMP/s.lyx" <<'EOF'
import std.io;
pub var g_c: int64;
fn side(v: int64): int64 { g_c := g_c + 1; return v; }
fn main(): int64 {
  g_c := 0;
  {
    defer PrintLn(side(3));
    Print("vor-ende "); PrintLn(g_c);
  }
  Print("aufrufe "); PrintLn(g_c);
  return 0;
}
EOF
rm -f "$TMP/s"
if (cd "$ROOT" && "$LYXC" --std-path="$ROOT" "$TMP/s.lyx" -o "$TMP/s" >/dev/null 2>&1); then
  got=$(timeout 5 "$TMP/s" 2>&1 | tr '\n' '|')
  want='vor-ende 1|3|aufrufe 1|'
  if [ "$got" = "$want" ]; then ok "Nebenwirkung laeuft einmal, zur defer-Zeit"
  else no "Nebenwirkung laeuft einmal, zur defer-Zeit" "'$got' erwartet '$want'"; fi
else
  no "Nebenwirkung laeuft einmal, zur defer-Zeit" "compile fehlgeschlagen"
fi

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
