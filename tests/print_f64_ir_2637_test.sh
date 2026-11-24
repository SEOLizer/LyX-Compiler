#!/usr/bin/env bash
# tests/print_f64_ir_2637_test.sh — gibt Print/PrintLn eine f64 auf ALLEN
# Zielen aus, und zwar gleich? (#2637)
#
# BEFUND. `Print(x)` mit einer gewoehnlichen f64-Variablen wurde auf den
# IR-Zielen (arm64, riscv, lyxos) mit "Print/PrintLn kann den Typ des
# Arguments nicht bestimmen." abgewiesen, waehrend linux, win64 und macosx64
# denselben Quelltext uebersetzten. Gemessen war der Mangel groesser als die
# Meldung: auch `PrintF64` ging auf den IR-Zielen nicht -- es fehlte die
# f64-Ausgabe ueberhaupt, nicht nur ein Fall in einer Aufzaehlung.
#
# DIE STELLE GAB ES SCHON. `FloatToStr` ist Builtin 403, steht in
# src/backend/builtin_typen.lyx als pchar-liefernd und uebersetzt auf allen
# Zielen. Der Print-Weg erzeugt damit erst Text und geht dann denselben Weg
# wie ein pchar.
#
# GEPRUEFT WIRD DIE WIRKUNG AM LAUFENDEN ERZEUGNIS, nicht die
# Uebersetzbarkeit: die Ausgabe muss auf x86, arm64 und riscv ZEICHENGLEICH
# sein. Ein Test, der nur "uebersetzt" prueft, waere auch von einer Fassung
# erfuellt, die auf arm64 etwas anderes ausgibt -- und genau das war der
# Grund fuer die laute Abweisung (vgl. #2025, wo `Print(a, ".", b)` auf arm64
# die halbe Zeile lieferte).
#
# UND: die laute Abweisung muss fuer echt Unentscheidbares BLEIBEN. Sonst
# waere aus einem lauten Default ein stiller geworden -- der schlimmere
# Tausch.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$ROOT/tests/lib/lyxc_guard.sh"; [ -f "$_g" ] && . "$_g"   # #1294
. "$ROOT/tests/lib/qemu.sh"   # #2048: der Emulator wird EINMAL gesucht, unter beiden Namen
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ulimit -c 0 2>/dev/null
pr() { if [ "$1" = ok ]; then PASS=$((PASS+1)); echo "PASS $2"; else FAIL=$((FAIL+1)); echo "FAIL $2"; fi; }

cat > "$TMP/f.lyx" <<'LYX'
fn main(): int64 {
  var x: f64 := 2.5;
  var y: f64 := 0.0 - 3.125;
  var z: f64 := 1234.5;
  Print(x);  PrintLn("");
  PrintLn(y);
  Print("z="); PrintLn(z);
  return 0;
}
LYX

# --- 1. jedes Ziel uebersetzt ----------------------------------------------
echo "--- f64 in Print/PrintLn: uebersetzt jedes Ziel? ---"
for t in linux win64 macosx64 arm64 riscv lyxos; do
  if ( cd "$ROOT" && "$LYXC" "$TMP/f.lyx" --std-path="$ROOT" --target="$t" -o "$TMP/f_$t" ) >"$TMP/log_$t" 2>&1; then
    pr ok "--target=$t uebersetzt"
  else
    pr fail "--target=$t: $(grep -oE 'kann den Typ.*|sema error.*|error.*' "$TMP/log_$t" | head -1)"
  fi
done

# --- 2. gleiche Ausgabe auf x86, arm64 und riscv ---------------------------
# Ohne qemu bleibt der Vergleich aus; ein roter Test aus Umgebungsgruenden
# sagt nichts ueber den Code.
echo "--- dieselbe Ausgabe auf x86, arm64 und riscv ---"
SOLL=""
if [ -x "$TMP/f_linux" ]; then
  SOLL="$("$TMP/f_linux" 2>&1 | tr '\n' '|')"
  if [ "$SOLL" = "2.500000|-3.125000|z=1234.500000|" ]; then
    pr ok "x86 gibt 2.500000 / -3.125000 / z=1234.500000"
  else
    pr fail "x86 gibt '$SOLL'"
  fi
fi
for paar in "$QEMU_ARM64 arm64" "$QEMU_RISCV64 riscv"; do
  set -- $paar
  if [ -z "${1:-}" ] || [ "$1" = "arm64" ] || [ "$1" = "riscv" ]; then
    echo "    (SKIP ${2:-$1}: kein Emulator gefunden)"
  elif [ ! -x "$TMP/f_$2" ]; then
    echo "    (SKIP $2: kein Erzeugnis)"
  else
    IST="$("$1" "$TMP/f_$2" 2>&1 | tr '\n' '|')"
    if [ -n "$SOLL" ] && [ "$IST" = "$SOLL" ]; then
      pr ok "$2 gibt zeichengleich dasselbe wie x86"
    else
      pr fail "$2 gibt '$IST', x86 gibt '$SOLL'"
    fi
  fi
done

# --- 3. Uebereinstimmung mit FloatToStr ------------------------------------
# Die beiden Wege muessen dieselbe Form liefern: der Print-Weg GEHT seit
# #2637 ueber FloatToStr, und die Praezision steckt im Builtin. Fiele sie
# auseinander, waere die Ausgabe je Schreibweise anders.
echo "--- Print(f64) stimmt mit FloatToStr(x, 6) ueberein ---"
cat > "$TMP/g.lyx" <<'LYX'
import std.io;
fn main(): int64 {
  var x: f64 := 2.5;
  var y: f64 := 0.0 - 3.125;
  var z: f64 := 1234.5;
  PrintLn(FloatToStr(x, 6));
  PrintLn(FloatToStr(y, 6));
  Print("z="); PrintLn(FloatToStr(z, 6));
  return 0;
}
LYX
if ( cd "$ROOT" && "$LYXC" "$TMP/g.lyx" --std-path="$ROOT" -o "$TMP/g" ) >"$TMP/glog" 2>&1 && [ -n "$SOLL" ]; then
  GIST="$("$TMP/g" 2>&1 | tr '\n' '|')"
  [ "$GIST" = "$SOLL" ] && pr ok "beide Wege liefern dieselbe Form" \
                        || pr fail "FloatToStr gibt '$GIST', Print gibt '$SOLL'"
else
  pr fail "Vergleichsprogramm uebersetzt nicht: $(grep -m1 -iE 'error' "$TMP/glog")"
fi

# --- 4. echt Unentscheidbares bleibt LAUT ---------------------------------
echo "--- die laute Abweisung bleibt fuer echt Unentscheidbares ---"
cat > "$TMP/u.lyx" <<'LYX'
type TP = struct { a: int64; };
fn main(): int64 {
  var s: TP;
  s.a := 1;
  Print(s);
  return 0;
}
LYX
for t in arm64 riscv lyxos; do
  if ( cd "$ROOT" && "$LYXC" "$TMP/u.lyx" --std-path="$ROOT" --target="$t" -o "$TMP/u_$t" ) >"$TMP/ulog_$t" 2>&1; then
    pr fail "--target=$t: ein Struct in Print uebersetzt stillschweigend"
  elif grep -q "kann den Typ des Arguments nicht bestimmen" "$TMP/ulog_$t"; then
    pr ok "--target=$t: Struct in Print scheitert weiter laut"
  else
    pr fail "--target=$t: scheitert, aber ohne die benannte Meldung"
  fi
done

echo ""
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
