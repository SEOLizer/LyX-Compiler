#!/usr/bin/env bash
# tests/strconcat_ir_test.sh — #2028: StrConcat (Builtin-ID 7) auf arm64/riscv.
#
# Zwei Befunde, nicht einer:
#
#   1. Der LINUX-Zweig beider Backends kannte id 7 gar nicht (der Windows-Zweig
#      von arm64 schon, ueber wab_strconcat). Jedes Programm mit
#      Zeichenkettenverkettung war damit fuer diese Ziele unbaubar — nach
#      PrintLn das meistbenutzte Builtin.
#
#   2. VERSCHACHTELTE Aufrufe waren falsch, und zwar auf ALLEN IR-Zielen
#      einschliesslich lyxos: ir_lower legte die Argumente in die festen Slots
#      0/1, der innere Aufruf ueberschrieb damit die des aeusseren.
#      `StrConcat(StrConcat("a","b"), StrConcat("c","d"))` ergab "ccd" statt
#      "abcd" — ohne Meldung. Seit #2028 bekommt jeder Aufruf seinen eigenen
#      hohen Block (dieselbe Loesung wie #839 und #1734).
#
# GEMESSEN WIRD DER TEXT unter qemu, gegen x86_64 als Referenz. Ein Test auf
# "uebersetzt durch" waere fuer Punkt 2 gruen gewesen — das Programm lief ja,
# es log nur.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

QEMU_ARM=""; QEMU_RV=""
command -v qemu-aarch64-static >/dev/null 2>&1 && QEMU_ARM="qemu-aarch64-static"
command -v qemu-riscv64-static >/dev/null 2>&1 && QEMU_RV="qemu-riscv64-static"

lauf() {
  local ziel="$1"
  local src="$2"
  local out="$3"
  local bin="$TMP/b_$ziel"
  ( cd "$ROOT" && timeout 180 "$LYXC" --target="$ziel" "$src" -o "$bin" ) >"$TMP/build_$ziel.log" 2>&1 || return 1
  case "$ziel" in
    x86_64) timeout 60 "$bin" >"$out" 2>&1 ;;
    arm64)  [ -n "$QEMU_ARM" ] || return 2; timeout 60 $QEMU_ARM "$bin" >"$out" 2>&1 ;;
    riscv)  [ -n "$QEMU_RV" ]  || return 2; timeout 60 $QEMU_RV  "$bin" >"$out" 2>&1 ;;
  esac
  return 0
}

cat > "$TMP/sc.lyx" <<'EOF'
unit main;
import std.io;
import std.string;
fn main(): int64 {
  PrintLn(StrConcat("Hallo, ", "Welt!"));
  PrintLn(StrConcat("", "nur-b"));
  PrintLn(StrConcat("nur-a", ""));
  PrintLn(StrConcat("", ""));
  PrintLn(IntToStr(StrLen(StrConcat("abc", "de"))));
  PrintLn(StrConcat(StrConcat("a", "b"), StrConcat("c", "d")));
  var s: pchar := "x";
  var i: int64 := 0;
  while (i < 200) { s := StrConcat(s, "y"); i := i + 1; }
  PrintLn(IntToStr(StrLen(s)));
  PrintLn(StrConcat("laenger-als-sechzehn-zeichen-sicher", "-und-noch-mehr-dahinter"));
  return 0;
}
EOF

echo "--- StrConcat auf den IR-Zielen (#2028) ---"

if ! lauf x86_64 "$TMP/sc.lyx" "$TMP/sc.x86"; then
  nok "das Pruefprogramm uebersetzt nicht einmal fuer x86_64"
  echo; echo "Ergebnis: $PASS PASS, $FAIL FAIL"; exit 1
fi

# Die Referenz muss stimmen, sonst vergleicht der Test zwei Fehler. Die
# entscheidenden Zeilen einzeln nachrechnen:
#   Zeile 5 = StrLen("abcde")            → 5
#   Zeile 6 = verschachtelte Verkettung  → abcd
#   Zeile 7 = "x" + 200 mal "y"          → 201
if [ "$(sed -n '5p' "$TMP/sc.x86")" = "5" ] \
   && [ "$(sed -n '6p' "$TMP/sc.x86")" = "abcd" ] \
   && [ "$(sed -n '7p' "$TMP/sc.x86")" = "201" ]; then
  ok "x86_64 liefert die nachgerechneten Werte (Referenz belastbar)"
else
  nok "x86_64 unerwartet: [$(tr '\n' '|' < "$TMP/sc.x86")]"
fi

for ziel in arm64 riscv; do
  lauf "$ziel" "$TMP/sc.lyx" "$TMP/sc.$ziel"; rc=$?
  if [ "$rc" = 2 ]; then
    nok "$ziel: qemu fehlt — die Wirkung wurde NICHT gemessen"
    continue
  fi
  if [ "$rc" != 0 ]; then
    nok "$ziel: uebersetzt nicht ($(grep -m1 -E 'error|Builtin-ID' "$TMP/build_$ziel.log"))"
    continue
  fi
  if diff -q "$TMP/sc.x86" "$TMP/sc.$ziel" >/dev/null; then
    ok "$ziel: alle acht Faelle zeichengleich mit x86_64"
  else
    nok "$ziel: weicht ab: [$(tr '\n' '|' < "$TMP/sc.$ziel")]"
    diff "$TMP/sc.x86" "$TMP/sc.$ziel" | head -6
  fi
  # Die Verschachtelung EINZELN benennen: sie war der stille Fehler, und in
  # einem Sammelvergleich ginge sie zwischen sieben anderen Zeilen unter.
  if [ "$(sed -n '6p' "$TMP/sc.$ziel")" = "abcd" ]; then
    ok "$ziel: verschachtelte Verkettung ergibt abcd (war ccd)"
  else
    nok "$ziel: verschachtelte Verkettung ergibt '$(sed -n '6p' "$TMP/sc.$ziel")' statt abcd"
  fi
done

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
