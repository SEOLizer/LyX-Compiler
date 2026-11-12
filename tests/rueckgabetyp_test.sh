#!/bin/bash
# #1704, #1683 — zwei Faelle derselben Bauart: eine Auskunft ueber den
# RUECKGABETYP faellt durch, und der Durchfall ist ein stiller ERSATZTYP
# statt einer Meldung. Beide Male stimmt derselbe Ausdruck ueber eine
# Zwischenvariable, weil dort der deklarierte Typ zaehlt — genau das macht sie
# im Alltag so schwer zu sehen.
#
# Die Gegenrichtung von #1704 — dass eine echte `extern fn` mit f64-Rueckgabe
# WEITERHIN als f64 gilt — deckt tests/f64_typspur_import_test.sh (#1566) ab.
# Das ist keine Formalie: ein erster Anlauf hat die Extern-Erkennung zu eng
# gefasst (Bibliotheksangabe verlangt) und genau jene Suite rot gemacht.
LYXC=${LYXC:-./lyxc}
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
P=0; F=0
ok()  { echo "PASS: $1"; P=$((P+1)); }
bad() { echo "FAIL: $1"; F=$((F+1)); }

lauf() {  # $1=Quelle $2=Erwartung $3=Beschreibung
  printf '%s' "$1" > "$TMP/p.lyx"
  if "$LYXC" --std-path=. "$TMP/p.lyx" -o "$TMP/p" > "$TMP/b.log" 2>&1; then
    chmod +x "$TMP/p"
    aus="$("$TMP/p" 2>&1 | tr '\n' ' ')"
    if [ "$aus" = "$2" ]; then ok "$3"; else bad "$3 (erwartet '$2', bekam '$aus')"; fi
  else
    bad "$3 — uebersetzt nicht ($(grep -oE 'error.*' "$TMP/b.log" | head -1))"
  fi
}

# ---------------------------------------------------------------------------
# #1704 — @wcet(N) und die extern-Signatur teilten sich Bits
# ---------------------------------------------------------------------------
# @wcet legt seine Schranke ab Bit 40 ab (24 Bit breit), die Rueckgabeklasse
# einer extern-Deklaration liegt auf 48-49. Der Vorlauf las die Bits aus JEDER
# Funktion, nicht nur aus externen: ab N=256 galt die Funktion als f64.
#
# Deshalb wird hier ueber die SCHWELLE geprueft. Ein Test mit @wcet(100) waere
# auch vor dem Fix gruen gewesen und haette nichts belegt.
for n in 100 255 256 500 16777215; do
  lauf "import std.io;
@wcet($n)
fn F(x: int64): int64 { return x * 2 + 1; }
fn main(): int64 { PrintLn(IntToStr(F(20) + 1)); return 0; }" "42 " "@wcet($n): Aufruf im Ausdruck rechnet ganzzahlig"
done

# Die Formen aus dem Bericht: nicht nur `+ 1`.
lauf 'import std.io;
@wcet(500)
fn F(x: int64): int64 { return x * 2 + 1; }
fn main(): int64 {
  var v: int64 := 7;
  PrintLn(IntToStr(F(20) + 2));
  PrintLn(IntToStr(F(20) + v));
  PrintLn(IntToStr(F(20) - 1));
  PrintLn(IntToStr(F(20) * 2));
  PrintLn(IntToStr(F(20) + F(1)));
  return 0; }' "43 48 40 82 44 " "@wcet: die uebrigen Rechenformen stimmen"

# Gegenprobe: eine ANNOTIERTE f64-Funktion muss weiterhin f64 sein.
lauf 'import std.io;
@wcet(500)
fn G(x: f64): f64 { return x * 2.0; }
fn main(): int64 { PrintF64(G(1.5) + 1.0); return 0; }' "4.000000 " "@wcet an einer f64-Funktion bleibt f64"

# ---------------------------------------------------------------------------
# #1683 — ClassName() im Print
# ---------------------------------------------------------------------------
lauf 'import std.io;
pub type TD = class { n: int64; fn Create(): void { self.n := 1; } }
pub type TE = class extends TD { fn Create(): void { self.n := 2; } }
fn main(): int64 {
  var d: TD := new TD();
  var e: TD := new TE();
  Print(d.ClassName()); Print(" ");
  Print(e.ClassName()); Print(" ");
  var s: pchar := d.ClassName();
  Print(s); Print("\n");
  return 0; }' "TD TE TD " "ClassName() direkt im Print liefert den Namen"

# In der Verkettung ging es schon vorher — als Gegenprobe, dass beide
# Auskuenfte jetzt dasselbe sagen.
lauf 'import std.io;
pub type TD = class { n: int64; fn Create(): void { self.n := 1; } }
fn main(): int64 {
  var d: TD := new TD();
  PrintLn("[" + d.ClassName() + "]");
  return 0; }' "[TD] " "ClassName() in der Verkettung unveraendert"

echo "----"
echo "$P PASS, $F FAIL"
[ "$F" -eq 0 ]
