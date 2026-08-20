#!/usr/bin/env bash
# tests/stack_limit_test.sh — #1138: `@stack_limit(N)` wird nachgewiesen.
#
# Bis 1.0.14J war das Attribut ein blosser Vermerk: der Compiler meldete, dass
# er die Zusicherung NICHT nachweist (#1099), und uebersetzte weiter. Jetzt
# pruefen zwei Teile:
#
#   1. RAHMENGROESSE — der Codegen kennt sie, wenn er `sub rsp, imm32` patcht.
#      Ist der Rahmen groesser als die Schranke, ist die Zusage schon fuer
#      EINEN Aufruf verletzt, unabhaengig von jeder Aufruftiefe.
#   2. REKURSION — eine rekursive Funktion verbraucht ohne nachweisbare Tiefe
#      beliebig viel Stapel. Der vorhandene Aufrufgraph (src/ir_call_graph.lyx)
#      erkennt auch INDIREKTE Zyklen; er wird nur gebaut, wenn das Attribut im
#      Programm ueberhaupt vorkommt.
#
# Die Schranke ist in BYTES angegeben (ebnf.md §4). Das ist die Einheit, in der
# der Compiler rechnet; eine Angabe ohne Einheit waere sonst mehrdeutig.
#
# ACHTUNG bei den Erwartungen: ein `var puffer: int64[4096]` liegt in Lyx NICHT
# im Rahmen — Arrays bekommen einen Heap-Block, der Slot haelt den Zeiger. Der
# Rahmen waechst also nur um 8 Byte pro Variable. Der Repro aus dem Issue wird
# deshalb wegen der REKURSION abgewiesen, nicht wegen des Puffers.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

fails() { # name, quelltext, erwarteter meldungsteil
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  msg="$("$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)"
  if [ -f "$TMP/c" ]; then echo "FAIL $1: uebersetzt, statt zu melden"; FAIL=$((FAIL+1)); return; fi
  case "$msg" in
    *"$3"*) echo "PASS $1"; PASS=$((PASS+1)) ;;
    *) echo "FAIL $1: Meldung ohne '$3'"; FAIL=$((FAIL+1)) ;;
  esac
}

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

K='import src.std.io;'

# --- Der Repro aus dem Issue: unbeschraenkte Rekursion -------------------
fails "Repro: Rekursion unter @stack_limit" "$K
@stack_limit(4096)
fn Tief(n: int64): int64 {
    var puffer: int64[4096];
    if (n <= 0) { return 0; }
    return Tief(n - 1);
}
fn main(): int64 { PrintLn(Tief(3)); return 0; }" "@stack_limit ist mit Rekursion nicht nachweisbar"

# Auch ein INDIREKTER Zyklus zaehlt — dafuer gibt es den Aufrufgraphen.
fails "indirekte Rekursion" "$K
@stack_limit(4096)
fn A(n: int64): int64 { if (n <= 0) { return 0; } return B(n - 1); }
fn B(n: int64): int64 { return A(n - 1); }
fn main(): int64 { PrintLn(A(4)); return 0; }" "mit Rekursion nicht nachweisbar"

# --- Rahmengroesse gegen die Schranke ------------------------------------
fails "Rahmen groesser als die Schranke" "$K
@stack_limit(16)
fn Viele(): int64 {
    var a: int64 := 1; var b: int64 := 2; var c: int64 := 3;
    var d: int64 := 4; var e: int64 := 5;
    return a + b + c + d + e;
}
fn main(): int64 { PrintLn(Viele()); return 0; }" "verletzt"

# Die Meldung nennt beide Zahlen — ohne sie waere sie nicht zu gebrauchen.
fails "Meldung nennt Schranke und Rahmen" "$K
@stack_limit(16)
fn Viele(): int64 {
    var a: int64 := 1; var b: int64 := 2; var c: int64 := 3;
    var d: int64 := 4; var e: int64 := 5;
    return a + b + c + d + e;
}
fn main(): int64 { PrintLn(Viele()); return 0; }" "@stack_limit(16) verletzt — der Rahmen belegt"

# --- Was weiterhin uebersetzen muss --------------------------------------
out "kleiner Rahmen, keine Rekursion" "$K
@stack_limit(4096)
fn Klein(a: int64): int64 { var x: int64 := a * 2; return x; }
fn main(): int64 { PrintLn(Klein(21)); return 0; }" '42'

out "Schranke genau eingehalten" "$K
@stack_limit(64)
fn Passt(): int64 { var a: int64 := 7; return a; }
fn main(): int64 { PrintLn(Passt()); return 0; }" '7'

# Rekursion ohne das Attribut ist erlaubt — geprueft wird nur, wer zusagt.
out "Rekursion ohne @stack_limit unveraendert" "$K
fn Fak(n: int64): int64 { if (n <= 1) { return 1; } return n * Fak(n - 1); }
fn main(): int64 { PrintLn(Fak(5)); return 0; }" '120'

out "Programm ohne Attribut unveraendert" "$K
fn Gross(): int64 { var a: int64 := 1; var b: int64 := 2; return a + b; }
fn main(): int64 { PrintLn(Gross()); return 0; }" '3'

# Zwei Funktionen, nur eine mit Attribut: die andere bleibt unberuehrt.
out "Attribut wirkt nur auf die annotierte Funktion" "$K
@stack_limit(4096)
fn Sicher(a: int64): int64 { return a + 1; }
fn Rekursiv(n: int64): int64 { if (n <= 0) { return 0; } return Rekursiv(n - 1); }
fn main(): int64 { PrintLn(Sicher(41)); PrintLn(Rekursiv(3)); return 0; }" '42
0'

# --- Die Argumentform bleibt geprueft (#1099) ----------------------------
fails "Schranke 0 wird abgewiesen" "$K
@stack_limit(0)
fn F(): int64 { return 1; }
fn main(): int64 { return F(); }" "stack_limit"

# --- Der Vermerk aus #1099 ist weg ---------------------------------------
# Solange nichts nachgewiesen wurde, meldete jedes Vorkommen "wird vom
# Compiler NICHT nachgewiesen". Das waere jetzt falsch.
printf '%s\n' "$K
@stack_limit(4096)
fn Klein(a: int64): int64 { return a * 2; }
fn main(): int64 { PrintLn(Klein(21)); return 0; }" > "$TMP/w.lyx"
wmsg="$("$LYXC" --std-path="$ROOT" "$TMP/w.lyx" -o "$TMP/w" 2>&1)"
case "$wmsg" in
  *"@stack_limit: die Zusicherung wird vom Compiler NICHT nachgewiesen"*)
    echo "FAIL Vermerk 'nicht nachgewiesen' ist weg: steht noch da"; FAIL=$((FAIL+1)) ;;
  *) echo "PASS Vermerk 'nicht nachgewiesen' ist weg"; PASS=$((PASS+1)) ;;
esac

# Die uebrigen unbewiesenen Attribute melden weiterhin. (@wcet stand hier bis
# 1.0.14K -- seit #1139 wird es nachgewiesen und meldet nichts mehr.)
printf '%s\n' "$K
@integrity(mode: software_lockstep)
fn F(): int64 { return 1; }
fn main(): int64 { return F(); }" > "$TMP/v.lyx"
vmsg="$("$LYXC" --std-path="$ROOT" "$TMP/v.lyx" -o "$TMP/v" 2>&1)"
case "$vmsg" in
  *"NICHT nachgewiesen"*) echo "PASS @integrity meldet weiterhin"; PASS=$((PASS+1)) ;;
  *) echo "FAIL @integrity meldet weiterhin: Meldung fehlt"; FAIL=$((FAIL+1)) ;;
esac

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
test "$FAIL" -eq 0
