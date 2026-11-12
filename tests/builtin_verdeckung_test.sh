#!/usr/bin/env bash
# tests/builtin_verdeckung_test.sh — #2082: eine Funktion der EIGENEN Unit
# verdeckt den gleichnamigen Builtin, auf allen drei Zielen (ebnf.md §15.4).
#
# Bis 1.2.13D rechneten die Ziele verschieden: `fn StrLen(p: pchar): int64
# { return 99; }` ergab auf x86 3 (Builtin), auf arm64/riscv 99. Umgekehrt
# verlor `fn sqrt` der eigenen Unit auch auf arm64/riscv gegen den Builtin,
# weil der IR-Weg `sqrt`, `Print*`, `Inspect`, `profile_*` vor der Suche nach
# der Nutzerfunktion abfing.
#
# Jede eigene Fassung liefert einen Wert, den der Builtin nie liefern wuerde.
# Gegenseite: ohne Definition bleibt der Builtin, und eine IMPORTIERTE
# `pub fn Print(s: pchar)` (std.io) verdeckt `Print(42)` nicht.
set -uo pipefail
ulimit -c 0   # ein Absturz unter qemu legt sonst eine .core-Datei ins Repo
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
. "$(dirname "$0")/lib/qemu.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

alle_ziele() {  # $1 Beschreibung, $2 Datei, $3 Soll mit |
  local was="$1" src="$2" erw="$3"
  for ziel in x86_64 arm64 riscv; do
    local bin="$TMP/b_$ziel" pre=""
    case "$ziel" in
      arm64) pre="$QEMU_ARM64" ;;
      riscv) pre="$QEMU_RISCV64" ;;
    esac
    if ! ( cd "$ROOT" && timeout 240 "$LYXC" --std-path="$ROOT" --target="$ziel" "$src" -o "$bin" ) >"$TMP/bl.log" 2>&1; then
      nok "$was [$ziel]: uebersetzt nicht ($(grep -m1 -iE '^lyxc:|error' "$TMP/bl.log"))"; continue
    fi
    if [ "$ziel" != "x86_64" ] && [ -z "$pre" ]; then nok "$was [$ziel]: qemu fehlt — NICHT gemessen"; continue; fi
    local ist; ist="$( (timeout 60 $pre "$bin" 2>&1) | tr '\n' '|')"
    if [ "$ist" = "$erw" ]; then ok "$was [$ziel] = $erw"
    else nok "$was [$ziel]: [$ist] statt [$erw]"; fi
  done
}

echo "--- eigene Definition verdeckt den Builtin ---"
cat > "$TMP/eigen.lyx" <<'EOF'
unit main;
import std.io;
fn StrLen(p: pchar): int64 { return 99; }
fn sqrt(x: f64): f64 { return 5.0; }
fn peek8(a: int64): int64 { return 44; }
fn PrintInt(n: int64): int64 { return n + 1; }
fn main(): int64 {
  var r: f64 := sqrt(4.0);
  PrintLn(IntToStr(StrLen("abc")));
  PrintLn(IntToStr(r as int64));
  PrintLn(IntToStr(peek8(0)));
  PrintLn(IntToStr(PrintInt(41)));
  PrintLn(IntToStr(StrLength("abc")));
  return 0;
}
// Definiert NACH dem Aufruf: die Vorwaertsreferenz gilt ebenso.
fn StrLength(p: pchar): int64 { return 77; }
EOF
alle_ziele "StrLen 99, sqrt 5, peek8 44, PrintInt 42, StrLength (nach main) 77" "$TMP/eigen.lyx" "99|5|44|42|77|"

echo
echo "--- Gegenseite: ohne Definition der Builtin ---"
cat > "$TMP/ohne.lyx" <<'EOF'
unit main;
import std.io;
fn main(): int64 {
  var r: f64 := sqrt(16.0);
  PrintLn(IntToStr(StrLen("abcd")));
  PrintLn(IntToStr(r as int64));
  Print(42); PrintLn("");
  return 0;
}
EOF
# Print(42) mit `import std.io`: std/io.lyx hat `pub fn Print(s: pchar)` —
# eine IMPORTIERTE Funktion verdeckt den Builtin nicht.
alle_ziele "StrLen 4, sqrt 4, Print(42) trotz import std.io" "$TMP/ohne.lyx" "4|4|42|"

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
