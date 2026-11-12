#!/usr/bin/env bash
# tests/sema_reste_2137_test.sh — #2137, drei Reste aus sema und ir_lower.
#
# (1) `crt_color.cyan` — Enum-Element einer IMPORTIERTEN Unit mit Praefix —
#     meldete "unbekannter Enum-Member", ohne Praefix ging es. Der
#     Knotenindex des Enums zeigte nach dem Import in den Baum des
#     Wurzelmoduls (die Entwertung in _sema_processImport kannte SYM_VAR,
#     SYM_CON und SYM_TYPE, nicht SYM_ENUM). Die Variantennamen werden jetzt
#     abgeschrieben; ein Tippfehler faellt weiter auf (Gegenseite).
# (2) O_RDONLY … O_APPEND und PROT_NONE fuehrten x86 (cg_addBuiltinCons) und
#     der IR-Weg (_irEingebauteKonst) mit Wert — sema nicht, sie waren also
#     unerreichbar. Gemessen werden die WERTE, auf allen Zielen gleich.
# (3) lowerAssign schrieb einen PARAMETER ohne den Versatz methodParamBase:
#     in einer Methode traf `a := ...` (erster Parameter) den Slot von
#     `self`. arm64 stuerzte beim naechsten Feldzugriff ab, riscv gab nichts
#     aus. Die Lesestelle hatte den Versatz.
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
    arm64|android-arm64) timeout 30 "$QEMU_ARM64" "$2" ;;
    riscv) timeout 30 "$QEMU_RISCV64" "$2" ;;
  esac
}

pruefe() {  # name, datei, soll-ausgabe
  local t
  for t in linux arm64 android-arm64 riscv; do
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

# (1) Enum-Element einer importierten Unit, mit und ohne Praefix. Die Werte
# sind die Ordinalzahlen aus std/crt.lyx: cyan=3, white=15, black=0.
cat > "$TMP/enum.lyx" <<'EOF'
import std.crt;
fn main(): int64 {
  var c: crt_color := crt_color.cyan;
  PrintInt(c as int64); Print(" ");
  PrintInt(crt_color.white as int64); Print(" ");
  PrintInt(crt_color.black as int64); Print(" ");
  PrintInt(cyan as int64); Print("\n");
  return 0;
}
EOF
pruefe "(1) crt_color.cyan aus importierter Unit" "$TMP/enum.lyx" "3 15 0 3|"

# Gegenseite: ein Tippfehler im Element bleibt laut — die Abschrift darf die
# Pruefung nicht abschalten.
cat > "$TMP/tippfehler.lyx" <<'EOF'
import std.crt;
fn main(): int64 {
  var c: crt_color := crt_color.cyann;
  PrintInt(c as int64);
  return 0;
}
EOF
for t in linux arm64; do
  rm -f "$TMP/n"
  ( cd "$ROOT" && timeout 240 "$LYXC" --std-path="$ROOT" --target=$t "$TMP/tippfehler.lyx" -o "$TMP/n" ) >"$TMP/n.log" 2>&1; rc=$?
  if [ "$rc" != "0" ] && grep -q "unbekannter Enum-Member 'cyann'" "$TMP/n.log"; then ok "(1) crt_color.cyann [$t]: laut abgewiesen"
  else nok "(1) crt_color.cyann [$t]: rc=$rc, keine Meldung"; fi
done

# (2) Die Werte der Linux-ABI: 0, 1, 2, 64, 512, 1024; PROT_NONE = 0.
cat > "$TMP/ocon.lyx" <<'EOF'
fn main(): int64 {
  PrintInt(O_RDONLY); Print(" ");
  PrintInt(O_WRONLY); Print(" ");
  PrintInt(O_RDWR); Print(" ");
  PrintInt(O_CREAT); Print(" ");
  PrintInt(O_TRUNC); Print(" ");
  PrintInt(O_APPEND); Print(" ");
  PrintInt(PROT_NONE); Print(" ");
  PrintInt(O_WRONLY | O_CREAT | O_TRUNC); Print("\n");
  return 0;
}
EOF
pruefe "(2) O_*/PROT_NONE ohne Deklaration" "$TMP/ocon.lyx" "0 1 2 64 512 1024 0 577|"

# Die Unit, die dieselben Namen selbst deklariert (std/fs.lyx), muss weiter
# uebersetzen — eingebaute Konstante und eigene Deklaration duerfen sich nicht
# beissen.
cat > "$TMP/fs.lyx" <<'EOF'
import std.fs;
fn main(): int64 {
  PrintInt(O_CREAT + O_APPEND); Print("\n");
  return 0;
}
EOF
pruefe "(2) neben std.fs" "$TMP/fs.lyx" "1088|"

# (3) Methode, die ihren Parametern zuweist und sie danach liest; danach ein
# Feldzugriff ueber self. Ohne Versatz ueberschrieb `a := ...` self.
cat > "$TMP/param.lyx" <<'EOF'
type K = class {
  v: int64;
  fn Setze(a: int64, b: int64): int64 {
    a := a + 100;
    b := b * 2;
    return a * 1000 + b + self.v;
  }
  fn Zaehle(n: int64): int64 {
    var s: int64 := 0;
    while (n > 0) { s := s + n; n := n - 1; }
    return s + self.v;
  }
};
fn main(): int64 {
  var k: K := new K();
  k.v := 7;
  PrintInt(k.Setze(3, 4)); Print(" ");
  PrintInt(k.Zaehle(4)); Print(" ");
  PrintInt(k.v); Print("\n");
  return 0;
}
EOF
pruefe "(3) Methode schreibt Parameter" "$TMP/param.lyx" "103015 17 7|"

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
