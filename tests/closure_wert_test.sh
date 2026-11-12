#!/usr/bin/env bash
# tests/closure_wert_test.sh — #2133: Funktionswerte, Adresse oder Satz.
#
# Ein Funktionswert ist die blanke Codeadresse (Funktionsname, Lambda ohne
# Erfassung, alles in einem `fn(...)`-Typ) oder ein Heap-Satz {Code,
# Umgebung} (einfangendes Lambda). Bei #2108 gemessen, vier Defekte:
#
#   1. `var h := plus; h(2, 3)` — x86 nahm jeden untypisierten Startwert als
#      Satz und las {Code, Umgebung} aus dem Code von plus: SIGSEGV. Der
#      IR-Weg hielt die Adresse und rechnete richtig.
#   2. `var f := mk7(); f(1)`, mk7 gibt ein Lambda OHNE Erfassung zurueck —
#      auf ALLEN Wegen ein Absturz: der Aufruf erwartete einen Satz (der
#      Rueckgabetyp ist ein Funktionstyp), bekam die Adresse. Seither geht ein
#      Funktionswert ueber eine Rueckgabegrenze immer als Satz; eine Adresse
#      wird als {Adresse, 0} eingepackt, und wo eine Adresse gebraucht wird
#      (`fn(...)`-Variable, Argument), wieder ausgepackt.
#   3. Ein erfasstes f64 rechnete x86 als Ganzzahl (x * y mit x = 1.5 -> 0
#      statt 6); dazu waren die Parameter eines Lambdas ohne Typ vermerkt.
#   4. `c()` im Rumpf eines Lambdas erfasste c nicht — c steht dort als
#      Aufrufname, nicht als Bezeichner (beide Wege: "undefined function").
#
# Gemessen wird die AUSGABE auf x86_64, arm64 und riscv (qemu): sie muss auf
# allen dreien gleich sein UND dem festen Sollwert entsprechen. Gegenseite: ein
# einfangendes Lambda an einer Stelle, die nur eine Adresse traegt, bricht zur
# Laufzeit laut ab (rc != 0, kein Signal, der Wert wird nie ausgegeben).
set -uo pipefail
ulimit -c 0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
. "$(dirname "$0")/lib/qemu.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

if [ -z "$QEMU_ARM64" ] || [ -z "$QEMU_RISCV64" ]; then echo "FAIL qemu fuer arm64/riscv fehlt — NICHT gemessen"; exit 1; fi

lauf() {  # ziel, binary
  case "$1" in
    linux) ( cd "$TMP" && timeout 30 "$2" ) ;;
    arm64) ( cd "$TMP" && timeout 30 "$QEMU_ARM64" "$2" ) ;;
    riscv) ( cd "$TMP" && timeout 30 "$QEMU_RISCV64" "$2" ) ;;
  esac
}

uebersetze() {  # ziel, datei, ausgabe — im TMP (dort liegt die importierte Unit)
  ( cd "$TMP" && timeout 240 "$LYXC" --std-path="$ROOT" -I . --target="$1" "$2" -o "$3" ) >"$TMP/bl.log" 2>&1
}

pruefe() {  # name, datei, soll-ausgabe
  local t x86aus=""
  for t in linux arm64 riscv; do
    rm -f "$TMP/p"
    if ! uebersetze "$t" "$2" "$TMP/p"; then
      nok "$1 [$t]: uebersetzt nicht ($(grep -m1 -iE 'error|lyxc:' "$TMP/bl.log"))"; continue
    fi
    local aus rc
    aus="$(lauf $t "$TMP/p" 2>/dev/null | tr '\n' '|')"; rc=${PIPESTATUS[0]}
    [ "$t" = linux ] && x86aus="$aus"
    if [ "$aus" = "$3" ] && [ "$rc" = "0" ] && [ "$aus" = "$x86aus" ]; then ok "$1 [$t]: [$aus]"
    else nok "$1 [$t]: [$aus] rc=$rc statt [$3] (x86: [$x86aus])"; fi
  done
}

# Gegenseite: laut abbrechen, bevor der Wert entsteht.
abbruch() {  # name, datei, verbotene ausgabe
  local t
  for t in linux arm64 riscv; do
    rm -f "$TMP/p"
    if ! uebersetze "$t" "$2" "$TMP/p"; then
      nok "$1 [$t]: uebersetzt nicht ($(grep -m1 -iE 'error|lyxc:' "$TMP/bl.log"))"; continue
    fi
    local aus rc
    aus="$(lauf $t "$TMP/p" 2>"$TMP/err" | tr '\n' '|')"; rc=${PIPESTATUS[0]}
    if [ "$rc" != "0" ] && [ "$rc" -lt 128 ] && [ "$aus" = "vor|" ]; then
      # x86 nennt den Grund; die IR-Ziele melden ihn (noch) nicht, siehe Kopf.
      if [ "$t" = linux ] && ! grep -q "#2133" "$TMP/err"; then nok "$1 [$t]: rc=$rc, aber ohne Meldung"
      else ok "$1 [$t]: laut abgebrochen (rc=$rc)"; fi
    else nok "$1 [$t]: [$aus] rc=$rc — erwartet: Abbruch nach [vor|], kein Signal ($3 darf nicht erscheinen)"; fi
  done
}

# ── Fall 1, woertlich aus dem Issue ─────────────────────────────────────────
cat > "$TMP/fall1.lyx" <<'EOF'
import std.io;
fn plus(a: int64, b: int64): int64 { return a + b; }
fn main(): int64 {
  var h := plus;
  PrintInt(h(2, 3)); PrintLn("");
  var h2 := h;
  PrintInt(h2(10, 20)); PrintLn("");
  // Ein Aufruf im zweiten Argument belegt dieselben Argumentplaetze.
  PrintInt(h(1, plus(2, 3))); PrintLn("");
  return 0;
}
EOF
pruefe "Fall 1: var h := plus" "$TMP/fall1.lyx" "5|30|6|"

# ── Fall 2: Lambda OHNE Erfassung als Rueckgabe ────────────────────────────
cat > "$TMP/fall2.lyx" <<'EOF'
import std.io;
fn inc(x: int64): int64 { return x + 1; }
fn mk7(): fn(int64): int64 {
  return fn(x: int64): int64 { return x + 7; };
}
fn mkInc(): fn(int64): int64 { return inc; }
fn makeAdder(n: int64): fn(int64): int64 { return fn(y: int64): int64 { return y + n; }; }
fn weiter(): fn(int64): int64 { return makeAdder(100); }
type F = fn(int64): int64;
fn mkAlias(): F { return fn(x: int64): int64 { return x * 3; }; }
type K = class {
  b: int64;
  fn Mach(): fn(int64): int64 { return fn(x: int64): int64 { return x - 1; }; }
};
fn main(): int64 {
  var f := mk7();
  PrintInt(f(1)); PrintLn("");
  var p := mkInc();
  PrintInt(p(41)); PrintLn("");
  var a := makeAdder(5);
  PrintInt(a(4)); PrintLn("");
  var w := weiter();
  PrintInt(w(1)); PrintLn("");
  var q := mkAlias();
  PrintInt(q(5)); PrintLn("");
  var o: K := new K();
  var m := o.Mach();
  PrintInt(m(10)); PrintLn("");
  return 0;
}
EOF
pruefe "Fall 2: Funktionswert ueber die Rueckgabegrenze" "$TMP/fall2.lyx" "8|42|9|101|15|9|"

# ── Fall 3: erfasstes f64 ──────────────────────────────────────────────────
cat > "$TMP/fall3.lyx" <<'EOF'
import std.io;
fn main(): int64 {
  var x: f64 := 1.5;
  var m := fn(y: f64): f64 { return x * y; };
  var r: f64 := m(4.0);
  PrintInt(r as int64); PrintLn("");
  var r2: f64 := m(3.0) + 0.5;
  PrintInt((r2 * 2.0) as int64); PrintLn("");
  return 0;
}
EOF
pruefe "Fall 3: erfasstes f64" "$TMP/fall3.lyx" "6|10|"

# ── Fall 4: Lambda ruft ein erfasstes Lambda ───────────────────────────────
cat > "$TMP/fall4.lyx" <<'EOF'
import std.io;
fn plus(a: int64, b: int64): int64 { return a + b; }
fn makeAdder(n: int64): fn(int64): int64 { return fn(y: int64): int64 { return y + n; }; }
fn main(): int64 {
  var k: int64 := 5;
  var c := fn(): int64 { return k + 1; };
  var d := fn(): int64 { return c() * 10; };
  PrintInt(d()); PrintLn("");
  // erfasste Adresse und erfasster Satz (mit und ohne Umgebung)
  var h := plus;
  var a := makeAdder(20);
  var z := fn(v: int64): int64 { return h(v, 100) + a(v); };
  PrintInt(z(1)); PrintLn("");
  // ein Lambda im Lambda erfasst eine Erfassung des aeusseren
  var aussen := fn(): int64 {
    var innen := fn(): int64 { return k * 2; };
    return innen() + c();
  };
  PrintInt(aussen()); PrintLn("");
  return 0;
}
EOF
pruefe "Fall 4: c() im Rumpf" "$TMP/fall4.lyx" "60|122|16|"

# ── Varianten: Argument, fn-Variable, Zuweisung, Modulvariable ─────────────
cat > "$TMP/varianten.lyx" <<'EOF'
import std.io;
fn inc(x: int64): int64 { return x + 1; }
fn mk7(): fn(int64): int64 { return fn(x: int64): int64 { return x + 7; }; }
fn makeAdder(n: int64): fn(int64): int64 { return fn(y: int64): int64 { return y + n; }; }
fn apply(f: fn(int64): int64, v: int64): int64 { return f(v); }
var gf: fn(int64): int64;
var gh := inc;
fn main(): int64 {
  // Satz mit Umgebung 0 dort, wo eine Adresse gebraucht wird
  var g: fn(int64): int64 := mk7();
  PrintInt(g(2)); PrintLn("");
  PrintInt(apply(mk7(), 3)); PrintLn("");
  var f := mk7();
  PrintInt(apply(f, 4)); PrintLn("");
  // Adresse als Argument, direkt und ueber eine Variable
  PrintInt(apply(inc, 5)); PrintLn("");
  var hi := inc;
  PrintInt(apply(hi, 6)); PrintLn("");
  // Zuweisung: die Darstellung haengt an der Deklaration
  var a := makeAdder(5);
  a := mk7();
  PrintInt(a(0)); PrintLn("");
  a := inc;
  PrintInt(a(0)); PrintLn("");
  f := makeAdder(20);
  PrintInt(f(1)); PrintLn("");
  // Modulvariable
  gf := mk7();
  PrintInt(gf(10)); PrintLn("");
  gf := inc;
  PrintInt(gf(10)); PrintLn("");
  PrintInt(gh(30)); PrintLn("");
  return 0;
}
EOF
pruefe "Varianten: Argument/fn-Variable/Zuweisung/Modulvariable" "$TMP/varianten.lyx" "9|10|11|6|7|7|1|21|17|11|31|"

# ── Aus einer importierten Unit ────────────────────────────────────────────
cat > "$TMP/fwlib.lyx" <<'EOF'
unit fwlib;
pub fn plusL(a: int64, b: int64): int64 { return a + b; }
pub fn incL(x: int64): int64 { return x + 1; }
pub fn mk7L(): fn(int64): int64 { return fn(x: int64): int64 { return x + 7; }; }
pub fn adderL(n: int64): fn(int64): int64 { return fn(y: int64): int64 { return y + n; }; }
pub fn mkIncL(): fn(int64): int64 { return incL; }
EOF
cat > "$TMP/import.lyx" <<'EOF'
import std.io;
import fwlib;
fn apply(f: fn(int64): int64, v: int64): int64 { return f(v); }
fn main(): int64 {
  var h := plusL;
  PrintInt(h(2, 3)); PrintLn("");
  var f := mk7L();
  PrintInt(f(1)); PrintLn("");
  var a := adderL(5);
  PrintInt(a(1)); PrintLn("");
  var p := mkIncL();
  PrintInt(p(1)); PrintLn("");
  PrintInt(apply(mk7L(), 2)); PrintLn("");
  var g: fn(int64): int64 := mkIncL();
  PrintInt(g(9)); PrintLn("");
  var k: int64 := 3;
  var d := fn(): int64 { return a(k) + f(k); };
  PrintInt(d()); PrintLn("");
  return 0;
}
EOF
pruefe "aus importierter Unit" "$TMP/import.lyx" "5|8|6|2|9|10|18|"

# ── Gegenseite: einfangendes Lambda, wo nur eine Adresse Platz hat ─────────
cat > "$TMP/ab_var.lyx" <<'EOF'
import std.io;
fn makeAdder(n: int64): fn(int64): int64 { return fn(y: int64): int64 { return y + n; }; }
fn main(): int64 {
  PrintLn("vor");
  var g: fn(int64): int64 := makeAdder(5);
  PrintInt(g(1)); PrintLn("");
  return 0;
}
EOF
abbruch "fn-Variable aus einfangendem Rueckgabewert" "$TMP/ab_var.lyx" "6"
cat > "$TMP/ab_arg.lyx" <<'EOF'
import std.io;
fn makeAdder(n: int64): fn(int64): int64 { return fn(y: int64): int64 { return y + n; }; }
fn apply(f: fn(int64): int64, v: int64): int64 { return f(v); }
fn main(): int64 {
  PrintLn("vor");
  var c := makeAdder(5);
  PrintInt(apply(c, 1)); PrintLn("");
  return 0;
}
EOF
abbruch "einfangendes Satz-Local als Argument" "$TMP/ab_arg.lyx" "6"

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
