#!/usr/bin/env bash
# tests/mixed_arith_trycatch_test.sh — #1212, #1281 und #1170.
#
# #1212: Gemischte int/float-Arithmetik rechnete auf Bitmustern. Ist eine Seite
# f64, wurde die f64-Operation emittiert — der ganzzahlige Operand ging dabei
# als Bitmuster eines double in die Rechnung. Und die beiden Schnellpfade fuer
# konstante Operanden emittierten ueberhaupt immer die GANZZAHL-Operation.
# Gemessen: 10 - 2.5 = -1.75, 2.5 + 10 = 2.5, 3 * 1.5 = -0.75, 7.0 / 2 = 0.0.
#
# #1281: `lowerTryStmt` in ir_lower senkte try/catch als reine Aneinanderreihung
# ab — die Stellen fuer push_handler, Spruenge und Label waren Kommentare ohne
# Code. Der catch-Rumpf lief IMMER. Betroffen sind alle Ziele ueber ir_lower
# (lyxos, arm64, riscv, arm-cm4, xtensa); der x86-Pfad ist seit #1147 in
# Ordnung. Bis die Handler-Absenkung steht, wird gemeldet statt still falsch
# uebersetzt.
#
# #1170: `src/crypto/lic_secret.lyx` ist gitignoriert, wird zum Bauen aber
# gebraucht — ein frischer Checkout scheiterte mit vier sema-Fehlern. Die
# committete Entwicklungsvorgabe tritt jetzt an ihre Stelle.
#
# Gemessen wird der WERT bzw. die Meldung, nicht die Uebersetzbarkeit.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

lyxc_run() { ( ulimit -v $(( 4 * 1024 * 1024 )); timeout 60 "$LYXC" "$@" ); }
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! lyxc_run --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    no "$1" "uebersetzt nicht"; return
  fi
  got="$(timeout 10 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then no "$1" "ABSTURZ (rc=$rc)"; return; fi
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1" "'$got' erwartet '$3'"; fi
}

KOPF='import src.std.io;'

# ===========================================================================
# #1212 — gemischte Arithmetik
# ===========================================================================

# Der Repro aus dem Bericht, in allen vier Grundrechenarten. Beide Operanden
# sind Literale — das trifft die Schnellpfade fuer konstante Operanden.
out "gemischte Literale in allen vier Grundrechenarten" "$KOPF
fn main(): int64 {
  PrintLn(FloatToStr(10 - 2.5));
  PrintLn(FloatToStr(2.5 + 10));
  PrintLn(FloatToStr(3 * 1.5));
  PrintLn(FloatToStr(7.0 / 2));
  return 0;
}" "7.500000
12.500000
4.500000
3.500000"

# Dieselbe Rechnung ueber Variablen — der allgemeine Pfad statt der
# Schnellpfade. Beide Reihenfolgen, damit die Umwandlung auf der richtigen
# Seite geprueft wird.
out "gemischte Variablen, beide Reihenfolgen" "$KOPF
fn main(): int64 {
  var i: int64 := 4;
  var f: f64 := 1.5;
  PrintLn(FloatToStr(i * f));
  PrintLn(FloatToStr(f - i));
  return 0;
}" "6.000000
-2.500000"

# Gemischt mit genau EINER Konstanten, je Seite einmal.
out "int-Variable mit float-Literal und umgekehrt" "$KOPF
fn main(): int64 {
  var x: int64 := 10;
  var y: f64 := 2.5;
  PrintLn(FloatToStr(x - 2.5));
  PrintLn(FloatToStr(10 - y));
  return 0;
}" "7.500000
7.500000"

# Vergleiche mischen ebenso.
out "gemischte Vergleiche" "$KOPF
fn main(): int64 {
  if (2.5 < 10) { PrintLn(\"kleiner\"); } else { PrintLn(\"FALSCH\"); }
  if (10 > 2.5) { PrintLn(\"groesser\"); } else { PrintLn(\"FALSCH\"); }
  return 0;
}" "kleiner
groesser"

# Gegenproben: reine Ganzzahl- und reine Gleitkommarechnung duerfen sich NICHT
# aendern. Insbesondere bleibt die Ganzzahldivision abschneidend — waere sie
# heimlich zu Gleitkomma geworden, ergaebe 7/2 den Wert 3.5.
out "reine Ganzzahlrechnung unveraendert" "$KOPF
fn main(): int64 {
  PrintLn(IntToStr(10 - 3));
  PrintLn(IntToStr(7 / 2));
  PrintLn(IntToStr(2 * 3 + 1));
  return 0;
}" "7
3
7"

out "reine Gleitkommarechnung unveraendert" "$KOPF
fn main(): int64 {
  PrintLn(FloatToStr(2.5 + 2.5));
  PrintLn(FloatToStr(7.5 / 2.5));
  return 0;
}" "5.000000
3.000000"

# ===========================================================================
# #1281 — try/catch auf ir_lower-Zielen
# ===========================================================================

printf '%s\n' "$KOPF
fn main(): int64 {
  try { PrintStrLn(\"try\"c); } catch (e: int64) { PrintStrLn(\"catch\"c); }
  return 0;
}" > "$TMP/tc.lyx"

# Der x86-Pfad ist seit #1147 in Ordnung und muss es bleiben: nur `try`.
if lyxc_run --std-path="$ROOT" "$TMP/tc.lyx" -o "$TMP/tc" >/dev/null 2>&1; then
  got="$("$TMP/tc" 2>&1)"
  if [ "$got" = "try" ]; then ok "x86: nur der try-Rumpf laeuft"
  else no "x86 try/catch" "'$got' erwartet 'try'"; fi
else
  no "x86 try/catch" "uebersetzt nicht"
fi

# Fuer ein ir_lower-Ziel wird gemeldet statt still falsch uebersetzt. Geprueft
# werden Meldung UND Exit-Code — ein Compiler, der meldet und trotzdem ein
# Binary hinlegt, waere sonst ebenso gruen.
rm -f "$TMP/tc_lyxos"
got=$(lyxc_run --std-path="$ROOT" --target=lyxos "$TMP/tc.lyx" -o "$TMP/tc_lyxos" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then
  no "lyxos: try/catch wird gemeldet" "Exit 0 — still uebersetzt"
elif echo "$got" | grep -q "try/catch wird fuer dieses Ziel noch nicht unterstuetzt"; then
  ok "lyxos: try/catch wird gemeldet (rc=$rc)"
else
  no "lyxos: try/catch wird gemeldet" "andere Meldung — '$(echo "$got" | tail -1)'"
fi

# Gegenprobe: ohne try uebersetzt dasselbe Ziel weiter. Ohne sie waere ein
# Backend, das gar nichts mehr annimmt, ebenso gruen.
printf '%s\nfn main(): int64 { PrintStrLn("ok"c); return 0; }\n' "$KOPF" > "$TMP/nl.lyx"
if lyxc_run --std-path="$ROOT" --target=lyxos "$TMP/nl.lyx" -o "$TMP/nl_lyxos" >/dev/null 2>&1; then
  ok "lyxos ohne try uebersetzt weiter"
else
  no "lyxos ohne try" "uebersetzt nicht mehr"
fi

# ===========================================================================
# #1170 — frischer Checkout kann bauen
# ===========================================================================
# Der vollstaendige Nachweis ist ein Bau im frischen Worktree; hier wird
# festgehalten, dass die Vorgabe existiert und das Makefile sie einsetzt —
# sonst verschwindet beides beim naechsten Aufraeumen unbemerkt.

if [ -f "$ROOT/src/crypto/lic_secret.dev.lyx" ]; then
  ok "Entwicklungsvorgabe lic_secret.dev.lyx ist da"
else
  no "lic_secret.dev.lyx" "fehlt — ein frischer Checkout kann nicht bauen"
fi

if grep -q "lic_secret.dev.lyx" "$ROOT/Makefile"; then
  ok "Makefile setzt die Vorgabe ein"
else
  no "Makefile" "verweist nicht mehr auf lic_secret.dev.lyx"
fi

# Die Vorgabe darf kein echtes Geheimnis tragen: der Ed25519-Key ist der
# oeffentliche Testvektor 1 aus RFC 8032, das Secret eine lesbare Zeichenkette.
if grep -q "NOT-FOR-PRODUCTIO" "$ROOT/src/crypto/lic_secret.dev.lyx" 2>/dev/null \
   || grep -q "poke8(out32+0,  76)" "$ROOT/src/crypto/lic_secret.dev.lyx" 2>/dev/null; then
  ok "Vorgabe traegt erkennbare Platzhalterwerte"
else
  no "Vorgabe" "Platzhalter nicht erkennbar — koennte ein echtes Secret sein"
fi

echo
echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
