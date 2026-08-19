#!/bin/bash
# #1595 — Struct-Rueckgabe by value: der Aufrufer stellt den Platz
#
# Der Nachweis aus dem Issue ist eine SPEICHERMESSUNG: die Repro darf im RSS
# nicht mehr wachsen — nicht "wenig wachsen", sondern gar nicht. Deshalb wird
# hier zweimal gemessen, mit zehnfacher Zahl von Rueckgaben, und die beiden
# Werte muessen beieinander liegen. Ein Test, der nur "laeuft durch" prueft,
# waere auch mit dem alten Bump-Bereich gruen gewesen.
#
# Dazu die Korrektheit: Wertsemantik (#1351), `f().feld`, `g(f())`,
# durchgereichte Rueckgabe, Methoden, globale Ziele.
set -u
cd "$(dirname "$0")/.."
LYXC=${LYXC:-./lyxc}
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
pruefe() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (erwartet '$3', erhalten '$2')"; fi; }

# ---------------------------------------------------------------- Korrektheit
cat > "$TMP/k.lyx" <<'EOF'
import std.io;
type Pair = struct { a: int64; b: int64; }
type Drei = struct { x: int64; y: int64; z: int64; }
var g: Pair;
type Fabrik = class {
  n: int64;
  fn Create(): void { self.n := 7; }
  fn Mach(v: int64): Pair { var p: Pair; p.a := v; p.b := self.n; return p; }
}
fn mach(v: int64): Pair { var p: Pair; p.a := v; p.b := v * 2; return p; }
fn nimm(p: Pair): int64 { return p.a * 100 + p.b; }
fn reiche(v: int64): Pair { return mach(v); }
fn gross(v: int64): Drei { var d: Drei; d.x := v; d.y := v+1; d.z := v+2; return d; }
fn aendert(p: Pair): int64 { p.a := 999; return p.a; }
fn main(): int64 {
  PrintLn("feld=" + IntToStr(mach(5).b));
  PrintLn("verschachtelt=" + IntToStr(nimm(mach(3))));
  var r: Pair := reiche(7);
  PrintLn("reiche=" + IntToStr(r.a) + "/" + IntToStr(r.b));
  var d: Drei := gross(10);
  PrintLn("drei=" + IntToStr(d.x) + "/" + IntToStr(d.y) + "/" + IntToStr(d.z));
  var o: Pair := mach(1);
  var w: int64 := aendert(o);
  PrintLn("wert=" + IntToStr(w) + "/" + IntToStr(o.a));
  var z: Pair := o;
  z.a := 42;
  PrintLn("alias=" + IntToStr(o.a) + "/" + IntToStr(z.a));
  var e1: Pair := mach(11);
  var e2: Pair := mach(22);
  PrintLn("zwei=" + IntToStr(e1.a) + "/" + IntToStr(e2.a));
  var f: Fabrik := new Fabrik();
  var m: Pair := f.Mach(21);
  PrintLn("methode=" + IntToStr(m.a) + "/" + IntToStr(m.b));
  g := mach(4);
  PrintLn("global=" + IntToStr(g.a) + "/" + IntToStr(g.b));
  return 0;
}
EOF
if ! "$LYXC" --std-path=. "$TMP/k.lyx" -o "$TMP/k" > "$TMP/k.log" 2>&1; then
  bad "Korrektheitsfaelle uebersetzen"; grep -E "error" "$TMP/k.log" | head -3
else
  ok "Korrektheitsfaelle uebersetzen"
  if timeout 60 "$TMP/k" > "$TMP/k.out" 2>&1; then
    v() { grep "^$1=" "$TMP/k.out" | head -1 | cut -d= -f2; }
    pruefe "f().feld"                    "$(v feld)"          "10"
    pruefe "g(f())"                      "$(v verschachtelt)" "306"
    pruefe "Rueckgabe durchgereicht"     "$(v reiche)"        "7/14"
    pruefe "groesseres Struct (3 Felder)" "$(v drei)"         "10/11/12"
    pruefe "Wertsemantik: Kopie geaendert, Original nicht" "$(v wert)" "999/1"
    pruefe "Zuweisung kopiert, kein Alias" "$(v alias)"       "1/42"
    pruefe "zwei Rueckgaben nacheinander" "$(v zwei)"         "11/22"
    pruefe "Methode mit Struct-Rueckgabe" "$(v methode)"      "21/7"
    pruefe "Ziel ist eine globale Variable" "$(v global)"     "4/8"
  else
    bad "Korrektheitsfaelle laufen"; head -3 "$TMP/k.out"
  fi
fi

# ---------------------------------------------------------------- Speicher
mess() {   # mess <durchlaeufe> -> RSS in kB
  sed "s/@N@/$1/" > "$TMP/m.lyx" <<'EOF'
import std.io;
type Pair = struct { a: int64; b: int64; }
fn mach(x: int64): Pair { var p: Pair; p.a := x; p.b := x; return p; }
fn main(): int64 {
  var s: int64 := 0;
  var i: int64 := 0;
  while (i < @N@) { var q: Pair := mach(i); s := s + q.a; i := i + 1; }
  PrintLn("summe=" + IntToStr(s));
  return 0;
}
EOF
  "$LYXC" --std-path=. "$TMP/m.lyx" -o "$TMP/m" > "$TMP/m.log" 2>&1 || return 1
  /usr/bin/time -f "%M" "$TMP/m" 2>"$TMP/m.rss" >/dev/null || return 1
  cat "$TMP/m.rss"
}

if ! command -v /usr/bin/time > /dev/null 2>&1; then
  echo "HINWEIS: /usr/bin/time fehlt — Speichermessung uebersprungen"
else
  klein=$(mess 200000)
  gross=$(mess 2000000)
  if [ -z "$klein" ] || [ -z "$gross" ]; then
    bad "Speichermessung laeuft"
  else
    ok "Speichermessung laeuft (200k: ${klein} kB, 2 Mio: ${gross} kB)"
    # Zehnfache Zahl von Rueckgaben darf den Speicher nicht mitwachsen lassen.
    # Grenze grosszuegig: alles unter dem Doppelten gilt als konstant.
    grenze=$(( klein * 2 ))
    if [ "$gross" -le "$grenze" ]; then
      ok "RSS waechst nicht mit der Zahl der Rueckgaben"
    else
      bad "RSS waechst mit der Zahl der Rueckgaben (${klein} kB -> ${gross} kB)"
    fi
  fi
fi

# Indirekter Aufruf: der Gerufene sieht nicht, ob er direkt oder ueber einen
# Funktionszeiger gerufen wird — er erwartet die Zieladresse in jedem Fall.
# Die Aufrufstelle kennt den Rueckgabetyp nur ueber den Zeigertyp-Alias.
# std.result macht genau das (ResultInt64AndThen), und es hat gekracht.
cat > "$TMP/indirekt.lyx" <<'EOF'
import std.io;
import std.result;
fn Kette(v: int64): ResultInt64 { return OkInt64(v * 10); }
fn KetteErr(v: int64): ResultInt64 { return ErrInt64(7); }
fn main(): int64 {
  PrintLn(IntToStr(ResultInt64Unwrap(ResultInt64AndThen(OkInt64(42), Kette as int64))));
  var r: ResultInt64 := ResultInt64AndThen(OkInt64(42), KetteErr as int64);
  if (ResultInt64IsOk(r)) { PrintLn("falsch ok"); } else { PrintLn("Err erkannt"); }
  return 0;
}
EOF
if "$LYXC" --std-path=. "$TMP/indirekt.lyx" -o "$TMP/indirekt" > "$TMP/i.log" 2>&1; then
  chmod +x "$TMP/indirekt"
  iaus="$("$TMP/indirekt" 2>&1 | tr '\n' ' ')"
  if [ "$iaus" = "420 Err erkannt " ]; then
    ok "Struct-Rueckgabe ueberlebt den indirekten Aufruf"
  else
    bad "indirekter Aufruf mit Struct-Rueckgabe (erwartet '420 Err erkannt ', bekam '$iaus')"
  fi
else
  bad "indirekter Aufruf uebersetzt nicht ($(grep -oE 'error.*' "$TMP/i.log" | head -1))"
fi

# Drei Units: der Typ des verschachtelten Feldes kommt aus einer DRITTEN Unit.
# Dieser Fall hat einen Anlauf zu Fall gebracht, den der Circle-Fall oben noch
# durchgehen liess: beim Uebersetzen von mm.vec ist mm.kreis dem Codegen noch
# unbekannt (Importe liest erst der Hauptdurchlauf ein), `V` sah also unbenutzt
# aus. Deshalb darf die Entscheidung nicht am Typ haengen, sondern an der
# Zuweisung, die den Zeiger ablegt.
mkdir -p "$TMP/mm"
cat > "$TMP/mm/vec.lyx" <<'EOF'
unit mm.vec;
pub type V = struct { x: int64; y: int64; };
pub fn VNew(a: int64, b: int64): V { var v: V; v.x := a; v.y := b; return v; }
EOF
cat > "$TMP/mm/kreis.lyx" <<'EOF'
unit mm.kreis;
import mm.vec;
pub type K = struct { c: V; r: int64; };
pub fn KNew(x: int64, y: int64, r: int64): K { var k: K; k.c := VNew(x, y); k.r := r; return k; }
EOF
cat > "$TMP/drei.lyx" <<'EOF'
import std.io;
import mm.vec;
import mm.kreis;
fn main(): int64 {
  var k: K := KNew(3, 4, 5);
  PrintLn("k=(" + IntToStr(k.c.x) + "," + IntToStr(k.c.y) + ") r=" + IntToStr(k.r));
  return 0;
}
EOF
if "$LYXC" --std-path=. -I "$TMP" "$TMP/drei.lyx" -o "$TMP/drei" > "$TMP/d.log" 2>&1; then
  chmod +x "$TMP/drei"
  daus="$("$TMP/drei" 2>&1 | head -1)"
  if [ "$daus" = "k=(3,4) r=5" ]; then
    ok "Feldtyp aus einer dritten Unit ueberlebt den Rahmen"
  else
    bad "Feldtyp aus einer dritten Unit ueberlebt den Rahmen nicht (erwartet 'k=(3,4) r=5', bekam '$daus')"
  fi
else
  bad "Drei-Unit-Fall uebersetzt nicht ($(grep -oE 'error.*' "$TMP/d.log" | head -1))"
fi

# Verschachtelte Structs ueber Unit-Grenzen: `Circle.center` ist ein Vec2 — im
# Feld liegt aber nur ein ZEIGER darauf. Solange irgendein Typ so einen Zeiger
# halten kann, darf Vec2 nicht im Rahmen liegen: der Rahmen des Erzeugers
# stirbt vor dem Leser. Genau daran ist der erste Anlauf gescheitert, und zwar
# still — `Vec2` hat nur int64-Felder, sah also fuer sich genommen unbedenklich
# aus. Der Fall braucht die Unit-Grenze: in EINER Unit formuliert ist er auch
# ohne den Fix gruen und belegt nichts.
cat > "$TMP/verschachtelt.lyx" <<'EOF'
import std.io;
import std.circle;
fn main(): int64 {
  var a: Circle := CircleFromXYR(0, 0, 100);
  var b: Circle := CircleFromXYR(300, 0, 100);
  var u: Circle := CircleUnion(a, b);
  PrintLn("u=(" + IntToStr(u.center.x) + "," + IntToStr(u.center.y) + ") r=" + IntToStr(u.radius));
  return 0;
}
EOF
if "$LYXC" --std-path=. "$TMP/verschachtelt.lyx" -o "$TMP/verschachtelt" > "$TMP/v.log" 2>&1; then
  chmod +x "$TMP/verschachtelt"
  vaus="$("$TMP/verschachtelt" 2>&1 | head -1)"
  # Vor dem Fix: u=(300,0) r=100 — der Mittelpunkt kam aus dem gefallenen Rahmen.
  if [ "$vaus" = "u=(150,0) r=250" ]; then
    ok "verschachteltes Struct ueberlebt den Rahmen des Erzeugers"
  else
    bad "verschachteltes Struct ueberlebt den Rahmen nicht (erwartet 'u=(150,0) r=250', bekam '$vaus')"
  fi
else
  bad "verschachteltes Struct uebersetzt nicht ($(grep -oE 'error.*' "$TMP/v.log" | head -1))"
fi

echo "----"
echo "$PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
