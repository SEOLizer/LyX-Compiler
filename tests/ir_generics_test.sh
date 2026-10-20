#!/usr/bin/env bash
# tests/ir_generics_test.sh — #2125: generische Funktionen auf dem IR-Weg
# (arm64, riscv, lyxos).
#
# Bis 1.2.14C wurde auf dem IR-Weg nichts instanziiert. Das Verzeichnis der
# generischen Funktionen wartete auf NK_GENERIC_DECL — eine Knotenart, die der
# Parser nie erzeugt (`fn f<T>` ist ein NK_FUNC_DECL mit Typparametern in c3).
# Der Aufruf `f<int64>(…)` trug dazu als Funktionsindex den STRING-Offset des
# Namens. Bis 1.2.14B lief arm64 still ins Leere (keine Ausgabe, rc 0), seit
# #2112 bricht es laut ab ("Sprungziel nie aufgeloest"); lyxos uebersetzte
# weiterhin ohne Meldung.
#
# Jetzt: je Typargument-Kombination eine Spezialisierung, gesenkt im Kontext
# der Unit der generischen Funktion, T durch das Argument ersetzt.
#
# Gemessen wird die AUSGABE gegen x86 (und x86 gegen den Sollwert, damit kein
# falscher Bezug gilt), dazu:
#   - Wiederverwendung: zweimal dieselbe Kombination erzeugt EINEN Rumpf —
#     am Erzeugnis gemessen (Groesse gegen zwei verschiedene Kombinationen);
#   - f64: der IR-Weg rechnet richtig. x86 war typgeloescht und wies f64 als
#     Typargument seit #2125 ab; seit #2134 spezialisiert auch x86, gemessen
#     wird deshalb der Wert auf allen drei Zielen (vorher: die Abweisung —
#     ein Test darf keine Luecke voraussetzen);
#   - Klassen-Typargument: Feldzugriff ueber T in derselben Unit richtig;
#     aus einer Unit, die die Klasse nicht kennt, laut statt still 0;
#   - lyxos ueber den lokalen Lader (nur Ganzzahlen, kein Allokieren).
set -uo pipefail
ulimit -c 0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
. "$(dirname "$0")/lib/qemu.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

if [ -z "$QEMU_ARM64" ] || [ -z "$QEMU_RISCV64" ]; then echo "FAIL qemu fuer arm64/riscv fehlt — NICHT gemessen"; exit 1; fi

lauf() {  # ziel, binary
  case "$1" in
    linux) timeout 30 "$2" ;;
    arm64) timeout 30 "$QEMU_ARM64" "$2" ;;
    riscv) timeout 30 "$QEMU_RISCV64" "$2" ;;
  esac
}

# baue <ziel> <datei> <ausgabe> [verzeichnis] — rc des Compilers, Log in $3.log
baue() {
  rm -f "$3"
  ( cd "${4:-$ROOT}" && timeout 240 "$LYXC" --std-path="$ROOT" --target="$1" "$2" -o "$3" ) >"$3.log" 2>&1
}

# vergleiche <name> <datei> <soll> [verzeichnis] — x86 == soll, IR-Ziele == x86
vergleiche() {
  local x86 t aus rc
  if ! baue linux "$2" "$TMP/x" "${4:-}"; then nok "$1 [x86]: uebersetzt nicht ($(grep -m1 -i error "$TMP/x.log"))"; return; fi
  x86="$(lauf linux "$TMP/x" 2>/dev/null | tr '\n' '|')"; rc=${PIPESTATUS[0]}
  if [ "$x86" = "$3" ] && [ "$rc" = 0 ]; then ok "$1 [x86]: [$x86]"
  else nok "$1 [x86]: [$x86] rc=$rc statt [$3]"; return; fi
  for t in arm64 riscv; do
    if ! baue $t "$2" "$TMP/p" "${4:-}"; then nok "$1 [$t]: uebersetzt nicht ($(grep -m1 -i error "$TMP/p.log"))"; continue; fi
    aus="$(lauf $t "$TMP/p" 2>/dev/null | tr '\n' '|')"; rc=${PIPESTATUS[0]}
    if [ "$aus" = "$x86" ] && [ "$rc" = 0 ]; then ok "$1 [$t] == x86"
    else nok "$1 [$t]: [$aus] rc=$rc statt [$x86]"; fi
  done
}

# nur_ir <name> <datei> <soll> [verzeichnis] — arm64/riscv == soll
nur_ir() {
  local t aus rc
  for t in arm64 riscv; do
    if ! baue $t "$2" "$TMP/p" "${4:-}"; then nok "$1 [$t]: uebersetzt nicht ($(grep -m1 -i error "$TMP/p.log"))"; continue; fi
    aus="$(lauf $t "$TMP/p" 2>/dev/null | tr '\n' '|')"; rc=${PIPESTATUS[0]}
    if [ "$aus" = "$3" ] && [ "$rc" = 0 ]; then ok "$1 [$t]: [$aus]"
    else nok "$1 [$t]: [$aus] rc=$rc statt [$3]"; fi
  done
}

# abgewiesen <name> <ziel> <datei> <muster> [verzeichnis] — laut, ohne Erzeugnis
abgewiesen() {
  if baue "$2" "$3" "$TMP/r" "${5:-}"; then nok "$1 [$2]: uebersetzt, statt abzuweisen"; return; fi
  if [ -e "$TMP/r" ]; then nok "$1 [$2]: Erzeugnis trotz Fehler"; return; fi
  if grep -q -- "$4" "$TMP/r.log"; then ok "$1 [$2]: laut abgewiesen"
  else nok "$1 [$2]: Meldung ohne '$4': $(grep -m1 -i error "$TMP/r.log")"; fi
}

# --- 1+2: die beiden Dateien aus dem Issue, woertlich ----------------------
vergleiche "feature_checks/generics/test_generics" tests/feature_checks/generics/test_generics.lyx \
  "max(10, 20) = 20|max(42, 7) = 42|min(3, 9) = 3|min(100, 1) = 1|"
vergleiche "generics_monomorph_test" tests/generics_monomorph_test.lyx \
  "OK: max[int64]|OK: min[int64]|OK: id[int64]|OK: id[pchar]|OK: clamp[int64]|OK: multiple instantiations reuse same specialization|All WP-2.1 generics monomorphization tests passed.|"

# --- 3: mehrere Typargumente, gleiche Instanz zweimal, generisch ruft generisch
cat > "$TMP/eigen.lyx" <<'EOF'
fn max<T>(a: T, b: T): T {
  if (a > b) { return a; }
  return b;
}
fn pick<A, B>(a: A, b: B, w: int64): int64 {
  if (w == 0) { return a; }
  return b;
}
fn max3<T>(a: T, b: T, c: T): T { return max<T>(max<T>(a, b), c); }
fn laenge<S>(s: S): int64 { return StrLen(s); }
fn main(): int64 {
  PrintLn(StrFromInt(max<int64>(3, 9)));
  PrintLn(StrFromInt(max<int64>(30, 9)));
  PrintLn(StrFromInt(pick<int64, int64>(5, 6, 0)));
  PrintLn(StrFromInt(pick<int64, int64>(5, 6, 1)));
  PrintLn(StrFromInt(laenge<pchar>("vier"c) + pick<pchar, int64>("x"c, 70, 1)));
  PrintLn(StrFromInt(max3<int64>(4, 11, 7)));
  PrintLn(StrFromInt(max3<int64>(40, 11, 7)));
  PrintLn(StrFromInt(max(8, 2)));
  return 0;
}
EOF
vergleiche "mehrere Typargumente / zweimal / generisch->generisch" "$TMP/eigen.lyx" "9|30|5|6|74|11|40|8|"

# --- 4: Wiederverwendung am Erzeugnis --------------------------------------
# Zweimal max<int64> gegen max<int64> + max<int32>: die Aufrufstellen sind
# gleich lang, der Unterschied ist genau ein Rumpf. Ohne Wiederverwendung
# haetten beide Programme zwei gleiche Rumpfe. Gezaehlt werden die Bytes
# ungleich 0 — riscv fuellt die Datei auf ganze Seiten auf, die Dateigroesse
# allein sagt dort nichts.
printf 'fn max<T>(a: T, b: T): T {\n  if (a > b) { return a; }\n  return b;\n}\nfn main(): int64 {\n  var a: int64 := max<int64>(1, 2);\n  var b: int64 := max<%s>(7, 4);\n  return a + b;\n}\n' int64 > "$TMP/d1.lyx"
printf 'fn max<T>(a: T, b: T): T {\n  if (a > b) { return a; }\n  return b;\n}\nfn main(): int64 {\n  var a: int64 := max<int64>(1, 2);\n  var b: int64 := max<%s>(7, 4);\n  return a + b;\n}\n' int32 > "$TMP/d2.lyx"
for t in arm64 riscv; do
  baue $t "$TMP/d1.lyx" "$TMP/d1"; baue $t "$TMP/d2.lyx" "$TMP/d2"
  s1=0; s2=0
  [ -f "$TMP/d1" ] && s1=$(tr -d '\000' < "$TMP/d1" | wc -c)
  [ -f "$TMP/d2" ] && s2=$(tr -d '\000' < "$TMP/d2" | wc -c)
  r1=$(lauf $t "$TMP/d1" >/dev/null 2>&1; echo $?)
  if [ "$s1" -gt 0 ] && [ "$s2" -gt "$s1" ] && [ "$r1" = 9 ]; then ok "gleiche Kombination = ein Rumpf [$t] ($s1 < $s2, rc $r1)"
  else nok "gleiche Kombination [$t]: $s1 vs $s2, rc $r1 (erwartet $s1 < $s2, rc 9)"; fi
done

# --- 5: f64 als Typargument ------------------------------------------------
cat > "$TMP/f64.lyx" <<'EOF'
fn max<T>(a: T, b: T): T {
  if (a > b) { return a; }
  return b;
}
fn add<T>(a: T, b: T): T { return a + b; }
fn zweit<A, B>(a: A, b: B): B { return b; }
fn main(): int64 {
  var x: f64 := add<f64>(1.5, 2.25);
  PrintLn(StrFromInt((x * 100.0) as int64));
  var y: f64 := max<f64>(0.0 - 1.5, 0.0 - 2.5);
  PrintLn(StrFromInt((y * 10.0) as int64));
  var z: f64 := zweit<int64, f64>(3, 0.5) * 8.0;
  PrintLn(StrFromInt(z as int64));
  PrintLn(StrFromInt(add<int64>(20, 22)));
  return 0;
}
EOF
# #2134: x86 spezialisiert jetzt ebenfalls — Wert auf allen drei Zielen.
vergleiche "f64-Typargument" "$TMP/f64.lyx" "375|-15|4|42|"

# --- 6: Unit-uebergreifend: Spezialisierung im Kontext der Deklaration -----
mkdir -p "$TMP/xm"
cat > "$TMP/xm/gm.lyx" <<'EOF'
unit gm;
fn hilf(a: int64): int64 { return a * 2; }
pub fn gmax<T>(a: T, b: T): T {
  if (a > b) { return a; }
  return b;
}
pub fn twice<T>(a: T): T { return gmax<T>(a, a) + hilf(a) - a; }
EOF
cat > "$TMP/xm/main.lyx" <<'EOF'
import gm;
fn main(): int64 {
  PrintLn(StrFromInt(gmax<int64>(4, 8)));
  PrintLn(StrFromInt(twice<int64>(21)));
  PrintLn(StrFromInt(gmax<int64>(80, 8)));
  return 0;
}
EOF
vergleiche "andere Unit (privater Helfer, generisch->generisch)" main.lyx "8|42|80|" "$TMP/xm"

# --- 7: Klasse als Typargument -----------------------------------------------
# x86 rechnete hier bis 1.2.15A still 0 (typgeloescht); seit #2134 gleich —
# die x86-Seite misst tests/generics_x86_typen_test.sh.
cat > "$TMP/kl.lyx" <<'EOF'
type P = class {
  x: int64;
  y: int64;
};
fn getx<T>(p: T): int64 { return p.x + p.y * 10; }
fn setx<T>(p: T, v: int64) { p.x := v; }
fn main(): int64 {
  var p: P := new P();
  p.x := 3; p.y := 4;
  setx<P>(p, 5);
  PrintLn(StrFromInt(getx<P>(p)));
  return 0;
}
EOF
nur_ir "Klasse als Typargument (Feld ueber T)" "$TMP/kl.lyx" "45|"

cat > "$TMP/xm/gk.lyx" <<'EOF'
unit gk;
pub fn getx<T>(p: T): int64 { return p.x; }
EOF
cat > "$TMP/xm/kl2.lyx" <<'EOF'
import gk;
type P = class {
  x: int64;
};
fn main(): int64 {
  var p: P := new P();
  p.x := 3;
  PrintLn(StrFromInt(getx<P>(p)));
  return 0;
}
EOF
abgewiesen "Feld ueber T, Klasse der Unit unbekannt" arm64 kl2.lyx "#2125" "$TMP/xm"
abgewiesen "Feld ueber T, Klasse der Unit unbekannt" riscv kl2.lyx "#2125" "$TMP/xm"

# --- 8: Rueckgabewert, dazu lyxos ueber den lokalen Lader ------------------
# Der Lader kann nur Ganzzahlfaelle (kein Allokieren, LyxOS liefert
# Syscall-Ergebnisse in rdx). Ganzzahl- und f64-Fall getrennt: bis 1.2.14C
# uebersetzte lyxos den Ganzzahlfall OHNE Meldung, `<f64>` parste nicht.
cat > "$TMP/lx_int.lyx" <<'EOF'
fn max<T>(a: T, b: T): T {
  if (a > b) { return a; }
  return b;
}
fn max3<T>(a: T, b: T, c: T): T { return max<T>(max<T>(a, b), c); }
fn main(): int64 {
  return max<int64>(3, 9) + max3<int64>(4, 11, 7) + max<int64>(1, 0);
}
EOF
cat > "$TMP/lx_f64.lyx" <<'EOF'
fn add<T>(a: T, b: T): T { return a + b; }
fn main(): int64 {
  var f: f64 := add<f64>(1.5, 2.25) * 4.0;
  return (f as int64) + add<int64>(1, 2);
}
EOF
rueckgabe() {  # name, datei, soll
  local t rc
  for t in arm64 riscv; do
    if baue $t "$2" "$TMP/lxb"; then
      rc=$(lauf $t "$TMP/lxb" >/dev/null 2>&1; echo $?)
      if [ "$rc" = "$3" ]; then ok "$1 [$t] = $3"; else nok "$1 [$t] = $rc statt $3"; fi
    else nok "$1 [$t]: uebersetzt nicht ($(grep -m1 -i error "$TMP/lxb.log"))"; fi
  done
  if LYX_STD_PATH="$ROOT/std" timeout 200 "$LYXC" --target=lyxos "$2" -o "$TMP/lx.lyxnative" >"$TMP/lx.log" 2>&1; then
    printf 'import src.tools.lbf.loader;\nfn main(): int64 { lbf_run("%s/lx.lyxnative"c); return 111; }' "$TMP" > "$TMP/r.lyx"
    ( cd "$ROOT" && LYX_STD_PATH="$ROOT/std" timeout 200 "$LYXC" "$TMP/r.lyx" -o "$TMP/rl" ) >/dev/null 2>&1
    rc=$(timeout 10 "$TMP/rl" >/dev/null 2>&1; echo $?)
    if [ "$rc" = "$3" ]; then ok "$1 [lyxos, Lader] = $3"; else nok "$1 [lyxos, Lader]: exit $rc statt $3"; fi
  else
    nok "$1 [lyxos]: uebersetzt nicht ($(grep -m1 -i error "$TMP/lx.log"))"
  fi
}
rueckgabe "Ganzzahl-Generika" "$TMP/lx_int.lyx" 21
rueckgabe "f64-Generika" "$TMP/lx_f64.lyx" 18

echo "ir_generics: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
