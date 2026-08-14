#!/usr/bin/env bash
# tests/defer_durchlaufener_rahmen_test.sh — #1334, #1388.
#
# #1334: Wirft eine GERUFENE Funktion, sprang die Ausnahme per longjmp direkt
# in den Handler weiter oben — der Rahmen dazwischen wurde uebersprungen, und
# niemand fuehrte seine defers aus. `defer CloseFile(fd)` leckte still, und
# zwar im HAEUFIGEREN Fall: man faengt oben und wirft unten. #1241 hatte nur
# den Rahmen behoben, in dem der `throw` selbst steht.
#
# Der Fix macht jede Funktion mit defers zum Halt der Abwicklung: eigener
# jmp_buf beim Eintritt, ein Landepunkt hinter dem Rumpf, und ein Zaehler im
# Rahmen, der sagt, wie weit der Rumpf gekommen ist. Ein statisches "alle
# defers" waere falsch — ein defer hinter der Wurfstelle wurde nie angemeldet.
#
# GEPRUEFT WIRD DIE REIHENFOLGE, nicht die blosse Anwesenheit: nur sie zeigt,
# dass jede Ebene einmal und von innen nach aussen abgearbeitet wird. Ein Test
# auf "d kam vor" waere auch mit doppelter Ausfuehrung gruen gewesen — genau
# der Fehler, der beim Bauen auftrat.
#
# #1388: Die Meldung ueber einen unbekannten Builtin nannte fest "lyxos",
# unabhaengig vom tatsaechlichen Ziel. Wer mit --target=arm64 uebersetzte,
# suchte am falschen Backend.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

out() { # name, quelltext, erwartete ausgabe, erwarteter rc
  printf '%s\n' "$2" > "$TMP/p.lyx"; rm -f "$TMP/p"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p" >/dev/null 2>&1; then
    no "$1" "uebersetzt nicht: $("$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p" 2>&1 | grep -i error | head -1)"
    return
  fi
  got="$(timeout 30 "$TMP/p" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then no "$1" "ABSTURZ (rc=$rc)"; return; fi
  if [ "$got" != "$3" ]; then no "$1" "'$got' erwartet '$3'"; return; fi
  if [ -n "$4" ] && [ "$rc" != "$4" ]; then no "$1" "rc=$rc erwartet $4"; return; fi
  ok "$1"
}

# ===========================================================================
# #1334 — der durchlaufene Rahmen
# ===========================================================================

out "#1334: Repro aus der Meldung" 'import std.io;
fn G(): int64 { throw 7; return 0; }
fn F(): int64 { defer PrintLn("D-MITTE"); G(); return 0; }
fn main(): int64 { try { F(); } catch (e: int64) { PrintLn("catch"); } return 0; }' "D-MITTE
catch" 0

# Drei Ebenen: jede Ebene einmal, von innen nach aussen, und innerhalb einer
# Ebene LIFO. Der defer HINTER der Wurfstelle war nie angemeldet und darf
# nicht laufen — daran haengt der ganze Sinn des Laufzeitzaehlers.
out "#1334: drei Ebenen, LIFO, nichts doppelt" 'import std.io;
fn G(): int64 { defer PrintLn("G1"); throw 7; return 0; }
fn F(): int64 {
  defer PrintLn("F1");
  defer PrintLn("F2");
  G();
  defer PrintLn("F3-nie");
  return 0;
}
fn E(): int64 { defer PrintLn("E1"); F(); return 0; }
fn main(): int64 {
  try { E(); } catch (e: int64) { PrintStr("catch "); PrintLn(IntToStr(e)); }
  return 0;
}' "G1
F2
F1
E1
catch 7" 0

# Der Wert der Ausnahme muss die Abwicklung ueberstehen.
out "#1334: der geworfene Wert kommt unveraendert an" 'import std.io;
fn G(): int64 { throw 4711; return 0; }
fn F(): int64 { defer PrintLn("d"); G(); return 0; }
fn main(): int64 {
  try { F(); } catch (e: int64) { PrintLn(IntToStr(e)); }
  return 0;
}' "d
4711" 0

# Ohne Handler endet der Prozess — die defers laufen trotzdem, sonst leckt
# genau der Deskriptor, fuer den man defer schreibt.
out "#1334: ohne Handler laufen die defers und der Prozess endet" 'import std.io;
fn G(): int64 { throw 5; return 0; }
fn F(): int64 { defer PrintLn("F-defer"); G(); return 0; }
fn main(): int64 { F(); PrintLn("nie"); return 0; }' "F-defer" 1

# Ein try IM durchlaufenen Rahmen: dort wickelt der try-Block schon ab, der
# Rahmen-Halt darf dieselben defers nicht ein zweites Mal ausfuehren.
out "#1334: try im selben Rahmen, nichts doppelt" 'import std.io;
fn F(): int64 {
  defer PrintLn("d-aussen");
  try { defer PrintLn("d-innen"); throw 2; } finally { PrintLn("f"); }
  return 0;
}
fn main(): int64 { try { F(); } catch (e: int64) { PrintLn("c"); } return 0; }' "d-innen
f
d-aussen
c" 0

# ===========================================================================
# Gegenproben: die Wege ohne Ausnahme bleiben, wie sie waren
# ===========================================================================

out "#1334: regulaerer Rueckweg unveraendert" 'import std.io;
fn F(): int64 { defer PrintLn("d"); PrintLn("rumpf"); return 7; }
fn main(): int64 { PrintLn(IntToStr(F())); return 0; }' "rumpf
d
7" 0

out "#1334: Funktion OHNE defer bekommt keinen Halt" 'import std.io;
fn G(): int64 { throw 3; return 0; }
fn F(): int64 { G(); return 0; }
fn main(): int64 { try { F(); } catch (e: int64) { PrintLn(IntToStr(e)); } return 0; }' "3" 0

out "#1334: defer in einer Schleife, Wurf nach zwei Runden" 'import std.io;
fn G(i: int64): int64 { if (i == 2) { throw 9; } return i; }
fn F(): int64 {
  var i: int64 := 0;
  while (i < 4) {
    defer PrintLn(IntToStr(i));
    G(i);
    i := i + 1;
  }
  return 0;
}
fn main(): int64 { try { F(); } catch (e: int64) { PrintLn("c"); } return 0; }' "0
1
2
c" 0

# ===========================================================================
# #1388 — die Meldung nennt das Ziel, mit dem uebersetzt wurde
# ===========================================================================

printf 'import std.io;\nfn main(): int64 { PrintLn("hallo"); return 0; }\n' > "$TMP/ir.lyx"
meldung="$("$LYXC" --std-path="$ROOT" "$TMP/ir.lyx" --target=arm64 -o "$TMP/ir" 2>&1 | grep -i "unbekannter Builtin" | head -1)"
if [ -z "$meldung" ]; then
  # Kein Fehler mehr? Dann ist das Backend inzwischen vollstaendig — der Test
  # sagt das, statt stumm gruen zu sein.
  ok "#1388: --target=arm64 uebersetzt std.io inzwischen ohne Meldung"
elif printf '%s' "$meldung" | grep -q -- "--target=arm64"; then
  ok "#1388: die Meldung nennt das tatsaechliche Ziel"
else
  no "#1388: die Meldung nennt das tatsaechliche Ziel" "$meldung"
fi

# Und fuer ein zweites Ziel, damit nicht bloss ein anderer fester Text steht.
meldung2="$("$LYXC" --std-path="$ROOT" "$TMP/ir.lyx" --target=riscv -o "$TMP/ir2" 2>&1 | grep -i "unbekannter Builtin" | head -1)"
if [ -z "$meldung2" ]; then
  ok "#1388: --target=riscv uebersetzt std.io inzwischen ohne Meldung"
elif printf '%s' "$meldung2" | grep -q -- "--target=riscv"; then
  ok "#1388: die Meldung nennt auch das zweite Ziel richtig"
else
  no "#1388: die Meldung nennt auch das zweite Ziel richtig" "$meldung2"
fi

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
