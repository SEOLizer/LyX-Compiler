#!/usr/bin/env bash
# tests/ir_f64_negativ_test.sh — #2129: unaeres Minus auf Gleitkomma im IR-Weg.
#
# Bis 1.2.15A uebersetzte lowerUnOp `-x` IMMER zu IRO_NEG, also zu `0 - bits`
# auf dem IEEE-Muster. Das ergibt eine plausible, aber falsche Zahl:
# 0 - 0x3FF8000000000000 = 0xC008000000000000 = -3.0. Aus `-1.5` wurde -3.0,
# aus `-0.25` -16.0, und `-(-1.5)` stimmte nur, weil sich zwei Fehler
# aufhoben. Betroffen: arm64, riscv, lyxos (alle IR-Backends); x86 rechnet
# seit #1803 richtig und ist hier der Massstab.
#
# Gemessen wird der WERT (x1000 als Ganzzahl ausgegeben) auf x86_64, arm64
# und riscv, dazu der Vergleich mit einem negativen Literal (Weg: welcher
# Zweig laeuft) und als Gegenseite die ganzzahlige Negation, die NICHT zur
# Gleitkomma-Negation werden darf. lyxos: Rueckgabewert ueber den lokalen
# LBF-Lader (nur Ganzzahl, nicht allokierend).
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

pruefe() {  # name, datei, soll-ausgabe
  local t
  for t in linux arm64 riscv; do
    rm -f "$TMP/p"
    if ! ( cd "$ROOT" && timeout 240 "$LYXC" --std-path="$ROOT" --target=$t "$2" -o "$TMP/p" ) >"$TMP/bl.log" 2>&1; then
      nok "$1 [$t]: uebersetzt nicht ($(grep -m1 -iE 'error' "$TMP/bl.log"))"; continue
    fi
    local aus rc
    aus="$(lauf $t "$TMP/p" 2>/dev/null | tr '\n' '|')"; rc=${PIPESTATUS[0]}
    if [ "$aus" = "$3" ] && [ "$rc" = "0" ]; then ok "$1 [$t]: [$aus]"
    else nok "$1 [$t]: [$aus] rc=$rc statt [$3]"; fi
  done
}

# Der Fall aus dem Issue, woertlich, und die Formen daneben: Literal,
# geklammert, im Ausdruck, als Argument, Modulkonstante, Modulvariable,
# Vergleich. `0.0 - 1.5` war schon richtig (IRO_FSUB) und steht als Bezug.
cat > "$TMP/issue.lyx" <<'EOF'
con C: f64 := -1.5;
var g: f64 := -0.25;
fn ident(x: f64): f64 { return x; }
fn main(): int64 {
  var y: f64 := -1.5;
  PrintInt((y * 1000.0) as int64); Print(" ");
  PrintInt((ident(-1.5) * 1000.0) as int64); Print(" ");
  PrintInt(((-(1.5)) * 1000.0) as int64); Print(" ");
  PrintInt(((2.0 + -0.25) * 1000.0) as int64); Print(" ");
  PrintInt((C * 1000.0) as int64); Print(" ");
  PrintInt((g * 1000.0) as int64); Print(" ");
  if (y < -1.4) { Print("lt "); } else { Print("ge "); }
  if (y > -1.6) { Print("gt "); } else { Print("le "); }
  PrintInt(((0.0 - 1.5) * 1000.0) as int64); Print("\n");
  return 0;
}
EOF
pruefe "Literal, Klammer, Ausdruck, Argument, con, var, Vergleich" "$TMP/issue.lyx" "-1500 -1500 -1500 1750 -1500 -250 lt gt -1500|"

# Negation von NAMEN (Local, Modulkonstante, Modulvariable), doppelte
# Negation, Negation im Produkt, im Vergleich; Gegenseite Ganzzahl.
cat > "$TMP/namen.lyx" <<'EOF'
con C: f64 := -1.5;
con D: f64 := -(0.25);
var g: f64 := -0.25;
fn p(x: f64) { PrintInt((x * 1000.0) as int64); Print(" "); }
fn main(): int64 {
  var a: f64 := 2.5;
  p(-a); p(-C); p(D); p(-g); p(-(-1.5)); p(-a * 2.0); p(1.0 - -2.0);
  var b: f64 := -a;
  p(b);
  if (-a < -2.4) { Print("lt "); } else { Print("ge "); }
  var i: int64 := 7;
  PrintInt(-i); Print(" "); PrintInt(-(0 - 9)); Print("\n");
  return 0;
}
EOF
pruefe "Namen, doppelt, Produkt, Ganzzahl-Gegenseite" "$TMP/namen.lyx" "-2500 1500 -250 250 1500 -5000 3000 -2500 lt -7 9|"

# --- lyxos: Rueckgabewert ueber den lokalen LBF-Lader -----------------------
# -1.5 * 10 + 100 = 85; mit der alten Ganzzahl-Negation (-3.0) waeren es 70.
lyxos_rc() {  # quelle -> Exit-Code von main
  rm -f "$TMP/e.lyxnative" "$TMP/er"
  ( cd "$ROOT" && timeout 240 "$LYXC" --std-path="$ROOT" --target=lyxos "$1" -o "$TMP/e.lyxnative" ) >/dev/null 2>&1 || { echo "UEBERSETZT-NICHT"; return; }
  printf 'import src.tools.lbf.loader;\nfn main(): int64 { lbf_run("%s/e.lyxnative"c); return 111; }' "$TMP" > "$TMP/er.lyx"
  ( cd "$ROOT" && timeout 240 "$LYXC" "$TMP/er.lyx" -o "$TMP/er" ) >/dev/null 2>&1 || { echo "LADER-UEBERSETZT-NICHT"; return; }
  ( ulimit -v 4000000; timeout 10 "$TMP/er" >/dev/null 2>&1 ); echo $?
}
cat > "$TMP/lx1.lyx" <<'EOF'
fn main(): int64 { var y: f64 := -1.5; return ((y * 10.0) as int64) + 100; }
EOF
cat > "$TMP/lx2.lyx" <<'EOF'
fn ident(x: f64): f64 { return x; }
fn main(): int64 { var a: f64 := 0.25; return ((ident(-a) * 100.0) as int64) + 100; }
EOF
cat > "$TMP/lx3.lyx" <<'EOF'
fn main(): int64 { var y: f64 := -1.5; if (y < -1.4) { return 7; } return 9; }
EOF
r="$(lyxos_rc "$TMP/lx1.lyx")"; [ "$r" = "85" ] && ok "lyxos -1.5 [$r]" || nok "lyxos -1.5: [$r] statt [85]"
r="$(lyxos_rc "$TMP/lx2.lyx")"; [ "$r" = "75" ] && ok "lyxos ident(-a) [$r]" || nok "lyxos ident(-a): [$r] statt [75]"
r="$(lyxos_rc "$TMP/lx3.lyx")"; [ "$r" = "7" ] && ok "lyxos Vergleich [$r]" || nok "lyxos Vergleich: [$r] statt [7]"

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
