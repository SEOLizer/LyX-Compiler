#!/usr/bin/env bash
# tests/shift_right_signed_test.sh — #1125: `>>` auf int64 zieht das Vorzeichen
# nach.
#
# `-8 >> 1` ergab 9223372036854775804 statt -4. Der Shift fuellte mit Nullen
# auf, statt das Vorzeichenbit nachzuziehen — auf einem vorzeichenbehafteten
# Typ in Zweierkomplement-Darstellung ist das falsch. Positive Werte fielen
# nicht auf, weil sich logischer und arithmetischer Shift dort nicht
# unterscheiden.
#
# Ursache war eine falsche Kodierung, die der Kommentar daneben verdeckte:
#
#     self.cg_e8(0x48); self.cg_e8(0xD3); self.cg_e8(0xEB);  // sar rbx, cl (signed)
#
# ModRM 0xEB ist /5 = SHR; SAR waere /7 = 0xFB. Der Disassembler sagte
# `shr %cl,%rbx`, der Quelltext behauptete `sar`.
#
# Auf einem vorzeichenLOSEN Typ (u8..u64) ist das Auffuellen richtig — dort
# bleibt es bei SHR. Der linke Operand entscheidet.
#
# Die Uebersetzungszeit-Faltung rechnet den Shift seither ausdruecklich
# (`cg_sarConst`), statt das `>>` des bauenden Compilers zu benutzen: dessen
# Verhalten ist genau das, was hier repariert wird — der Fixpunkt haette sonst
# davon abgehangen, mit welchem Wirt gebaut wurde.
#
# Geprueft wird der WERT. Ein Test auf Uebersetzbarkeit waere immer gruen
# gewesen.

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

# --- Die Tabelle aus dem Issue -------------------------------------------
out "Repro: -8 >> 1" "$K
fn main(): int64 { var a: int64 := 0 - 8; PrintLn(a >> 1); return 0; }" '-4'

out "-1 >> 1 bleibt -1" "$K
fn main(): int64 { var a: int64 := 0 - 1; PrintLn(a >> 1); return 0; }" '-1'

out "-8 >> 2" "$K
fn main(): int64 { var a: int64 := 0 - 8; PrintLn(a >> 2); return 0; }" '-2'

out "-100 >> 3 rundet ab" "$K
fn main(): int64 { var a: int64 := 0 - 100; PrintLn(a >> 3); return 0; }" '-13'

out "8 >> 1 unveraendert" "$K
fn main(): int64 { var a: int64 := 8; PrintLn(a >> 1); return 0; }" '4'

# Der Shift-Betrag als Variable laeuft durch denselben Zweig.
out "variabler Shift-Betrag" "$K
fn main(): int64 { var a: int64 := 0 - 8; var s: int64 := 2; PrintLn(a >> s); return 0; }" '-2'

# --- Uebersetzungszeit und Laufzeit muessen dasselbe sagen ---------------
# Ein konstanter Ausdruck wird gefaltet und nimmt einen anderen Weg als die
# Laufzeitrechnung. Bis 1.0.13R faltete der Compiler mit dem `>>` des Wirts.
out "konstanter Ausdruck wird arithmetisch gefaltet" "$K
fn main(): int64 { PrintLn((0 - 8) >> 1); return 0; }" '-4'

out "gefaltet und gerechnet stimmen ueberein" "$K
fn main(): int64 { var a: int64 := 0 - 100; PrintLn((0 - 100) >> 3); PrintLn(a >> 3); return 0; }" '-13
-13'

out "con-Wert wird arithmetisch gefaltet" "$K
con NEG: int64 := 0 - 64;
fn main(): int64 { PrintLn(NEG >> 4); return 0; }" '-4'

# --- Vorzeichenlose Typen fuellen weiterhin mit Nullen auf ---------------
# Auf u64 ist SHR richtig: 2^64-8 halbiert ist 9223372036854775804.
out "uint64 bleibt logisch" "$K
fn main(): int64 { var u: uint64 := 18446744073709551608; PrintLn(u >> 1); return 0; }" '9223372036854775804'

out "u32 bleibt logisch" "$K
fn main(): int64 { var w: u32 := 4294967288; PrintLn(w >> 1); return 0; }" '2147483644'

# Der Cast ist der ausdrueckliche Fluchtweg zum logischen Shift.
out "as uint64 erzwingt den logischen Shift" "$K
fn main(): int64 { var a: int64 := 0 - 8; PrintLn((a as uint64) >> 1); return 0; }" '9223372036854775804'

# --- Halbierung als Muster ------------------------------------------------
# Binaersuche und Mittelwertbildung sind die Stellen, an denen der Fehler
# praktisch zuschlug.
out "Mittelwert zweier negativer Zahlen" "$K
fn main(): int64 { var lo: int64 := 0 - 100; var hi: int64 := 0 - 20; PrintLn((lo + hi) >> 1); return 0; }" '-60'

out "wiederholte Halbierung endet bei -1" "$K
fn main(): int64 {
    var v: int64 := 0 - 1024;
    var i: int64 := 0;
    while (i < 12) { v := v >> 1; i := i + 1; }
    PrintLn(v);
    return 0;
}" '-1'

# --- Gegenproben: die uebrigen Operatoren --------------------------------
out "Linksshift unveraendert" "$K
fn main(): int64 { var a: int64 := 0 - 8; PrintLn(a << 1); var b: int64 := 3; PrintLn(b << 4); return 0; }" '-16
48'

out "Division und Modulo unveraendert" "$K
fn main(): int64 { var a: int64 := 0 - 7; PrintLn(a / 2); PrintLn(a % 3); return 0; }" '-3
-1'

out "bitweise Operatoren unveraendert" "$K
fn main(): int64 { var a: int64 := 12; var b: int64 := 10; PrintLn(a & b); PrintLn(a | b); PrintLn(a ^ b); return 0; }" '8
14
6'

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
test "$FAIL" -eq 0
