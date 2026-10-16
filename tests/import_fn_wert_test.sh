#!/usr/bin/env bash
# tests/import_fn_wert_test.sh — #2113: eine `pub fn` aus einer importierten
# Unit als FUNKTIONSWERT (Argument vom Funktionstyp, `f as int64`).
#
# Bis 1.2.14B kannte cg_isDeclaredFunc (codegen_x86.lyx) nur die Funktionen
# der LAUFENDEN Unit (topLevelHead). Ein importierter Name fiel in cg_genExpr
# bis auf einen stillen cg_zeroRax durch: der Funktionswert war 0, der Aufruf
# darueber SIGSEGV — oder, ueber eine dritte Unit gespeichert, still `false`.
# Der Direktaufruf ging, weil er nur eine Marke patcht (CG_PATCH_CALL).
#
# Gemessen wird der WERT (Ausgabe + rc), beide Seiten: lokal (ging immer) und
# importiert, int und bool, der `as int64`-Weg und der Weg ueber eine dritte
# Unit. arm64/riscv gehen den IR-Weg (_findFuncByName kennt Importe) und
# messen gegen, dass beide Wege dasselbe liefern.
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

mkdir -p "$TMP/u"
# Repro aus dem Issue, woertlich.
cat > "$TMP/u/fpa.lyx" <<'EOF'
unit fpa;
pub fn Ja(a: int64, b: int64, c: int64): bool { return a + b + c == 6; }
pub fn Zahl(a: int64, b: int64, c: int64): int64 { return a + b + c; }
EOF
cat > "$TMP/m.lyx" <<'EOF'
import fpa;
type FI = fn(int64, int64, int64): int64;
fn rufI(f: FI): int64 { return f(1, 2, 3); }
fn main(): int64 {
    if (rufI(Zahl) == 6) { PrintStr("import int ok\n"); } else { PrintStr("FALSCH\n"); }
    return 0;
}
EOF
# Beide Seiten: lokal und importiert, int und bool, Parameter und `as int64`.
cat > "$TMP/v.lyx" <<'EOF'
import fpa;
type FI = fn(int64, int64, int64): int64;
type FB = fn(int64, int64, int64): bool;
fn lokalZ(a: int64, b: int64, c: int64): int64 { return a + b + c; }
fn lokalJ(a: int64, b: int64, c: int64): bool { return a + b + c == 6; }
fn rufI(f: FI): int64 { return f(1, 2, 3); }
fn rufB(f: FB): bool { return f(1, 2, 3); }
fn main(): int64 {
    PrintInt(rufI(lokalZ)); PrintStr("\n");
    if (rufB(lokalJ)) { PrintStr("lokal bool ok\n"); } else { PrintStr("lokal bool FALSCH\n"); }
    PrintInt(rufI(Zahl)); PrintStr("\n");
    if (rufB(Ja)) { PrintStr("import bool ok\n"); } else { PrintStr("import bool FALSCH\n"); }
    var x: int64 := Ja as int64;
    var g: FB := x as FB;
    if (g(1, 2, 3)) { PrintStr("import cast ok\n"); } else { PrintStr("import cast FALSCH\n"); }
    var y: int64 := Zahl as int64;
    var h: FI := y as FI;
    PrintInt(h(10, 20, 30)); PrintStr("\n");
    return 0;
}
EOF
# netmax-Form: der Wert wird in einer DRITTEN Unit gespeichert und dort
# aufgerufen — einmal im Hauptmodul genommen, einmal in der Unit selbst.
cat > "$TMP/u/fpb.lyx" <<'EOF'
unit fpb;
import fpa;
pub type FB3 = fn(int64, int64, int64): bool;
var gF: int64 := 0;
pub fn Merke(f: FB3): void { gF := f as int64; }
pub fn MerkeJa(): void { gF := Ja as int64; }
pub fn Rufe(): bool { var g: FB3 := gF as FB3; return g(1, 2, 3); }
EOF
cat > "$TMP/t.lyx" <<'EOF'
import fpa;
import fpb;
fn main(): int64 {
    Merke(Ja);
    if (Rufe()) { PrintStr("dritte Unit ok\n"); } else { PrintStr("dritte Unit FALSCH\n"); }
    MerkeJa();
    if (Rufe()) { PrintStr("in Unit genommen ok\n"); } else { PrintStr("in Unit genommen FALSCH\n"); }
    return 0;
}
EOF

# pruefe name, datei, ziel(""=x86), lauf-praefix, soll-ausgabe
pruefe() {
  local name="$1" f="$2" ziel="$3" lauf="$4" soll="$5"
  local zarg=(); [ -n "$ziel" ] && zarg=(--target="$ziel")
  rm -f "$TMP/p"
  if ! ( cd "$TMP" && "$LYXC" "${zarg[@]}" "$f" -I u -o "$TMP/p" ) >"$TMP/bl.log" 2>&1; then
    nok "$name: uebersetzt nicht ($(grep -m1 -iE 'error' "$TMP/bl.log"))"; return
  fi
  ( cd "$TMP" && timeout 30 $lauf "$TMP/p" >"$TMP/out" 2>/dev/null ); local rc=$?
  local aus; aus="$(tr '\n' '|' < "$TMP/out")"
  if [ "$aus" = "$soll" ] && [ "$rc" = "0" ]; then ok "$name: [$aus] rc=0"
  else nok "$name: [$aus] rc=$rc statt [$soll] rc=0"; fi
}

V_SOLL="6|lokal bool ok|6|import bool ok|import cast ok|60|"
T_SOLL="dritte Unit ok|in Unit genommen ok|"

pruefe "x86 Issue-Repro"            m.lyx "" "" "import int ok|"
pruefe "x86 lokal+import int/bool/cast" v.lyx "" "" "$V_SOLL"
pruefe "x86 ueber dritte Unit"      t.lyx "" "" "$T_SOLL"

if [ -n "$QEMU_ARM64" ]; then
  pruefe "arm64 lokal+import int/bool/cast" v.lyx arm64 "$QEMU_ARM64" "$V_SOLL"
  pruefe "arm64 ueber dritte Unit"  t.lyx arm64 "$QEMU_ARM64" "$T_SOLL"
else nok "qemu fuer arm64 fehlt — arm64 NICHT gemessen"; fi
if [ -n "$QEMU_RISCV64" ]; then
  pruefe "riscv lokal+import int/bool/cast" v.lyx riscv "$QEMU_RISCV64" "$V_SOLL"
  pruefe "riscv ueber dritte Unit"  t.lyx riscv "$QEMU_RISCV64" "$T_SOLL"
else nok "qemu fuer riscv fehlt — riscv NICHT gemessen"; fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
