#!/bin/bash
# Runde 13 — Auflösung im Compiler (#1650, #1647)
#
#   * #1650: `super.M()` muss die naechste Implementierung entlang der
#     Vererbungskette treffen, nicht nur die direkte Basisklasse. Geprueft
#     wird beides: dass eine Zwischenklasse OHNE eigene Implementierung
#     uebersprungen wird — und dass eine MIT eigener Implementierung gewinnt.
#     Ohne die zweite Haelfte waere ein "greif einfach zur Wurzel" ebenfalls
#     gruen, und das waere ein neuer Defekt.
#   * #1647: dieselbe Datei muss unter -O0 bis -O3 gleich uebersetzen. Der
#     Test faehrt alle vier Stufen; vorher war genau -O0 rot.
set -u
cd "$(dirname "$0")/.."
LYXC=${LYXC:-./lyxc}
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
DATA="tests/data/runde13"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
pruefe() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (erwartet '$3', erhalten '$2')"; fi; }

# ---------------------------------------------------------------- #1650
cat > "$TMP/super.lyx" <<'EOF'
import std.io;
pub type TA = class {
  fn Init(): void {}
  virtual fn Sag(): void { PrintLn("A"); }
  virtual fn Wert(n: int64): int64 { return n + 1; }
}
pub type TB = class extends TA { }          // erbt, ueberschreibt nicht
pub type TC = class extends TB { }          // zweite Zwischenebene
pub type TD = class extends TC {
  override fn Sag(): void { super.Sag(); PrintLn("D"); }
  override fn Wert(n: int64): int64 { return super.Wert(n) * 10; }
}
// Gegenprobe: die naechste Implementierung gewinnt, nicht die Wurzel.
pub type TE = class extends TA {
  override fn Sag(): void { PrintLn("E"); }
}
pub type TF = class extends TE {
  override fn Sag(): void { super.Sag(); PrintLn("F"); }
}
// Eine Ebene, wie vor dem Fix schon korrekt — darf nicht kaputtgehen.
pub type TG = class extends TA {
  override fn Sag(): void { super.Sag(); PrintLn("G"); }
}
// TA.Sag meldet sich in jeder Kette gleich; unterschieden wird ueber die
// Reihenfolge der Gesamtausgabe, nicht ueber die einzelne Zeile.
fn main(): int64 {
  var d: TD := new TD();  d.Sag();
  PrintLn(IntToStr(d.Wert(1)));
  var f: TF := new TF();  f.Sag();
  var g: TG := new TG();  g.Sag();
  return 0;
}
EOF
if ! "$LYXC" --std-path=. "$TMP/super.lyx" -o "$TMP/super" > "$TMP/super.log" 2>&1; then
  bad "#1650 uebersetzt"; grep -E "error" "$TMP/super.log" | head -3
else
  ok "#1650 uebersetzt"
  if timeout 60 "$TMP/super" > "$TMP/super.out" 2>&1; then
    # Die REIHENFOLGE der ganzen Ausgabe ist der Nachweis: welcher Rumpf wann
    # lief. Einzelne Zeilen zu greppen taugt hier nicht — TA.Sag() erscheint
    # dreimal, einmal je Kette.
    # A,D = zwei Zwischenebenen uebersprungen; 20 = Rueckgabe ueber die Kette;
    # E,F = die NAECHSTE Implementierung gewinnt (nicht die Wurzel);
    # A,G = die direkte Basisklasse, wie vor dem Fix schon richtig.
    erwartet="A
D
20
E
F
A
G"
    if [ "$(cat "$TMP/super.out")" = "$erwartet" ]; then
      ok "#1650 super trifft die naechste Implementierung (vier Ketten)"
    else
      bad "#1650 super trifft die naechste Implementierung"
      diff <(echo "$erwartet") "$TMP/super.out" | head -8
    fi
  else
    bad "#1650 laeuft"; head -3 "$TMP/super.out"
  fi
fi

# ---------------------------------------------------------------- #1647
cat > "$TMP/enum.lyx" <<'EOF'
import std.io;
import runde13.enums;
fn main(): int64 {
  PrintLn("none="  + IntToStr(AL_NONE));
  PrintLn("right=" + IntToStr(AL_RIGHT));
  PrintLn("folgt=" + IntToStr(AL_FOLGT));
  return 0;
}
EOF
for O in 0 1 2 3; do
  if ! "$LYXC" --std-path=. -I "$DATA/.." "-O$O" "$TMP/enum.lyx" -o "$TMP/enum$O" > "$TMP/enum$O.log" 2>&1; then
    bad "#1647 -O$O uebersetzt"; grep -E "error" "$TMP/enum$O.log" | head -2
  else
    ok "#1647 -O$O uebersetzt"
    if timeout 60 "$TMP/enum$O" > "$TMP/enum$O.out" 2>&1; then
      w() { grep "^$1=" "$TMP/enum$O.out" | head -1 | cut -d= -f2; }
      pruefe "#1647 -O$O Werte stimmen" "$(w none)/$(w right)/$(w folgt)" "0/2/3"
    else
      bad "#1647 -O$O laeuft"
    fi
  fi
done

echo "----"
echo "$PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
