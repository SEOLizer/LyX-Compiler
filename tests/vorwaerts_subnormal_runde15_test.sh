#!/bin/bash
# Runde 15 — Vorwaertsverweis und subnormale Literale (#1663, #1662)
#
#   * #1663: eine Klasse, die eine WEITER UNTEN deklarierte als Parametertyp
#     nimmt. Der Feldzugriff lieferte still 0, der Methodenaufruf brach ab.
#     Geprueft wird beides, und zusaetzlich die Gegenprobe mit umgedrehter
#     Reihenfolge — die war schon vorher gruen und muss es bleiben.
#   * #1662: subnormale Werte wurden still zu 0. Verglichen werden BITMUSTER
#     gegen die IEEE-754-Referenz; formatiert saehe man den Unterschied nicht.
#     Der Test faehrt die Grenzen ab: kleinster normaler, mitten im
#     subnormalen Bereich, kleinster subnormaler, und darunter (dort ist 0
#     richtig).
set -u
cd "$(dirname "$0")/.."
LYXC=${LYXC:-./lyxc}
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
pruefe() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (erwartet '$3', erhalten '$2')"; fi; }

# ---------------------------------------------------------------- #1663
cat > "$TMP/vor.lyx" <<'EOF'
unit Main;
import std.io;

// TA nennt TB, das erst weiter unten steht — Feld UND Methode.
pub type TA = class {
  n: int64;
  fn Create(): void { self.n := 1; }
  fn Feld(o: TB): int64 { return o.m; }
  fn Meth(o: TB): int64 { return o.Wert(); }
}

pub type TB = class {
  m: int64;
  fn Create(): void { self.m := 7; }
  fn Wert(): int64 { return self.m * 10; }
}

// Gegenprobe: dieselbe Beziehung in der anderen Richtung, also mit einer
// bereits deklarierten Klasse. Das war vorher schon richtig.
pub type TC = class {
  fn Create(): void { }
  fn Rueck(o: TB): int64 { return o.m + 100; }
}

// Vererbung ueber Vorwaertsverweis: TD erbt von TE, das spaeter steht.
pub type TD = class extends TE {
  fn Create(): void { self.basis := 5; }
  fn Summe(): int64 { return self.basis + self.Zusatz(); }
}

pub type TE = class {
  basis: int64;
  fn Create(): void { self.basis := 0; }
  virtual fn Zusatz(): int64 { return 3; }
}

fn main(): int64 {
  var a: TA := new TA();
  var b: TB := new TB();
  var c: TC := new TC();
  var d: TD := new TD();
  PrintLn("feld=" + IntToStr(a.Feld(b)));
  PrintLn("methode=" + IntToStr(a.Meth(b)));
  PrintLn("rueck=" + IntToStr(c.Rueck(b)));
  PrintLn("erben=" + IntToStr(d.Summe()));
  return 0;
}
EOF
if ! "$LYXC" --std-path=. "$TMP/vor.lyx" -o "$TMP/vor" > "$TMP/vor.log" 2>&1; then
  bad "#1663 uebersetzt"; grep -E "error" "$TMP/vor.log" | head -3
else
  ok "#1663 uebersetzt"
  if timeout 60 "$TMP/vor" > "$TMP/vor.out" 2>&1; then
    v() { grep "^$1=" "$TMP/vor.out" | head -1 | cut -d= -f2; }
    pruefe "#1663 Feldzugriff ueber Vorwaertsverweis"   "$(v feld)"    "7"
    pruefe "#1663 Methodenaufruf ueber Vorwaertsverweis" "$(v methode)" "70"
    pruefe "#1663 Rueckwaertsverweis unveraendert"      "$(v rueck)"   "107"
    pruefe "#1663 Vererbung ueber Vorwaertsverweis"     "$(v erben)"   "8"
  else
    bad "#1663 laeuft"; head -3 "$TMP/vor.out"
  fi
fi

# ---------------------------------------------------------------- #1662
cat > "$TMP/sub.lyx" <<'EOF'
import std.io;
import std.alloc;
fn bits(d: f64): int64 { var c: int64 := alloc(8); pokef64(c, d); return peek64(c); }
fn main(): int64 {
  PrintLn("normal=" + IntToStr(bits(2.2250738585072014e-308)));
  PrintLn("sub308=" + IntToStr(bits(1.0e-308)));
  PrintLn("sub310=" + IntToStr(bits(1.0e-310)));
  PrintLn("sub320=" + IntToStr(bits(1.0e-320)));
  PrintLn("kleinst=" + IntToStr(bits(4.9e-324)));
  PrintLn("darunter=" + IntToStr(bits(1.0e-330)));
  PrintLn("gross=" + IntToStr(bits(1.0e300)));
  PrintLn("eins=" + IntToStr(bits(1.0)));
  return 0;
}
EOF
if ! "$LYXC" --std-path=. "$TMP/sub.lyx" -o "$TMP/sub" > "$TMP/sub.log" 2>&1; then
  bad "#1662 uebersetzt"; grep -E "error" "$TMP/sub.log" | head -3
else
  ok "#1662 uebersetzt"
  if timeout 60 "$TMP/sub" > "$TMP/sub.out" 2>&1; then
    b() { grep "^$1=" "$TMP/sub.out" | head -1 | cut -d= -f2; }
    # Referenzen: Bitmuster des naechstgelegenen double (CPython struct.pack).
    pruefe "#1662 kleinster normaler unveraendert" "$(b normal)"   "4503599627370496"
    pruefe "#1662 subnormal 1.0e-308"              "$(b sub308)"   "2024022533073106"
    pruefe "#1662 subnormal 1.0e-310"              "$(b sub310)"   "20240225330731"
    pruefe "#1662 subnormal 1.0e-320"              "$(b sub320)"   "2024"
    pruefe "#1662 kleinster subnormaler 4.9e-324"  "$(b kleinst)"  "1"
    pruefe "#1662 darunter ist 0 (richtig so)"     "$(b darunter)" "0"
    pruefe "#1662 grosser Wert unveraendert"       "$(b gross)"    "9094988921128908188"
    pruefe "#1662 1.0 unveraendert"                "$(b eins)"     "4607182418800017408"
  else
    bad "#1662 laeuft"; head -3 "$TMP/sub.out"
  fi
fi

echo "----"
echo "$PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
