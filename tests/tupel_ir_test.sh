#!/usr/bin/env bash
# tests/tupel_ir_test.sh — #2080: Tupel-Rueckgabe und Array-Literale auf allen
# drei Zielen.
#
# Der IR-Weg (arm64, riscv) kannte `var a, b := f();` nur als LyxOS-Syscall-
# Paar: der zweite Name las mit IRO_LOAD_ERRVAL (164) den Fehlerschatten eines
# Syscalls. arm64 und riscv wiesen den Opcode ab. Darunter lag ein zweiter
# Defekt: ein Array-Literal `[a, b]` bzw. ein Tupelausdruck `(a, b)` fiel im
# IR-Weg bis auf "unbekannter Ausdruck" durch — `var u := (7, 8); u[0]`
# stuerzte auf arm64 ab, auf riscv endete das Programm ohne Ausgabe.
#
# Jetzt: ein Tupel ist im IR-Weg ein Zeiger auf ein Array-Literal (ebnf §15,
# TupleExpr), entpackt wird mit zwei Elementzugriffen. Auf x86 bleibt es bei
# rax/rdx (#1088).
#
# Jeder Wert ist eindeutig — die Ausgabe zeigt, WELCHES Element wo ankam.
set -uo pipefail
ulimit -c 0   # ein Absturz unter qemu legt sonst eine .core-Datei ins Repo
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
. "$(dirname "$0")/lib/qemu.sh"   # #2048: beide Paketnamen
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

alle_ziele() {  # $1 Beschreibung, $2 Datei (in $TMP/m), $3 Soll mit |
  local was="$1" src="$2" erw="$3"
  for ziel in x86_64 arm64 riscv; do
    local bin="$TMP/b_$ziel" pre=""
    case "$ziel" in
      arm64) pre="$QEMU_ARM64" ;;
      riscv) pre="$QEMU_RISCV64" ;;
    esac
    if ! ( cd "$TMP/m" && timeout 240 "$LYXC" --std-path="$ROOT" --target="$ziel" "$src" -o "$bin" ) >"$TMP/bl.log" 2>&1; then
      nok "$was [$ziel]: uebersetzt nicht ($(grep -m1 -iE '^lyxc:|error' "$TMP/bl.log"))"; continue
    fi
    if [ "$ziel" != "x86_64" ] && [ -z "$pre" ]; then nok "$was [$ziel]: qemu fehlt — NICHT gemessen"; continue; fi
    local ist; ist="$( (timeout 60 $pre "$bin" 2>&1) | tr '\n' '|')"
    if [ "$ist" = "$erw" ]; then ok "$was [$ziel] = $erw"
    else nok "$was [$ziel]: [$ist] statt [$erw]"; fi
  done
}

mkdir -p "$TMP/m/bib"

echo "--- Array-Literal und Tupelausdruck ---"
cat > "$TMP/m/lit.lyx" <<'EOF'
unit main;
import std.io;
fn main(): int64 {
  var u := (7, 8);
  PrintLn(IntToStr(u[0])); PrintLn(IntToStr(u[1]));
  var w: int64[] := [4, 6, 9];
  PrintLn(IntToStr(w[0])); PrintLn(IntToStr(w[2]));
  var a, b := (14, 15);
  PrintLn(IntToStr(a)); PrintLn(IntToStr(b));
  return 0;
}
EOF
alle_ziele "u = (7, 8) | w = [4, 6, 9] | var a, b := (14, 15)" "lit.lyx" "7|8|4|9|14|15|"

echo
echo "--- Entpacken einer Nutzerfunktion: frei, importiert, Methode, geerbt, Struct ---"
cat > "$TMP/m/bib/tb.lyx" <<'EOF'
unit bib.tb;
pub fn Paar(): [int64, int64] { return (70, 80); }
pub type Basis = class { v: int64;
  pub fn Zwei(): [int64, int64] { return (self.v, self.v + 1); } };
EOF
cat > "$TMP/m/t.lyx" <<'EOF'
unit main;
import std.io;
import bib.tb;
type P = struct { x: int64; };
fn tupel(): [int64, int64] { return (3, 5); }
fn mitStruct(): [int64, P] { var p: P; p.x := 42; return (9, p); }
type K = class { w: int64;
  pub fn Hol(): [int64, int64] { return (self.w, self.w * 2); } };
type L = class extends K { z: int64; };
type M = class extends Basis { q: int64; };
fn main(): int64 {
  var a, b := tupel();          PrintLn(IntToStr(a)); PrintLn(IntToStr(b));
  var c, _ := tupel();          PrintLn(IntToStr(c));
  var i, j := Paar();           PrintLn(IntToStr(i)); PrintLn(IntToStr(j));
  var k: K := new K(); k.w := 6;
  var e, f := k.Hol();          PrintLn(IntToStr(e)); PrintLn(IntToStr(f));
  var l: L := new L(); l.w := 11;
  var g, h := l.Hol();          PrintLn(IntToStr(g)); PrintLn(IntToStr(h));
  var mm: M := new M(); mm.v := 20;
  var r, s := mm.Zwei();        PrintLn(IntToStr(r)); PrintLn(IntToStr(s));
  var n, ps := mitStruct();     PrintLn(IntToStr(n)); PrintLn(IntToStr(ps.x));
  return 0;
}
EOF
alle_ziele "tupel 3,5 | _ | Paar 70,80 | k.Hol 6,12 | geerbt 11,22 | importierte Basis 20,21 | Struct 9,42" \
  "t.lyx" "3|5|3|70|80|6|12|11|22|20|21|9|42|"

echo
echo "--- viele Locals: Typpuffer waechst mit (Laufvariablen, Entpacken) ---"
# Bis 1.2.13A zogen nur `var`-Deklarationen den Typpuffer der Locals mit.
# Vergroesserten `for … to`, `for … in range` oder das Entpacken den
# Namenspuffer, schrieb das naechste `var` hinter das Ende des alten
# Typpuffers. Am VERHALTEN liess sich das vorher nicht zeigen (der
# Arena-Allokator schluckt den Ueberlauf; gemessen mit 29..31 Locals und mit
# einem stehengebliebenen f64-Typ aus einer frueheren Funktion — beide
# lieferten das richtige Ergebnis). Dieser Fall stellt sicher, dass Wachsen
# und Entpacken zusammen weiter stimmen; der Fix selbst ist am Code belegt
# (ein Helfer _regLocal statt vier Kopien, von denen drei unvollstaendig waren).
{
  echo 'unit main;'
  echo 'import std.io;'
  echo 'type P = struct { x: int64; y: int64; };'
  echo 'fn zwei(): [int64, int64] { return (1, 2); }'
  echo 'fn main(): int64 {'
  for n in $(seq 1 28); do echo "  var v$n: int64 := $n;"; done
  echo '  var summe: int64 := 0;'
  echo '  for i := 0 to 2 { summe := summe + i; }'
  echo '  for j in range(3) { summe := summe + j; }'
  echo '  var t0, t1 := zwei();'
  for n in $(seq 29 40); do echo "  var w$n: int64 := $n;"; done
  echo '  var p: P; p.x := 41; p.y := 42;'
  echo '  PrintLn(IntToStr(p.x)); PrintLn(IntToStr(p.y));'
  echo '  PrintLn(IntToStr(summe + t0 + t1 + v28 + w40));'
  echo '  return 0;'
  echo '}'
} > "$TMP/m/viele.lyx"
# summe = (0+1+2) + (0+1+2) = 6; + 1 + 2 + 28 + 40 = 77
alle_ziele "p.x 41 | p.y 42 | Summe 77" "viele.lyx" "41|42|77|"

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
