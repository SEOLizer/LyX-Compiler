#!/usr/bin/env bash
# tests/ausgabepfad_ziele_2179_test.sh — nicht schreibbarer Ausgabepfad auf JEDEM Ziel (#2179).
#
# tests/schreibfehler_test.sh (#1682) prueft den Fall fuer das Standardziel.
# Auf arm64 und android-arm64 endete lyxc bei einem nicht schreibbaren Pfad
# trotzdem mit rc 0 und ohne Datei: die arm64-ELF-Schreiber in src/lyxc.lyx
# werteten FileWriteAll mit `result != 0` aus — ein Fehler ist NEGATIV und
# galt damit als Erfolg. Sie laufen jetzt ueber EmitWriteFile
# (src/emit_write.lyx), dieselbe Stelle wie alle anderen Ziele.
#
# Beide Richtungen je Ziel: der gesperrte Pfad muss mit Status != 0 und einer
# Meldung auf stderr enden, der gueltige mit 0 und einer Datei. Nur die erste
# Haelfte waere auch von einem Compiler erfuellt, der nie schreibt.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

printf 'fn main(): int64 { return 0; }\n' > "$TMP/q.lyx"
sperr="$TMP/sperre"; mkdir -p "$sperr"; chmod 555 "$sperr"
if [ -w "$sperr" ]; then echo "SKIP: Verzeichnis bleibt schreibbar (root?) — nicht pruefbar"; exit 0; fi

for t in x86 arm64 android-arm64 riscv lyxos win64 macosx64 macos-arm64 windows-arm64 esp32 arm-cm4 "x86 --shared" "arm64 --shared"; do
  set -- $t; ziel="$1"; zus="${2:-}"
  opt=""; [ "$ziel" != x86 ] && opt="--target=$ziel"
  name="$ziel${zus:+ $zus}"
  (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" $opt $zus "$TMP/q.lyx" -o "$sperr/raus" >"$TMP/a.out" 2>"$TMP/a.err"); rc=$?
  if [ "$rc" -eq 0 ]; then no "$name gesperrt" "Status 0"; 
  elif ! grep -qiE "Ausgabedatei|write|Cannot" "$TMP/a.err"; then no "$name gesperrt" "Status $rc, aber keine Meldung auf stderr"
  else ok "$name: gesperrter Pfad -> Status $rc mit Meldung"; fi
  rm -f "$TMP/gut"
  (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" $opt $zus "$TMP/q.lyx" -o "$TMP/gut" >/dev/null 2>"$TMP/b.err"); rc=$?
  if [ "$rc" -eq 0 ] && [ -s "$TMP/gut" ]; then ok "$name: gueltiger Pfad -> Datei"
  else no "$name gueltig" "Status $rc, Datei $( [ -s "$TMP/gut" ] && echo da || echo fehlt )"; fi
done

echo "ausgabepfad_ziele_2179: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
