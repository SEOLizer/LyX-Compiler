#!/bin/bash
# Nachtrag zu #1595, gefunden beim Nachmessen von #1691.
#
# Mit Struct-Rueckgabe belegt der verdeckte Zeiger rdi — es bleiben FUENF
# Registerplaetze, nicht sechs. Die Schranke im Prolog stand weiter auf sechs:
# beim sechsten Parameter traf kein Spill-Zweig, er bekam einen Slot und wurde
# nie befuellt (las 0), und die folgenden rutschten auf dem Stapel um eine
# Stelle.
#
# Geprueft wird UEBER DIE SCHWELLE (5 bis 9). Ein Test mit vier oder fuenf
# Argumenten waere auch mit dem Fehler gruen gewesen — genau daran ist es
# durchgerutscht: die Faelle aus #1595 hatten alle weniger.
LYXC=${LYXC:-./lyxc}
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
P=0; F=0
ok()  { echo "PASS: $1"; P=$((P+1)); }
bad() { echo "FAIL: $1"; F=$((F+1)); }

lauf() { # $1=quelltext $2=erwartet $3=name
  printf '%s\n' "$1" > "$TMP/c.lyx"
  if "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" > "$TMP/b.log" 2>&1; then
    chmod +x "$TMP/c"; got="$("$TMP/c" 2>&1 | head -1)"
    if [ "$got" = "$2" ]; then ok "$3"; else bad "$3 — '$got' erwartet '$2'"; fi
  else
    bad "$3 — uebersetzt nicht ($(grep -oE 'error.*' "$TMP/b.log" | head -1))"
  fi
}

# --- freie Funktion, int64-Argumente, 5 bis 9 -----------------------------
for n in 5 6 7 8 9; do
  ps=""; args=""; setz=""; felder=""; ausg=""; erw=""
  for i in $(seq 1 $n); do
    ps="$ps p$i: int64,"; args="$args $i,"; setz="$setz v.F$i := p$i;"
    felder="$felder F$i: int64;"; ausg="$ausg + IntToStr(v.F\$i) + \" \""
    erw="$erw$i "
  done
  ps=${ps%,}; args=${args%,}
  ausg=""
  for i in $(seq 1 $n); do ausg="$ausg + IntToStr(v.F$i) + \" \""; done
  lauf "import std.io;
pub type TS = struct {$felder }
fn Mach($ps): TS { var v: TS;$setz return v; }
fn main(): int64 { var v: TS := Mach($args); PrintLn(\"\"$ausg); return 0; }" \
    "$erw" "freie Funktion, $n Argumente, Struct-Rueckgabe"
done

# --- METHODE mit Struct-Rueckgabe und vielen Argumenten -------------------
#    Dort traegt der Prolog den Versatz schon im Startwert; die Gegenprobe
#    stellt sicher, dass der Fix die andere Seite nicht verschoben hat.
lauf 'import std.io;
pub type TS = struct { A: int64; B: int64; C: int64; D: int64; E: int64; F: int64; }
pub type TK = class {
  n: int64;
  fn Create(): void { self.n := 100; }
  fn Mach(a: int64, b: int64, c: int64, d: int64, e: int64, f: int64): TS {
    var v: TS; v.A := a; v.B := b; v.C := c; v.D := d; v.E := e; v.F := f + self.n; return v;
  }
}
fn main(): int64 {
  var k: TK := new TK();
  var v: TS := k.Mach(1, 2, 3, 4, 5, 6);
  PrintLn(IntToStr(v.A) + " " + IntToStr(v.B) + " " + IntToStr(v.C) + " " + IntToStr(v.D) + " " + IntToStr(v.E) + " " + IntToStr(v.F));
  return 0; }' "1 2 3 4 5 106" "Methode, 6 Argumente, Struct-Rueckgabe"

# --- f64-Argumente: der Fall aus std.matrix -------------------------------
#    Mat3New nimmt NEUN f64 und liefert einen Struct. Genau daran ist es
#    aufgefallen; f64 laeuft ueber andere Register als int64.
lauf 'import std.io;
import std.matrix;
fn main(): int64 {
  var a: Mat3 := Mat3New(2.0,1.0,3.0, 0.0,4.0,5.0, 6.0,7.0,1.0);
  Print(FloatToStr(a.m00,0)); Print(" "); Print(FloatToStr(a.m12,0)); Print(" ");
  Print(FloatToStr(a.m20,0)); Print(" "); Print(FloatToStr(a.m22,0)); Print("\n");
  return 0; }' "2 5 6 1" "Mat3New: neun f64-Argumente, Struct-Rueckgabe"

# --- Gegenprobe: OHNE Struct-Rueckgabe bleibt die Grenze bei sechs --------
lauf 'import std.io;
fn Summe(a: int64, b: int64, c: int64, d: int64, e: int64, f: int64, g: int64): int64 {
  return a + b + c + d + e + f + g; }
fn main(): int64 { PrintLn(IntToStr(Summe(1,2,3,4,5,6,7))); return 0; }' \
  "28" "ohne Struct-Rueckgabe: sieben Argumente unveraendert"

echo "----"
echo "$P PASS, $F FAIL"
[ "$F" -eq 0 ]
