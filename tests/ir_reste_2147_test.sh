#!/usr/bin/env bash
# tests/ir_reste_2147_test.sh — #2147, #2153: Reste des IR-Wegs (arm64, riscv).
#
# Bis 1.2.16C:
#   (1) Structs waren auf dem IR-Weg Aliase: `modn(p)` aenderte p beim
#       Aufrufer, `var q: Pt := p` und `q := p` bogen nur den Zeiger um
#       (x86 kopiert seit #1351/#1528).
#   (2) Ein Vorgabeparameter einer IMPORTIERTEN Funktion kam als Muell an —
#       _callDeclNi sah nur die eigene Unit.
#   (3) Das Speicherbild: ohne Ausrichtung, i8/i16/i32 galten als acht Byte,
#       und jeder Feldzugriff las/schrieb acht Byte (ein int8-Feld
#       ueberschrieb seine Nachbarn). Jetzt dieselben Regeln wie x86.
#   (4) len() auf einem Array kannte der IR-Weg nicht.
#   (5) Eine Zuweisung an einen Namen ohne Speicherort entfiel still (nur
#       intern erreichbar — sema weist unbekannte Namen vorher ab; hier nicht
#       gemessen).
#   (6) Die Kuerzung schmaler Typen fehlte bei Lambda-Rueckgaben und bei
#       Feldern.
#   #2153: Gemischte Arithmetik f64 mit Ganzzahl rechnete auf dem Bitmuster
#       (`1.5 * 2` = 0, `1.5 + 1` = 1.5).
#
# Gemessen werden WERTE auf x86_64, arm64 und riscv; sie muessen gleich sein.
# Beim Speicherbild der Wert UND die Groesse (sizeof), bei den schmalen
# Feldern die Nachbarn (der falsche Weg ueberschreibt sie), bei der Kopie
# BEIDE Seiten (Original unveraendert, Kopie veraendert).
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

lauf() {
  case "$1" in
    linux) ( cd "$TMP" && timeout 30 "$2" ) ;;
    arm64) ( cd "$TMP" && timeout 30 "$QEMU_ARM64" "$2" ) ;;
    riscv) ( cd "$TMP" && timeout 30 "$QEMU_RISCV64" "$2" ) ;;
  esac
}
baue() {  # ziel, datei, ausgabe [verzeichnis]
  ( cd "${4:-$ROOT}" && timeout 240 "$LYXC" --std-path="$ROOT" --target=$1 "$2" -o "$3" ) >"$3.log" 2>&1
}
pruefe() {  # name datei soll [verzeichnis]
  local t
  for t in linux arm64 riscv; do
    rm -f "$TMP/p"
    if ! baue $t "$2" "$TMP/p" "${4:-}"; then
      nok "$1 [$t]: uebersetzt nicht ($(grep -m1 -iE 'error|fehler|unbekannt' "$TMP/p.log"))"; continue
    fi
    local aus rc
    aus="$(lauf $t "$TMP/p" 2>&1 | tr '\n' '|')"; rc=${PIPESTATUS[0]}
    if [ "$aus" = "$3" ] && [ "$rc" = 0 ]; then ok "$1 [$t]: [$aus]"
    else nok "$1 [$t]: [$aus] rc=$rc statt [$3]"; fi
  done
}

# --- (1) Struct als Wert ------------------------------------------------------
cat > "$TMP/wert.lyx" <<'EOF'
type Pt = struct { x: int64; y: int64; };
fn modn(p: Pt): int64 { p.x := 50; return p.x; }
fn modr(ref p: Pt): int64 { p.y := 77; return p.y; }
fn main(): int64 {
  var p: Pt; p.x := 3; p.y := 4;
  var r: int64 := modn(p);
  PrintInt(r); Print(" "); PrintInt(p.x); Print("|");
  // ref: die Aenderung soll beim Aufrufer ankommen (Gegenseite)
  var r2: int64 := modr(p);
  PrintInt(r2); Print(" "); PrintInt(p.y); Print("|");
  var q: Pt := p;
  q.y := 99;
  PrintInt(p.y); Print(" "); PrintInt(q.y); Print("|");
  var s: Pt; s.x := 1; s.y := 2;
  s := p;
  s.x := 11;
  PrintInt(p.x); Print(" "); PrintInt(s.x); Print(" "); PrintInt(s.y); Print("\n");
  return 0;
}
EOF
pruefe "Struct als Wert" "$TMP/wert.lyx" "50 3|77 77|77 99|3 11 77|"

# --- (2) Vorgabewert einer importierten Funktion ----------------------------
mkdir -p "$TMP/imp/lib"
cat > "$TMP/imp/lib/skal.lyx" <<'EOF'
pub fn Skal(x: int64, f: int64 = 3): int64 { return x * f; }
pub fn Skal2(x: int64, f: int64 = 4, g: f64 = 0.5): int64 { return x * f + ((g * 10.0) as int64); }
EOF
cat > "$TMP/imp/haupt.lyx" <<'EOF'
import lib.skal;
fn main(): int64 {
  PrintInt(Skal(6)); Print(" "); PrintInt(Skal(6, 2)); Print(" ");
  PrintInt(Skal2(2)); Print(" "); PrintInt(Skal2(2, 1)); Print("\n");
  return 0;
}
EOF
pruefe "Vorgabewert einer importierten Funktion" "haupt.lyx" "18 12 13 7|" "$TMP/imp"

# --- (3) Speicherbild und schmale Felder ---------------------------------------
cat > "$TMP/layout.lyx" <<'EOF'
type R = struct { a: int8; b: int32; c: int16; d: int64; e: u8; };
type Q = struct { a: i8; b: i16; c: i32; };
type K = class { a: int8; b: int64; };
fn main(): int64 {
  var r: R; r.a := 0 - 1; r.b := 0 - 2; r.c := 0 - 3; r.d := 4; r.e := 255;
  PrintInt(sizeof(R)); Print(" "); PrintInt(sizeof(Q)); Print(" ");
  PrintInt(r.a); Print(" "); PrintInt(r.b); Print(" "); PrintInt(r.c); Print(" ");
  PrintInt(r.d); Print(" "); PrintInt(r.e); Print("|");
  // Ueberlauf in ein schmales Feld: gekuerzt, Nachbar unberuehrt
  r.a := 300;
  PrintInt(r.a); Print(" "); PrintInt(r.b); Print("|");
  var q: Q; q.a := 0 - 7; q.b := 40000; q.c := 0 - 8;
  PrintInt(q.a); Print(" "); PrintInt(q.b); Print(" "); PrintInt(q.c); Print("|");
  var k: K := new K(); k.a := 200; k.b := 7;
  PrintInt(k.a); Print(" "); PrintInt(k.b); Print("\n");
  return 0;
}
EOF
pruefe "Speicherbild und schmale Felder" "$TMP/layout.lyx" "32 8 -1 -2 -3 4 255|44 -2|-7 -25536 -8|-56 7|"

# --- (4) len() auf Arrays -------------------------------------------------------
cat > "$TMP/len.lyx" <<'EOF'
fn main(): int64 {
  var a: [5]int64;
  var d: int64[] := [1, 2, 3];
  var t: array := [7, 8, 9, 10];
  PrintInt(len(a)); Print(" "); PrintInt(len(d)); Print(" "); PrintInt(len(t)); Print("\n");
  return 0;
}
EOF
pruefe "len() auf Arrays" "$TMP/len.lyx" "5 3 4|"

# --- (6) Kuerzung bei Lambda-Rueckgabe ---------------------------------------
cat > "$TMP/lambda.lyx" <<'EOF'
fn main(): int64 {
  var sq: fn(int64): int8 := fn(z: int64): int8 { return z; };
  var su: fn(int64): u8 := fn(z: int64): u8 { return z; };
  PrintInt(sq(300)); Print(" "); PrintInt(su(300)); Print(" "); PrintInt(sq(5)); Print("\n");
  return 0;
}
EOF
pruefe "Kuerzung bei Lambda-Rueckgabe" "$TMP/lambda.lyx" "44 44 5|"

# --- #2153 gemischte Arithmetik --------------------------------------------------
cat > "$TMP/gemischt.lyx" <<'EOF'
fn main(): int64 {
  var v: f64 := 1.5 * 2;
  var w: f64 := 2 * 1.5;
  var n: int64 := 2;
  var x: f64 := 1.5 * n;
  var y: f64 := 1.5 + 1;
  var z: f64 := 7 / 2.0;
  var f: f64 := 2.5;
  var u: f64 := f * 4;
  PrintInt((v * 10.0) as int64); Print(" "); PrintInt((w * 10.0) as int64); Print(" ");
  PrintInt((x * 10.0) as int64); Print(" "); PrintInt((y * 10.0) as int64); Print(" ");
  PrintInt((z * 10.0) as int64); Print(" "); PrintInt((u * 10.0) as int64); Print(" ");
  if (2 < 2.5) { Print("t"); } else { Print("f"); }
  if (3 < 2.5) { Print("t"); } else { Print("f"); }
  // Gegenseite: rein ganzzahlig bleibt ganzzahlig
  var g: int64 := 7 / 2;
  Print(" "); PrintInt(g); Print("\n");
  return 0;
}
EOF
pruefe "gemischte Arithmetik f64/Ganzzahl" "$TMP/gemischt.lyx" "30 30 30 25 35 100 tf 3|"

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
