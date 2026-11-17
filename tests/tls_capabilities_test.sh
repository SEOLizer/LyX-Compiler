#!/usr/bin/env bash
# tests/tls_capabilities_test.sh — #2096: die Capability-Zusage der nativen
# TLS-Units.
#
# Das Issue sagt zu: "Ohne OpenSSL entfaellt der CA-Store-Scan; fs.meta darf
# nicht mehr noetig sein. Server braucht nur network.tcp.bind, io.wait,
# system.rand, system.time, memory.mmap."
#
# Gemessen wird das in BEIDE Richtungen, denn ein Test, der nur das
# Verschwinden einer Warnung prueft, waere auch von einem Compiler erfuellt,
# der sie nie mehr ausgibt:
#
#   1. Ein Server mit std.net.tls13 und GENAU diesen fuenf Rechten uebersetzt
#      ohne den fs-Hinweis, laeuft, bindet einen Port und bringt die
#      TLS-Zustandsmaschine zum Urteil — ohne eine Datei anzufassen.
#   2. Dasselbe mit std.net.tls12.
#   3. Der OpenSSL-Wrapper std.net.tls bekommt den Hinweis WEITERHIN: er
#      stattet den CA-Store wirklich ab, und ohne fs.read/fs.meta stirbt der
#      Handschlag an SIGSYS (#1348).
#   4. std.net.https ebenso (es haengt ueber FFI an derselben Bibliothek).
#
# Hintergrund: die Pruefung im Codegen verglich ein TEILSTUECK ("net.tls", 7
# Zeichen) und traf damit auch tls13, tls12 und tls_config. Der Rat war dort
# nicht nur unnoetig, sondern falsch — er verlangte zwei Rechte, die mit den
# nativen Units gerade wegfallen. Seit #2096 wird exakt verglichen.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

CAPS='@capabilities([network.tcp.bind, io.wait, system.rand, system.time, memory.mmap])'

# --- 1 und 2: die nativen Units, mit genau den fuenf zugesagten Rechten ---
for unit in tls13 tls12; do
  if [ "$unit" = tls13 ]; then NEU="TlsNeu"; SCHRITT="TlsSchritt"; FUETTER="TlsFuetter"; FREI="TlsFrei"; ZEIT="TlsConfigZeit";
  else NEU="Tls12Neu"; SCHRITT="Tls12Schritt"; FUETTER="Tls12Fuetter"; FREI="Tls12Frei"; ZEIT="TlsConfigZeit"; fi
  cat > "$TMP/$unit.lyx" <<LYXEOF
unit main;

$CAPS

import std.io;
import std.alloc;
import std.net.socket;
import std.net.tls_config;
import std.net.$unit;

fn main(): int64 {
  var cfg: int64 := alloc(TlsConfigGroesse());
  TlsConfigNeu(cfg, 1);
  $ZEIT(cfg, 1800000000);
  var c: int64 := $NEU(cfg);
  if (c == 0) { PrintLn("KEIN SPEICHER"); return 1; }
  // Ein unvollstaendiges ClientHello: die Zustandsmaschine muss urteilen,
  // ohne eine Datei anzufassen. Welcher Code kommt, ist hier nicht die
  // Frage — nur dass sie laeuft.
  var puf: int64 := alloc(64);
  poke8(puf, 22); poke8(puf + 1, 3); poke8(puf + 2, 3);
  poke8(puf + 3, 0); poke8(puf + 4, 4);
  poke8(puf + 5, 1); poke8(puf + 6, 0); poke8(puf + 7, 0); poke8(puf + 8, 0);
  $FUETTER(c, puf, 9);
  Print("urteil "); PrintInt($SCHRITT(c)); PrintLn("");
  var l: TCPListener := TCPListenerNew();
  TCPListenerSetReuseAddr(l);
  Print("bind "); PrintInt(TCPListenerBindTo(l, 0, 18997)); PrintLn("");
  TCPListenerClose(l);
  $FREI(c);
  PrintLn("fertig");
  return 0;
}
LYXEOF
  ( cd "$ROOT" && timeout 300 "$LYXC" "$TMP/$unit.lyx" --std-path=. -o "$TMP/$unit" ) > "$TMP/log_$unit" 2>&1
  if [ ! -x "$TMP/$unit" ]; then
    no "std.net.$unit uebersetzt unter den fuenf Rechten" "$(grep -m1 -i error "$TMP/log_$unit")"
  else
    if grep -q 'fs.meta' "$TMP/log_$unit"; then
      no "std.net.$unit ohne fs-Hinweis" "der CA-Store-Hinweis kommt noch: $(grep -m1 'fehlt:' "$TMP/log_$unit")"
    else
      ok "std.net.$unit: kein fs.read/fs.meta verlangt"
    fi
    ( ulimit -v 4000000 -c 0; timeout 60 "$TMP/$unit" ) > "$TMP/run_$unit" 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
      no "std.net.$unit laeuft unter den fuenf Rechten" "rc=$rc $(tr '\n' ' ' < "$TMP/run_$unit")"
    else
      if grep -q '^bind 0$' "$TMP/run_$unit" && grep -q '^urteil ' "$TMP/run_$unit" \
         && grep -q '^fertig$' "$TMP/run_$unit"; then
        ok "std.net.$unit: Listener gebunden und Zustandsmaschine geurteilt"
      else
        no "std.net.$unit: Wirkung" "$(tr '\n' ' ' < "$TMP/run_$unit")"
      fi
    fi
  fi
done

# --- 3 und 4: der OpenSSL-Weg MUSS den Hinweis weiter bekommen ---
for unit in tls https; do
  cat > "$TMP/o_$unit.lyx" <<LYXEOF
unit main;

$CAPS

import std.io;
import std.net.$unit;

fn main(): int64 {
  PrintLn("nur uebersetzen");
  return 0;
}
LYXEOF
  ( cd "$ROOT" && timeout 300 "$LYXC" "$TMP/o_$unit.lyx" --std-path=. -o "$TMP/o_$unit" ) > "$TMP/log_o_$unit" 2>&1
  if grep -q 'CA-Store des Systems' "$TMP/log_o_$unit" \
     && grep -q 'fs.read' "$TMP/log_o_$unit" && grep -q 'fs.meta' "$TMP/log_o_$unit"; then
    ok "std.net.$unit (OpenSSL): Hinweis auf fs.read und fs.meta kommt weiter"
  else
    no "std.net.$unit (OpenSSL): Hinweis fehlt" "$(grep -m2 -i warning "$TMP/log_o_$unit" | tr '\n' ' ')"
  fi
done

# --- 5: die Deklaration in den Units selbst ---
for f in std/net/tls13.lyx std/net/tls12.lyx; do
  if grep -q '@capabilities(\[memory.mmap, system.rand\])' "$ROOT/$f"; then
    ok "$f deklariert memory.mmap und system.rand"
  else
    no "$f" "Deklaration fehlt oder weicht ab: $(grep -m1 '@capabilities' "$ROOT/$f")"
  fi
done
# tls_config darf KEINE fuehren: es fasst nur Felder an.
if grep -q '@capabilities' "$ROOT/std/net/tls_config.lyx"; then
  no "std/net/tls_config.lyx" "fuehrt eine Deklaration, obwohl es nichts braucht"
else
  ok "std/net/tls_config.lyx fuehrt bewusst keine Capability"
fi

echo "--- $PASS PASS, $FAIL FAIL"
if [ "$FAIL" != 0 ]; then exit 1; fi
echo "ALL PASS"
exit 0
