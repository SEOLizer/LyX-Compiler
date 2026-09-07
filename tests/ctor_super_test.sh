#!/usr/bin/env bash
# #1973: Der Konstruktor der Basisklasse lief NICHT mit, wenn die Ableitung ein
# eigenes `Create` definiert — und zwar ohne jede Meldung. Die Felder der Basis
# blieben auf 0.
#
# ENTSCHIEDEN WURDE FUER DIE DELPHI-SEMANTIK: der Basiskonstruktor wird nicht
# heimlich untergeschoben, sondern ausdruecklich gerufen. Neu ist, dass sein
# FEHLEN auffaellt — aus dem stillen Nullfeld wird ein Uebersetzungsfehler.
#
# Die Alternative waere gewesen, ihn automatisch laufen zu lassen (C++/Java).
# Das haette das Verhalten bestehenden Codes stillschweigend geaendert; so
# aendert es sich sichtbar und an der Stelle, an der die Entscheidung faellt.
#
# GEMESSEN WIRD IN DREI RICHTUNGEN, denn eine Verschaerfung ist erst dann
# richtig, wenn sie NUR den gemeldeten Fall trifft:
#   * ohne eigenes Create  -> das der Basis wird geerbt und laeuft
#   * mit super.Create()   -> laeuft, beide Feldgruppen gesetzt
#   * ohne super.Create()  -> Uebersetzungsfehler mit Klassennamen
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

# --- Die gueltigen Formen laufen und setzen ALLE Felder --------------------
cat > "$TMP/gut.lyx" <<'EOF'
import std.io;
type TBasis = class {
  N: int64;
  fn Create(): void { self.N := 42; }
}
type TOhne = class extends TBasis { M: int64; }
type TMitSuper = class extends TBasis {
  M: int64;
  fn Create(): void { super.Create(); self.M := 7; }
}
type TSuperImZweig = class extends TBasis {
  M: int64;
  fn Create(): void {
    if (1 == 1) { super.Create(); }
    self.M := 9;
  }
}
fn main(): int64 {
  var a: TOhne := new TOhne();
  var b: TMitSuper := new TMitSuper();
  var c: TSuperImZweig := new TSuperImZweig();
  PrintStr(IntToStr(a.N)); PrintStr(" ");
  PrintStr(IntToStr(b.N)); PrintStr(" "); PrintStr(IntToStr(b.M)); PrintStr(" ");
  PrintStr(IntToStr(c.N)); PrintStr(" "); PrintLn(IntToStr(c.M));
  return 0;
}
EOF
if ( cd "$ROOT" && timeout 120 "$LYXC" --std-path="$ROOT" "$TMP/gut.lyx" -o "$TMP/gut" ) >"$TMP/g.log" 2>&1; then
    ist="$( ulimit -v 4000000; timeout 60 "$TMP/gut" 2>&1 )"
    if [ "$ist" = "42 42 7 42 9" ]; then
        ok "geerbtes, ausdruecklich gerufenes und im Zweig gerufenes Create laufen"
    else
        nok "gueltige Formen: erwartet '42 42 7 42 9', bekommen '$ist'"
    fi
else
    nok "gueltige Formen uebersetzen nicht"; grep -v Copyright "$TMP/g.log" | sed -n '1,4p'
fi

# --- Der gemeldete Fall wird abgewiesen ------------------------------------
cat > "$TMP/schlecht.lyx" <<'EOF'
import std.io;
type TBasis = class {
  N: int64;
  fn Create(): void { self.N := 42; }
}
type TEigen = class extends TBasis {
  M: int64;
  fn Create(): void { self.M := 7; }
}
fn main(): int64 { var b: TEigen := new TEigen(); PrintLn(IntToStr(b.N)); return 0; }
EOF
if ( cd "$ROOT" && timeout 120 "$LYXC" --std-path="$ROOT" "$TMP/schlecht.lyx" -o "$TMP/schlecht" ) >"$TMP/s.log" 2>&1; then
    nok "fehlendes super.Create() uebersetzt durch, statt zu melden"
elif grep -q "weder super.Create() noch setzt es ein Feld" "$TMP/s.log"; then
    # Die Meldung muss die KLASSE nennen — sonst sucht man sie in einer Datei
    # mit dreissig Ableitungen von Hand.
    if grep -q "TEigen" "$TMP/s.log"; then
        ok "fehlendes super.Create() wird gemeldet, mit Klassennamen"
    else
        nok "Meldung nennt die Klasse nicht: $(grep -v Copyright "$TMP/s.log" | head -1)"
    fi
else
    nok "fehlendes super.Create(): falsche Meldung ($(grep -v Copyright "$TMP/s.log" | head -1))"
fi

# --- GEGENPROBE: eigenes Create, das die Basisfelder SELBST setzt ----------
#
# Die erste Fassung dieser Pruefung verlangte `super.Create()` ausnahmslos und
# wies damit ein gaengiges Muster ab: eine Ableitung, die die Initialisierung
# der Basis bewusst und vollstaendig uebernimmt. Drei Tests im Bestand nutzen
# es, und in einem verdeckte die neue Meldung sogar die erwartete Meldung eines
# anderen Tests. Gemeldet wird deshalb nur, wo wirklich etwas ungesetzt bleibt.
cat > "$TMP/selbst.lyx" <<'EOF'
import std.io;
type TBasis = class {
  N: int64;
  fn Create(): void { self.N := 42; }
}
type TSelbst = class extends TBasis {
  M: int64;
  fn Create(): void { self.N := 222; self.M := 7; }
}
fn main(): int64 {
  var s: TSelbst := new TSelbst();
  PrintStr(IntToStr(s.N)); PrintStr(" "); PrintLn(IntToStr(s.M));
  return 0;
}
EOF
if ( cd "$ROOT" && timeout 120 "$LYXC" --std-path="$ROOT" "$TMP/selbst.lyx" -o "$TMP/selbst" ) >"$TMP/se.log" 2>&1; then
    ist="$( ulimit -v 4000000; timeout 60 "$TMP/selbst" 2>&1 )"
    if [ "$ist" = "222 7" ]; then ok "eigenes Create, das die Basisfelder selbst setzt, ist erlaubt"
    else nok "Basisfelder selbst gesetzt: bekommen '$ist'"; fi
else
    nok "eigenes Create mit Basisfeldern wird faelschlich abgewiesen"; grep -v Copyright "$TMP/se.log" | sed -n '1,3p'
fi

# --- GEGENPROBE: eine Basis OHNE Create darf nichts verlangen --------------
#
# Ohne diese Pruefung waere eine Fassung, die bei JEDER Ableitung mit eigenem
# Create meckert, oben unauffaellig — und wuerde Code abweisen, der nie einen
# Basiskonstruktor hatte.
cat > "$TMP/ohnebasis.lyx" <<'EOF'
import std.io;
type TLeer = class { N: int64; }
type TAbl = class extends TLeer {
  M: int64;
  fn Create(): void { self.M := 3; }
}
fn main(): int64 { var a: TAbl := new TAbl(); PrintLn(IntToStr(a.M)); return 0; }
EOF
if ( cd "$ROOT" && timeout 120 "$LYXC" --std-path="$ROOT" "$TMP/ohnebasis.lyx" -o "$TMP/ob" ) >"$TMP/ob.log" 2>&1; then
    ist="$( ulimit -v 4000000; timeout 60 "$TMP/ob" 2>&1 )"
    if [ "$ist" = "3" ]; then ok "Basis ohne Create verlangt kein super.Create()"
    else nok "Basis ohne Create: bekommen '$ist'"; fi
else
    nok "Basis ohne Create wird faelschlich abgewiesen"; grep -v Copyright "$TMP/ob.log" | sed -n '1,3p'
fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
