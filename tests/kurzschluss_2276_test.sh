#!/usr/bin/env bash
# tests/kurzschluss_2276_test.sh — `&&` und `||` werten BEDINGT aus, auf jedem
# Ziel gleich (#2276).
#
# Im IR-Weg wurden beide bis 1.2.22D als BITWEISES Und/Oder gesenkt — im
# Quelltext stand es sogar: "TK_AND (&&; treat as bitwise for now)". Damit
# wurde die rechte Seite IMMER ausgewertet, und zwei Dinge gingen schief:
#
#   1. Jede WACHE starb:  `if (p != 0 && peek64(p) == 1)`  → SIGSEGV auf
#      arm64/riscv, weil peek64(0) trotzdem lief. Der Compiler ist voll
#      solcher Wachen; der arm64-gebaute lyxc starb an der ersten
#      `extern fn ... link`, weil die Grenze in sema._fnRecordSig nicht
#      kurzgeschlossen wurde und sn_kind() auf den gepackten link-String
#      losging. Das war die Ursache der Selbstbau-Abweichung aus #2276.
#   2. Der WERT war falsch, wo die Operanden nicht 0/1 sind: `2 && 1` ist
#      bitweise 0 — also "falsch", obwohl beide Seiten wahr sind.
#
# Dieselbe Klasse wie #1023, das es fuer den x86-Weg behoben hat; der IR-Weg
# wurde nie nachgezogen.
#
# GEMESSEN WIRD BEIDES: dass die rechte Seite bei Abbruch NICHT laeuft (ueber
# einen Seiteneffekt gezaehlt, nicht ueber "stuerzt nicht ab"), und dass sie
# laeuft, wenn sie muss. Ein Test, der nur "kein Absturz" prueft, waere auch
# von einem Compiler erfuellt, der die rechte Seite gar nicht erst erzeugt.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
. "$(dirname "$0")/lib/qemu.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ulimit -c 0
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

ZIELE="x86"
[ -n "$QEMU_ARM64" ] && ZIELE="$ZIELE arm64" || echo "HINWEIS: Emulator fuer arm64 fehlt"
[ -n "$QEMU_RISCV64" ] && ZIELE="$ZIELE riscv" || echo "HINWEIS: Emulator fuer riscv fehlt"

cat > "$TMP/k.lyx" <<'LYX'
unit main;
import std.io;
import std.alloc;

var zaehler: int64 := 0;

fn nebenwirkung(): int64 { zaehler := zaehler + 1; return 1; }
fn lies(p: int64): int64 { return peek64(p); }
fn zwei(): int64 { return 2; }

fn main(): int64 {
  var p: int64 := 0;

  // 1. WACHE: die rechte Seite darf nicht laufen, sonst faultet peek64(0).
  if (p != 0 && peek64(p) == 1) { PrintStr("nie\n"c); }
  if (p != 0 && lies(p) == 1)   { PrintStr("nie\n"c); }
  if (p == 0 || lies(p) == 1)   { PrintStr("oder-links\n"c); }

  // 2. SEITENEFFEKT: gezaehlt wird, wie oft die rechte Seite wirklich lief.
  zaehler := 0;
  if (p != 0 && nebenwirkung() == 1) { PrintStr("nie\n"c); }   // darf NICHT zaehlen
  if (p == 0 && nebenwirkung() == 1) { PrintStr("und-beide\n"c); }  // MUSS zaehlen
  if (p == 0 || nebenwirkung() == 1) { PrintStr("oder-kurz\n"c); }  // darf NICHT zaehlen
  if (p != 0 || nebenwirkung() == 1) { PrintStr("oder-rechts\n"c); } // MUSS zaehlen
  PrintStr("zaehler="c); PrintInt(zaehler); PrintStr("\n"c);

  // 3. WERT: Operanden ungleich 0/1. Bitweise waere 2 & 1 = 0.
  var x: int64 := 2;
  var y: int64 := 1;
  if (x && y) { PrintStr("wert-und\n"c); } else { PrintStr("wert-und-FALSCH\n"c); }
  if (zwei() && y) { PrintStr("wert-ruf\n"c); } else { PrintStr("wert-ruf-FALSCH\n"c); }
  if (x || 0) { PrintStr("wert-oder\n"c); } else { PrintStr("wert-oder-FALSCH\n"c); }

  // 4. KETTE mit Grenze — die Form, an der der Selbstbau starb.
  var feld: int64 := alloc(16);
  poke64(feld, 7);
  var i: int64 := 99;
  var n: int64 := 2;
  if (i >= 0 && i < n && peek64(feld + i * 8) == 7) { PrintStr("nie\n"c); }
  PrintStr("kette ok\n"c);
  return 0;
}
LYX

# Erwartung gegengerechnet, nicht geraten: bei `p == 0 || …` ist die LINKE
# Seite wahr, also wird der Zweig genommen (er druckt) und die rechte Seite
# laeuft trotzdem nicht — "oder-kurz" gehoert dazu, der Zaehler aber nicht.
# zaehler = 2: einmal `und-beide`, einmal `oder-rechts`.
ERW="oder-links und-beide oder-kurz oder-rechts zaehler=2 wert-und wert-ruf wert-oder kette ok"

for z in $ZIELE; do
  opt=""; q=""
  [ "$z" = arm64 ] && { opt="--target=arm64"; q="$QEMU_ARM64"; }
  [ "$z" = riscv ] && { opt="--target=riscv"; q="$QEMU_RISCV64"; }
  if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" $opt "$TMP/k.lyx" -o "$TMP/k.$z" >"$TMP/k.$z.log" 2>&1); then
    no "$z" "uebersetzt nicht: $(grep -m1 -iE 'error|lyxc:' "$TMP/k.$z.log")"; continue
  fi
  got=$( cd "$TMP" && timeout 60 $q "$TMP/k.$z" 2>&1 | tr '\n' ' ' ); got="${got% }"
  if [ "$got" = "$ERW" ]; then ok "$z: $got"
  else no "$z" "'$got' erwartet '$ERW'"; fi
done

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
