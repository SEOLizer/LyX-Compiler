#!/usr/bin/env bash
# tests/builtin_verdeckung_import_test.sh — #2103: eine Funktion einer
# IMPORTIERTEN Unit mit Builtin-Namen verdeckt den Builtin nicht — auf allen
# Zielen dieselbe Regel (ebnf.md §15.4: nur die eigene Unit verdeckt).
#
# Bis 1.2.14C entschied auf dem IR-Weg die Reihenfolge in lowerCall: Builtins
# vor der Funktionssuche gewannen (sqrt), die dahinter verloren (peek8,
# StrLen). arm64/riscv lieferten 44 und 97, x86 7 und 2.
#
# Gemessen wird der WERT auf x86_64, arm64 und riscv. Gegenseite: dieselben
# Funktionen in der EIGENEN Unit verdecken den Builtin weiterhin (#2082), und
# eine importierte Funktion OHNE Builtin-Namen wird weiter gerufen.
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

mkdir -p "$TMP/bib"
cat > "$TMP/bib/v.lyx" <<'EOF'
unit bib.v;
pub fn peek8(a: int64): int64 { return 44; }
pub fn sqrt(x: f64): f64 { return 5.0; }
pub fn StrLen(p: pchar): int64 { return 97; }
pub fn Eigen(a: int64): int64 { return a * 3; }
EOF

pruefe() {  # name, datei, soll
  local t r
  for t in linux arm64 riscv; do
    rm -f "$TMP/m"
    if ! ( cd "$TMP" && timeout 240 "$LYXC" --std-path="$ROOT" -I "$TMP" --target=$t "$2" -o "$TMP/m" ) >"$TMP/bl.log" 2>&1; then
      nok "$1 [$t]: uebersetzt nicht ($(grep -m1 -iE 'error' "$TMP/bl.log"))"; continue
    fi
    case $t in
      linux) r="$(timeout 30 "$TMP/m" | tr '\n' ' ')" ;;
      arm64) r="$(timeout 30 "$QEMU_ARM64" "$TMP/m" | tr '\n' ' ')" ;;
      riscv) r="$(timeout 30 "$QEMU_RISCV64" "$TMP/m" | tr '\n' ' ')" ;;
    esac
    if [ "$r" = "$3" ]; then ok "$1 [$t]: [$r]"; else nok "$1 [$t]: [$r] statt [$3]"; fi
  done
}

# Der Fall aus dem Issue, woertlich (plus Eigen fuer die Gegenseite).
cat > "$TMP/m.lyx" <<'EOF'
unit main;
import std.io;
import std.alloc;
import bib.v;
fn main(): int64 { var b: int64 := alloc(8); poke8(b, 7); var r: f64 := sqrt(4.0); PrintLn(IntToStr(peek8(b))); PrintLn(IntToStr(r as int64)); PrintLn(IntToStr(StrLen("ab"))); PrintLn(IntToStr(Eigen(5))); return 0; }
EOF
pruefe "importierte Unit: Builtin gewinnt" "$TMP/m.lyx" "7 2 2 15 "

# Gegenseite: dieselben Namen in der EIGENEN Unit verdecken den Builtin.
cat > "$TMP/e.lyx" <<'EOF'
unit main;
import std.io;
import std.alloc;
fn peek8(a: int64): int64 { return 44; }
fn StrLen(p: pchar): int64 { return 97; }
fn main(): int64 { var b: int64 := alloc(8); poke8(b, 7); PrintLn(IntToStr(peek8(b))); PrintLn(IntToStr(StrLen("ab"))); return 0; }
EOF
pruefe "eigene Unit: Funktion verdeckt" "$TMP/e.lyx" "44 97 "

# StrTrim (ID 407): bisher nur auf arm64/riscv baubar, weil std/string die
# Fassung lieferte. Jetzt als Builtin auf allen Zielen — derselbe Wert.
cat > "$TMP/t.lyx" <<'EOF'
import std.io;
import std.alloc;
fn kopie(s: pchar): pchar {
  var n: int64 := StrLen(s);
  var b: int64 := alloc(n + 1);
  var i: int64 := 0;
  while (i <= n) { poke8(b + i, peek8((s as int64) + i)); i := i + 1; }
  return b as pchar;
}
fn zeig(s: pchar) { Print("["); Print(s); Print("] "); PrintLn(IntToStr(StrLen(s))); }
fn main(): int64 {
  zeig(StrTrim(kopie("  ab c \t\r\n")));
  zeig(StrTrim(kopie("xyz")));
  zeig(StrTrim(kopie(" \t ")));
  zeig(StrTrim("  literal"));
  return 0;
}
EOF
pruefe "StrTrim-Builtin" "$TMP/t.lyx" "[ab c] 4 [xyz] 3 [] 0 [literal] 7 "

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
