#!/usr/bin/env bash
# tests/defer_exit_paths_test.sh — #1118: defer auf den Ausgaengen, die nicht
# das Funktionsende sind.
#
# `defer` lief bisher nur, wenn der Block regulaer oder ueber `return` verlassen
# wurde. Zwei Ausgaenge fehlten:
#
#   throw  — der defer im try-Block wurde uebersprungen, der catch-Zweig lief
#            als erstes. Genau im Fehlerfall unterblieb also die Freigabe.
#   break  — der defer in einem switch-/match-Zweig wurde uebersprungen. Das
#            wiegt schwer, weil der Compiler `break` oder `return` in jedem
#            Zweig ERZWINGT ("switch case may fall through"): der defekte Pfad
#            war der vorgeschriebene.
#
# Fuer Schleifen war dasselbe in #1006 (PR #1029) ueber `loopDeferMark` geloest;
# hier fehlte die Entsprechung fuer try (`tryDeferMark`) und fuer den
# switch-/match-Zweig (dort greift `loopDeferMark`, es wurde nur nie gesetzt).
#
# Geprueft wird die REIHENFOLGE der Ausgaben, nicht die Uebersetzbarkeit — der
# fehlende defer uebersetzt ja anstandslos, er laeuft nur nicht.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
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

K='import src.std.io;'

# --- Der Repro aus dem Issue: throw ---------------------------------------
out "Repro: defer im try, throw" "$K
fn F(): void {
    try { defer Print(\"d\"c); throw 1; }
    catch { Print(\"c\"c); }
}
fn main(): int64 { F(); PrintStrLn(\"\"c); return 0; }" 'dc'

# Mehrere defers laufen in umgekehrter Anlagereihenfolge — wie am Funktionsende.
out "mehrere defers, umgekehrte Reihenfolge" "$K
fn F(): void {
    try { defer Print(\"1\"c); defer Print(\"2\"c); throw 1; }
    catch { Print(\"c\"c); }
}
fn main(): int64 { F(); PrintStrLn(\"\"c); return 0; }" '21c'

# Nur die defers DIESES try-Blocks laufen; der aeussere wartet auf sein Ende.
out "verschachtelte try-Bloecke" "$K
fn F(): void {
    try {
        defer Print(\"A\"c);
        try { defer Print(\"i\"c); throw 1; }
        catch { Print(\"c\"c); }
        Print(\"n\"c);
    }
    catch { Print(\"C\"c); }
}
fn main(): int64 { F(); PrintStrLn(\"\"c); return 0; }" 'icnA'

# Ein defer VOR dem try gehoert nicht zum Block und darf beim throw nicht laufen.
out "defer vor dem try bleibt liegen" "$K
fn F(): void {
    defer Print(\"f\"c);
    try { defer Print(\"d\"c); throw 1; }
    catch { Print(\"c\"c); }
    Print(\"e\"c);
}
fn main(): int64 { F(); PrintStrLn(\"\"c); return 0; }" 'dcef'

# Der geworfene Wert steht beim Emittieren in rax; die dazwischengeschobenen
# defers duerfen ihn nicht ueberschreiben. Ein defer, der selbst rechnet und
# aufruft, wuerde das aufdecken — der catch-Zweig wird sonst nicht erreicht.
# (Den Wert im catch AUSZULESEN geht nicht: `catch (e)` bindet nichts, der
# Parser lehnt `catch (e: int64)` ab. Eigene Luecke, nicht Teil von #1118.)
out "defer mit Aufruf stoert den throw nicht" "$K
fn H(a: int64, b: int64): int64 { Print(\"h\"c); return a + b; }
fn F(): void {
    try { defer PrintLn(H(1, 2)); throw 3 + 4; }
    catch { Print(\"c\"c); }
}
fn main(): int64 { PrintStrLn(\"\"c); F(); PrintStrLn(\"\"c); return 0; }" '
h3
c'

# --- Der zweite Pfad aus dem Kommentar: switch-break ----------------------
out "Repro: defer im switch-Zweig" "$K
fn G(x: int64): void {
    switch (x) {
      case 1: { defer Print(\"a\"c); Print(\"n\"c); break; }
      default: { break; }
    }
    Print(\"e\"c);
}
fn main(): int64 { G(1); PrintStrLn(\"\"c); return 0; }" 'nae'

out "defer im default-Zweig" "$K
fn G(x: int64): void {
    switch (x) {
      case 1: { break; }
      default: { defer Print(\"a\"c); Print(\"n\"c); break; }
    }
    Print(\"e\"c);
}
fn main(): int64 { G(9); PrintStrLn(\"\"c); return 0; }" 'nae'

# Ein switch INNERHALB einer Schleife: der break verlaesst nur den Zweig, die
# defers der Schleife bleiben liegen bis zu deren Ende.
out "switch in einer Schleife" "$K
fn G(): void {
    var i: int64 := 0;
    while (i < 2) {
        defer Print(\"L\"c);
        switch (i) {
          case 0: { defer Print(\"a\"c); Print(\"0\"c); break; }
          default: { defer Print(\"b\"c); Print(\"1\"c); break; }
        }
        i := i + 1;
    }
}
fn main(): int64 { G(); PrintStrLn(\"\"c); return 0; }" '0aL1bL'

# `match` verwendet eine andere Schreibweise (`case p => Block`, kein `break`)
# und war nie betroffen — hier als Gegenprobe, dass die Markierung im
# match-Zweig nichts verschiebt.
out "defer im match-Zweig unveraendert" "$K
fn G(x: int64): int64 {
    var r: int64 := 0;
    match x {
      case 1 => { defer Print(\"a\"c); Print(\"n\"c); r := 1; }
      case _ => { r := 9; }
    }
    Print(\"e\"c);
    return r;
}
fn main(): int64 { PrintStrLn(\"\"c); PrintLn(G(1)); return 0; }" '
nae1'

# --- Gegenproben: die bisher funktionierenden Wege bleiben --------------
out "defer am Funktionsende unveraendert" "$K
fn F(): void { defer Print(\"d\"c); Print(\"n\"c); }
fn main(): int64 { F(); PrintStrLn(\"\"c); return 0; }" 'nd'

out "defer vor return unveraendert" "$K
fn F(): int64 { defer Print(\"d\"c); return 5; }
fn main(): int64 { PrintLn(F()); return 0; }" 'd5'

out "defer mit Schleifen-break unveraendert (#1006)" "$K
fn F(): void {
    var i: int64 := 0;
    while (i < 3) { defer Print(\"d\"c); if (i == 1) { break; } Print(\"n\"c); i := i + 1; }
}
fn main(): int64 { F(); PrintStrLn(\"\"c); return 0; }" 'ndd'

out "defer mit continue unveraendert (#1006)" "$K
fn F(): void {
    var i: int64 := 0;
    while (i < 2) { defer Print(\"d\"c); i := i + 1; continue; }
}
fn main(): int64 { F(); PrintStrLn(\"\"c); return 0; }" 'dd'

# try ohne defer und ohne throw darf sich nicht veraendern.
out "try ohne defer unveraendert" "$K
fn F(): void {
    try { Print(\"t\"c); throw 1; }
    catch { Print(\"c\"c); }
}
fn main(): int64 { F(); PrintStrLn(\"\"c); return 0; }" 'tc'

out "try ohne throw laeuft den Erfolgspfad" "$K
fn F(): void {
    try { defer Print(\"d\"c); Print(\"t\"c); }
    catch { Print(\"c\"c); }
    Print(\"e\"c);
}
fn main(): int64 { F(); PrintStrLn(\"\"c); return 0; }" 'tde'

# throw AUSSERHALB eines try beendet den Prozess mit 1 — unveraendert.
out "throw ohne try beendet mit 1" "$K
fn main(): int64 { PrintStrLn(\"x\"c); throw 1; return 0; }" 'x'

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
test "$FAIL" -eq 0
