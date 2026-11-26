#!/usr/bin/env bash
# tests/simd_asm_2521_test.sh — Stufe 1 von #2521: Vektorbefehle im asm-Block.
#
# WAS HIER GEPINNT WIRD, und der dritte Punkt ist der wichtigste:
#
#   1. Ein handgeschriebener Kern RECHNET -- gesaettigte Byte-Addition, gegen
#      die skalare Fassung bitgleich, ueber beide Saettigungsraender.
#   2. Ein Mnemonic AUSSERHALB des Zielprofils wird LAUT abgewiesen, nicht
#      still als NOP verworfen (Abnahmepunkt 4 des Issues).
#   3. KEIN Vektorregister bleibt ueber den Blockrand hinweg beansprucht
#      (Abnahmepunkt 5): eine Funktion mit asm-Block mitten in f64-Rechnung
#      liefert weiter richtige Werte.
#
# Punkt 3 ist der Grund, warum Stufe 1 OHNE clobber-Abschnitt sicher ist, und
# er ist GEMESSEN, nicht vermutet: der Codegen haelt keine f64-Werte in xmm
# ueber Anweisungsgrenzen. Sollte eine kuenftige Optimierung das aendern --
# etwa f64-Locals in xmm halten --, wird DIESER Test rot, statt dass Programme
# mit asm-Bloecken still falsch rechnen. Ohne ihn waere die Mnemonic-Liste
# eine Zeitbombe.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$ROOT/tests/lib/lyxc_guard.sh"; [ -f "$_g" ] && . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ulimit -c 0 2>/dev/null
ok() { PASS=$((PASS+1)); echo "PASS $1"; }
no() { FAIL=$((FAIL+1)); echo "FAIL $1: $2"; }

# --- 1: der Kern rechnet ---------------------------------------------------
cat > "$TMP/k.lyx" <<'LYX'
import std.io;
import std.alloc;

fn sattAdd16(a: int64, b: int64, ziel: int64) {
  asm { "movdqu xmm0, [rdi]" "movdqu xmm1, [rsi]" "paddusb xmm0, xmm1" "movdqu [rdx], xmm0"
        : : in("rdi", a) in("rsi", b) in("rdx", ziel) }
}
fn sattSub16(a: int64, b: int64, ziel: int64) {
  asm { "movdqu xmm0, [rdi]" "movdqu xmm1, [rsi]" "psubusb xmm0, xmm1" "movdqu [rdx], xmm0"
        : : in("rdi", a) in("rsi", b) in("rdx", ziel) }
}
fn minimum16(a: int64, b: int64, ziel: int64) {
  asm { "movdqu xmm0, [rdi]" "movdqu xmm1, [rsi]" "pminub xmm0, xmm1" "movdqu [rdx], xmm0"
        : : in("rdi", a) in("rsi", b) in("rdx", ziel) }
}

fn main(): int64 {
  var a: int64 := alloc(16); var b: int64 := alloc(16); var z: int64 := alloc(16);
  var i: int64 := 0;
  while (i < 16) { poke8(a + i, (i * 16) & 255); poke8(b + i, 200); i += 1; }

  // Addition: saettigt oben, sobald a[i] + 200 > 255.
  sattAdd16(a, b, z);
  var g1: int64 := 1;
  i := 0;
  while (i < 16) {
    var s: int64 := (peek8(a + i) & 255) + 200;
    if (s > 255) { s := 255; }
    if ((peek8(z + i) & 255) != s) { g1 := 0; }
    i += 1;
  }
  Print("add-bitgleich "); PrintInt(g1); PrintLn("");

  // Subtraktion: saettigt UNTEN auf 0 -- die andere Richtung.
  sattSub16(a, b, z);
  var g2: int64 := 1;
  i := 0;
  while (i < 16) {
    var d: int64 := (peek8(a + i) & 255) - 200;
    if (d < 0) { d := 0; }
    if ((peek8(z + i) & 255) != d) { g2 := 0; }
    i += 1;
  }
  Print("sub-bitgleich "); PrintInt(g2); PrintLn("");

  minimum16(a, b, z);
  var g3: int64 := 1;
  i := 0;
  while (i < 16) {
    var m: int64 := peek8(a + i) & 255;
    if ((peek8(b + i) & 255) < m) { m := peek8(b + i) & 255; }
    if ((peek8(z + i) & 255) != m) { g3 := 0; }
    i += 1;
  }
  Print("min-bitgleich "); PrintInt(g3); PrintLn("");
  return 0;
}
LYX
if ( cd "$ROOT" && timeout 600 "$LYXC" --std-path="$ROOT" "$TMP/k.lyx" -o "$TMP/k" ) >"$TMP/k.log" 2>&1 \
   && [ -x "$TMP/k" ]; then
  ok "Kern uebersetzt"
  AUS="$( ulimit -v 4000000; timeout 120 "$TMP/k" 2>&1 )"
  for teil in add sub min; do
    if echo "$AUS" | grep -q "$teil-bitgleich 1"; then ok "$teil: bitgleich zur skalaren Fassung"
    else no "$teil weicht ab" "$(echo "$AUS" | tr '\n' ' ')"; fi
  done
else
  no "Kern uebersetzt nicht" "$(grep -m1 -i error "$TMP/k.log")"
fi

# --- 2: ausserhalb des Profils wird LAUT abgewiesen ------------------------
# pshufb ist SSSE3 und verlangt die Stufe sse4. Mit --target-cpu=baseline muss
# die Uebersetzung scheitern UND die Gruppe nennen.
cat > "$TMP/p.lyx" <<'LYX'
import std.io;
fn f(a: int64) { asm { "pshufb xmm0, xmm1" : : in("rdi", a) } }
fn main(): int64 { f(0); PrintLn(1); return 0; }
LYX
if ( cd "$ROOT" && timeout 600 "$LYXC" --std-path="$ROOT" --target-cpu=baseline "$TMP/p.lyx" -o "$TMP/p" ) >"$TMP/p.log" 2>&1; then
  no "pshufb unter baseline" "uebersetzt, statt laut abzuweisen -- stiller Durchfall"
else
  if grep -qiE 'sse4|target-cpu|@cpu' "$TMP/p.log"; then
    ok "pshufb unter baseline: laut abgewiesen, mit Nennung der Stufe"
  else
    no "pshufb unter baseline: abgewiesen, aber ohne Grund" "$(tail -2 "$TMP/p.log" | tr '\n' ' ')"
  fi
fi
# Gegenrichtung: mit der Zusage muss es gehen. Ohne sie waere der Test auch von
# einer Fassung erfuellt, die pshufb IMMER abweist.
if ( cd "$ROOT" && timeout 600 "$LYXC" --std-path="$ROOT" --target-cpu=sse4 "$TMP/p.lyx" -o "$TMP/p2" ) >/dev/null 2>&1 \
   && [ -x "$TMP/p2" ]; then
  ok "pshufb mit Zusage sse4: uebersetzt"
else
  no "pshufb mit Zusage sse4" "wird auch mit Zusage abgewiesen"
fi

# --- 3: kein Vektorregister ueber den Blockrand (Abnahmepunkt 5) ----------
cat > "$TMP/f.lyx" <<'LYX'
import std.io;
fn rechne(a: f64, b: f64): f64 {
  var s: f64 := a + b;
  var p: f64 := a * b;
  asm { "pxor xmm0, xmm0" }
  var q: f64 := s + p;
  asm { "pxor xmm0, xmm1" }
  var r: f64 := q * 2.0;
  asm { "pxor xmm0, xmm0" }
  return r + s;
}
fn main(): int64 {
  // ((3+4) + 3*4) * 2 + (3+4) = 38 + 7 = 45
  PrintLn(FloatToStr(rechne(3.0, 4.0)));
  return 0;
}
LYX
if ( cd "$ROOT" && timeout 600 "$LYXC" --std-path="$ROOT" "$TMP/f.lyx" -o "$TMP/f" ) >"$TMP/f.log" 2>&1 \
   && [ -x "$TMP/f" ]; then
  W="$( ulimit -v 4000000; timeout 120 "$TMP/f" 2>&1 | tr -d ' ' )"
  case "$W" in
    45*) ok "f64-Rechnung ueberlebt drei xmm-zerstoerende asm-Bloecke (45)" ;;
    *)   no "f64-Rechnung durch asm-Block verfaelscht" "'$W' statt 45 -- xmm wird jetzt ueber Anweisungsgrenzen gehalten, die Mnemonic-Liste braucht einen clobber-Abschnitt" ;;
  esac
else
  no "f64-Probe uebersetzt nicht" "$(grep -m1 -i error "$TMP/f.log")"
fi

echo ""
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
