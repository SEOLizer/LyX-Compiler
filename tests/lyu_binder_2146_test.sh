#!/bin/bash
# #2146 Stufe C3: der eingebaute Binder. Eine Unit, von der NUR die .lyu mit
# Objektabbild vorliegt, ist aufrufbar -- bis 1.2.38E wies cg_patchAll jeden
# solchen Aufruf mit "stammt aus einer .lyu ohne Objektcode" ab.
#
# DIE GEGENPROBE IST DER KERN: ohne --with-objcode muss dieselbe Uebersetzung
# weiter scheitern. Ein Test, der nur das Gelingen prueft, waere auch von
# einem Compiler erfuellt, der die .lyx heimlich doch findet.
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
PASS=0; FAIL=0
pr() { if [ "$1" = ok ]; then PASS=$((PASS+1)); echo "PASS $2"; else FAIL=$((FAIL+1)); echo "FAIL $2"; fi; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/src/m" "$T/nur/m" "$T/src/oo" "$T/nur/oo"

cat > "$T/src/m/basis.lyx" <<'LYX'
unit m.basis;
pub fn Plus(a: int64, b: int64): int64 { return a + b; }
pub fn Verdopple(a: int64): int64 { return Plus(a, a); }
LYX
cat > "$T/src/m/zaehl.lyx" <<'LYX'
unit m.zaehl;
pub var Summe: int64;
pub fn Nimm(s: pchar): int64 { Summe := Summe + StrLen(s); return Summe; }
LYX
cat > "$T/src/m/a.lyx" <<'LYX'
unit m.a;
import m.basis;
pub fn APlus(x: int64): int64 { return Plus(x, 1); }
LYX
cat > "$T/src/m/b.lyx" <<'LYX'
unit m.b;
import m.basis;
pub fn BPlus(x: int64): int64 { return Plus(x, 2); }
LYX
cat > "$T/src/oo/einfach.lyx" <<'LYX'
unit oo.einfach;
pub type TEinfach = class {
  wert: int64;
  fn Setz(w: int64) { self.wert := w; }
  fn Zeig(): int64 { return self.wert; }
}
pub fn Probe1(w: int64): int64 { var e: TEinfach := new TEinfach(); e.Setz(w); return e.Zeig() * 2; }
LYX
cat > "$T/src/oo/basis.lyx" <<'LYX'
unit oo.basis;
pub type TBasis = class {
  wert: int64;
  fn Setz(w: int64) { self.wert := w; }
  fn Zeig(): int64 { return self.wert; }
}
LYX
cat > "$T/src/oo/kind.lyx" <<'LYX'
unit oo.kind;
import oo.basis;
pub type TKind = class extends TBasis {
  fn Doppelt(): int64 { return self.Zeig() * 2; }
}
pub fn Probe(w: int64): int64 { var k: TKind := new TKind(); k.Setz(w); return k.Doppelt(); }
LYX

baue() {  # $1 = Unterverzeichnis, $2 = Unit, $3.. = zusaetzliche Schalter
  local d="$1"; local u="$2"; shift 2
  "$LYXC" --std-path="$T/src" --compile-unit "$@" "$T/src/$d/$u.lyx" \
      -o "$T/nur/$d/$u.lyu" > "$T/bau_$u.log" 2>&1
}
# WICHTIG: aus einem LEEREN Verzeichnis uebersetzen. Der Import-Resolver
# bevorzugt das Arbeitsverzeichnis vor --std-path -- im Repo-Wurzelverzeichnis
# findet er std/*.lyx und uebersetzt daraus, statt das Abbild zu binden. Genau
# daran ist die erste Fassung dieses Tests vorbeigemessen: sie war gruen, weil
# sie die Quelle benutzte.
mkdir -p "$T/leer"
fuehre() {  # $1 = Programmdatei, $2 = Zielname -> Ausgabe auf stdout, rc im Rueckgabewert
  rm -f "$T/$2"
  ( cd "$T/leer" && "$LYXC" --std-path="$T/nur" -I"$T/nur" "$T/$1" -o "$T/$2" ) > "$T/lauf_$2.log" 2>&1 || return 1
  [ -x "$T/$2" ] || return 1
  "$T/$2"
}

for u in basis zaehl a b; do baue m $u --with-objcode || { echo "FAIL Bau $u"; echo "Ergebnis: 0 PASS, 1 FAIL"; exit 1; }; done
for u in einfach basis kind; do baue oo $u --with-objcode || { echo "FAIL Bau oo/$u"; echo "Ergebnis: 0 PASS, 1 FAIL"; exit 1; }; done

# 1) Funktionen einer reinen .lyu sind aufrufbar und rechnen richtig.
cat > "$T/p1.lyx" <<'LYX'
import m.basis;
fn main(): int64 { return Verdopple(21); }
LYX
fuehre p1.lyx p1 >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 42 ]; then
  pr ok "Verdopple(21) aus der .lyu ergibt 42"
else
  pr no "falscher Rueckgabewert $RC statt 42: $(grep -i error "$T/lauf_p1.log" | head -2)"
fi

# 2) GEGENPROBE: ohne Abbild muss es weiter scheitern, und zwar mit Grund.
baue m basis
if ( cd "$T/leer" && "$LYXC" --std-path="$T/nur" -I"$T/nur" "$T/p1.lyx" -o "$T/p1n" ) > "$T/ohne.log" 2>&1; then
  pr no "ohne Objektcode uebersetzt es trotzdem -- der Test misst nicht das Binden"
else
  if grep -q "ohne Objektcode" "$T/ohne.log"; then
    pr ok "ohne Objektcode scheitert es weiter mit dem genannten Grund"
  else
    pr no "scheitert, aber mit anderem Grund: $(grep -i error "$T/ohne.log" | head -2)"
  fi
fi
baue m basis --with-objcode

# 3) Globale Variable: ueber die Grenze geteilt, nicht doppelt.
cat > "$T/p2.lyx" <<'LYX'
import m.zaehl;
fn main(): int64 { Nimm("abc"); Nimm("de"); return Summe; }
LYX
fuehre p2.lyx p2 >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 5 ]; then
  pr ok "die globale Summe steht nach 3+2 Zeichen auf 5 -- ein Slot"
else
  pr no "Summe ergibt $RC statt 5: $(grep -i error "$T/lauf_p2.log" | head -2)"
fi

# 4) Raute: dieselbe Unit ueber zwei Wege, einmal gebunden.
cat > "$T/p3.lyx" <<'LYX'
import m.a;
import m.b;
fn main(): int64 { return APlus(10) + BPlus(10); }
LYX
fuehre p3.lyx p3 >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 23 ]; then
  pr ok "Rautenimport: m.basis einmal gebunden, Ergebnis 23"
else
  pr no "Rautenimport ergibt $RC statt 23: $(grep -i error "$T/lauf_p3.log" | head -2)"
fi

# 5) Klasse aus der .lyu: new, Methodenaufruf, VMT.
cat > "$T/p4.lyx" <<'LYX'
import oo.einfach;
fn main(): int64 { return Probe1(21); }
LYX
fuehre p4.lyx p4 >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 42 ]; then
  pr ok "Klasse aus der .lyu: new und Methodenaufruf ergeben 42"
else
  pr no "Klasse ergibt $RC statt 42: $(grep -i error "$T/lauf_p4.log" | head -2)"
fi

# 6) Geerbte Methode ueber zwei .lyu hinweg.
cat > "$T/p5.lyx" <<'LYX'
import oo.kind;
fn main(): int64 { return Probe(21); }
LYX
fuehre p5.lyx p5 >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 42 ]; then
  pr ok "geerbte Methode aus einer zweiten .lyu ergibt 42"
else
  pr no "Vererbung ergibt $RC statt 42: $(grep -i error "$T/lauf_p5.log" | head -2)"
fi

# 7) Eine ECHTE stdlib-Unit, nur als .lyu -- mit ihrer ganzen Importhuelle.
#    std.string importiert std.alloc; fehlt dessen Abbild, scheitert es mit
#    "Quelle der importierten Unit nicht lesbar", und zwar zu Recht.
if [ -f std/string.lyx ] && [ -f std/alloc.lyx ]; then
  mkdir -p "$T/snur/std"
  SFEHL=""
  for u in alloc string; do
    "$LYXC" --std-path=. --compile-unit --with-objcode "std/$u.lyx" \
        -o "$T/snur/std/$u.lyu" > "$T/sbau_$u.log" 2>&1 || SFEHL="$SFEHL $u"
  done
  if [ -n "$SFEHL" ]; then
    pr no "kein Abbild fuer std/$SFEHL"
  else
    cat > "$T/p6.lyx" <<'LYX'
import std.string;
fn main(): int64 { return StrLen(StrConcat("Donau", "dampf")); }
LYX
    rm -f "$T/p6"
    if ( cd "$T/leer" && "$LYXC" --std-path="$T/snur" -I"$T/snur" "$T/p6.lyx" -o "$T/p6" ) > "$T/p6.log" 2>&1 \
       && [ -x "$T/p6" ]; then
      "$T/p6"; RC=$?
      if [ "$RC" -eq 10 ]; then
        pr ok "std.string + std.alloc nur als .lyu: StrConcat+StrLen ergeben 10"
      else
        pr no "std.string ergibt $RC statt 10"
      fi
    else
      pr no "std.string bindet nicht: $(grep -i error "$T/p6.log" | head -2)"
    fi
  fi
else
  echo "SKIP 7: std/string.lyx oder std/alloc.lyx fehlt"
fi

# 8) Der reservierte Vorspann ist vollstaendig abgedeckt: die Konstante muss
#    hinter der letzten reservierten Zelle liegen. Ein neuer Platz dort, der
#    hier nicht nachgezogen wird, liesse das Abbild seine EIGENE Kopie lesen
#    -- und die liegt im nur lesbaren Codebereich.
VS=$(grep -oE '^con CG_VEC_SUM: int64 := [0-9]+' src/codegen_x86.lyx | grep -oE '[0-9]+$')
RE=$(grep -oE '^con CG_RES_DATEN_ENDE: int64 := [0-9]+' src/codegen_x86.lyx | grep -oE '[0-9]+$')
GROESSTE=$(grep -oE '^con CG_[A-Z_]+: int64 := [0-9]+;[[:space:]]*// data\[[0-9]+' src/codegen_x86.lyx \
           | grep -oE ':= [0-9]+' | grep -oE '[0-9]+' | sort -n | tail -1)
if [ -n "$VS" ] && [ -n "$RE" ] && [ "$RE" -ge "$((GROESSTE + 8))" ] && [ "$RE" -eq "$((VS + 8))" ]; then
  pr ok "CG_RES_DATEN_ENDE=$RE deckt alle reservierten Zellen (groesste bei $GROESSTE)"
else
  pr no "CG_RES_DATEN_ENDE=$RE passt nicht zu CG_VEC_SUM=$VS / groesster Zelle $GROESSTE"
fi

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "OK: der eingebaute Binder bindet Abbilder aus der .lyu (#2146 Stufe C3)"
