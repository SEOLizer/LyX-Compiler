#!/bin/bash
# #1668 — zwei gleichnamige Mitglieder in derselben Klasse
#
# Lyx kennt keine Ueberladung, es kann also nur eines gelten; welches, war dem
# Quelltext nicht anzusehen. Geprueft wird ein ABBRUCH — der Compiler muss NEIN
# sagen. Dazu die Gegenproben, dass gueltige Faelle weiter durchgehen; sonst
# waere die Verschaerfung ein neuer Defekt.
set -u
cd "$(dirname "$0")/.."
LYXC=${LYXC:-./lyxc}
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# weist_ab <name> <erwartetes Wort in der Meldung>
weist_ab() {
  if "$LYXC" --std-path=. "$TMP/$1.lyx" -o "$TMP/$1.bin" > "$TMP/$1.log" 2>&1; then
    bad "$1 wird abgewiesen (uebersetzte klaglos)"
  elif grep -q "bereits deklariert" "$TMP/$1.log"; then
    if grep -q "zuerst in Zeile" "$TMP/$1.log"; then
      ok "$1 wird abgewiesen, Meldung nennt beide Zeilen"
    else
      bad "$1: Meldung nennt die erste Zeile nicht"; head -2 "$TMP/$1.log"
    fi
  else
    bad "$1: abgewiesen, aber mit anderer Meldung"; head -2 "$TMP/$1.log"
  fi
}

nimmt_an() {
  if "$LYXC" --std-path=. "$TMP/$1.lyx" -o "$TMP/$1.bin" > "$TMP/$1.log" 2>&1; then
    if timeout 30 "$TMP/$1.bin" > "$TMP/$1.out" 2>&1; then
      if [ "$(cat "$TMP/$1.out")" = "$2" ]; then
        ok "$1 bleibt erlaubt und rechnet richtig"
      else
        bad "$1 rechnet falsch (erwartet '$2', erhalten '$(cat "$TMP/$1.out")')"
      fi
    else
      bad "$1 laeuft"
    fi
  else
    bad "$1 bleibt erlaubt"; grep -E "error" "$TMP/$1.log" | head -2
  fi
}

# --- abzuweisen -----------------------------------------------------------
cat > "$TMP/methode.lyx" <<'EOF'
unit Main;
import std.io;
pub type TDing = class {
  fn Create(): void { }
  fn Wert(): int64 { return 1; }
  fn Wert(): int64 { return 2; }
}
fn main(): int64 { var d: TDing := new TDing(); PrintLn(IntToStr(d.Wert())); return 0; }
EOF
weist_ab methode

cat > "$TMP/feld.lyx" <<'EOF'
import std.io;
type A = class {
  x: int64;
  x: int64;
  fn Create(): void { self.x := 1; }
}
fn main(): int64 { var a: A := new A(); PrintLn(IntToStr(a.x)); return 0; }
EOF
weist_ab feld

cat > "$TMP/gemischt.lyx" <<'EOF'
import std.io;
type B = class {
  w: int64;
  fn Create(): void { self.w := 1; }
  fn w(): int64 { return 2; }
}
fn main(): int64 { var b: B := new B(); PrintLn(IntToStr(b.w)); return 0; }
EOF
weist_ab gemischt

# --- weiterhin erlaubt ----------------------------------------------------
# Gleicher Name in ZWEI Klassen ist voellig in Ordnung.
cat > "$TMP/zweiklassen.lyx" <<'EOF'
import std.io;
type C1 = class { fn Create(): void { } fn Wert(): int64 { return 1; } }
type C2 = class { fn Create(): void { } fn Wert(): int64 { return 2; } }
fn main(): int64 {
  var a: C1 := new C1();
  var b: C2 := new C2();
  PrintLn(IntToStr(a.Wert() + b.Wert()));
  return 0;
}
EOF
nimmt_an zweiklassen "3"

# override in einer ABGELEITETEN Klasse ist kein Duplikat.
cat > "$TMP/ueberschreiben.lyx" <<'EOF'
import std.io;
type Basis = class { fn Create(): void { } virtual fn Wert(): int64 { return 1; } }
type Abl = class extends Basis {
  fn Create(): void { }
  override fn Wert(): int64 { return super.Wert() + 10; }
}
fn main(): int64 { var a: Abl := new Abl(); PrintLn(IntToStr(a.Wert())); return 0; }
EOF
nimmt_an ueberschreiben "11"

# Ein Feld in der Basisklasse und eine gleichnamige Methode in der ABLEITUNG
# sind zwei verschiedene Klassen — hier greift die Pruefung bewusst nicht.
cat > "$TMP/getrennt.lyx" <<'EOF'
import std.io;
type P = class { w: int64; fn Create(): void { self.w := 5; } }
type Q = class extends P { fn Create(): void { self.w := 7; } fn Hol(): int64 { return self.w; } }
fn main(): int64 { var q: Q := new Q(); PrintLn(IntToStr(q.Hol())); return 0; }
EOF
nimmt_an getrennt "7"

echo "----"
echo "$PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
