#!/usr/bin/env bash
# tests/ir_datei_builtins_test.sh — #2104: close, rename, unlink, mkdir und
# exit auf allen drei Zielen.
#
# ir_lower vergibt dafuer die IDs 221/224/225/226/227 an JEDES IR-Ziel; die
# Linux-Zweige von arm64 und riscv kannten keine davon. `exit(3)` war fuer
# beide Ziele unuebersetzbar ("Builtin-ID 227 wird nicht behandelt"). Der
# Waechter tests/backend_abdeckung_test.sh vergleicht nur arm64 gegen riscv —
# fehlt eine ID auf BEIDEN Seiten, sieht er nichts.
#
# Gemessen wird die WIRKUNG im Dateisystem und der Rueckgabewert, auch der
# Fehlerfall (zweites unlink: -2 = ENOENT) und der Modus des Verzeichnisses:
# bis hierher reichte der IR-Weg den Modus von mkdir gar nicht weiter.
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

cat > "$TMP/f.lyx" <<'EOF'
unit main;
import std.io;
fn main(): int64 {
  var fd: int64 := open("t1.txt"c, 65, 420);
  write(fd, "hallo"c, 5);
  PrintLn(IntToStr(close(fd)));
  PrintLn(IntToStr(rename("t1.txt"c, "t2.txt"c)));
  PrintLn(IntToStr(mkdir("dd"c, 448)));
  PrintLn(IntToStr(unlink("t2.txt"c)));
  PrintLn(IntToStr(unlink("t2.txt"c)));
  exit(7);
  return 0;
}
EOF
for ziel in x86_64 arm64 riscv; do
  pre=""
  case "$ziel" in arm64) pre="$QEMU_ARM64" ;; riscv) pre="$QEMU_RISCV64" ;; esac
  if ! ( cd "$ROOT" && timeout 240 "$LYXC" --std-path="$ROOT" --target="$ziel" "$TMP/f.lyx" -o "$TMP/f_$ziel" ) >"$TMP/bl.log" 2>&1; then
    nok "[$ziel] uebersetzt nicht ($(grep -m1 -iE '^lyxc:|error' "$TMP/bl.log"))"; continue
  fi
  if [ "$ziel" != "x86_64" ] && [ -z "$pre" ]; then nok "[$ziel] qemu fehlt — NICHT gemessen"; continue; fi
  w="$TMP/w_$ziel"; mkdir -p "$w"
  aus="$( (cd "$w" && timeout 60 $pre "$TMP/f_$ziel" 2>&1) | tr '\n' '|')"; rc=$?
  rc="$( (cd "$w" && rm -rf dd && timeout 60 $pre "$TMP/f_$ziel" >/dev/null 2>&1); echo $? )"
  modus="$(stat -c %a "$w/dd" 2>/dev/null)"
  rest="$(ls "$w" | grep -c 't[12].txt')"
  if [ "$aus" = "0|0|0|0|-2|" ]; then ok "[$ziel] close/rename/mkdir/unlink = 0, zweites unlink = -2"
  else nok "[$ziel] Ausgabe [$aus] statt [0|0|0|0|-2|]"; fi
  if [ "$rc" = "7" ]; then ok "[$ziel] exit(7) beendet mit 7"; else nok "[$ziel] Exit $rc statt 7"; fi
  if [ "$modus" = "700" ]; then ok "[$ziel] mkdir legt dd mit Modus 700 an"; else nok "[$ziel] Modus von dd: '$modus' statt 700"; fi
  if [ "$rest" = "0" ]; then ok "[$ziel] t1.txt umbenannt und t2.txt geloescht"; else nok "[$ziel] $rest Datei(en) uebrig"; fi
done

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
