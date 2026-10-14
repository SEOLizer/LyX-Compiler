#!/usr/bin/env bash
# tests/verschachtelte_namen_test.sh — #2044: eine innere Funktion ist genau
# dort sichtbar, wo sema sie sieht, und ein Aufruf trifft genau sie.
#
# Bis 1.2.12A trug eine innere Funktion auf dem x86-Weg ihren BLANKEN Namen
# als Marke. Zwei gleichnamige innere Funktionen — oder eine innere und eine
# gleichnamige Modulfunktion — fielen auf eine Marke zusammen, und jeder Aufruf
# traf die zuerst angelegte. Fehlerfrei uebersetzt, falsches Ergebnis:
#
#     ersteR()/zweiteR() mit je einer `nib`     11|11 statt 11|21
#     innere `helfer` neben einer auf Modulebene    1 statt 2
#
# Jede Funktion liefert hier einen EIGENEN Wert. Damit zeigt die Ausgabe,
# WELCHE gerufen wurde — ein Test, der nur "rechnet etwas" prueft, haette die
# Verwechslung nicht gesehen.
#
# Die Gueltigkeit ist die von sema (_checkStmt, SNK_BLOCK): eine innere
# Funktion gilt in ihrem BLOCK, dort auch vor ihrer Zeile; eine Variable oder
# ein Parameter desselben Namens verdeckt sie.
#
# Der IR-Weg (arm64, riscv) bindet einige Faelle noch anders — er sucht auf
# Funktions- statt Blockebene und kennt keine Verdeckung (#2074), und zwei
# private gleichnamige Funktionen zweier Units fallen dort zusammen (#2076).
# Diese Faelle laufen hier nur auf x86_64 (`nur_x86`); nach dem jeweiligen Fix
# gehoeren sie nach `alle_ziele`.
set -uo pipefail
ulimit -c 0   # ein Absturz unter qemu legt sonst eine .core-Datei ins Repo
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
. "$(dirname "$0")/lib/qemu.sh"   # #2048: beide Paketnamen
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

# Uebersetzt $2 (im Verzeichnis $4, Vorgabe $TMP) fuer Ziel $1; Ausgabe nach $3.
# rc 1 = uebersetzt nicht, 2 = qemu fehlt.
lauf() {
  local ziel="$1" src="$2" out="$3" wd="${4:-$TMP}"
  local bin="$TMP/b_${ziel}_$(basename "$src" .lyx)"
  ( cd "$wd" && timeout 240 "$LYXC" --std-path="$ROOT" --target="$ziel" "$src" -o "$bin" ) >"$TMP/build_$ziel.log" 2>&1 || return 1
  case "$ziel" in
    x86_64) timeout 60 "$bin" >"$out" 2>&1 ;;
    arm64)  [ -n "$QEMU_ARM64" ]   || return 2; timeout 60 $QEMU_ARM64   "$bin" >"$out" 2>&1 ;;
    riscv)  [ -n "$QEMU_RISCV64" ] || return 2; timeout 60 $QEMU_RISCV64 "$bin" >"$out" 2>&1 ;;
  esac
  return 0
}

pruefe() {  # $1 Beschreibung, $2 Quelle, $3 Soll (Zeilen mit |), $4 Ziele, $5 Arbeitsverzeichnis
  local was="$1" src="$2" erw="$3" ziele="$4" wd="${5:-$TMP}"
  for ziel in $ziele; do
    lauf "$ziel" "$src" "$TMP/aus.$ziel" "$wd"; local rc=$?
    if [ "$rc" = 2 ]; then
      nok "$was [$ziel]: qemu fehlt — die Wirkung wurde NICHT gemessen"
    elif [ "$rc" != 0 ]; then
      nok "$was [$ziel]: uebersetzt nicht ($(grep -m1 -iE '^lyxc:|error' "$TMP/build_$ziel.log"))"
    else
      local ist; ist="$(tr '\n' '|' < "$TMP/aus.$ziel")"
      if [ "$ist" = "$erw" ]; then ok "$was [$ziel] = $erw"
      else nok "$was [$ziel]: [$ist] statt [$erw]"; fi
    fi
  done
}
alle_ziele() { pruefe "$1" "$2" "$3" "x86_64 arm64 riscv" "${4:-$TMP}"; }
nur_x86()    { pruefe "$1" "$2" "$3" "x86_64" "${4:-$TMP}"; }

echo "--- #2044 Repro A: zwei aeussere Funktionen mit je einer gleichnamigen inneren ---"
# Woertlich aus dem Issue.
cat > "$TMP/a.lyx" <<'EOF'
unit main;
import std.io;
fn ersteR(): int64 {
  fn nib(n: int64): int64 { return n + 10; }
  return nib(1);
}
fn zweiteR(): int64 {
  fn nib(n: int64): int64 { return n + 20; }
  return nib(1);
}
fn main(): int64 { PrintLn(IntToStr(ersteR())); PrintLn(IntToStr(zweiteR())); return 0; }
EOF
alle_ziele "jede nib bleibt bei ihrer Funktion" "$TMP/a.lyx" "11|21|"

echo
echo "--- #2044 Repro B: eine innere verdeckt die gleichnamige auf Modulebene ---"
cat > "$TMP/b.lyx" <<'EOF'
unit main;
import std.io;
fn helfer(): int64 { return 1; }
fn aussen(): int64 {
  fn helfer(): int64 { return 2; }
  return helfer();
}
fn main(): int64 { PrintLn(IntToStr(aussen())); PrintLn(IntToStr(helfer())); return 0; }
EOF
# Zweite Zeile: AUSSERHALB von aussen gilt weiter die Modulfunktion.
alle_ziele "innen die innere, aussen die Modulfunktion" "$TMP/b.lyx" "2|1|"

echo
echo "--- Aufruf vor der Deklaration, drei Ebenen, Rekursion, Geschwister ---"
cat > "$TMP/ebenen.lyx" <<'EOF'
unit main;
import std.io;
fn nib(n: int64): int64 { return 1; }
fn a(): int64 {
  var vorher: int64 := spaeter(3);          // steht weiter unten im Block
  fn spaeter(n: int64): int64 { return n * 3; }
  fn nib(n: int64): int64 { return 10; }
  fn b(): int64 {
    fn nib(n: int64): int64 { return 20; }
    return nib(0);
  }
  fn fak(n: int64): int64 { if (n <= 1) { return 1; } return n * fak(n - 1); }
  fn zwei(n: int64): int64 { return spaeter(n) + 1; }   // Geschwister
  PrintLn(IntToStr(vorher));
  PrintLn(IntToStr(b()));
  PrintLn(IntToStr(nib(0)));
  PrintLn(IntToStr(fak(5)));
  PrintLn(IntToStr(zwei(4)));
  return 0;
}
fn main(): int64 { a(); PrintLn(IntToStr(nib(0))); return 0; }
EOF
alle_ziele "9 | b->20 | a->10 | fak 120 | zwei 13 | Modul 1" "$TMP/ebenen.lyx" "9|20|10|120|13|1|"

echo
echo "--- ueber Unit-Grenzen ---"
# Zwei Units mit gleichnamiger PRIVATER Aussenfunktion `rechne` und darin je
# einer `nib`: die Marke traegt den unit-lokalen Namen der Aussenfunktion
# (#1655), die beiden bleiben getrennt. Auf den IR-Zielen fallen schon die
# beiden `rechne` zusammen, mit oder ohne innere Funktion (#2076) — deshalb
# nur x86_64; die Fassung mit verschieden benannten Aussenfunktionen
# (`einsR`/`zweiR`) laeuft auf allen Zielen.
#
# Und die andere Richtung: in bib.zwei steht `helfer` nur als INNERE Funktion
# von `nutzer`. Ein freier Aufruf `helfer()` in Zwei() meint die oeffentliche
# aus bib.eins. Bis 1.2.12A trug der Vorlauf fuer private Namen (#1655) auch
# innere Funktionen ein und lenkte diesen Aufruf an die innere um (727 statt
# 1020).
mkdir -p "$TMP/m/bib"
cat > "$TMP/m/bib/eins.lyx" <<'EOF'
unit bib.eins;
fn rechne(): int64 { fn nib(n: int64): int64 { return n + 1; } return nib(0); }
pub fn Eins(): int64 { return rechne(); }
pub fn helfer(): int64 { return 300; }
EOF
cat > "$TMP/m/bib/zwei.lyx" <<'EOF'
unit bib.zwei;
import bib.eins;
fn rechne(): int64 { fn nib(n: int64): int64 { return n + 2; } return nib(0); }
fn nutzer(): int64 {
  fn helfer(): int64 { return 7; }
  return helfer();
}
pub fn Zwei(): int64 { return rechne() * 10 + nutzer() * 100 + helfer(); }
EOF
cat > "$TMP/m/haupt.lyx" <<'EOF'
unit main;
import std.io;
import bib.eins;
import bib.zwei;
fn main(): int64 { PrintLn(IntToStr(Eins())); PrintLn(IntToStr(Zwei())); return 0; }
EOF
nur_x86 "Eins 1 | Zwei 2*10 + 7*100 + 300" "haupt.lyx" "1|1020|" "$TMP/m"

mkdir -p "$TMP/m2/bib"
cat > "$TMP/m2/bib/eins.lyx" <<'EOF'
unit bib.eins;
fn einsR(): int64 { fn nib(n: int64): int64 { return n + 1; } return nib(0); }
pub fn Eins(): int64 { return einsR(); }
EOF
cat > "$TMP/m2/bib/zwei.lyx" <<'EOF'
unit bib.zwei;
fn zweiR(): int64 { fn nib(n: int64): int64 { return n + 2; } return nib(0); }
pub fn Zwei(): int64 { return zweiR(); }
EOF
cat > "$TMP/m2/haupt.lyx" <<'EOF'
unit main;
import std.io;
import bib.eins;
import bib.zwei;
fn main(): int64 { PrintLn(IntToStr(Eins())); PrintLn(IntToStr(Zwei())); return 0; }
EOF
alle_ziele "gleichnamige innere in zwei Units: 1 | 2" "haupt.lyx" "1|2|" "$TMP/m2"

echo
echo "--- Gueltigkeit je BLOCK (x86_64; IR-Weg: #2074) ---"
cat > "$TMP/block.lyx" <<'EOF'
unit main;
import std.io;
fn nib(n: int64): int64 { return 1; }
fn aussen(x: int64): int64 {
  if (x > 0) {
    fn nib(n: int64): int64 { return n + 40; }
    return nib(2);
  }
  return nib(2);                 // nach dem Block: wieder die Modulfunktion
}
fn wahl(x: int64): int64 {
  if (x > 0) {
    fn w(): int64 { return 30; }
    return w();
  } else {
    fn w(): int64 { return 12; }   // gleicher Name, anderer Block
    return w();
  }
}
fn main(): int64 {
  PrintLn(IntToStr(aussen(1))); PrintLn(IntToStr(aussen(0)));
  PrintLn(IntToStr(wahl(1)));   PrintLn(IntToStr(wahl(0)));
  return 0;
}
EOF
nur_x86 "if-Block 42 | danach 1 | if 30 | else 12" "$TMP/block.lyx" "42|1|30|12|"

echo
echo "--- Verdeckung durch Parameter und Variable (x86_64; IR-Weg: #2074) ---"
cat > "$TMP/verdeckt.lyx" <<'EOF'
unit main;
import std.io;
fn zehn(n: int64): int64 { return n + 10; }
fn fuenf(n: int64): int64 { return n + 5; }
fn aussen(): int64 {
  fn nib(): int64 { return 99; }
  fn zehn(n: int64): int64 { return n + 20; }
  // Der Parameter der inneren Funktion verdeckt die nib von aussen. (Umgekehrt
  // nicht: eine innere fn im RUMPF verdeckt einen Parameter, denn der Rumpf
  // ist der innere Bereich — so loest sema auf.)
  fn innen(nib: int64): int64 { return nib; }
  PrintLn(IntToStr(innen(7)));
  {
    var zehn: fn(int64): int64 := fuenf;    // die Variable verdeckt die innere zehn
    PrintLn(IntToStr(zehn(1)));
  }
  PrintLn(IntToStr(zehn(0)));               // wieder die innere
  return 0;
}
fn main(): int64 { aussen(); return 0; }
EOF
nur_x86 "Parameter 7 | Zeiger fuenf(1) 6 | innere zehn(0) 20" "$TMP/verdeckt.lyx" "7|6|20|"

echo
echo "--- innere Funktion einer METHODE (x86_64; IR-Weg: #2074) ---"
# Bis 1.2.12A wurde sie erst nach der NAECHSTEN freien Funktion erzeugt, unter
# dem blanken Namen — der Aufruf traf die gleichnamige Modulfunktion (101).
cat > "$TMP/methode.lyx" <<'EOF'
unit main;
import std.io;
type K = class { v: int64;
  pub fn Rechne(): int64 { fn hilf(n: int64): int64 { return n + 5; } return hilf(self.v); } };
fn hilf(n: int64): int64 { return n + 100; }
fn main(): int64 { var k: K := new K(); k.v := 1; PrintLn(IntToStr(k.Rechne())); PrintLn(IntToStr(hilf(1))); return 0; }
EOF
nur_x86 "Methode 6 | Modul 101" "$TMP/methode.lyx" "6|101|"
# Dasselbe als LETZTE Deklaration der Datei: dann folgte bis 1.2.12A keine
# freie Funktion mehr, die die innere erzeugt haette.
cat > "$TMP/methode_letzt.lyx" <<'EOF'
unit main;
import std.io;
fn main(): int64 { var k: K := new K(); k.v := 2; PrintLn(IntToStr(k.Rechne())); return 0; }
type K = class { v: int64;
  pub fn Rechne(): int64 { fn hilf(n: int64): int64 { return n * 21; } return hilf(self.v); } };
EOF
nur_x86 "Methode als letzte Deklaration: 42" "$TMP/methode_letzt.lyx" "42|"

echo
echo "--- innere Funktion als WERT (x86_64; IR-Weg: #2074) ---"
# Bis 1.2.12A fiel der Bezeichner bis auf cg_zeroRax durch: f war 0, der
# Aufruf stuerzte ab.
cat > "$TMP/wert.lyx" <<'EOF'
unit main;
import std.io;
fn innen(n: int64): int64 { return n + 70; }
fn aussen(): int64 {
  fn innen(n: int64): int64 { return n + 7; }
  var f: fn(int64): int64 := innen;
  return f(1);
}
fn main(): int64 { PrintLn(IntToStr(aussen())); return 0; }
EOF
nur_x86 "f := innen; f(1) = 8" "$TMP/wert.lyx" "8|"

echo
echo "--- Signatur der INNEREN, nicht der gleichnamigen Modulfunktion (x86_64; IR-Weg: #2074) ---"
# Vorgabewert, f64-Rueckgabe, Struct- und Tupel-Rueckgabe werden ueber den
# Namen nachgeschlagen. Mit dem blanken Namen fanden sie die Modulfunktion:
# 100 | 198 | 90 | 90 | 80 | 80.
cat > "$TMP/signatur.lyx" <<'EOF'
unit main;
import std.io;
type P = struct { x: int64; y: int64; };
fn w(n: int64 = 3): int64 { return 100; }
fn halb(v: f64): int64 { return 99; }
fn paar(): P { var p: P; p.x := 90; p.y := 90; return p; }
fn tupel(): [int64, int64] { return (80, 80); }
fn aussen(): int64 {
  fn w(n: int64 = 4): int64 { return n; }
  fn halb(v: f64): f64 { return v / 2.0; }
  fn paar(): P { var p: P; p.x := 1; p.y := 2; return p; }
  fn tupel(): [int64, int64] { return (3, 5); }
  PrintLn(IntToStr(w()));
  var h: f64 := halb(9.0);
  PrintLn(IntToStr((h * 2.0) as int64));
  var p: P := paar();
  PrintLn(IntToStr(p.x)); PrintLn(IntToStr(p.y));
  var t0, t1 := tupel();
  PrintLn(IntToStr(t0)); PrintLn(IntToStr(t1));
  return 0;
}
fn main(): int64 { return aussen(); }
EOF
nur_x86 "Vorgabe 4 | f64 9 | Struct 1,2 | Tupel 3,5" "$TMP/signatur.lyx" "4|9|1|2|3|5|"

echo
echo "--- die stdlib-Units mit inneren Funktionen uebersetzen ZUSAMMEN ---"
# sigv4 (w4), bluetooth_ext und bluetooth_gatts (je eine nib). Das ist nur
# ein Baucheck — den WERT der nib-Rechnung misst tests/nested_fn_ir_test.sh
# an einer woertlichen Kopie von _gs_uuid16_str (die Funktion ist nicht pub,
# die oeffentliche API braucht D-Bus). Dass die Erzeugnisse aller 452
# stdlib-Units durch #2044 bytegleich geblieben sind, steht im PR.
cat > "$TMP/drei.lyx" <<'EOF'
unit main;
import std.hardware.bluetooth_gatts;
import std.hardware.bluetooth_ext;
import std.cloud.aws.sigv4;
fn main(): int64 { return 0; }
EOF
lauf x86_64 "$TMP/drei.lyx" "$TMP/drei.aus" "$ROOT"; rc=$?
if [ "$rc" = 0 ]; then ok "sigv4 + bluetooth_ext + bluetooth_gatts in einem Programm"
else nok "sigv4 + bluetooth_ext + bluetooth_gatts: uebersetzt nicht ($(grep -m1 -iE 'error' "$TMP/build_x86_64.log"))"; fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
