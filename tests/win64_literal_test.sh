#!/usr/bin/env bash
# tests/win64_literal_test.sh — #2154: Print("ab\0cd") auf win64.
#
# Seit #2141 gibt Print mit einem Literal dessen bekannte Laenge aus — auf
# dem SysV-Weg per write-Syscall. Im PE-Weg blieb es beim Helfer
# _lyx_print_str, der am ersten Nullbyte endet: `Print("ab\0cd")` gab "ab".
# Jetzt ruft der Codegen win_print_strn (win_x86.lyx, WriteFile mit Laenge)
# — ohne rohen Syscall (tests/win64_syscalls_test.sh zaehlt das).
#
# Gemessen unter wine (die Bytes der Ausgabe, NUL eingeschlossen); ohne wine
# am Erzeugnis: `mov esi, <Laenge>` direkt vor dem Aufruf.
set -uo pipefail
ulimit -c 0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

cat > "$TMP/w.lyx" <<'LYX'
fn main(): int64 {
  Print("ab\0cd"); Print("|");
  PrintStr("ab\0cd"); Print("|");
  Print("x", 5, "y\0z");
  PrintLn("");
  return 0;
}
LYX
if ! ( cd "$ROOT" && timeout 240 "$LYXC" --std-path="$ROOT" --target=win64 --format=pe "$TMP/w.lyx" -o "$TMP/w.exe" ) >"$TMP/w.log" 2>&1; then
  nok "uebersetzt nicht: $(grep -m1 -i error "$TMP/w.log")"
else
  ok "uebersetzt"
  # Erzeugnis: mov esi, 5 (BE 05 00 00 00) unmittelbar vor einem call (E8)
  if python3 -c "import sys; d=open(sys.argv[1],'rb').read(); sys.exit(0 if bytes([0xBE,5,0,0,0,0xE8]) in d else 1)" "$TMP/w.exe"; then
    ok "Erzeugnis: Literallaenge 5 geht an den Helfer"
  else nok "Erzeugnis: kein 'mov esi, 5; call'"; fi
  if command -v wine >/dev/null 2>&1; then
    aus="$(cd "$TMP" && WINEDEBUG=-all timeout 120 wine w.exe 2>/dev/null | od -An -c | tr -s ' ' | tr -d '\n')"
    soll=" a b \\0 c d | a b | x 5 y \\0 z \\n"
    if [ "$aus" = "$soll" ]; then ok "wine: [$aus]"; else nok "wine: [$aus] statt [$soll]"; fi
  else
    echo "SKIP wine nicht vorhanden — nur das Erzeugnis geprueft"
  fi
fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
