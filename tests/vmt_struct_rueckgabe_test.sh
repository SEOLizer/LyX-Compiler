#!/bin/bash
# #1694 — Regression aus #1595: bei einer struct-liefernden Methode traegt rdi
# die Zieladresse des Aufrufers, `self` ist nach rsi gerueckt. Der
# VMT-Dispatch las weiter aus rdi, nahm also den sret-Puffer fuer das Objekt,
# holte daraus Muell als Vtable-Zeiger und sprang dorthin.
#
# Ausgeloest hat es die blosse ANWESENHEIT eines Interfaces mit gleichnamiger
# Methode — erst dadurch wird der Aufruf virtuell. Deshalb prueft dieser Test
# genau diese Kombination und nicht nur "Methode gibt Struct zurueck": ohne
# Interface war der Fall auch vor dem Fix gruen und haette nichts belegt.
LYXC=${LYXC:-./lyxc}
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
P=0; F=0
ok()  { echo "PASS: $1"; P=$((P+1)); }
bad() { echo "FAIL: $1"; F=$((F+1)); }

lauf() {  # $1=Datei $2=Erwartung $3=Beschreibung
  if "$LYXC" --std-path=. "$1" -o "$TMP/p" > "$TMP/b.log" 2>&1; then
    chmod +x "$TMP/p"
    aus="$("$TMP/p" 2>&1 | tr '\n' ' ')"; rc=$?
    if [ "$aus" = "$2" ]; then ok "$3"
    else bad "$3 (erwartet '$2', bekam '$aus', rc=$rc)"; fi
  else
    bad "$3 — uebersetzt nicht ($(grep -oE 'error.*' "$TMP/b.log" | head -1))"
  fi
}

# 1) Der Minimalfall aus dem Bericht.
cat > "$TMP/a.lyx" <<'EOF'
unit Main;
import std.io;
pub type TPaar = struct { A: int64; B: int64; }
pub type IGeber = interface {
  fn Hol(): TPaar;
}
pub type TDing = class {
  n: int64;
  fn Create(): void { self.n := 7; }
  fn Hol(): TPaar { var p: TPaar; p.A := self.n; p.B := 1; return p; }
}
fn main(): int64 {
  var d: TDing := new TDing();
  var p: TPaar := d.Hol();
  PrintLn(IntToStr(p.A) + "/" + IntToStr(p.B));
  return 0;
}
EOF
lauf "$TMP/a.lyx" "7/1 " "Interface mit gleichnamiger Methode: virtueller Aufruf liefert den Struct"

# 2) Der Rueckgabetyp der Interface-Methode ist gleichgueltig — es zaehlt
#    allein, dass der Name kollidiert und der Aufruf dadurch virtuell wird.
sed 's/fn Hol(): TPaar;/fn Hol(): int64;/' "$TMP/a.lyx" > "$TMP/b.lyx"
lauf "$TMP/b.lyx" "7/1 " "Interface-Methode liefert int64, Klassenmethode einen Struct"

# 3) Die Klasse implementiert das Interface wirklich.
cat > "$TMP/c.lyx" <<'EOF'
unit Main;
import std.io;
pub type TPaar = struct { A: int64; B: int64; }
pub type IGeber = interface {
  fn Hol(): TPaar;
}
pub type TDing = class implements IGeber {
  n: int64;
  fn Create(): void { self.n := 3; }
  fn Hol(): TPaar { var p: TPaar; p.A := self.n; p.B := 9; return p; }
}
fn main(): int64 {
  var d: TDing := new TDing();
  var p: TPaar := d.Hol();
  PrintLn(IntToStr(p.A) + "/" + IntToStr(p.B));
  return 0;
}
EOF
lauf "$TMP/c.lyx" "3/9 " "implements: virtueller Aufruf ueber das Interface"

# 4) Ueberschriebene virtuelle Methode mit Struct-Rueckgabe — hier muss die
#    Ableitung gewinnen. Ein Test, der nur "stuerzt nicht ab" prueft, wuerde
#    nicht merken, wenn der Dispatch die falsche Methode findet.
cat > "$TMP/d.lyx" <<'EOF'
unit Main;
import std.io;
pub type TPaar = struct { A: int64; B: int64; }
pub type IGeber = interface {
  fn Hol(): TPaar;
}
pub type TBasis = class {
  fn Create(): void { }
  virtual fn Hol(): TPaar { var p: TPaar; p.A := 1; p.B := 1; return p; }
}
pub type TAbl = class extends TBasis {
  fn Create(): void { }
  override fn Hol(): TPaar { var p: TPaar; p.A := 42; p.B := 43; return p; }
}
fn main(): int64 {
  var b: TBasis := new TAbl();
  var p: TPaar := b.Hol();
  PrintLn(IntToStr(p.A) + "/" + IntToStr(p.B));
  return 0;
}
EOF
lauf "$TMP/d.lyx" "42/43 " "override: der Dispatch findet die Methode der Ableitung"

# 5) Gegenprobe: ohne Interface bleibt der Aufruf statisch und muss weiter
#    laufen — der Fix darf den nicht-virtuellen Weg nicht anfassen.
sed '/pub type IGeber = interface {/,/^}/d' "$TMP/a.lyx" > "$TMP/e.lyx"
lauf "$TMP/e.lyx" "7/1 " "ohne Interface: statischer Aufruf unveraendert"

# 6) #1694 zweiter Anlauf: der Empfaenger ist ein FELD, nicht eine lokale
#    Variable. Der erste Fix hat das nicht erwischt, weil dieser Test nur
#    lokale Empfaenger kannte — und genau daran ist es liegengeblieben.
#
#    `cg_callRetStructBytes` entschied ueber `cg_exprClassName`, und die kannte
#    keinen Feldausdruck. Die Aufrufstelle gab deshalb KEIN verdecktes Argument
#    mit, waehrend der Gerufene eines erwartete: er fand in rdi den EMPFAENGER
#    und schrieb sein Ergebnis ueber das Objekt.
#
#    Der Test prueft deshalb nicht nur, dass es laeuft, sondern dass das Objekt
#    HINTERHER noch heil ist — der Absturz kam ja erst beim naechsten Zugriff.
cat > "$TMP/feld.lyx" <<'EOF'
unit Main;
import std.io;
pub type TVier = struct { A: int64; B: int64; C: int64; D: int64; }
pub type IGeber = interface { fn Hol(i: int64): TVier; }
pub type TQuelle = class implements IGeber {
  Kennung: int64;
  fn Create(): void { self.Kennung := 4242; }
  fn Hol(i: int64): TVier { var v: TVier; v.A := 10; v.B := 20; v.C := 30; v.D := 40; return v; }
}
pub type THalter = class {
  Geber: IGeber;
  Quelle: TQuelle;
  fn Create(g: IGeber, q: TQuelle): void { self.Geber := g; self.Quelle := q; }
  fn UeberFeld(): int64 { var v: TVier := self.Geber.Hol(0); return v.A + v.D; }
}
fn main(): int64 {
  var q: TQuelle := new TQuelle();
  var h: THalter := new THalter(q as IGeber, q);
  PrintLn(IntToStr(h.UeberFeld()));
  PrintLn(IntToStr(h.UeberFeld()));
  var v: TVier := h.Geber.Hol(0);
  PrintLn(IntToStr(v.A + v.D));
  var w: TVier := h.Quelle.Hol(0);
  PrintLn(IntToStr(w.A + w.D));
  PrintLn(IntToStr(q.Kennung));
  return 0;
}
EOF
lauf "$TMP/feld.lyx" "50 50 50 50 4242 " "Feld als Empfaenger: Ergebnis stimmt und das Objekt bleibt heil"

# 7) Der Dispatch muss das Objekt aus rsi lesen, sobald sret im Spiel ist.
#    Ohne diese Sperre kaeme derselbe Fehler beim naechsten Umbau zurueck.
if grep -q "mov rax,\[rsi\]" src/codegen_x86.lyx; then
  ok "VMT-Dispatch kennt den sret-Fall (liest aus rsi)"
else
  bad "VMT-Dispatch liest nur aus rdi — der sret-Fall fehlt wieder"
fi

echo "----"
echo "$P PASS, $F FAIL"
[ "$F" -eq 0 ]
