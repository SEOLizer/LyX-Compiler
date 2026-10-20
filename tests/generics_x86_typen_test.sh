#!/usr/bin/env bash
# tests/generics_x86_typen_test.sh — #2134: Generika auf x86, Typargument-
# Anzahl, generische TYPEN, laute Feldzugriffe.
#
# Bis 1.2.15A:
#   (1) x86 erzeugte EINEN typgeloeschten Rumpf je generischer Funktion;
#       `getx<P>(p)` mit `p.x` lieferte still 0 (IR: richtig 45). Gleitkomma
#       als Typargument wies x86 seit #2125 ab.
#   (2) `max<int64, int64>(1, 2)` uebersetzte auf x86 (sema pruefte die
#       Anzahl nie — der Zweig fragte nach einer Symbolart, die es nicht gibt).
#   (3) `type Box<T> = class {...}` parste auf keinem Ziel; `Box<int64>` als
#       Typangabe galt still als `Box`.
#   (4) IR: ein unaufloesbarer Feldzugriff lieferte einen unbeschriebenen
#       Temp, eine Zuweisung entfiel still.
#
# Gemessen wird der WERT auf x86, arm64 und riscv (qemu), dazu jede Abweisung
# auf allen drei Zielen — und die Gegenseite (richtige Form uebersetzt).
# lyxos: Ganzzahlfaelle ueber den lokalen Lader (er kann nicht allokieren,
# siehe CLAUDE.md "Messsonden"), Klassen am Erzeugnis.
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

baue() {  # ziel datei ausgabe [verzeichnis]
  rm -f "$3"
  ( cd "${4:-$ROOT}" && timeout 240 "$LYXC" --std-path="$ROOT" --target="$1" "$2" -o "$3" ) >"$3.log" 2>&1
}

# vergleiche <name> <datei> <soll> [verzeichnis] — jedes Ziel == soll
vergleiche() {
  local t aus rc
  for t in linux arm64 riscv; do
    if ! baue $t "$2" "$TMP/p" "${4:-}"; then nok "$1 [$t]: uebersetzt nicht ($(grep -m1 -iE 'error|fehler' "$TMP/p.log"))"; continue; fi
    aus="$(lauf $t "$TMP/p" 2>/dev/null | tr '\n' '|')"; rc=${PIPESTATUS[0]}
    if [ "$aus" = "$3" ] && [ "$rc" = 0 ]; then ok "$1 [$t]: [$aus]"
    else nok "$1 [$t]: [$aus] rc=$rc statt [$3]"; fi
  done
}

# abgewiesen <name> <datei> <muster> — auf allen drei Zielen laut, ohne Erzeugnis
abgewiesen() {
  local t
  for t in linux arm64 riscv; do
    if baue $t "$2" "$TMP/r"; then nok "$1 [$t]: uebersetzt, statt abzuweisen"; continue; fi
    if [ -e "$TMP/r" ]; then nok "$1 [$t]: Erzeugnis trotz Fehler"; continue; fi
    if grep -q -- "$3" "$TMP/r.log"; then ok "$1 [$t]: laut abgewiesen"
    else nok "$1 [$t]: Meldung ohne '$3': $(head -c 200 "$TMP/r.log")"; fi
  done
}

# --- 1: Feld ueber T (Woertlich aus #2125/#2134) ----------------------------
cat > "$TMP/kl.lyx" <<'EOF'
type P = class {
  x: int64;
  y: int64;
};
fn getx<T>(p: T): int64 { return p.x + p.y * 10; }
fn setx<T>(p: T, v: int64) { p.x := v; }
fn main(): int64 {
  var p: P := new P();
  p.x := 3; p.y := 4;
  setx<P>(p, 5);
  PrintLn(StrFromInt(getx<P>(p)));
  return 0;
}
EOF
vergleiche "Feld ueber T lesen und schreiben" "$TMP/kl.lyx" "45|"

# --- 1b: Spezialisierung in Spezialisierung, gleiche Parameternamen mit
# verschiedener Zuordnung, Rekursion mit anderer Kombination, Klasse als
# Rueckgabe eines generischen Aufrufs, Gleitkomma ----------------------------
cat > "$TMP/gf.lyx" <<'EOF'
type P = class {
  x: int64;
  y: int64;
};
fn ident<A>(a: A): A { return a; }
fn wrap<A>(a: A): int64 {
  var i: int64 := ident<int64>(7);
  var b: int64 := wrap2<A>(a);
  return i;
}
fn rek<T>(a: T, n: int64): T {
  if (n <= 0) { return a; }
  var k: int64 := rek<int64>(n, n - 1);
  return rek<T>(a + a, n - 1);
}
fn wrap2<A>(a: A): int64 { return 1; }
fn getP<T>(p: T): T { return p; }
fn feld<T>(p: T): int64 { return getP<T>(p).y; }
fn add<T>(a: T, b: T): T { return a + b; }
fn main(): int64 {
  PrintLn(StrFromInt(wrap<f64>(2.5)));
  var w: f64 := ident<f64>(2.5) * 4.0;
  PrintLn(StrFromInt(w as int64));
  var r: f64 := rek<f64>(0.75, 2) * 4.0;
  PrintLn(StrFromInt(r as int64));
  PrintLn(StrFromInt(rek<int64>(3, 3)));
  var p: P := new P();
  p.x := 11; p.y := 31;
  PrintLn(StrFromInt(getP<P>(p).x + feld<P>(p)));
  PrintLn(StrFromInt((add<f64>(0.25, 0.5) * 4.0) as int64));
  return 0;
}
EOF
vergleiche "generisch->generisch, Rekursion, f64, Klasse als Ergebnis" "$TMP/gf.lyx" "7|10|12|24|42|3|"

# --- 1c: Unit-uebergreifend: Spezialisierung im Kontext der Deklaration ----
mkdir -p "$TMP/xm"
# `nenn` steht nur da, damit die Unit den Typ f64 nennt: der IR-Weg ersetzt T
# durch einen KNOTEN seiner Tabelle und weist sonst laut ab (#2125, eigener
# Befund, nicht Gegenstand dieses Tests). x86 braucht das nicht.
cat > "$TMP/xm/gk.lyx" <<'EOF'
unit gk;
fn nenn(x: f64): f64 { return x; }
fn hilf(a: int64): int64 { return a * 2; }
pub fn twice<T>(a: T): T { return a + a; }
pub fn mal<T>(a: T): int64 { return hilf(7); }
EOF
cat > "$TMP/xm/main.lyx" <<'EOF'
import gk;
fn main(): int64 {
  var f: f64 := twice<f64>(1.25) * 4.0;
  PrintLn(StrFromInt(f as int64));
  PrintLn(StrFromInt(twice<int64>(21) + mal<f64>(0.5)));
  return 0;
}
EOF
vergleiche "andere Unit (f64, privater Helfer)" main.lyx "10|56|" "$TMP/xm"

# --- 1d: Aufruf OHNE Typargumente — typgeloeschter Rumpf. Ganzzahl geht
# weiter, ein Feld ueber T bricht zur Laufzeit LAUT ab (bis 1.2.15A: still 0).
cat > "$TMP/ohne.lyx" <<'EOF'
fn max<T>(a: T, b: T): T { if (a > b) { return a; } return b; }
fn main(): int64 { PrintLn(StrFromInt(max(8, 2))); return 0; }
EOF
vergleiche "Aufruf ohne Typargumente (Ganzzahl)" "$TMP/ohne.lyx" "8|"
cat > "$TMP/geloescht.lyx" <<'EOF'
type P = class {
  x: int64;
  y: int64;
};
fn gety<T>(p: T): int64 { return p.y; }
fn main(): int64 {
  var p: P := new P();
  p.x := 3; p.y := 4;
  PrintLn(StrFromInt(gety(p)));
  return 0;
}
EOF
for t in linux arm64 riscv; do
  if baue $t "$TMP/geloescht.lyx" "$TMP/g"; then
    aus="$(lauf $t "$TMP/g" 2>/dev/null | tr '\n' '|')"; rc=${PIPESTATUS[0]}
    if [ "$rc" != 0 ] && [ -z "$aus" ]; then ok "Feld ueber T ohne Typargumente [$t]: Abbruch rc=$rc"
    else nok "Feld ueber T ohne Typargumente [$t]: [$aus] rc=$rc (erwartet: Abbruch ohne Ausgabe)"; fi
  else nok "Feld ueber T ohne Typargumente [$t]: uebersetzt nicht"; fi
done

# --- 2: Anzahl der Typargumente (sema, alle Ziele) --------------------------
cat > "$TMP/anz.lyx" <<'EOF'
fn max<T>(a: T, b: T): T { if (a > b) { return a; } return b; }
fn main(): int64 { PrintLn(StrFromInt(max<int64, int64>(1, 2))); return 0; }
EOF
abgewiesen "zu viele Typargumente" "$TMP/anz.lyx" "generic type argument count mismatch"
cat > "$TMP/anz0.lyx" <<'EOF'
fn h(a: int64): int64 { return a; }
fn main(): int64 { return h<int64>(3); }
EOF
abgewiesen "Typargumente an nicht-generischer Funktion" "$TMP/anz0.lyx" "nicht-generische Funktion"
cat > "$TMP/anz2.lyx" <<'EOF'
fn pick<A, B>(a: A, b: B): A { return a; }
fn main(): int64 { PrintLn(StrFromInt(pick<int64>(1, 2))); return 0; }
EOF
abgewiesen "zu wenige Typargumente" "$TMP/anz2.lyx" "generic type argument count mismatch"
mkdir -p "$TMP/xa"
printf 'unit ga;\npub fn gmax<T>(a: T, b: T): T { if (a > b) { return a; } return b; }\n' > "$TMP/xa/ga.lyx"
printf 'import ga;\nfn main(): int64 { return gmax<int64, int64>(1, 2); }\n' > "$TMP/xa/main.lyx"
for t in linux arm64; do
  if baue $t main.lyx "$TMP/r" "$TMP/xa"; then nok "Anzahl, importierte Funktion [$t]: uebersetzt"
  elif grep -q "generic type argument count mismatch" "$TMP/r.log"; then ok "Anzahl, importierte Funktion [$t]: laut abgewiesen"
  else nok "Anzahl, importierte Funktion [$t]: $(head -c 200 "$TMP/r.log")"; fi
done

# --- 3: generische Typen ----------------------------------------------------
cat > "$TMP/box.lyx" <<'EOF'
type Box<T> = class {
  v: T;
  fn Get(): T { return self.v; }
  fn Put(x: T) { self.v := x; }
};
type Pair<A, B> = class {
  a: A;
  b: B;
  fn First(): A { return self.a; }
  fn Second(): B { return self.b; }
};
type Node<T> = class {
  val: T;
  next: Node<T>;
};
type Pt<T> = struct {
  x: T;
  y: T;
};
fn summe(b: Box<int64>, c: Box<int64>): int64 { return b.Get() + c.v; }
fn mach(x: f64): Box<f64> {
  var b: Box<f64> := new Box<f64>();
  b.Put(x);
  return b;
}
fn main(): int64 {
  var b: Box<int64> := new Box<int64>();
  b.Put(20);
  var c: Box<int64> := new Box<int64>();
  c.v := 22;
  PrintLn(StrFromInt(summe(b, c)));
  var f: Box<f64> := mach(1.25);
  PrintLn(StrFromInt((f.Get() * 4.0) as int64));
  var p: Pair<int64, f64> := new Pair<int64, f64>();
  p.a := 7; p.b := 0.5;
  PrintLn(StrFromInt(p.First() + (p.Second() * 8.0) as int64));
  var bb: Box<Box<int64>> := new Box<Box<int64>>();
  bb.v := b;
  PrintLn(StrFromInt(bb.Get().Get()));
  var n1: Node<int64> := new Node<int64>();
  var n2: Node<int64> := new Node<int64>();
  n1.val := 3; n2.val := 4; n1.next := n2;
  PrintLn(StrFromInt(n1.val * 10 + n1.next.val));
  var q: Pt<int64>;
  q.x := 5; q.y := 6;
  PrintLn(StrFromInt(q.x * q.y));
  return 0;
}
EOF
vergleiche "generische Typen (Felder, Methoden, f64, geschachtelt, rekursiv, struct)" "$TMP/box.lyx" "42|5|11|20|34|30|"

# VMT: die Instanz einer generischen Klasse mit nicht-generischer Basis
# ueberschreibt deren virtuelle Methode; der Aufruf ueber den Basistyp muss
# die Instanz treffen. (Ableiten VON einer Instanz ist Rest und wird unten
# laut abgewiesen.)
cat > "$TMP/vmt.lyx" <<'EOF'
type Basis = class {
  virtual fn Wert(): int64 { return 1; }
};
type Huelle<T> = class extends Basis {
  v: T;
  override fn Wert(): int64 { return 100 + self.v; }
};
fn frag(b: Basis): int64 { return b.Wert(); }
fn main(): int64 {
  var h: Huelle<int64> := new Huelle<int64>();
  h.v := 23;
  PrintLn(StrFromInt(frag(h)));
  var g: Basis := new Basis();
  PrintLn(StrFromInt(frag(g)));
  return 0;
}
EOF
vergleiche "generische Klasse mit Basis und override (VMT)" "$TMP/vmt.lyx" "123|1|"

# Wiederverwendung: Box<int64> zweimal genannt = eine Klasse. Zwei Instanzen
# derselben Kombination muessen zuweisungsvertraeglich sein (sema).
cat > "$TMP/gleich.lyx" <<'EOF'
type Box<T> = class {
  v: T;
};
fn mk(): Box<int64> { var b: Box<int64> := new Box<int64>(); b.v := 9; return b; }
fn main(): int64 {
  var a: Box<int64> := mk();
  PrintLn(StrFromInt(a.v));
  return 0;
}
EOF
vergleiche "dieselbe Kombination ist derselbe Typ" "$TMP/gleich.lyx" "9|"

printf 'type Box<T> = class {\n  v: T;\n};\nfn main(): int64 {\n  var b: Box<int64, int64> := new Box<int64, int64>();\n  return 0;\n}\n' > "$TMP/t1.lyx"
abgewiesen "Typ: falsche Anzahl" "$TMP/t1.lyx" "Anzahl der Typargumente"
printf 'type Q = class {\n  v: int64;\n};\nfn main(): int64 {\n  var b: Q<int64> := new Q();\n  return 0;\n}\n' > "$TMP/t2.lyx"
abgewiesen "Typ: Typargumente an nicht-generischem Typ" "$TMP/t2.lyx" "kein generischer Typ"
printf 'type Box<T> = class {\n  v: T;\n};\nfn f<T>(x: T): int64 {\n  var b: Box<T> := new Box<T>();\n  return 0;\n}\nfn main(): int64 { return f<int64>(1); }\n' > "$TMP/t3.lyx"
abgewiesen "Typ: Typparameter einer Funktion als Argument" "$TMP/t3.lyx" "#2134"
printf 'type I<T> = interface {\n  fn F(): T;\n};\nfn main(): int64 { return 0; }\n' > "$TMP/t4.lyx"
abgewiesen "Typ: generisches Interface" "$TMP/t4.lyx" "nur class und struct"
printf 'type Box<T> = class {\n  v: T;\n};\ntype K = class extends Box<int64> {\n  w: int64;\n};\nfn main(): int64 { return 0; }\n' > "$TMP/t5.lyx"
abgewiesen "Typ: Ableitung von einer Instanz" "$TMP/t5.lyx" "Ableitung von einer generischen Klasse"
printf 'type Box<T> = class {\n  v: T;\n};\nfn main(): int64 {\n  var b: Box<int64[]> := new Box<int64[]>();\n  return 0;\n}\n' > "$TMP/t6.lyx"
abgewiesen "Typ: Array als Typargument" "$TMP/t6.lyx" "kein einfacher Typname"
mkdir -p "$TMP/xt"
printf 'unit gt;\npub type Box<T> = class {\n  v: T;\n};\n' > "$TMP/xt/gt.lyx"
printf 'import gt;\nfn main(): int64 {\n  var b: Box<int64> := new Box<int64>();\n  return 0;\n}\n' > "$TMP/xt/main.lyx"
for t in linux arm64; do
  if baue $t main.lyx "$TMP/r" "$TMP/xt"; then nok "Typ aus anderer Unit [$t]: uebersetzt"
  elif grep -q "kein generischer Typ dieser Unit" "$TMP/r.log"; then ok "Typ aus anderer Unit [$t]: laut abgewiesen"
  else nok "Typ aus anderer Unit [$t]: $(head -c 200 "$TMP/r.log")"; fi
done

# --- 4: IR — Feld, dessen Versatz der IR-Weg nicht bestimmen kann, AUSSERHALB
# einer Spezialisierung. Ausloeser: `a[0].x` auf einem untypisierten `array`
# (sema laesst es durch). Bis 1.2.15A lieferte lowerField den unbeschriebenen
# Temp — gemessen kam still `1` heraus (0 + 1). Jetzt laut. Die
# Gegenseite: derselbe Zugriff ueber einen typisierten Ausdruck rechnet.
# (x86 rechnet hier weiterhin still 0 — eigener Befund, siehe Bericht #2134.)
cat > "$TMP/feld.lyx" <<'EOF'
type P = class {
  x: int64;
};
fn mk(): P { var p: P := new P(); p.x := 41; return p; }
fn main(): int64 {
  var a: array := [0, 0];
  var p: P := mk();
  a[0] := p as int64;
  PrintLn(StrFromInt(a[0].x + 1));
  return 0;
}
EOF
cat > "$TMP/feld_ok.lyx" <<'EOF'
type P = class {
  x: int64;
};
fn mk(): P { var p: P := new P(); p.x := 41; return p; }
fn main(): int64 {
  PrintLn(StrFromInt(mk().x + 1));
  return 0;
}
EOF
for t in arm64 riscv; do
  if baue $t "$TMP/feld.lyx" "$TMP/f"; then
    nok "Feld ohne bestimmbaren Typ [$t]: uebersetzt ($(lauf $t "$TMP/f" 2>/dev/null | tr '\n' '|'))"
  elif grep -q "Feld nicht aufloesbar" "$TMP/f.log"; then ok "Feld ohne bestimmbaren Typ [$t]: laut abgewiesen"
  else nok "Feld ohne bestimmbaren Typ [$t]: $(head -c 200 "$TMP/f.log")"; fi
done
vergleiche "Feld ueber Aufrufergebnis (Gegenseite)" "$TMP/feld_ok.lyx" "42|"

# --- lyxos: Ganzzahl ueber den Lader, Klassen am Erzeugnis ----------------
cat > "$TMP/lx.lyx" <<'EOF'
fn max<T>(a: T, b: T): T { if (a > b) { return a; } return b; }
fn add<T>(a: T, b: T): T { return a + b; }
fn main(): int64 {
  var f: f64 := add<f64>(1.25, 0.5) * 4.0;
  return max<int64>(3, 9) + (f as int64);
}
EOF
if LYX_STD_PATH="$ROOT/std" timeout 200 "$LYXC" --target=lyxos "$TMP/lx.lyx" -o "$TMP/lx.lyxnative" >"$TMP/lx.log" 2>&1; then
  printf 'import src.tools.lbf.loader;\nfn main(): int64 { lbf_run("%s/lx.lyxnative"c); return 111; }' "$TMP" > "$TMP/rl.lyx"
  ( cd "$ROOT" && LYX_STD_PATH="$ROOT/std" timeout 200 "$LYXC" "$TMP/rl.lyx" -o "$TMP/rl" ) >/dev/null 2>&1
  rc=$(timeout 10 "$TMP/rl" >/dev/null 2>&1; echo $?)
  if [ "$rc" = 16 ]; then ok "lyxos (Lader): Generika = 16"; else nok "lyxos (Lader): exit $rc statt 16"; fi
else nok "lyxos: uebersetzt nicht ($(grep -m1 -i error "$TMP/lx.log"))"; fi
if LYX_STD_PATH="$ROOT/std" timeout 200 "$LYXC" --target=lyxos "$TMP/box.lyx" -o "$TMP/bx.lyxnative" >"$TMP/bx.log" 2>&1 && [ -s "$TMP/bx.lyxnative" ]; then
  ok "lyxos: generische Typen uebersetzen"
else nok "lyxos: generische Typen: $(grep -m1 -iE 'error|fehler' "$TMP/bx.log")"; fi
if LYX_STD_PATH="$ROOT/std" timeout 200 "$LYXC" --target=lyxos "$TMP/anz.lyx" -o "$TMP/az.lyxnative" >"$TMP/az.log" 2>&1; then
  nok "lyxos: falsche Typargument-Anzahl uebersetzt"
else ok "lyxos: falsche Typargument-Anzahl laut abgewiesen"; fi

echo "generics_x86_typen: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
