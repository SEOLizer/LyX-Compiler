#!/usr/bin/env bash
# tests/operator_overloading_ir_test.sh — #2060: Operator-Ueberladung
# (ebnf §15.3) auch auf den IR-Zielen.
#
# Hat der linke Operand einen Klassentyp, der die passende Methode definiert,
# ist `a + b` der Aufruf `a.Add(b)`, `a == b` ist `a.Eq(b)`, `a[i]` ist
# `a.Get(i)`. Umgesetzt war das nur im x86-Codegen. Der IR-Weg behielt fuer
# jeden Operator die eingebaute Bedeutung — auf zwei Objektzeigern heisst
# das: `a + b` addiert Adressen und benutzt die Summe als Objekt (Absturz),
# `a[i]` indiziert roh in den Objektspeicher, `a == b` vergleicht Adressen.
# Nichts davon meldete etwas.
#
# GEMESSEN WIRD DER WERT, auf x86_64, arm64 und riscv. Zwei Dinge verdienen
# dabei besondere Sorgfalt:
#   * Ein Adressvergleich kann ZUFAELLIG dasselbe liefern wie der
#     Inhaltsvergleich (beim Vormessen stimmte `a < b` genau deshalb). Die
#     Vergleichsfaelle laufen darum in beiden Anlagereihenfolgen.
#   * Die Gegenseite: wo KEINE Ueberladung greift, bleibt der Operator, was
#     er war — Zahlen, Zeiger, Klassen ohne die Methode, Arrays von Objekten.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
. "$(dirname "$0")/lib/qemu.sh"   # #2048: beide Paketnamen
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }
mkdir -p "$TMP/w/bib"

# Die Klasse, an der fast alle Faelle haengen. `gZ` zaehlt die Aufrufe von
# Add — fuer die Pruefung, dass kein Operand zweimal ausgewertet wird.
KOPF='unit main;
var gZ: int64 := 0;
type V = class { x: int64;
  fn Add(o: V): V { gZ := gZ + 1; var r: V := new V(); r.x := self.x + o.x; return r; }
  fn Sub(o: V): V { var r: V := new V(); r.x := self.x - o.x; return r; }
  fn Mul(o: V): V { var r: V := new V(); r.x := self.x * o.x; return r; }
  fn Div(o: V): V { var r: V := new V(); r.x := self.x / o.x; return r; }
  fn Mod(o: V): V { var r: V := new V(); r.x := self.x % o.x; return r; }
  fn Eq(o: V): int64 { if (self.x == o.x) { return 1; } return 0; }
  fn Lt(o: V): int64 { if (self.x < o.x) { return 1; } return 0; }
  fn Le(o: V): int64 { if (self.x <= o.x) { return 1; } return 0; }
  fn Gt(o: V): int64 { if (self.x > o.x) { return 1; } return 0; }
  fn Ge(o: V): int64 { if (self.x >= o.x) { return 1; } return 0; }
  fn Get(i: int64): int64 { return self.x * 10 + i; } };
fn mk(n: int64): V { var r: V := new V(); r.x := n; return r; }
'

# $1 Beschreibung, $2 Rumpf von main ODER Pfad einer fertigen Quelle, $3 Soll,
# $4 Arbeitsverzeichnis (optional; dann ist $2 ein Dateiname darin)
fall() {
  local was="$1" erw="$3" wd="${4:-}" src ziel
  if [ -n "$wd" ]; then src="$2"
  else
    src="$TMP/f.lyx"; wd="$ROOT"
    printf '%s\nfn main(): int64 {\n%s\n}\n' "$KOPF" "$2" > "$src"
  fi
  for ziel in x86_64 arm64 riscv; do
    local bin="$TMP/b_${ziel}" pre=""
    if ! ( cd "$wd" && timeout 300 "$LYXC" --std-path="$ROOT" --target="$ziel" "$src" -o "$bin" ) >"$TMP/bl.log" 2>&1; then
      nok "$was [$ziel]: uebersetzt nicht ($(grep -m1 -E '^lyxc:|error' "$TMP/bl.log"))"
      continue
    fi
    case "$ziel" in
      arm64) [ -n "$QEMU_ARM64" ]   || { nok "$was [$ziel]: qemu fehlt — NICHT gemessen"; continue; }; pre="$QEMU_ARM64" ;;
      riscv) [ -n "$QEMU_RISCV64" ] || { nok "$was [$ziel]: qemu fehlt — NICHT gemessen"; continue; }; pre="$QEMU_RISCV64" ;;
    esac
    local rc
    rc="$( ( timeout 60 $pre "$bin" >/dev/null 2>&1 ) 2>/dev/null; echo $? )"
    if [ "$rc" = "$erw" ]; then ok "$was [$ziel] (rc=$rc)"
    else nok "$was [$ziel]: rc=$rc statt $erw"; fi
  done
}

echo "--- #2060: die Rechenoperatoren ---"
fall "+  -> Add" '  var c: V := mk(3) + mk(4); return c.x;' 7
fall "-  -> Sub" '  var a: V := mk(9); var b: V := mk(4); var c: V := a - b; return c.x;' 5
fall "*  -> Mul" '  var a: V := mk(6); var b: V := mk(7); var c: V := a * b; return c.x;' 42
fall "/  -> Div" '  var a: V := mk(84); var b: V := mk(4); var c: V := a / b; return c.x;' 21
fall "%  -> Mod" '  var a: V := mk(17); var b: V := mk(5); var c: V := a % b; return c.x;' 2

echo
echo "--- #2060: der Index ---"
fall "a[i] -> Get" '  var a: V := mk(3); return a[2];' 32

echo
echo "--- #2060: die Vergleiche, in BEIDEN Anlagereihenfolgen ---"
#
# Zwei verschiedene Objekte mit gleichem Inhalt: der Inhaltsvergleich sagt
# "gleich", der Adressvergleich "verschieden".
fall "== -> Eq (zwei Objekte, gleicher Inhalt)" '  var a: V := mk(3); var b: V := mk(3); return (a == b) + 10;' 11
#
# Fuer die Ordnung haengt das Ergebnis eines Adressvergleichs daran, welches
# Objekt zuerst angelegt wurde. Mit a zuerst UND mit b zuerst — eine der
# beiden Fassungen faellt bei einem Adressvergleich durch.
#   (a < b) * 8 + (a <= b) * 4 + (a > b) * 2 + (a >= b), mit a.x = 9, b.x = 4:
#   0 + 0 + 2 + 1 = 3
fall "<  <=  >  >=  (a zuerst angelegt)" \
  '  var a: V := mk(9); var b: V := mk(4); return (a < b) * 8 + (a <= b) * 4 + (a > b) * 2 + (a >= b);' 3
fall "<  <=  >  >=  (b zuerst angelegt)" \
  '  var b: V := mk(4); var a: V := mk(9); return (a < b) * 8 + (a <= b) * 4 + (a > b) * 2 + (a >= b);' 3
# Und <= / >= am Gleichstand — dort unterscheiden sie sich von < / >.
fall "<= und >= bei gleichem Inhalt" \
  '  var a: V := mk(5); var b: V := mk(5); return (a <= b) * 2 + (a >= b) + (a < b) * 8 + (a > b) * 16;' 3

echo
echo "--- #2060: != faellt auf die Verneinung von Eq zurueck ---"
#
# V definiert kein Ne. Verschiedener Inhalt -> 1, gleicher Inhalt in zwei
# Objekten -> 0. Der zweite Fall ist der, den ein Adressvergleich verfehlt.
fall "!= bei verschiedenem Inhalt" '  var a: V := mk(3); var b: V := mk(4); return (a != b) + 10;' 11
fall "!= bei gleichem Inhalt in zwei Objekten" '  var a: V := mk(3); var b: V := mk(3); return (a != b) + 10;' 10

echo
echo "--- #2060: Ketten ---"
#
# Das Ergebnis einer ueberladenen Rechnung ist selbst wieder ein gueltiger
# linker Operand und ein gueltiger Empfaenger.
fall "(a + b) + c" '  var r: V := (mk(1) + mk(2)) + mk(4); return r.x;' 7
fall "a + b * c  (Punkt vor Strich, beide ueberladen)" \
  '  var a: V := mk(2); var b: V := mk(3); var c: V := mk(4); var r: V := a + b * c; return r.x;' 14
fall "(a + b)[1]  und  (a + b) == c" \
  '  var a: V := mk(2); var b: V := mk(3); var c: V := mk(5); return (a + b)[1] + ((a + b) == c);' 52
fall "Aufrufergebnis als linker Operand: mk(3) + mk(4)" '  return (mk(3) + mk(4))[0];' 70

echo
echo "--- #2060: jeder Operand wird GENAU EINMAL ausgewertet ---"
#
# Add zaehlt mit. `(a + b) + c` sind zwei Aufrufe; liefe ein Operand doppelt
# (einmal fuer die Typbestimmung, einmal fuer den Aufruf), waeren es mehr.
fall "zwei Additionen sind zwei Aufrufe von Add" \
  '  var r: V := (mk(1) + mk(2)) + mk(4); return gZ * 10 + r.x;' 27

echo
echo "--- #2060: ein GEERBTER Operator wirkt ---"
#
# Die Ableitung definiert nichts selbst. Auf dem x86-Weg war genau das bis
# 1.2.11F ebenfalls falsch (gesucht wurde nur in der Klasse selbst) — hier
# stimmen die Wege jetzt ueberein.
cat > "$TMP/w/erbe.lyx" <<'EOF'
unit main;
type A = class { x: int64;
  fn Add(o: A): A { var r: A := new A(); r.x := self.x + o.x; return r; }
  fn Eq(o: A): int64 { if (self.x == o.x) { return 1; } return 0; }
  fn Get(i: int64): int64 { return self.x * 10 + i; } };
type B = class extends A { y: int64; };
fn main(): int64 {
  var a: B := new B(); var b: B := new B();
  a.x := 3; b.x := 4;
  var c: A := a + b;
  var d: B := new B(); d.x := 3;
  return c.x * 10 + (a == d) + (a[0] % 2);
}
EOF
fall "+ == [] aus der Basisklasse" "erbe.lyx" 71 "$TMP/w"

echo
echo "--- #2060: die Klasse steht in einem ANDEREN MODUL ---"
#
# Hier haengt alles an der Frage, welchen TYP ein Aufruf liefert, wenn die
# Funktion in einer anderen Unit steht. Drei Wege: freie Funktion als linker
# Operand, ueberladene Rechnung als linker Operand, Methodenaufruf als
# Empfaenger eines weiteren Methodenaufrufs.
cat > "$TMP/w/bib/vek.lyx" <<'EOF'
unit bib.vek;
pub type Vek = class { x: int64;
  fn Add(o: Vek): Vek { var r: Vek := new Vek(); r.x := self.x + o.x; return r; }
  fn Eq(o: Vek): int64 { if (self.x == o.x) { return 1; } return 0; }
  fn Get(i: int64): int64 { return self.x * 10 + i; }
  fn Doppelt(): Vek { var r: Vek := new Vek(); r.x := self.x * 2; return r; }
  fn Wert(): int64 { return self.x; } };
pub fn MkVek(n: int64): Vek { var r: Vek := new Vek(); r.x := n; return r; }
EOF
cat > "$TMP/w/imp.lyx" <<'EOF'
unit main;
import bib.vek;
fn main(): int64 {
  var b: Vek := MkVek(4);
  var j: Vek := MkVek(3) + b;            // freie Funktion links
  var k: Vek := (j + b) + b;             // ueberladene Rechnung links
  var gleich: int64 := (j == MkVek(7));  // Vergleich, zwei Objekte
  return k.Doppelt().Wert() + j[1] + gleich;   // Methodenkette: 30 + 71 + 1
}
EOF
fall "importierte Klasse: Operatoren, Ketten, Methodenkette" "imp.lyx" 102 "$TMP/w"

echo
echo "--- GEGENPROBE: wo keine Ueberladung greift, bleibt der Operator ---"
fall "Zahlen: + - * / % und Vergleiche" \
  '  var a: int64 := 17; var b: int64 := 5; return (a + b) + (a - b) + (a * b) % 7 + (a / b) + (a % b) + (a > b) + (a == b);' 41
fall "Zeiger: Index und Addition auf pchar bzw. int64" \
  '  var p: int64 := mmap(0, 4096, 3, 34, 0 - 1, 0); poke8(p + 3, 65); var q: int64 := p + 3; return peek8(q);' 65
#
# Eine Klasse OHNE die Methode: `==` vergleicht dann die Objekte selbst.
# Dasselbe Objekt -> gleich, zwei Objekte mit gleichem Inhalt -> verschieden.
cat > "$TMP/w/ohne.lyx" <<'EOF'
unit main;
type N = class { x: int64; };
fn main(): int64 {
  var a: N := new N(); var b: N := new N();
  a.x := 3; b.x := 3;
  var c: N := a;
  return (a == c) * 10 + (a == b) + 20;
}
EOF
fall "Klasse ohne Eq: == bleibt der Vergleich der Objekte" "ohne.lyx" 30 "$TMP/w"
#
# Ein ARRAY von Klassenwerten ist kein Klassenobjekt (#1109). `cs[1]` ist der
# Elementzugriff und darf nicht zu `cs.Get(1)` werden — obwohl die Klasse der
# ELEMENTE ein Get hat.
cat > "$TMP/w/feld.lyx" <<'EOF'
unit main;
type G = class { x: int64;
  fn Get(i: int64): int64 { return 99; } };
fn main(): int64 {
  var cs: G[2];
  var g0: G := new G(); g0.x := 5;
  var g1: G := new G(); g1.x := 7;
  cs[0] := g0; cs[1] := g1;
  var e: G := cs[1];
  return e.x + g0[0];
}
EOF
# 7 = das zweite ELEMENT (waere `cs[1]` zu `cs.Get(1)` geworden, staende dort
# 99 und der Feldzugriff danach liefe ins Leere); 99 = Get auf dem Objekt.
fall "G[2]: cs[1] ist das Element, g0[0] ist Get: 7 + 99" "feld.lyx" 106 "$TMP/w"

echo
echo "--- das Beispiel, an dem es auffiel ---"
#
# examples/basics/text_operators.lyx muss auf jedem Ziel dieselbe Ausgabe
# liefern wie auf x86.
if ( cd "$ROOT" && timeout 300 "$LYXC" examples/basics/text_operators.lyx -o "$TMP/to_x86" ) >"$TMP/bl.log" 2>&1; then
  soll="$("$TMP/to_x86" 2>&1)"
  for ziel in arm64 riscv; do
    pre="$QEMU_ARM64"; [ "$ziel" = "riscv" ] && pre="$QEMU_RISCV64"
    if ! ( cd "$ROOT" && timeout 300 "$LYXC" --target="$ziel" examples/basics/text_operators.lyx -o "$TMP/to_$ziel" ) >"$TMP/bl.log" 2>&1; then
      nok "text_operators [$ziel]: uebersetzt nicht ($(grep -m1 -E '^lyxc:|error' "$TMP/bl.log"))"; continue
    fi
    [ -n "$pre" ] || { nok "text_operators [$ziel]: qemu fehlt — NICHT gemessen"; continue; }
    ist="$( ( timeout 60 $pre "$TMP/to_$ziel" 2>&1 ) 2>/dev/null )"
    if [ "$ist" = "$soll" ]; then ok "text_operators [$ziel]: Ausgabe wie auf x86 ($(printf '%s\n' "$ist" | wc -l) Zeilen)"
    else nok "text_operators [$ziel]: weicht ab — erste Abweichung: $(diff <(printf '%s\n' "$soll") <(printf '%s\n' "$ist") | grep -m1 '^>')"; fi
  done
else
  nok "text_operators uebersetzt auf x86 nicht ($(grep -m1 -E '^lyxc:|error' "$TMP/bl.log"))"
fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
