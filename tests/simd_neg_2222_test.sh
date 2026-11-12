#!/usr/bin/env bash
# tests/simd_neg_2222_test.sh — Negation eines `parallel Array` (#2222).
#
# `0.0 - a`, `0 - a` und `-a` auf `parallel Array<f64|f32>` uebersetzten
# ohne Meldung. Auf x86 lief jede dieser Formen in den SKALAREN Zweig und
# rechnete auf dem ZEIGER der Ablage (btc/neg rax, subsd) — der naechste
# Zugriff stuerzte mit SIGSEGV ab. Auf arm64 lieferte `0.0 - a` still den
# unveraenderten Wert, `-a` brach mit "Opcode 129" ab.
#
# Jetzt:
#   * `-a` ist umgesetzt: x86 (cg_emitSSE2Neg), arm64 (FNEG in
#     emitNeonBinOp), lyxos (emitSimdNeg, schon vorher). Gekippt wird das
#     Vorzeichenbit, nicht `0 - x` gerechnet — deshalb steht +0.0 unter den
#     Werten: als `0 - x` gaebe es +0.0, richtig ist -0.0.
#   * Skalar mit Vektor (`0.0 - a`, `0 - a`, `a * 2.0`) und verschachtelte
#     Vektorausdruecke weist sema laut ab.
#
# Gemessen wird das BITMUSTER jedes Elements (peek64 bzw. peek32), nicht die
# Ausgabe — sechs Nachkommastellen trennen float(0.1) nicht von 0.1, und
# 0.1 ist in f32 nicht exakt (Hinweis aus #2222). Laengen 1..9: der Pfad hat
# einen 16-Byte-Vektorteil und einen Rest Element fuer Element; die Grenzen
# liegen fuer f32 (vier je Block) und f64 (zwei je Block) bei verschiedenen
# Laengen. Dazu: die Quelle bleibt unveraendert.
#
# Erwartete Muster (Python, struct.pack):
#   f64:  -2.5 -4610560118520545280   -0.1 -4631501856787818086   -0.0 1<<63
#          2.5  4612811918334230528    0.1  4591870180066957722
#   f32:  -2.5 0xC0200000=3223322624  -0.1 0xBDCCCCCD=3184315597  -0.0 2147483648
#          2.5 1075838976              0.1 1036831949
#
# riscv kennt `parallel Array` gar nicht und meldet das laut (#1339, Opcode
# 165) — dort gibt es nichts zu messen.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
. "$(dirname "$0")/lib/qemu.sh"   # #2048
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# quelle T N -> Lyx-Programm; gibt "fehlerNeg fehlerQuelle" aus.
quelle() {
  local t="$1" n="$2" w lese e0 e1 e2 q0 q1
  if [ "$t" = f64 ]; then
    w=8; lese='peek64(p + k * 8)'
    e0='0 - 4610560118520545280'; e1='0 - 4631501856787818086'; e2='1 << 63'
    q0='4612811918334230528'; q1='4591870180066957722'
  else
    w=4; lese='peek32(p + k * 4) & 0xFFFFFFFF'
    e0='3223322624'; e1='3184315597'; e2='2147483648'
    q0='1075838976'; q1='1036831949'
  fi
  cat <<LYX
import std.io;
fn erw(m: int64): int64 {
  if (m == 0) { return $e0; }
  if (m == 1) { return $e1; }
  return $e2;
}
fn quell(m: int64): int64 {
  if (m == 0) { return $q0; }
  if (m == 1) { return $q1; }
  return 0;
}
fn main(): int64 {
  let a: parallel Array<$t>($n) = parallel Array<$t>($n);
  var k: int64 := 0;
  while (k < $n) {
    var m: int64 := k % 3;
    if (m == 0) { a[k] := 2.5; }
    if (m == 1) { a[k] := 0.1; }
    if (m == 2) { a[k] := 0.0; }
    k := k + 1;
  }
  let b: parallel Array<$t> = -a;
  var fNeg: int64 := 0;
  var fQuelle: int64 := 0;
  var p: int64 := b as int64;
  k := 0;
  while (k < $n) {
    var v: int64 := $lese;
    if (v != erw(k % 3)) { fNeg := fNeg + 1; }
    k := k + 1;
  }
  p := a as int64;
  k := 0;
  while (k < $n) {
    var v2: int64 := $lese;
    if (v2 != quell(k % 3)) { fQuelle := fQuelle + 1; }
    k := k + 1;
  }
  PrintLn(fNeg); PrintLn(fQuelle);
  return 0;
}
LYX
}

# Werte: x86 und arm64, f64 und f32, Laengen 1..9.
for t in f64 f32; do
  for z in x86 arm64; do
    opt=""; run=""
    if [ $z = arm64 ]; then
      opt="--target=arm64"; run="$QEMU_ARM64"
      if [ -z "$run" ]; then echo "HINWEIS: qemu fuer arm64 fehlt — nur uebersetzt."; fi
    fi
    schlecht=""
    for n in 1 2 3 4 5 6 7 8 9; do
      quelle $t $n > "$TMP/n.lyx"
      if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" $opt "$TMP/n.lyx" -o "$TMP/n.$z" >"$TMP/n.log" 2>&1); then
        schlecht="$schlecht n=$n:uebersetzt-nicht($(grep -i error "$TMP/n.log" | head -1 | cut -c1-90))"; continue
      fi
      [ $z = arm64 ] && [ -z "$run" ] && continue
      got=$( ulimit -c 0; cd "$TMP" && timeout 30 $run "$TMP/n.$z" 2>/dev/null | tr '\n' ' '; echo "rc=${PIPESTATUS[0]}" )
      if [ "$got" != "0 0 rc=0" ]; then schlecht="$schlecht n=$n:'$got'"; fi
    done
    if [ -z "$schlecht" ]; then ok "-a auf $t, Laengen 1..9, Bitmuster [$z]"
    else no "-a auf $t [$z]" "$schlecht"; fi
  done
done

# Weg auf x86: die Maske hat die Breite des Elements. f64 braucht
# `psllq xmm2, 63` (66 0F 73 F2 3F), f32 `pslld xmm2, 31` (66 0F 72 F2 1F);
# mit der jeweils anderen waere ein Mantissenbit bzw. gar nichts gekippt.
# Geprueft wird beidseitig: die richtige Folge steht da, die falsche nicht.
# Dazu `xorps xmm0, xmm2` (0F 57 C2) — gekippt wird, nicht subtrahiert.
for t in f64 f32; do
  quelle $t 5 > "$TMP/w.lyx"
  (cd "$ROOT" && "$LYXC" --std-path="$ROOT" "$TMP/w.lyx" -o "$TMP/w.$t" >/dev/null 2>&1)
  hex=$(od -An -v -tx1 "$TMP/w.$t" | tr -d ' \n')
  q=0; f=0; x=0
  [[ $hex == *660f73f23f* ]] && q=1
  [[ $hex == *660f72f21f* ]] && f=1
  [[ $hex == *0f57c2* ]] && x=1
  if [ $t = f64 ]; then soll="1 0 1"; else soll="0 1 1"; fi
  if [ "$q $f $x" = "$soll" ]; then ok "Maske und xorps am Erzeugnis [$t] (psllq/pslld/xorps = $q $f $x)"
  else no "Maske am Erzeugnis [$t]" "psllq/pslld/xorps = $q $f $x, erwartet $soll"; fi
done

# Laut abgewiesen — auf allen Zielen in sema, also vor jedem Backend.
# Status UND Meldung; eine Meldung ohne Status uebersaehe jedes Makefile.
abweisen() { # name, ausdruck, ziel
  local name="$1" ausdr="$2" z="$3" opt=""
  [ "$z" != x86 ] && opt="--target=$z"
  cat > "$TMP/r.lyx" <<LYX
import std.io;
fn main(): int64 {
  let a: parallel Array<f64>(4) = parallel Array<f64>(4);
  let c: parallel Array<f64>(4) = parallel Array<f64>(4);
  a[0] := 2.5;
  let n: parallel Array<f64> = $ausdr;
  var r: f64 := n[0];
  PrintLn(FloatToStr(r, 4));
  return 0;
}
LYX
  (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" $opt "$TMP/r.lyx" -o "$TMP/r" >"$TMP/r.out" 2>"$TMP/r.err")
  local rc=$?
  if [ $rc -ne 0 ] && grep -q "#2222" "$TMP/r.err" "$TMP/r.out"; then ok "abgewiesen [$z]: $name (rc $rc)"
  else no "nicht abgewiesen [$z]: $name" "rc $rc, $(grep -i error "$TMP/r.err" "$TMP/r.out" | head -1)"; fi
}
for z in x86 arm64 lyxos; do
  abweisen "0.0 - a"     "0.0 - a"     $z
  abweisen "0 - a"       "0 - a"       $z
  abweisen "a * 2.0"     "a * 2.0"     $z
  abweisen "2.0 + a"     "2.0 + a"     $z
  abweisen "-(a + c)"    "-(a + c)"    $z
  abweisen "(a + c) * c" "(a + c) * c" $z
done

# Gegenprobe: die umgesetzten Formen bleiben durchlaessig (sonst waere die
# Ablehnung schlicht zu weit).
cat > "$TMP/g.lyx" <<'LYX'
import std.io;
fn main(): int64 {
  let a: parallel Array<f64>(4) = parallel Array<f64>(4);
  let c: parallel Array<f64>(4) = parallel Array<f64>(4);
  a[0] := 2.5; c[0] := 1.0;
  let s: parallel Array<f64> = a + c;
  let n: parallel Array<f64> = -s;
  var r: f64 := n[0];
  var x: f64 := 0.0 - r;
  PrintLn(FloatToStr(x, 4));
  return 0;
}
LYX
if (cd "$ROOT" && "$LYXC" --std-path="$ROOT" "$TMP/g.lyx" -o "$TMP/g" >/dev/null 2>&1); then
  got=$( ulimit -c 0; cd "$TMP" && timeout 10 "$TMP/g" 2>/dev/null )
  if [ "$got" = "3.5000" ]; then ok "a + c, -s und Skalar-Negation eines Elements bleiben erlaubt ($got)"
  else no "Gegenprobe" "'$got' erwartet 3.5000"; fi
else
  no "Gegenprobe" "uebersetzt nicht"
fi

echo "----"
echo "$PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
