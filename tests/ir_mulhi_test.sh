#!/usr/bin/env bash
# tests/ir_mulhi_test.sh — #2460: mulhi/umulhi auf dem IR-Weg.
#
# BEFUND: die beiden Namen waren seit #1552 nur an ZWEI der drei Stellen
# bekannt, die ein Builtin braucht — sema (`_regBuiltin`) und der direkte
# x86-Codegen. In der Aufzaehlung von ir_lower fehlten sie, und damit
# scheiterte JEDES Ziel, das ueber das IR geht:
#
#   lyxc: --target=arm64: unbekannter Name im Aufruf: umulhi
#
# Die Meldung in #2460 nannte win64; gemessen mit 1.2.35C traf es win64,
# arm64, riscv und lyxos gleichlautend. std/crypto/bignum.lyx und darueber die
# ganze TLS-Kette waren auf diesen Zielen nicht uebersetzbar.
#
# Gemessen wird der WERT, nicht die Uebersetzbarkeit: "uebersetzt wieder" ist
# keine Aussage ueber "rechnet richtig" (#1789 — IRO_DIV stand in der Liste
# und lieferte still 0). Die Erwartungswerte sind von Hand gegengerechnet:
#   umulhi(2^64-1, 2^64-1) = 2^64-2   -> vorzeichenbehaftet gedruckt -2
#   mulhi (-1, -1)         = 0
#   umulhi(2^32, 2^32)     = 1
#   mulhi (-2^32, 2^32)    = -1
#   umulhi(2^64-1, 2)      = 1

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$ROOT/tests/lib/lyxc_guard.sh"; [ -f "$_g" ] && . "$_g"
. "$ROOT/tests/lib/qemu.sh"   # #2048: QEMU_ARM64 / QEMU_RISCV64 — nicht selbst suchen
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1${2:+: $2}"; FAIL=$((FAIL+1)); }

ERWARTET="-2 0 1 -1 1"

cat > "$TMP/mh.lyx" <<'LYX'
fn main(): int64 {
  var m1: int64 := 0 - 1;
  var e32: int64 := 4294967296;
  PrintInt(umulhi(m1, m1)); PrintStr(" "c);
  PrintInt(mulhi(m1, m1)); PrintStr(" "c);
  PrintInt(umulhi(e32, e32)); PrintStr(" "c);
  PrintInt(mulhi(0 - e32, e32)); PrintStr(" "c);
  PrintInt(umulhi(m1, 2)); PrintStr("\n"c);
  return 0;
}
LYX

# ------------------------------------------------- Referenz: der Schnellweg

if "$LYXC" --std-path="$ROOT" "$TMP/mh.lyx" -o "$TMP/mh_x86" > "$TMP/log" 2>&1; then
  aus=$("$TMP/mh_x86" 2>/dev/null | tr -d '\n')
  if [ "$aus" = "$ERWARTET" ]; then
    ok "x86-Schnellweg rechnet die fuenf Faelle richtig (Referenz)"
  else
    no "x86-Schnellweg" "erhalten [$aus], erwartet [$ERWARTET]"
  fi
else
  no "x86-Schnellweg uebersetzt" "$(grep -m1 -i error "$TMP/log")"
fi

# ------------------------------------------------- IR-Ziele: Wert ausfuehren

probe() { # probe <ziel> <emulator aus lib/qemu.sh, leer wenn keiner da>
  local z="$1" q="$2"
  if ! "$LYXC" --std-path="$ROOT" --target="$z" "$TMP/mh.lyx" -o "$TMP/mh_$z" > "$TMP/log" 2>&1; then
    no "$z uebersetzt mulhi/umulhi" "$(grep -m1 -iE 'unbekannter Name|error' "$TMP/log")"
    return
  fi
  ok "$z uebersetzt mulhi/umulhi"
  if [ -z "$q" ] || ! command -v "$q" > /dev/null 2>&1; then
    echo "SKIP kein Emulator vorhanden — der Wert bleibt auf $z ungemessen"
    return
  fi
  local aus
  aus=$(cd "$TMP" && timeout 120 "$q" "./mh_$z" 2>/dev/null | tr -d '\n')
  if [ "$aus" = "$ERWARTET" ]; then
    ok "$z rechnet dieselben Werte wie x86"
  else
    no "$z Werte" "erhalten [$aus], erwartet [$ERWARTET]"
  fi
}

probe arm64 "$QEMU_ARM64"
probe riscv "$QEMU_RISCV64"

# lyxos laeuft hier nicht (es braucht den eigenen Kern, und der lokale
# LBF-Lader liefert Syscall-Ergebnisse im falschen Register, siehe CLAUDE.md).
# Geprueft wird deshalb am ERZEUGNIS, dass die beiden Formen der
# Ein-Operanden-Multiplikation drinstehen: imul rcx (48 F7 E9) fuer mulhi,
# mul rcx (48 F7 E1) fuer umulhi. Die Zahl ist bekannt: das Programm ruft
# mulhi zweimal und umulhi dreimal.
if "$LYXC" --std-path="$ROOT" --target=lyxos "$TMP/mh.lyx" -o "$TMP/mh_lyxos" > "$TMP/log" 2>&1; then
  ok "lyxos uebersetzt mulhi/umulhi"
  h=$(xxd -p "$TMP/mh_lyxos" | tr -d '\n')
  n_s=$(grep -o '48f7e9' <<<"$h" | wc -l)
  n_u=$(grep -o '48f7e1' <<<"$h" | wc -l)
  if [ "$n_s" -eq 2 ] && [ "$n_u" -eq 3 ]; then
    ok "lyxos-Erzeugnis: zweimal imul rcx, dreimal mul rcx"
  else
    no "lyxos-Erzeugnis" "imul rcx ${n_s}x (erwartet 2), mul rcx ${n_u}x (erwartet 3)"
  fi
else
  no "lyxos uebersetzt mulhi/umulhi" "$(grep -m1 -iE 'unbekannter Name|error' "$TMP/log")"
fi

# ------------------------------------------------- die Unit, die es brauchte

for z in win64 arm64 riscv lyxos; do
  if "$LYXC" --std-path="$ROOT" --target="$z" --compile-unit "$ROOT/std/crypto/bignum.lyx" \
       -o "$TMP/bignum_$z.lyu" > "$TMP/log" 2>&1; then
    ok "std/crypto/bignum.lyx laesst sich fuer $z vorkompilieren"
  else
    no "std/crypto/bignum.lyx fuer $z" "$(grep -m1 -iE 'unbekannter Name|error' "$TMP/log")"
  fi
done

echo "----"
echo "$PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
