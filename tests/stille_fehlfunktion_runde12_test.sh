#!/bin/bash
# Runde 12 — drei stille Fehlfunktionen (#1637, #1652, #1655)
#
# Gemeinsame Bauart: uebersetzt klaglos, rechnet falsch. Ein Test, der nur
# "laeuft durch" prueft, waere vorher gruen gewesen — deshalb misst jeder
# Abschnitt hier den WEG:
#   * #1637: der Vorgabewert muss EINGESETZT sein. Der Beweis ist nicht ein
#     plausibler Wert, sondern derselbe Wert bei zwei verschiedenen
#     Registerzustaenden (Aufruf mit und ohne vorherige Fremdaufrufe).
#   * #1652: die Verkettung muss VERKETTEN statt Adressen zu addieren — der
#     vordere Teil des Ergebnisses ist der Zeuge.
#   * #1655: dieselben zwei Module in BEIDEN Import-Reihenfolgen. Vorher
#     entschied die Reihenfolge, welcher Rumpf lief.
set -u
cd "$(dirname "$0")/.."
LYXC=${LYXC:-./lyxc}
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
DATA="tests/data/runde12"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
pruefe() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (erwartet '$3', erhalten '$2')"; fi; }

lauf() {  # lauf <name> <quelle> -> Ausgabe in $TMP/<name>.out, rc in $RC
  local n="$1" q="$2"
  if ! "$LYXC" --std-path=. -I "$DATA" "$q" -o "$TMP/$n" > "$TMP/$n.build" 2>&1; then
    bad "$n uebersetzt"; sed -n '1,8p' "$TMP/$n.build"; RC=99; return
  fi
  timeout 60 "$TMP/$n" > "$TMP/$n.out" 2>&1; RC=$?
}
hole() { grep "^$2=" "$TMP/$1.out" | head -1 | cut -d= -f2; }

# ---------------------------------------------------------------- #1637
cat > "$TMP/t1637.lyx" <<'EOF'
import std.io;
type Basis = class {
  fn Geerbt(a: int64, b: int64 = 7): int64 { return a * 100 + b; }
  fn Virt(a: int64 = 3): int64 { return 1000 + a; }
}
type Abl = class extends Basis {
  override fn Virt(a: int64 = 3): int64 { return 2000 + a + super.Virt(); }
  fn Zwei(a: int64, b: int64 = 5, c: int64 = 9): int64 { return a + b * 10 + c * 100; }
}
fn stoerer(p: int64, q: int64, r: int64): int64 { return p + q + r; }
fn main(): int64 {
  var t: Abl := new Abl();
  PrintLn("einfach=" + IntToStr(t.Zwei(1)));
  PrintLn("teil=" + IntToStr(t.Zwei(1, 2)));
  PrintLn("voll=" + IntToStr(t.Zwei(1, 2, 3)));
  PrintLn("geerbt=" + IntToStr(t.Geerbt(1)));
  PrintLn("virt=" + IntToStr(t.Virt()));
  // Register vorher mit anderen Werten fuellen: bliebe der Vorgabewert aus,
  // aenderte sich das Ergebnis. Genau daran war der Defekt zu erkennen.
  var muell: int64 := stoerer(11, 22, 33);
  PrintLn("nach_stoerer=" + IntToStr(t.Zwei(1)));
  PrintLn("stoerer=" + IntToStr(muell));
  return 0;
}
EOF
lauf t1637 "$TMP/t1637.lyx"
if [ "${RC:-99}" -eq 0 ]; then
  pruefe "#1637 Vorgabewert eingesetzt"            "$(hole t1637 einfach)"      "951"
  pruefe "#1637 teilweise belegt"                  "$(hole t1637 teil)"         "921"
  pruefe "#1637 vollstaendig belegt"               "$(hole t1637 voll)"         "321"
  pruefe "#1637 geerbte Methode"                   "$(hole t1637 geerbt)"       "107"
  pruefe "#1637 virtuell + super"                  "$(hole t1637 virt)"         "3006"
  pruefe "#1637 unabhaengig vom Registerzustand"   "$(hole t1637 nach_stoerer)" "951"
elif [ "${RC:-99}" -ne 99 ]; then
  bad "#1637 Programm laeuft (rc=$RC)"
fi

# ---------------------------------------------------------------- #1652
cat > "$TMP/t1652.lyx" <<'EOF'
import std.io;
con C1: pchar := "CON";
let L1: pchar := "LET";
var G1: pchar := "GVAR";
con N: int64 := 7;
fn main(): int64 {
  var lokal: pchar := C1;
  PrintLn("lokal=A[" + lokal + "]");
  PrintLn("kon=B[" + C1 + "]");
  PrintLn("let=C[" + L1 + "]");
  PrintLn("var=D[" + G1 + "]");
  PrintLn("suffix=" + C1 + "-sfx");
  PrintLn("kette=K[" + C1 + L1 + G1 + "]");
  PrintLn("zahl=N[" + IntToStr(N) + "]");
  PrintLn("falten=" + IntToStr(N + 1));
  return 0;
}
EOF
lauf t1652 "$TMP/t1652.lyx"
if [ "${RC:-99}" -eq 0 ]; then
  pruefe "#1652 lokale pchar-Kopie"        "$(hole t1652 lokal)"  "A[CON]"
  pruefe "#1652 globale con"               "$(hole t1652 kon)"    "B[CON]"
  pruefe "#1652 globale let"               "$(hole t1652 let)"    "C[LET]"
  pruefe "#1652 globale var"               "$(hole t1652 var)"    "D[GVAR]"
  pruefe "#1652 con als linker Operand"    "$(hole t1652 suffix)" "CON-sfx"
  pruefe "#1652 Kette aus drei Globalen"   "$(hole t1652 kette)"  "K[CONLETGVAR]"
  pruefe "#1652 Zahl unveraendert"         "$(hole t1652 zahl)"   "N[7]"
  # Gegenprobe: die Konstantenfaltung darf fuer ZAHLEN weiterhin greifen.
  pruefe "#1652 Ganzzahl-Faltung intakt"   "$(hole t1652 falten)" "8"
else
  [ "${RC:-99}" -ne 99 ] && bad "#1652 Programm laeuft (rc=$RC)"
fi

# ---------------------------------------------------------------- #1655
cat > "$TMP/t1655ab.lyx" <<'EOF'
unit coll_ab;
import std.io;
import m.a;
import m.b;
fn main(): int64 { CallA(); CallB(); return 0; }
EOF
cat > "$TMP/t1655ba.lyx" <<'EOF'
unit coll_ba;
import std.io;
import m.b;
import m.a;
fn main(): int64 { CallA(); CallB(); return 0; }
EOF
cat > "$TMP/t1655gl.lyx" <<'EOF'
unit coll_gl;
import std.io;
import n.a;
import n.b;
fn main(): int64 {
  PrintLn("A=" + IntToStr(A()));
  PrintLn("B=" + IntToStr(B()));
  return 0;
}
EOF
erwartet_ab="A.helper x=1 y=2 z=3
B.helper v=42"
for v in ab ba; do
  lauf "t1655$v" "$TMP/t1655$v.lyx"
  if [ "${RC:-99}" -eq 0 ]; then
    if [ "$(cat "$TMP/t1655$v.out")" = "$erwartet_ab" ]; then
      ok "#1655 Reihenfolge $v: jede Unit ruft ihren eigenen Helfer"
    else
      bad "#1655 Reihenfolge $v: falscher Rumpf getroffen"
      sed -n '1,4p' "$TMP/t1655$v.out"
    fi
  elif [ "${RC:-99}" -ne 99 ]; then
    bad "#1655 Reihenfolge $v laeuft (rc=$RC)"
  fi
done
cat > "$TMP/t1655ge.lyx" <<'EOF'
unit coll_ge;
import std.io;
import q.a;
import q.b;
fn main(): int64 {
  PrintLn("QA=" + IntToStr(QA()));
  PrintLn("QB=" + IntToStr(QB()));
  return 0;
}
EOF
lauf t1655gl "$TMP/t1655gl.lyx"
if [ "${RC:-99}" -eq 0 ]; then
  pruefe "#1655 gleiche Stelligkeit, Unit A" "$(hole t1655gl A)" "101"
  pruefe "#1655 gleiche Stelligkeit, Unit B" "$(hole t1655gl B)" "201"
elif [ "${RC:-99}" -ne 99 ]; then
  bad "#1655 gleiche Stelligkeit laeuft (rc=$RC)"
fi

# Geschachtelte private Funktionen: dieselbe Kollision eine Ebene tiefer.
# Der erste Anlauf des Fixes hat nur die Top-Level-Kette gekannt — dann waere
# hier QB=101 herausgekommen, waehrend alles andere gruen aussah.
lauf t1655ge "$TMP/t1655ge.lyx"
if [ "${RC:-99}" -eq 0 ]; then
  pruefe "#1655 geschachtelt, Unit A" "$(hole t1655ge QA)" "101"
  pruefe "#1655 geschachtelt, Unit B" "$(hole t1655ge QB)" "201"
elif [ "${RC:-99}" -ne 99 ]; then
  bad "#1655 geschachtelt laeuft (rc=$RC)"
fi

echo "----"
echo "$PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
