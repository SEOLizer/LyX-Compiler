#!/usr/bin/env bash
# tests/generics_closure_reste_test.sh — #2143: Reste aus #2134/#2133.
#
# Bis 1.2.16A:
#   (1) `var q: T` in einer generischen Funktion: sema "unknown type in var
#       decl 'T'" (nur Parameter und Rueckgabe vom Typ T gingen).
#   (2) IR: `twice<f64>(...)` einer Unit, die f64 nirgends nennt, laut
#       abgewiesen (#2125); eine Klasse der rufenden Unit als Typargument mit
#       Feldzugriff ebenso. x86 konnte beides.
#   (3) Ein Lambda mit Funktionstyp als Rueckgabe packte nicht in {Code,
#       Umgebung} ein, und ein Aufruf ueber ein Local wusste nie, ob er einen
#       Funktionswert liefert: `var a := mk(10); a(1)` mit einfangendem
#       inneren Lambda sprang den Satz als Code an (SIGSEGV, alle Ziele). Ebenso
#       jede tiefere Kette (`dreifach(3)(2)(1)` ueber Locals, Aliase, Units).
#   (4) IR: `k.Plus(5)` mit Funktionstyp-Rueckgabe, geerbt von einer Klasse
#       einer anderen Unit — galt als Adresse (SIGSEGV auf arm64/riscv).
#   dazu aus #2134 laut abgewiesen und jetzt umgesetzt:
#   (5) ein generischer Typ einer ANDEREN Unit (`import gt; Box<int64>`);
#   (6) ein generischer Typ ueber den Typparameter einer generischen
#       Funktion (`Box<T>` in `fn f<T>`), auch ueber Unit-Grenzen.
#
# Gemessen wird die AUSGABE auf x86_64, arm64 und riscv (qemu): gleich auf
# allen dreien UND gleich dem festen Sollwert. Gegenseiten: was weiter nicht
# geht, wird laut abgewiesen bzw. bricht zur Laufzeit laut ab. lyxos:
# Ganzzahlfall ueber den lokalen Lader (er kann nicht allokieren, CLAUDE.md
# "Messsonden"), sonst am Erzeugnis.
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

# uebersetze <ziel> <datei> <ausgabe> [verzeichnis]
uebersetze() {
  ( cd "${4:-$TMP}" && timeout 240 "$LYXC" --std-path="$ROOT" -I . --target="$1" "$2" -o "$3" ) >"$3.log" 2>&1
}

pruefe() {  # name, datei, soll [verzeichnis]
  local t x86aus="" aus rc
  for t in linux arm64 riscv; do
    rm -f "$TMP/p"
    if ! uebersetze "$t" "$2" "$TMP/p" "${4:-}"; then
      nok "$1 [$t]: uebersetzt nicht ($(grep -m1 -iE 'error|lyxc:' "$TMP/p.log"))"; continue
    fi
    aus="$(lauf $t "$TMP/p" 2>/dev/null | tr '\n' '|')"; rc=${PIPESTATUS[0]}
    [ "$t" = linux ] && x86aus="$aus"
    if [ "$aus" = "$3" ] && [ "$rc" = 0 ] && [ "$aus" = "$x86aus" ]; then ok "$1 [$t]: [$aus]"
    else nok "$1 [$t]: [$aus] rc=$rc statt [$3] (x86: [$x86aus])"; fi
  done
}

abgewiesen() {  # name, datei, muster [verzeichnis] — laut, ohne Erzeugnis
  local t
  for t in linux arm64 riscv; do
    rm -f "$TMP/r"
    if uebersetze "$t" "$2" "$TMP/r" "${4:-}"; then nok "$1 [$t]: uebersetzt, statt abzuweisen"; continue; fi
    if [ -e "$TMP/r" ]; then nok "$1 [$t]: Erzeugnis trotz Fehler"; continue; fi
    if grep -q -- "$3" "$TMP/r.log"; then ok "$1 [$t]: laut abgewiesen"
    else nok "$1 [$t]: Meldung ohne '$3': $(head -c 200 "$TMP/r.log")"; fi
  done
}

abbruch() {  # name, datei — laut zur Laufzeit: rc != 0, kein Signal, nur "vor|"
  local t aus rc
  for t in linux arm64 riscv; do
    rm -f "$TMP/p"
    if ! uebersetze "$t" "$2" "$TMP/p"; then nok "$1 [$t]: uebersetzt nicht ($(grep -m1 -iE 'error|lyxc:' "$TMP/p.log"))"; continue; fi
    aus="$(lauf $t "$TMP/p" 2>"$TMP/err" | tr '\n' '|')"; rc=${PIPESTATUS[0]}
    if [ "$rc" != 0 ] && [ "$rc" -lt 128 ] && [ "$aus" = "vor|" ]; then ok "$1 [$t]: laut abgebrochen (rc=$rc)"
    else nok "$1 [$t]: [$aus] rc=$rc — erwartet Abbruch nach [vor|]"; fi
  done
}

# ── (1) Local vom Typparameter ──────────────────────────────────────────────
cat > "$TMP/lokal_t.lyx" <<'EOF'
type Box<T> = class {
  v: T;
};
type P = class {
  x: int64;
  y: int64;
};
type Pt = struct {
  x: int64;
  y: int64;
};
fn ident<T>(a: T): T {
  var q: T := a;
  return q;
}
fn sum<T>(a: T, b: T): T {
  var q: T;
  q := a + b;
  return q;
}
fn swapsum<T>(a: T, b: T): T {
  var t: T := a;
  var u: T := b;
  var w: T := t;
  t := u;
  u := w;
  return t * 10.0 + u;
}
fn feld<T>(p: T): int64 {
  var q: T := p;
  return q.x * 10 + q.y;
}
fn main(): int64 {
  PrintLn(StrFromInt(ident<int64>(41) + 1));
  var f: f64 := sum<f64>(1.25, 0.5) * 4.0;
  PrintLn(StrFromInt(f as int64));
  var s: f64 := swapsum<f64>(1.5, 2.0) * 2.0;
  PrintLn(StrFromInt(s as int64));
  var p: P := new P();
  p.x := 4; p.y := 2;
  PrintLn(StrFromInt(feld<P>(p)));
  var bx: Box<f64> := new Box<f64>();
  bx.v := 0.75;
  var g: f64 := ident<f64>(bx.v) * 4.0;
  PrintLn(StrFromInt(g as int64));
  var pt: Pt;
  pt.x := 3; pt.y := 9;
  PrintLn(StrFromInt(feld<Pt>(pt)));
  return 0;
}
EOF
pruefe "(1) var q: T (int64, f64, Klasse, Struct, Box-Feld)" lokal_t.lyx "42|7|43|42|3|39|"
printf 'fn f<T>(a: T): T {\n  var q: U := a;\n  return q;\n}\nfn main(): int64 { return f<int64>(1); }\n' > "$TMP/lokal_u.lyx"
abgewiesen "(1) Gegenseite: unbekannter Typ im generischen Rumpf" lokal_u.lyx "unknown type in var decl"
printf 'fn f<T>(a: T): T { return a; }\nfn g(a: int64): int64 {\n  var q: T := a;\n  return q;\n}\nfn main(): int64 { return g(1); }\n' > "$TMP/lokal_aussen.lyx"
abgewiesen "(1) Gegenseite: T ausserhalb seiner Funktion" lokal_aussen.lyx "unknown type in var decl"

# ── (2) Typargument, das die Unit der generischen Funktion nicht nennt ─────
mkdir -p "$TMP/u2"
cat > "$TMP/u2/gk.lyx" <<'EOF'
unit gk;
pub fn twice<T>(a: T): T { return a + a; }
pub fn first<T>(a: T, b: int64): T { var q: T := a; return q; }
pub fn getx<T>(p: T): int64 { return p.x; }
pub fn getz<T>(p: T): int64 { return p.z; }
EOF
cat > "$TMP/u2/main.lyx" <<'EOF'
import gk;
type P = class {
  w: int64;
  x: int64;
};
fn main(): int64 {
  var f: f64 := twice<f64>(1.25) * 4.0;
  PrintLn(StrFromInt(f as int64));
  PrintLn(StrFromInt(twice<int64>(21)));
  var g: f64 := first<f64>(2.5, 1) * 2.0;
  PrintLn(StrFromInt(g as int64));
  var p: P := new P();
  p.w := 1; p.x := 42;
  PrintLn(StrFromInt(getx<P>(p)));
  return 0;
}
EOF
pruefe "(2) f64 und Klasse der rufenden Unit, Unit nennt beide nicht" main.lyx "10|42|5|42|" "$TMP/u2"
printf 'import gk;\ntype P = class {\n  w: int64;\n  x: int64;\n};\nfn main(): int64 {\n  var p: P := new P();\n  PrintLn(StrFromInt(getz<P>(p)));\n  return 0;\n}\n' > "$TMP/u2/feldfehlt.lyx"
abgewiesen "(2) Gegenseite: Feld, das das Typargument nicht hat" feldfehlt.lyx "Feld ueber einen Typparameter nicht aufloesbar" "$TMP/u2"

# ── (3) Lambda mit Funktionstyp als Rueckgabe ───────────────────────────────
cat > "$TMP/lambda.lyx" <<'EOF'
fn apply2(g: fn(int64): fn(int64): int64, a: int64): int64 {
  var h := g(a);
  return h(1);
}
fn erzeuge(): fn(int64): fn(int64): int64 {
  return fn(n: int64): fn(int64): int64 { return fn(y: int64): int64 { return y + n; }; };
}
fn main(): int64 {
  var k: int64 := 5;
  var mk := fn(n: int64): fn(int64): int64 {
    return fn(y: int64): int64 { return y + n + k; };
  };
  var a := mk(10);
  PrintLn(StrFromInt(a(1)));
  var mk0 := fn(): fn(int64): int64 { return fn(y: int64): int64 { return y * 2; }; };
  var b := mk0();
  PrintLn(StrFromInt(b(21)));
  var mk2 := mk;
  var a2 := mk2(100);
  PrintLn(StrFromInt(a2(1)));
  var tf: fn(int64): fn(int64): int64 := fn(n: int64): fn(int64): int64 { return fn(y: int64): int64 { return y * n; }; };
  var b2 := tf(6);
  PrintLn(StrFromInt(b2(7)));
  PrintLn(StrFromInt(apply2(tf, 9)));
  var aus := fn(): int64 {
    var c := mk(1000);
    return c(1);
  };
  PrintLn(StrFromInt(aus()));
  var e := erzeuge();
  var f := e(30);
  PrintLn(StrFromInt(f(12)));
  var dreifach := fn(n: int64): fn(int64): fn(int64): int64 {
    return fn(m: int64): fn(int64): int64 { return fn(y: int64): int64 { return y + m * 10 + n * 100; }; };
  };
  var d1 := dreifach(3);
  var d2 := d1(2);
  PrintLn(StrFromInt(d2(1)));
  return 0;
}
EOF
pruefe "(3) Lambda/Local/Parameter/Kopie/Erfassung/Kette" lambda.lyx "16|42|106|42|9|1006|42|321|"
cat > "$TMP/fw.lyx" <<'EOF'
unit fw;
pub type F1 = fn(int64): int64;
pub type F2 = fn(int64): F1;
pub fn erzeugeU(): fn(int64): fn(int64): int64 {
  return fn(n: int64): fn(int64): int64 { return fn(y: int64): int64 { return y + n; }; };
}
pub fn erzeugeA(): F2 {
  return fn(n: int64): F1 { return fn(y: int64): int64 { return y * n; }; };
}
pub type Bau = class {
  b: int64;
  fn Stufe(): fn(int64): fn(int64): int64 {
    return fn(n: int64): fn(int64): int64 { return fn(y: int64): int64 { return y - n; }; };
  }
};
pub type KindB = class extends Bau {
  c: int64;
};
EOF
cat > "$TMP/fwmain.lyx" <<'EOF'
import fw;
type G1 = fn(int64): int64;
type G2 = fn(int64): G1;
fn lokal(): G2 {
  return fn(n: int64): G1 { return fn(y: int64): int64 { return y + n * 2; }; };
}
fn main(): int64 {
  var e := erzeugeU();
  var f := e(30);
  PrintLn(StrFromInt(f(12)));
  var ea := erzeugeA();
  var fa := ea(6);
  PrintLn(StrFromInt(fa(7)));
  var k: KindB := new KindB();
  var s := k.Stufe();
  var t := s(8);
  PrintLn(StrFromInt(t(50)));
  var l := lokal();
  var m := l(20);
  PrintLn(StrFromInt(m(2)));
  var g: G2 := fn(n: int64): G1 { return fn(y: int64): int64 { return y + n + 1; }; };
  var h := g(40);
  PrintLn(StrFromInt(h(1)));
  return 0;
}
EOF
pruefe "(3) Kette ueber Units, Aliase, geerbte Methode" fwmain.lyx "42|42|42|42|42|"
cat > "$TMP/ab_lambda.lyx" <<'EOF'
fn main(): int64 {
  var mk := fn(n: int64): fn(int64): int64 { return fn(y: int64): int64 { return y + n; }; };
  PrintLn("vor");
  var g: fn(int64): int64 := mk(5);
  PrintLn(StrFromInt(g(1)));
  return 0;
}
EOF
abbruch "(3) Gegenseite: einfangender Rueckgabewert in einer fn-Variablen" ab_lambda.lyx

# ── (4) geerbte Methode einer importierten Klasse ───────────────────────────
cat > "$TMP/kl.lyx" <<'EOF'
unit kl;
pub type Basis = class {
  b: int64;
  fn Mach(): fn(int64): int64 { return fn(x: int64): int64 { return x * 2; }; }
  fn Plus(n: int64): fn(int64): int64 { return fn(x: int64): int64 { return x + n; }; }
  fn Wert(): int64 { return self.b + 1; }
};
pub type Kind = class extends Basis {
  c: int64;
};
EOF
cat > "$TMP/klmain.lyx" <<'EOF'
import kl;
type Enkel = class extends Basis {
  e: int64;
};
fn main(): int64 {
  var k: Kind := new Kind();
  k.b := 7;
  var p := k.Plus(5);
  PrintLn(StrFromInt(p(1)));
  var m := k.Mach();
  PrintLn(StrFromInt(m(21)));
  var b: Basis := new Basis();
  var q := b.Plus(10);
  PrintLn(StrFromInt(q(1)));
  var en: Enkel := new Enkel();
  var r := en.Plus(40);
  PrintLn(StrFromInt(r(2)));
  PrintLn(StrFromInt(k.Wert()));
  return 0;
}
EOF
pruefe "(4) geerbte Methode mit fn-Rueckgabe (importierte Basis)" klmain.lyx "6|42|11|42|8|"

# ── (5) generischer Typ einer anderen Unit ──────────────────────────────────
mkdir -p "$TMP/u5"
cat > "$TMP/u5/gt.lyx" <<'EOF'
unit gt;
fn geheim(x: int64): int64 { return x * 3; }
pub type Box<T> = class {
  v: T;
  fn Get(): T { return self.v; }
  fn Put(x: T) { self.v := x; }
  fn Drei(): int64 { return geheim(7); }
};
pub type Pair<A, B> = class {
  a: A;
  b: B;
};
pub fn mkBox(): Box<int64> {
  var b: Box<int64> := new Box<int64>();
  b.v := 5;
  return b;
}
EOF
cat > "$TMP/u5/main.lyx" <<'EOF'
import gt;
fn summe(b: Box<int64>): int64 { return b.Get() + b.v; }
fn main(): int64 {
  var b: Box<int64> := new Box<int64>();
  b.Put(20);
  PrintLn(StrFromInt(summe(b)));
  var f: Box<f64> := new Box<f64>();
  f.Put(1.25);
  var fg: f64 := f.Get();
  PrintLn(StrFromInt((fg * 4.0) as int64));
  var p: Pair<int64, f64> := new Pair<int64, f64>();
  p.a := 7; p.b := 0.5;
  var pb: f64 := p.b;
  PrintLn(StrFromInt(p.a + (pb * 8.0) as int64));
  var bb: Box<Box<int64>> := new Box<Box<int64>>();
  bb.v := b;
  PrintLn(StrFromInt(bb.Get().Get()));
  PrintLn(StrFromInt(b.Drei()));
  var m: Box<int64> := mkBox();
  PrintLn(StrFromInt(m.Get()));
  return 0;
}
EOF
pruefe "(5) generischer Typ einer anderen Unit (privater Helfer, geschachtelt)" main.lyx "40|5|11|20|21|5|" "$TMP/u5"
printf 'import gt;\ntype P = class {\n  x: int64;\n};\nfn main(): int64 {\n  var b: Box<P> := new Box<P>();\n  return 0;\n}\n' > "$TMP/u5/eigen.lyx"
abgewiesen "(5) Gegenseite: Typ der rufenden Unit als Argument" eigen.lyx "Typargument ist ein Typ dieser Unit" "$TMP/u5"

# ── (6) Box<T> in fn f<T> ───────────────────────────────────────────────────
cat > "$TMP/abh.lyx" <<'EOF'
type Box<T> = class {
  v: T;
  fn Get(): T { return self.v; }
  fn Put(x: T) { self.v := x; }
};
fn verpack<T>(x: T): Box<T> {
  var b: Box<T> := new Box<T>();
  b.Put(x);
  return b;
}
fn rund<T>(x: T): T {
  var b: Box<T> := verpack<T>(x);
  var g: T := b.Get();
  return g + g;
}
fn tief<T>(x: T): T {
  var bb: Box<Box<T>> := new Box<Box<T>>();
  bb.v := verpack<T>(x);
  return bb.v.v;
}
fn main(): int64 {
  var b: Box<int64> := verpack<int64>(21);
  PrintLn(StrFromInt(b.Get() * 2));
  PrintLn(StrFromInt(rund<int64>(4)));
  var f: f64 := rund<f64>(1.25) * 2.0;
  PrintLn(StrFromInt(f as int64));
  PrintLn(StrFromInt(tief<int64>(17)));
  return 0;
}
EOF
pruefe "(6) Box<T> in fn f<T> (new, Methoden, Rueckgabe, geschachtelt, transitiv)" abh.lyx "42|8|5|17|"
mkdir -p "$TMP/u6"
cat > "$TMP/u6/gb.lyx" <<'EOF'
unit gb;
pub type Box<T> = class {
  v: T;
};
pub fn verpack<T>(x: T): T {
  var b: Box<T> := new Box<T>();
  b.v := x;
  return b.v * 2;
}
pub fn intern(): int64 { return verpack<int64>(5); }
EOF
cat > "$TMP/u6/main.lyx" <<'EOF'
import gb;
fn main(): int64 {
  PrintLn(StrFromInt(intern()));
  PrintLn(StrFromInt(verpack<int64>(21)));
  PrintLn(StrFromInt(verpack<uint8>(3)));
  return 0;
}
EOF
pruefe "(6) Box<T> in fn f<T> einer anderen Unit, Kombination nur im Aufrufer" main.lyx "10|42|6|" "$TMP/u6"
cat > "$TMP/abh_ohne.lyx" <<'EOF'
type Box<T> = class {
  v: T;
};
fn verpack<T>(x: T): T {
  var b: Box<T> := new Box<T>();
  b.v := x;
  return b.v;
}
fn main(): int64 {
  PrintLn("vor");
  PrintLn(StrFromInt(verpack(21)));
  return 0;
}
EOF
abbruch "(6) Gegenseite: Aufruf ohne Typargumente (typgeloeschter Rumpf)" abh_ohne.lyx

# ── lyxos ───────────────────────────────────────────────────────────────────
cat > "$TMP/lx.lyx" <<'EOF'
fn ident<T>(a: T): T {
  var q: T := a;
  return q;
}
fn main(): int64 { return ident<int64>(40) + 2; }
EOF
if LYX_STD_PATH="$ROOT/std" timeout 200 "$LYXC" --target=lyxos "$TMP/lx.lyx" -o "$TMP/lx.lyxnative" >"$TMP/lx.log" 2>&1; then
  printf 'import src.tools.lbf.loader;\nfn main(): int64 { lbf_run("%s/lx.lyxnative"c); return 111; }' "$TMP" > "$TMP/rl.lyx"
  ( cd "$ROOT" && LYX_STD_PATH="$ROOT/std" timeout 200 "$LYXC" "$TMP/rl.lyx" -o "$TMP/rl" ) >/dev/null 2>&1
  rc=$(timeout 10 "$TMP/rl" >/dev/null 2>&1; echo $?)
  if [ "$rc" = 42 ]; then ok "lyxos (Lader): var q: T = 42"; else nok "lyxos (Lader): exit $rc statt 42"; fi
else nok "lyxos: var q: T uebersetzt nicht ($(grep -m1 -iE 'error|fehler' "$TMP/lx.log"))"; fi
for f in lambda.lyx klmain.lyx abh.lyx; do
  rm -f "$TMP/x.lyxnative"
  if ( cd "$TMP" && LYX_STD_PATH="$ROOT/std" timeout 200 "$LYXC" -I . --target=lyxos "$f" -o "$TMP/x.lyxnative" ) >"$TMP/x.log" 2>&1 && [ -s "$TMP/x.lyxnative" ]; then
    ok "lyxos: $f uebersetzt"
  else nok "lyxos: $f: $(grep -m1 -iE 'error|fehler|lyxc:' "$TMP/x.log")"; fi
done
for d in u2 u5 u6; do
  rm -f "$TMP/x.lyxnative"
  if ( cd "$TMP/$d" && LYX_STD_PATH="$ROOT/std" timeout 200 "$LYXC" -I . --target=lyxos main.lyx -o "$TMP/x.lyxnative" ) >"$TMP/x.log" 2>&1 && [ -s "$TMP/x.lyxnative" ]; then
    ok "lyxos: $d/main.lyx uebersetzt"
  else nok "lyxos: $d/main.lyx: $(grep -m1 -iE 'error|fehler|lyxc:' "$TMP/x.log")"; fi
done

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
