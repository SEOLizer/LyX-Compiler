#!/usr/bin/env bash
# tests/methodmerker_2321_test.sh — Merktabelle fuer cg_findMethodDeclNi (#2321).
#
# Die Suche nach dem Deklarationsknoten einer Methode lief fuer JEDEN
# Methodenaufruf die AST-Geschwisterliste der Klasse ab: beim Uebersetzen von
# src/lyxc.lyx 91 302 Aufrufe mit 4 164 137 Namensvergleichen (45,6 je
# Aufruf). Gemerkt wird jetzt in einer direkt abgebildeten Tabelle mit dem
# Schluessel {pNodes, topLevelHead, classIdx, Namenszeiger, Namenslaenge}.
#
# Dieser Test prueft nicht die Geschwindigkeit, sondern die GEFAHR eines
# Merkers: einen zu kurzen Schluessel. Dieselbe Methodennamen in verschiedenen
# Klassen, in einer Vererbungskette und in VERSCHIEDENEN Units muessen
# weiterhin auf ihre eigene Deklaration zeigen. Ein Merker, der nur den Namen
# als Schluessel nimmt, liefert hier das Ergebnis des ersten Aufrufs — und das
# ist eine stille Fehlfunktion, kein Abbruch.
#
# Gemessen werden WERTE, nicht "laeuft durch": jede Methode gibt eine eigene
# Zahl zurueck, und die Summe ist nur bei richtiger Zuordnung richtig.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ulimit -c 0
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# Zweite Unit mit DENSELBEN Klassen- und Methodennamen. Der Schluessel des
# Merkers enthaelt die Knotentabelle (pNodes) — ohne sie wuerde hier die
# Deklaration der anderen Unit gefunden (#2176: dieselbe Knotennummer bedeutet
# in einer anderen Tabelle etwas anderes).
mkdir -p "$TMP/zwei"
cat > "$TMP/zwei/fremd.lyx" <<'EOF'
unit zwei.fremd;

pub type Traeger = class {
  wert: int64;
  fn Hole(): int64 { return 700; }
  fn Zweit(): int64 { return 701; }
  fn Dritt(): int64 { return 702; }
};

pub fn fremdSumme(): int64 {
  var t: Traeger := new Traeger();
  return t.Hole() + t.Zweit() + t.Dritt();
}
EOF

cat > "$TMP/m.lyx" <<'EOF'
unit main;
import std.io;
import zwei.fremd;

// Gleiche Methodennamen in zwei unverwandten Klassen.
type Traeger = class {
  wert: int64;
  fn Hole(): int64 { return 100; }
  fn Zweit(): int64 { return 101; }
  fn Dritt(): int64 { return 102; }
};

type Anders = class {
  wert: int64;
  fn Hole(): int64 { return 200; }
  fn Zweit(): int64 { return 201; }
  fn Dritt(): int64 { return 202; }
};

// Vererbungskette: Hole bleibt geerbt, Zweit wird ueberschrieben.
type Basis = class {
  wert: int64;
  virtual fn Hole(): int64 { return 300; }
  virtual fn Zweit(): int64 { return 301; }
};

type Abgeleitet = class extends Basis {
  override fn Zweit(): int64 { return 401; }
};

fn main(): int64 {
  var t: Traeger := new Traeger();
  var a: Anders := new Anders();
  var b: Basis := new Basis();
  var d: Abgeleitet := new Abgeleitet();

  // Jede Methode mehrfach aufrufen: der zweite Aufruf liest den Merker, der
  // erste hat ihn gefuellt. Ein falscher Schluessel zeigt sich erst dort.
  var s: int64 := 0;
  var i: int64 := 0;
  while (i < 3) {
    s := s + t.Hole() + t.Zweit() + t.Dritt();
    s := s + a.Hole() + a.Zweit() + a.Dritt();
    s := s + b.Hole() + b.Zweit();
    s := s + d.Hole() + d.Zweit();
    i := i + 1;
  }
  Print("summe="); PrintLn(IntToStr(s));
  Print("fremd="); PrintLn(IntToStr(fremdSumme()));
  // Einzelwerte, damit eine falsche Zuordnung benannt wird und nicht nur die
  // Summe daneben liegt.
  Print("t="); Print(IntToStr(t.Hole())); Print(","); Print(IntToStr(t.Zweit())); Print(","); PrintLn(IntToStr(t.Dritt()));
  Print("a="); Print(IntToStr(a.Hole())); Print(","); Print(IntToStr(a.Zweit())); Print(","); PrintLn(IntToStr(a.Dritt()));
  Print("b="); Print(IntToStr(b.Hole())); Print(","); PrintLn(IntToStr(b.Zweit()));
  Print("d="); Print(IntToStr(d.Hole())); Print(","); PrintLn(IntToStr(d.Zweit()));
  return 0;
}
EOF

if (cd "$TMP" && timeout 300 "$LYXC" --std-path="$ROOT" -I "$TMP" "$TMP/m.lyx" -o "$TMP/m" >"$TMP/m.log" 2>&1); then
  ok "uebersetzt (zwei Units mit gleichen Klassen- und Methodennamen)"
  AUS="$("$TMP/m" 2>&1)"
  hol() { printf '%s\n' "$AUS" | sed -n "s/^$1=//p" | head -1; }
  # 3 * (100+101+102 + 200+201+202 + 300+301 + 300+401) = 3 * 2208 = 6624
  if [ "$(hol summe)" = "6624" ]; then ok "Summe 6624 (jede Methode ihre eigene Deklaration)"
  else no "Summe" "'$(hol summe)' statt 6624 — eine Methode zeigt auf die falsche Deklaration"; fi
  if [ "$(hol t)" = "100,101,102" ]; then ok "Traeger (main): 100,101,102"; else no "Traeger" "'$(hol t)'"; fi
  if [ "$(hol a)" = "200,201,202" ]; then ok "Anders: 200,201,202"; else no "Anders" "'$(hol a)'"; fi
  if [ "$(hol b)" = "300,301" ]; then ok "Basis: 300,301"; else no "Basis" "'$(hol b)'"; fi
  # Geerbte Methode + Ueberschreibung: der Merker darf die Besitzersuche nicht
  # ueberspringen.
  if [ "$(hol d)" = "300,401" ]; then ok "Abgeleitet: geerbtes Hole 300, ueberschriebenes Zweit 401"
  else no "Abgeleitet" "'$(hol d)' statt 300,401 — Vererbung falsch aufgeloest"; fi
  # Gleichnamige Klasse in der ZWEITEN Unit.
  if [ "$(hol fremd)" = "2103" ]; then ok "zwei.fremd.Traeger: 700+701+702 = 2103"
  else no "zweite Unit" "'$(hol fremd)' statt 2103 — der Schluessel unterscheidet die Knotentabellen nicht"; fi
else
  no "uebersetzt" "$(grep -m1 -iE 'error|sema' "$TMP/m.log")"
fi

# Der Merker darf nicht an einem einzigen Eintrag haengen: gemessen waren nur
# 2,4 % der Aufrufe unmittelbare Wiederholungen, 45,6 Vergleiche je Aufruf.
# Deshalb muss die Tabelle mehrere Eintraege halten — sonst ist die Aenderung
# wirkungslos. Geprueft am Quelltext, weil die Wirkung sonst nur in einer
# Zeitmessung sichtbar waere.
if grep -q "mdniCap := 4096" "$ROOT/src/codegen_x86.lyx"; then
  ok "Merktabelle hat 4096 Eintraege (kein Ein-Eintrag-Merker)"
else
  no "Merktabelle" "mdniCap nicht gesetzt — ein Ein-Eintrag-Merker brachte bei 2,4 % Wiederholungen nichts"
fi

echo "=== PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
