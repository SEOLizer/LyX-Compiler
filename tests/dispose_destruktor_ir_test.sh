#!/usr/bin/env bash
# tests/dispose_destruktor_ir_test.sh — #2054: `dispose` ruft den Destruktor
# auch auf den IR-Zielen.
#
# Der x86-Weg ruft `Destroy` seit #1235. `lowerDispose` in ir_lower erzeugte
# bis 1.2.11B nur IRO_FREE — auf arm64 und riscv lief der Destruktor nie,
# ohne Meldung. Uebersetzt wurde fehlerfrei, das Programm endete mit rc 0.
#
# Wer einen Destruktor schreibt, tut das wegen seiner WIRKUNG. Gemessen wird
# deshalb nicht, ob das Programm durchlaeuft (das tat es vorher auch), sondern
# was der Destruktor hinterlaesst: er schreibt in eine Modulvariable, und
# `main` gibt sie zurueck. tests/class_lifecycle_test.sh prueft dasselbe ueber
# die Ausgabe, aber nur auf x86.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
. "$(dirname "$0")/lib/qemu.sh"   # #2048: beide Paketnamen
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

# $1 Ziel, $2 Quelle (relativ zu $3), $3 Arbeitsverzeichnis → setzt RC
# RC = Rueckgabewert des Programms, "B" = uebersetzt nicht, "Q" = kein qemu
lauf() {
  local ziel="$1" src="$2" wd="$3" bin="$TMP/b_$1" pre=""
  RC=""
  if ! ( cd "$wd" && timeout 300 "$LYXC" --std-path="$ROOT" --target="$ziel" "$src" -o "$bin" ) >"$TMP/bl.log" 2>&1; then
    RC="B"; return
  fi
  case "$ziel" in
    arm64) [ -n "$QEMU_ARM64" ]   || { RC="Q"; return; }; pre="$QEMU_ARM64" ;;
    riscv) [ -n "$QEMU_RISCV64" ] || { RC="Q"; return; }; pre="$QEMU_RISCV64" ;;
  esac
  RC="$( ( timeout 60 $pre "$bin" >/dev/null 2>&1 ) 2>/dev/null; echo $? )"
}

# $1 Beschreibung, $2 Quelle, $3 erwarteter Rueckgabewert, $4 Verzeichnis (optional)
alle_ziele() {
  local was="$1" src="$2" erw="$3" wd="${4:-$ROOT}" ziel
  for ziel in x86_64 arm64 riscv; do
    lauf "$ziel" "$src" "$wd"
    case "$RC" in
      B) nok "$was [$ziel]: uebersetzt nicht ($(grep -m1 -E '^lyxc:|error' "$TMP/bl.log"))" ;;
      Q) nok "$was [$ziel]: qemu fehlt — NICHT gemessen" ;;
      "$erw") ok "$was [$ziel] (rc=$RC)" ;;
      *) nok "$was [$ziel]: rc=$RC statt $erw" ;;
    esac
  done
}

echo "--- #2054: der Destruktor LAEUFT ---"
#
# Der Kernfall. Vor dem Fix auf arm64 und riscv: rc 40 — die Variable blieb
# unberuehrt.
cat > "$TMP/laeuft.lyx" <<'EOF'
unit main;
var gSpur: int64 := 0;
type K = class { v: int64;
  pub fn Destroy() { gSpur := gSpur + 1; } };
fn main(): int64 {
  var k: K := new K();
  dispose k;
  return gSpur + 40;
}
EOF
alle_ziele "dispose ruft Destroy genau einmal" "$TMP/laeuft.lyx" 41

echo
echo "--- der Destruktor sieht SEIN Objekt ---"
#
# `self` muss das Objekt sein, das freigegeben wird. Ein Aufruf mit falschem
# oder fehlendem Empfaenger liefe ebenfalls "genau einmal" — er laese nur ein
# anderes Feld. Zwei Objekte mit verschiedenen Werten, freigegeben wird das
# zweite.
cat > "$TMP/selbst.lyx" <<'EOF'
unit main;
var gWert: int64 := 0;
type K = class { v: int64;
  pub fn Destroy() { gWert := self.v; } };
fn main(): int64 {
  var a: K := new K();
  var b: K := new K();
  a.v := 11; b.v := 23;
  dispose b;
  return gWert;
}
EOF
alle_ziele "Destroy liest das Feld des freigegebenen Objekts" "$TMP/selbst.lyx" 23

echo
echo "--- Reihenfolge: erst der Destruktor, dann das Folgende ---"
#
# Die Spur wird als Ziffernfolge aufgebaut. 12 heisst: Destruktor (1), dann
# die Anweisung nach `dispose` (2). 21 hiesse, er liefe verspaetet; 2, er
# liefe gar nicht.
cat > "$TMP/folge.lyx" <<'EOF'
unit main;
var gFolge: int64 := 0;
type K = class { v: int64;
  pub fn Destroy() { gFolge := gFolge * 10 + 1; } };
fn main(): int64 {
  var k: K := new K();
  dispose k;
  gFolge := gFolge * 10 + 2;
  return gFolge;
}
EOF
alle_ziele "Destroy laeuft VOR der naechsten Anweisung" "$TMP/folge.lyx" 12

echo
echo "--- #1624: ein GEERBTER Destruktor zaehlt ---"
#
# Die Ableitung bringt keinen eigenen mit. Ohne den Lauf ueber die
# Vererbungskette waere der Test auch von einer Fassung erfuellt, die nur in
# der eigenen Klasse nachsieht.
cat > "$TMP/erbe.lyx" <<'EOF'
unit main;
var gSpur: int64 := 0;
type Basis = class { v: int64;
  pub fn Destroy() { gSpur := 7; } };
type Abl = class extends Basis { w: int64; };
fn main(): int64 {
  var a: Abl := new Abl();
  dispose a;
  return gSpur;
}
EOF
alle_ziele "Destroy aus der Basisklasse wird gerufen" "$TMP/erbe.lyx" 7

echo
echo "--- der EIGENE Destruktor gewinnt gegen den geerbten ---"
#
# Die andere Seite der Kette: haben beide einen, laeuft der der Ableitung —
# und nur der. 5 = nur Ableitung; 3 = nur Basis; 8 = beide.
cat > "$TMP/eigen.lyx" <<'EOF'
unit main;
var gSpur: int64 := 0;
type Basis = class { v: int64;
  pub fn Destroy() { gSpur := gSpur + 3; } };
type Abl = class extends Basis { w: int64;
  pub fn Destroy() { gSpur := gSpur + 5; } };
fn main(): int64 {
  var a: Abl := new Abl();
  dispose a;
  return gSpur;
}
EOF
alle_ziele "bei zwei Destruktoren laeuft nur der der Ableitung" "$TMP/eigen.lyx" 5

echo
echo "--- GEGENPROBE: eine Klasse OHNE Destruktor ---"
#
# Muss uebersetzen und laufen, ohne dass irgendetwas gerufen wird. Die laute
# Meldung im Lowerer ("Destruktor nicht aufloesbar") darf nur greifen, wenn
# sema einen vermerkt hat.
cat > "$TMP/ohne.lyx" <<'EOF'
unit main;
type K = class { v: int64; };
fn main(): int64 {
  var k: K := new K();
  k.v := 9;
  dispose k;
  return 9;
}
EOF
alle_ziele "dispose ohne Destruktor laeuft durch" "$TMP/ohne.lyx" 9

# NICHT GEPRUEFT, und zwar mit Absicht: ein Destruktor, der in einem ANDEREN
# MODUL steht (importierte Klasse, oder lokale Ableitung einer importierten
# Basis). Der laeuft derzeit auf KEINEM Ziel, auch nicht auf x86 — sema
# vermerkt ihn nicht (`_exprClassDeclNi` sieht nur Deklarationen des eigenen
# Moduls), und beide Codewege lesen genau diesen Vermerk. Das ist ein eigener
# Defekt mit eigener Ursache. Ein Fall dazu waere hier dauerhaft rot und
# wuerde verdecken, was dieser Test misst.

echo
echo "--- alle Ziele binden GLEICH (virtueller Destruktor ueber Basisreferenz) ---"
#
# x86 bindet den Destruktor statisch am Typ des Ausdrucks; der IR-Weg tut
# jetzt dasselbe. Ob ein virtuell deklarierter Destruktor ueber eine
# Basisreferenz die Fassung der Ableitung rufen SOLLTE, ist eine Sprachfrage
# und hier nicht entschieden. Festgehalten wird nur, dass die Ziele nicht
# auseinanderlaufen: dasselbe Programm, derselbe Rueckgabewert.
cat > "$TMP/virt.lyx" <<'EOF'
unit main;
var gSpur: int64 := 0;
type Basis = class { v: int64;
  pub virtual fn Destroy() { gSpur := 3; } };
type Abl = class extends Basis { w: int64;
  pub override fn Destroy() { gSpur := 5; } };
fn main(): int64 {
  var b: Basis := new Abl();
  dispose b;
  return gSpur;
}
EOF
lauf x86_64 "$TMP/virt.lyx" "$ROOT"; vx="$RC"
if [ "$vx" = "B" ]; then
  # Die Schreibweise wird nicht ueberall angenommen; dann gibt es nichts zu
  # vergleichen, und das ist kein Befund dieses Tests.
  echo "HINWEIS virtueller Destruktor uebersetzt auf x86_64 nicht ($(grep -m1 -E '^lyxc:|error' "$TMP/bl.log")) — Vergleich entfaellt"
else
  for ziel in arm64 riscv; do
    lauf "$ziel" "$TMP/virt.lyx" "$ROOT"
    case "$RC" in
      Q) nok "virtueller Destruktor [$ziel]: qemu fehlt — NICHT gemessen" ;;
      "$vx") ok "virtueller Destruktor: $ziel bindet wie x86_64 (rc=$RC)" ;;
      *) nok "virtueller Destruktor: $ziel liefert $RC, x86_64 liefert $vx — die Ziele laufen auseinander" ;;
    esac
  done
fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
