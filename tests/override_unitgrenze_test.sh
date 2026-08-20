#!/bin/bash
# #1710 — Fehlendes `override` wurde ueber die Unit-Grenze nicht gemeldet.
#
# Der Defekt ist doppelt still: keine Meldung beim Uebersetzen UND zur Laufzeit
# laeuft die Basisfassung. Ein Test, der nur die Meldung prueft, wuerde die
# Haelfte uebersehen; einer, der nur das Ergebnis prueft, waere mit `override`
# gruen und ohne rot, ohne den Grund zu nennen. Hier wird beides geprueft.
#
# Der Kern ist die UNIT-GRENZE: in einer Datei hat der Compiler das immer
# gemeldet. Ein Test ohne zweite Unit waere auch vor dem Fix gruen gewesen.
LYXC=${LYXC:-./lyxc}
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
P=0; F=0
ok()  { echo "PASS: $1"; P=$((P+1)); }
bad() { echo "FAIL: $1"; F=$((F+1)); }

mkdir -p "$TMP/Mini"
cat > "$TMP/Mini/Basis.lyx" <<'EOF'
unit Mini.Basis;
pub type TBasis = class {
  Groesse: int64;
  fn Create(): void { self.Groesse := 0; }
  fn Setze(): void { self.Anwenden(); }
  virtual fn Anwenden(): void { }
  fn Nichtvirtuell(): void { }
}
EOF

# 1) Ohne override MUSS gemeldet werden — auch wenn die Basis importiert ist.
cat > "$TMP/ohne.lyx" <<'EOF'
import Mini.Basis;
import std.io;
pub type TAbleitung = class extends TBasis {
  fn Create(): void { self.Groesse := 0; }
  fn Anwenden(): void { self.Groesse := 42; }
}
fn main(): int64 {
  var a: TAbleitung := new TAbleitung();
  a.Setze();
  PrintLn(IntToStr(a.Groesse));
  return 0;
}
EOF
msg="$("$LYXC" --std-path="$ROOT" "$TMP/ohne.lyx" -I "$TMP" -o "$TMP/ohne" 2>&1)"
if [ $? -ne 0 ] && echo "$msg" | grep -q "override"; then
  ok "importierte Basisklasse: fehlendes override wird gemeldet"
else
  bad "importierte Basisklasse: keine Meldung ($(echo "$msg" | grep -i error | head -1))"
fi

# 2) Mit override laeuft es und ruft die ABLEITUNG — nicht die Basisfassung.
#    Genau das war der Schaden: still lief vorher die Basis und lieferte 0.
sed 's/  fn Anwenden(): void/  override fn Anwenden(): void/' "$TMP/ohne.lyx" > "$TMP/mit.lyx"
if "$LYXC" --std-path="$ROOT" "$TMP/mit.lyx" -I "$TMP" -o "$TMP/mit" > "$TMP/m.log" 2>&1; then
  chmod +x "$TMP/mit"; aus="$("$TMP/mit" 2>&1 | head -1)"
  if [ "$aus" = "42" ]; then
    ok "mit override laeuft die Fassung der Ableitung (42)"
  else
    bad "mit override kommt '$aus' statt 42 — es laeuft die Basisfassung"
  fi
else
  bad "mit override uebersetzt nicht ($(grep -oE 'error.*' "$TMP/m.log" | head -1))"
fi

# 3) Eine NICHT virtuelle Basismethode gleichen Namens darf schweigen.
#    Ohne diese Gegenprobe waere eine Regel, die pauschal meldet, ebenfalls
#    gruen — und im Alltag unbrauchbar.
cat > "$TMP/nv.lyx" <<'EOF'
import Mini.Basis;
import std.io;
pub type TAbl2 = class extends TBasis {
  fn Create(): void { self.Groesse := 1; }
  fn Nichtvirtuell(): void { self.Groesse := 7; }
}
fn main(): int64 { var a: TAbl2 := new TAbl2(); PrintLn(IntToStr(a.Groesse)); return 0; }
EOF
if "$LYXC" --std-path="$ROOT" "$TMP/nv.lyx" -I "$TMP" -o "$TMP/nv" > "$TMP/n.log" 2>&1; then
  ok "nicht virtuelle Basismethode: keine Meldung"
else
  bad "nicht virtuelle Basismethode faelschlich gemeldet ($(grep -oE 'sema error.*' "$TMP/n.log" | head -1))"
fi

# 4) Der Fall in EINER Unit muss weiter gemeldet werden (bestand schon).
cat > "$TMP/eine.lyx" <<'EOF'
import std.io;
pub type TB = class {
  n: int64;
  fn Create(): void { self.n := 0; }
  virtual fn Tu(): void { }
}
pub type TA = class extends TB {
  fn Create(): void { self.n := 0; }
  fn Tu(): void { self.n := 1; }
}
fn main(): int64 { var a: TA := new TA(); PrintLn(IntToStr(a.n)); return 0; }
EOF
if "$LYXC" --std-path="$ROOT" "$TMP/eine.lyx" -o "$TMP/eine" > "$TMP/e.log" 2>&1; then
  bad "eine Unit: fehlendes override wird nicht mehr gemeldet (Regress)"
else
  ok "eine Unit: unveraendert gemeldet"
fi

# 5) Sperre: die Pruefung darf nicht wieder am fehlenden Knoten aufgeben.
if grep -q "_mthIstVirtuell" "$ROOT/src/sema.lyx"; then
  ok "die Pruefung fragt die Methodentabelle importierter Typen"
else
  bad "kein Rueckgriff auf die Methodentabelle — die Luecke ist zurueck"
fi

echo "----"
echo "$P PASS, $F FAIL"
[ "$F" -eq 0 ]
