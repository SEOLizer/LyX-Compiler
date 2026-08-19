#!/bin/bash
# #1670 — ClassName(): Klassenname zur Laufzeit.
#
# Geprueft wird vor allem, dass der Name DYNAMISCH ist: eine als Basisklasse
# deklarierte Variable muss die tatsaechliche Klasse melden. Ein Test, der nur
# `x.ClassName()` auf einer direkt deklarierten Variablen prueft, waere auch
# mit einer rein statischen Antwort gruen — und die waere der eigentliche
# Defekt.
#
# Dazu die Grenze aus ebnf.md 20.1: eine Klasse OHNE Methoden bekommt
# struct-Layout und traegt keinen Typzeiger; dort ist der statische Name die
# richtige Antwort.
set -u
cd "$(dirname "$0")/.."
LYXC=${LYXC:-./lyxc}
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
pruefe() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (erwartet '$3', erhalten '$2')"; fi; }

cat > "$TMP/cn.lyx" <<'EOF'
import std.io;
import runde17.ctrl;

type TBasis = class {
  a: int64;
  fn Create(): void { self.a := 1; }
  virtual fn Tu(): void { }
}
type TAbl = class extends TBasis { b: int64; fn Create(): void { self.b := 2; } }
type TTiefer = class extends TAbl { fn Create(): void { } }
type TOhneMethoden = class { c: int64; }

fn main(): int64 {
  var x: TAbl := new TAbl();
  var y: TBasis := x as TBasis;
  PrintLn("direkt=" + x.ClassName());
  PrintLn("ueber-basis=" + y.ClassName());        // dynamisch: TAbl, nicht TBasis
  var t: TTiefer := new TTiefer();
  var tb: TBasis := t as TBasis;
  PrintLn("zwei-ebenen=" + tb.ClassName());
  var b: TBasis := new TBasis();
  PrintLn("basis=" + b.ClassName());
  var s: TOhneMethoden;
  PrintLn("ohne-methoden=" + s.ClassName());
  // Importierte Klassen
  var e: TEdit := new TEdit();
  var c: TControl := e as TControl;
  PrintLn("import-dyn=" + c.ClassName());
  // Gegenprobe: is und as? bleiben unveraendert — beide haengen an derselben
  // VMT-Adresse, vor die der Name gelegt wurde.
  if (c is TEdit) { PrintLn("is=1"); } else { PrintLn("is=0"); }
  var z: TEdit := c as? TEdit;
  if (z != null) { PrintLn("as=1"); } else { PrintLn("as=0"); }
  return 0;
}
EOF
if ! "$LYXC" --std-path=. -I tests/data "$TMP/cn.lyx" -o "$TMP/cn" > "$TMP/cn.log" 2>&1; then
  bad "uebersetzt"; grep -E "error" "$TMP/cn.log" | head -3
else
  ok "uebersetzt"
  if timeout 60 "$TMP/cn" > "$TMP/cn.out" 2>&1; then
    v() { grep "^$1=" "$TMP/cn.out" | head -1 | cut -d= -f2; }
    pruefe "direkter Empfaenger"                 "$(v direkt)"        "TAbl"
    pruefe "dynamisch ueber Basisklasse"         "$(v ueber-basis)"   "TAbl"
    pruefe "dynamisch ueber zwei Ebenen"         "$(v zwei-ebenen)"   "TTiefer"
    pruefe "Basisklasse meldet sich selbst"      "$(v basis)"         "TBasis"
    pruefe "Klasse ohne Methoden: statisch"      "$(v ohne-methoden)" "TOhneMethoden"
    pruefe "importierte Klasse, dynamisch"       "$(v import-dyn)"    "TEdit"
    pruefe "is unveraendert"                     "$(v is)"            "1"
    pruefe "as? unveraendert"                    "$(v as)"            "1"
  else
    bad "laeuft"; head -3 "$TMP/cn.out"
  fi
fi

# Kein bestimmbarer Klassentyp: melden statt raten.
cat > "$TMP/unklar.lyx" <<'EOF'
import std.io;
fn main(): int64 {
  var n: int64 := 5;
  PrintLn(n.ClassName());
  return 0;
}
EOF
if "$LYXC" --std-path=. "$TMP/unklar.lyx" -o "$TMP/unklar" > "$TMP/unklar.log" 2>&1; then
  bad "ClassName auf Nicht-Klasse wird abgewiesen (uebersetzte klaglos)"
else
  ok "ClassName auf Nicht-Klasse wird abgewiesen"
fi

echo "----"
echo "$PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
