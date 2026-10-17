#!/usr/bin/env bash
# tests/ir_closures_test.sh — #2108: Closures und Lambdas im IR-Weg.
#
# Bis 1.2.14C kannte lowerExpr (src/ir_lower.lyx) NK_CLOSURE nicht: bis
# 1.2.13F bekam der Knoten einen unbeschriebenen Temp (arm64 SIGSEGV, riscv
# ohne Ausgabe), seit #2092 brach die Uebersetzung laut ab. lowerClosure & Co.
# waren Stubs, lowerExprExtended wurde nie gerufen.
#
# Dazu ein zweiter Defekt, der am Zaehler-Lambda auffiel: IRO_CALL_INDIRECT
# fehlte in der Seiteneffekt-Liste der IR-Optimierung. `f(7);` als Anweisung
# (Ergebnis ungelesen) wurde als toter Code gestrichen — auch fuer jeden
# gewoehnlichen Funktionszeiger.
#
# Gemessen wird die AUSGABE auf x86_64, arm64 und riscv (qemu): sie muss auf
# allen dreien gleich sein UND dem festen Sollwert entsprechen (die Semantik
# des x86-Wegs: Erfassung per Wert, Mutation bleibt in der Umgebung des
# Lambdas, zwei Lambdas haben je eine eigene Kopie). Gegenseite: ein
# einfangendes Lambda als Argument oder in einer `fn(...)`-Variablen wird auf
# beiden Wegen laut abgewiesen (#1249). lyxos wird nur uebersetzt — der lokale
# LBF-Lader kann allokierende Abbilder nicht ausfuehren (rdx statt rax).
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
    linux) timeout 30 "$2" ;;
    arm64) timeout 30 "$QEMU_ARM64" "$2" ;;
    riscv) timeout 30 "$QEMU_RISCV64" "$2" ;;
  esac
}

pruefe() {  # name, datei, soll-ausgabe
  local t x86aus=""
  for t in linux arm64 riscv; do
    rm -f "$TMP/p"
    if ! ( cd "$ROOT" && timeout 240 "$LYXC" --std-path="$ROOT" --target=$t "$2" -o "$TMP/p" ) >"$TMP/bl.log" 2>&1; then
      nok "$1 [$t]: uebersetzt nicht ($(grep -m1 -iE 'error' "$TMP/bl.log"))"; continue
    fi
    local aus rc
    aus="$(lauf $t "$TMP/p" 2>/dev/null | tr '\n' '|')"; rc=${PIPESTATUS[0]}
    [ "$t" = linux ] && x86aus="$aus"
    if [ "$aus" = "$3" ] && [ "$rc" = "0" ] && [ "$aus" = "$x86aus" ]; then ok "$1 [$t]: [$aus]"
    else nok "$1 [$t]: [$aus] rc=$rc statt [$3] (x86: [$x86aus])"; fi
  done
}

# Der Fall aus dem Issue, unveraendert.
pruefe "wp02_closures" "$ROOT/tests/wp02_closures.lyx" "3|10|PASS|"

cat > "$TMP/faelle.lyx" <<'EOF'
import std.io;

fn makeCounter(start: int64): fn(): int64 {
  var n: int64 := start;
  return fn(): int64 { n := n + 1; return n; };
}

fn apply(f: fn(int64): int64, v: int64): int64 {
  return f(v);
}

fn laut(x: int64): int64 {
  PrintInt(x); PrintLn("");
  return x;
}

type K = class {
  v: int64;
  fn Mach(): int64 {
    var g := fn(d: int64): int64 { return self.v + d; };
    return g(2);
  }
};

fn main(): int64 {
  // Erfassung per Wert: eine spaetere Aenderung aussen sieht das Lambda nicht.
  var a: int64 := 10;
  var b: int64 := 3;
  var f := fn(x: int64): int64 { return x * a + b; };
  a := 100;
  PrintInt(f(2)); PrintLn("");
  // Mutation innen bleibt in der Umgebung, aussen unsichtbar.
  var k: int64 := 5;
  var inc := fn(): int64 { k := k + 1; return k; };
  PrintInt(inc()); PrintLn("");
  PrintInt(inc()); PrintLn("");
  PrintInt(k); PrintLn("");
  // Zwei Lambdas erfassen dieselbe Variable: je eine eigene Kopie.
  var s: int64 := 0;
  var p := fn(): int64 { s := s + 10; return s; };
  var q := fn(): int64 { s := s + 1; return s; };
  PrintInt(p()); PrintLn("");
  PrintInt(q()); PrintLn("");
  PrintInt(p()); PrintLn("");
  PrintInt(s); PrintLn("");
  // Lambda als Rueckgabewert, zwei unabhaengige Zaehler, Aufruf als Anweisung.
  var c1 := makeCounter(0);
  var c2 := makeCounter(100);
  c1(); c1();
  PrintInt(c1()); PrintLn("");
  PrintInt(c2()); PrintLn("");
  // Lambda ohne Erfassung: als Argument, ueber eine Variable, als Kopie.
  PrintInt(apply(fn(y: int64): int64 { return y * y; }, 9)); PrintLn("");
  var sq := fn(y: int64): int64 { return y + 1; };
  PrintInt(apply(sq, 41)); PrintLn("");
  var g := sq;
  PrintInt(g(2)); PrintLn("");
  // Sieben Parameter und die Umgebung.
  var m: int64 := 1000;
  var many := fn(p1: int64, p2: int64, p3: int64, p4: int64, p5: int64, p6: int64, p7: int64): int64 {
    return m + p1 + p2 * 2 + p3 * 3 + p4 * 4 + p5 * 5 + p6 * 6 + p7 * 7; };
  PrintInt(many(1, 1, 1, 1, 1, 1, 1)); PrintLn("");
  // In einer Schleife erzeugt: jede Erzeugung kopiert den aktuellen Wert.
  var i: int64 := 0;
  var summe: int64 := 0;
  while (i < 4) {
    var mal := fn(x: int64): int64 { return x * i; };
    summe := summe + mal(10);
    i := i + 1;
  }
  PrintInt(summe); PrintLn("");
  // Ohne return: liefert 0. Lambda-Ergebnis als Argument eines Lambdas.
  var z: int64 := 3;
  var tu := fn(): int64 { PrintInt(z); PrintLn(""); };
  PrintInt(tu()); PrintLn("");
  var plusz := fn(x: int64): int64 { return x + z; };
  PrintInt(plusz(plusz(1))); PrintLn("");
  // `self` einer Methode erfasst.
  var o: K := new K();
  o.v := 40;
  PrintInt(o.Mach()); PrintLn("");
  // Aufruf ueber einen gewoehnlichen Funktionszeiger als Anweisung.
  var fz: fn(int64): int64 := laut;
  fz(7);
  return 0;
}
EOF
pruefe "Erfassung/Mutation/Rueckgabe/Argument/self" "$TMP/faelle.lyx" \
  "23|6|7|5|10|1|20|0|3|101|81|42|3|1028|60|3|0|7|42|7|"

# Gegenseite (#1249): ein einfangendes Lambda passt in keinen `fn(...)`-Typ.
cat > "$TMP/arg.lyx" <<'EOF'
fn apply(f: fn(int64): int64, v: int64): int64 { return f(v); }
fn main(): int64 {
  var a: int64 := 4;
  PrintInt(apply(fn(y: int64): int64 { return y + a; }, 9));
  return 0;
}
EOF
cat > "$TMP/typ.lyx" <<'EOF'
fn main(): int64 {
  var a: int64 := 4;
  var f: fn(int64): int64 := fn(y: int64): int64 { return y + a; };
  PrintInt(f(1));
  return 0;
}
EOF
for fall in arg typ; do
  for t in linux arm64 riscv; do
    ( cd "$ROOT" && timeout 240 "$LYXC" --std-path="$ROOT" --target=$t "$TMP/$fall.lyx" -o "$TMP/k" ) >"$TMP/k.log" 2>&1; rc=$?
    if [ "$rc" != "0" ] && grep -q "einfangendes Lambda" "$TMP/k.log"; then ok "$fall [$t]: laut abgewiesen"
    else nok "$fall [$t]: rc=$rc, keine Meldung zum einfangenden Lambda"; fi
  done
done

# lyxos: nur Uebersetzung (siehe Kopf).
if ( cd "$ROOT" && timeout 240 "$LYXC" --std-path="$ROOT" --target=lyxos tests/wp02_closures.lyx -o "$TMP/l" ) >"$TMP/l.log" 2>&1 \
   && [ -s "$TMP/l" ]; then ok "wp02_closures [lyxos]: uebersetzt"
else nok "wp02_closures [lyxos]: $(grep -m1 -iE 'error' "$TMP/l.log")"; fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
