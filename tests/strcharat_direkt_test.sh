#!/usr/bin/env bash
# tests/strcharat_direkt_test.sh — StrCharAt als ein Befehl statt Aufruf (#2228).
#
# Bis 1.2.19H war jedes StrCharAt ein `call` auf den Helfer bei
# CG_H_STRCHARAT, der aus genau `movzx rax, byte [rdi+rsi]; ret` besteht. In
# einer Zeichenschleife kostete jedes Byte call/ret; im Selbstbau standen
# 2275 solche Aufrufe, direkt erzeugt wurde er 3,6 % schneller.
#
# Geprueft wird der WEG am Erzeugnis, in beiden Richtungen: drei zusaetzliche
# StrCharAt duerfen keinen `call` mehr kosten, muessen aber drei
# zusaetzliche Ladebefehle bringen (sonst haette der Compiler sie
# weggelassen). Dazu die Werte: das Ergebnis ist vorzeichenlos (0..255), ein
# movsx statt movzx fiele bei Bytes ab 0x80 auf.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

printf '%s\n' 'import std.io;
import std.alloc;
fn main(): int64 {
  var b: int64 := alloc(8);
  poke8(b, 65); poke8(b + 1, 128); poke8(b + 2, 255); poke8(b + 3, 0);
  var s: pchar := b as pchar;
  PrintLn(StrCharAt(s, 0));
  PrintLn(StrCharAt(s, 1));
  PrintLn(StrCharAt(s, 2));
  PrintLn(StrCharAt("Lyx", 2));
  var i: int64 := 1;
  PrintLn(StrCharAt("abc", i + 1) - StrCharAt("abc", i - 1));
  return 0;
}' > "$TMP/w.lyx"
if (cd "$ROOT" && "$LYXC" --std-path="$ROOT" "$TMP/w.lyx" -o "$TMP/w" >"$TMP/w.log" 2>&1); then
  got="$( ulimit -c 0; cd "$TMP" && timeout 20 "$TMP/w" 2>&1 | tr '\n' ' ')"; got="${got% }"
  if [ "$got" = "65 128 255 120 2" ]; then ok "Werte, vorzeichenlos ($got)"
  else no "Werte" "'$got' erwartet '65 128 255 120 2'"; fi
else no "Werte" "uebersetzt nicht"; fi

# Erzeugnis: --emit=obj, denn das fertige Programm traegt keine Section-Header
# und objdump zaehlte dort still null (siehe tests/einbettung_test.sh).
zaehle() { # quelle -> "calls ladebefehle"
  printf '%s\n' "$1" > "$TMP/z.lyx"
  (cd "$ROOT" && "$LYXC" --std-path="$ROOT" --emit=obj "$TMP/z.lyx" -o "$TMP/z.o" >/dev/null 2>&1) || { echo "X X"; return; }
  local d; d="$(objdump -d -z --no-show-raw-insn "$TMP/z.o" 2>/dev/null)"
  echo "$(grep -c 'call' <<<"$d") $(grep -c 'movzbq (%rdi,%rsi,1),%rax' <<<"$d")"
}
A='import std.io;
fn main(): int64 {
  var s: pchar := "Lyx";
  var x: int64 := 0;
  PrintLn(x);
  return 0;
}'
B='import std.io;
fn main(): int64 {
  var s: pchar := "Lyx";
  var x: int64 := StrCharAt(s, 0) + StrCharAt(s, 1) + StrCharAt(s, 2);
  PrintLn(x);
  return 0;
}'
read -r ca la <<<"$(zaehle "$A")"; read -r cb lb <<<"$(zaehle "$B")"
if [ "$ca" = X ] || [ "$cb" = X ]; then no "Erzeugnis" "uebersetzt nicht"
else
  if [ "$cb" -eq "$ca" ]; then ok "kein call fuer StrCharAt ($ca vs $cb)"
  else no "kein call fuer StrCharAt" "$ca calls ohne, $cb mit drei StrCharAt"; fi
  if [ $((lb - la)) -eq 3 ]; then ok "drei Ladebefehle mehr ($la -> $lb)"
  else no "drei Ladebefehle mehr" "$la -> $lb"; fi
fi

echo "strcharat_direkt: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
