#!/usr/bin/env bash
# tests/konst_f64_print_test.sh — #2148: Gleitkomma in Konstanten, PrintStr
# am Nullbyte, PrintInt(INT64_MIN) auf riscv.
#
# Bis 1.2.16B:
#   (1) x86: `con W: f64 := (3 as f64) * 0.5` war still 0 — cg_istF64Konstante
#       kannte CGN_CAST nicht, und cg_evalConExpr reichte den Wert durch den
#       Cast, ohne die Darstellung zu wechseln. Ebenso eine Modulvariable
#       `var v: f64 := (10 as f64) / 4.0` (0) und `(7.9 as int64) * 2`
#       (ein Bitmuster mal 2).
#   (2) x86: cg_faltF64 behandelte Token 82 als `>` und 83 als `<=` — laut
#       Lexer ist es umgekehrt. Jede gefaltete f64-Konstante mit <= oder >
#       ergab das Gegenteil. Dazu: `con A: bool := X <= 2.0; if (A)` scheiterte
#       in sema mit "@if: non-constant expression", und der IR-Weg wies
#       Vergleiche in Konstanten ganz ab (#1798).
#   (3) PrintStr("ab\0cd") gab auf x86 "ab", auf dem IR-Weg "ab\0cd" aus.
#       PrintStr ist die pchar-Ausgabe (std/io.lyx: StrLen) — jetzt endet sie
#       ueberall am Nullbyte. Print mit Literal behaelt die volle Laenge
#       (#2141, Gegenseite).
#   (4) riscv: PrintInt(INT64_MIN) und IntToStr(INT64_MIN) gaben Satzzeichen
#       aus — die Ziffernschleife negierte n, und 0 - INT64_MIN ist wieder
#       INT64_MIN.
#
# Gemessen werden WERTE auf x86_64, arm64 und riscv; bei den Vergleichen
# BEIDE Ausgaenge (wahr und falsch), damit eine vertauschte Zuordnung nicht
# zufaellig passt.
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
    linux) ( cd "$TMP" && timeout 30 "$2" ) ;;
    arm64) ( cd "$TMP" && timeout 30 "$QEMU_ARM64" "$2" ) ;;
    riscv) ( cd "$TMP" && timeout 30 "$QEMU_RISCV64" "$2" ) ;;
  esac
}

baue() {  # ziel, datei, ausgabe
  ( cd "$ROOT" && timeout 240 "$LYXC" --std-path="$ROOT" --target=$1 "$2" -o "$3" ) >"$3.log" 2>&1
}

# pruefe name datei soll-stdout [ziele]   (NUL als @, Zeilenende als |)
pruefe() {
  local t ziele="${4:-linux arm64 riscv}"
  for t in $ziele; do
    rm -f "$TMP/p"
    if ! baue $t "$2" "$TMP/p"; then
      nok "$1 [$t]: uebersetzt nicht ($(grep -m1 -iE 'error|fehler' "$TMP/p.log"))"; continue
    fi
    local aus rc
    aus="$(lauf $t "$TMP/p" 2>&1 | tr '\0\n' '@|')"; rc=${PIPESTATUS[0]}
    if [ "$aus" = "$3" ]; then ok "$1 [$t]: [$aus]"
    else nok "$1 [$t]: [$aus] statt [$3]"; fi
  done
}

# --- (1) Cast in Konstante und Modulvariable --------------------------------
cat > "$TMP/cast.lyx" <<'EOF'
con W: f64 := (3 as f64) * 0.5;
con D: int64 := (2.5 as int64) + 1;
var v: f64 := (10 as f64) / 4.0;
var k: int64 := (7.9 as int64) * 2;
fn main(): int64 {
  var w: f64 := W;
  PrintInt((w * 100.0) as int64); Print(" ");
  PrintInt(D); Print(" ");
  PrintInt((v * 100.0) as int64); Print(" ");
  PrintInt(k); Print("\n");
  return 0;
}
EOF
pruefe "Cast in Konstante/Modulvariable" "$TMP/cast.lyx" "150 3 250 14|"

# Gemischt f64 * Ganzzahl in einer Konstanten: nur x86. Der IR-Weg rechnet
# gemischte Arithmetik mit Ganzzahl-Literal auch zur LAUFZEIT falsch (0) —
# ein eigener Defekt (#2153), an dem dieser Test nicht haengen darf.
cat > "$TMP/gemischt.lyx" <<'EOF'
con W: f64 := 1.5 * 2;
fn main(): int64 {
  PrintInt((W * 10.0) as int64); Print("\n");
  return 0;
}
EOF
pruefe "f64 * Ganzzahl in Konstante" "$TMP/gemischt.lyx" "30|" "linux"

# --- (2) Vergleiche auf f64-Konstanten, beide Ausgaenge ---------------------
cat > "$TMP/vgl.lyx" <<'EOF'
con X: f64 := 1.0;
con Y: f64 := 2.0;
con A: int64 := X <= Y;
con B: int64 := X > Y;
con C: int64 := Y <= X;
con D: int64 := Y > X;
con E: int64 := X <= X;
con F: int64 := X > X;
con G: int64 := X < Y;
con H: int64 := X >= Y;
fn main(): int64 {
  PrintInt(A); PrintInt(B); PrintInt(C); PrintInt(D);
  PrintInt(E); PrintInt(F); PrintInt(G); PrintInt(H);
  Print("\n");
  return 0;
}
EOF
pruefe "f64-Vergleich in Konstante" "$TMP/vgl.lyx" "10011010|"

# Eine bool-Konstante aus einem f64-Vergleich als Bedingung: sema faltete das
# `if` und scheiterte an der Gleitkommazahl. Beide Ausgaenge, dazu ein
# gemischter Vergleich (Ganzzahl gegen f64) und && in der Konstanten.
cat > "$TMP/bedingung.lyx" <<'EOF'
con X: f64 := 1.0;
con A: bool := X <= 2.0;
con B: bool := X > 2.0;
con M: bool := X <= 2;
con N: bool := 3 > X && 1 < 2;
con O: bool := 1 < 2 && 3 >= 4;
fn main(): int64 {
  if (A) { Print("A1"); } else { Print("A0"); }
  if (B) { Print("B1"); } else { Print("B0"); }
  if (M) { Print("M1"); } else { Print("M0"); }
  if (N) { Print("N1"); } else { Print("N0"); }
  if (O) { Print("O1"); } else { Print("O0"); }
  Print("\n");
  return 0;
}
EOF
pruefe "bool-Konstante aus f64-Vergleich" "$TMP/bedingung.lyx" "A1B0M1N1O0|"

# --- (3) PrintStr endet am Nullbyte, Print(Literal) nicht -------------------
cat > "$TMP/nul.lyx" <<'EOF'
fn main(): int64 {
  PrintStr("ab\0cd"); Print("|");
  Print("ab\0cd"); Print("\n");
  return 0;
}
EOF
pruefe "PrintStr am Nullbyte, Print voll" "$TMP/nul.lyx" "ab|ab@cd|"

# --- (4) INT64_MIN als Text --------------------------------------------------
cat > "$TMP/imin.lyx" <<'EOF'
fn main(): int64 {
  var m: int64 := 0x8000000000000000;
  PrintInt(m); Print(" ");
  Print(IntToStr(m)); Print(" ");
  PrintInt(m + 1); Print(" ");
  PrintInt(0 - 7); Print(" ");
  PrintInt(0); Print(" ");
  Print(IntToStr(0 - 1200)); Print("\n");
  return 0;
}
EOF
pruefe "INT64_MIN als Text" "$TMP/imin.lyx" "-9223372036854775808 -9223372036854775808 -9223372036854775807 -7 0 -1200|"

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
