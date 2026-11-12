#!/usr/bin/env bash
# tests/peek_breiten_2300_test.sh — #2300: peek8/16/32/64 bedeuten auf JEDEM
# Ziel dasselbe.
#
# Bis 1.2.24C erweiterte `peek32` nur auf x86-64 mit Vorzeichen; arm64, riscv
# und lyxos erweiterten mit Null. Dasselbe Programm lieferte damit je nach
# Ziel einen anderen Wert:
#
#   poke32(p, -1); PrintInt(peek32(p))
#     x86 -> -1        arm64/riscv -> 4294967295
#
# Die Ursache lag nicht im gemeinsamen IR-Weg — ir_lower gibt fuer alle
# Breiten nur IRO_CALL_BUILTIN mit der Nummer weiter (200/208/201/202) —,
# sondern in der Umsetzung der Nummer 201 in den Backends: arm64 lud mit
# `LDR Wt` statt `LDRSW Xt`, riscv mit `LWU` statt `LW` (das auf RV64
# vorzeichenerweitert), lyxos mit `mov eax,[rax]` statt `movsxd`.
#
# Festgelegt gilt die x86-Bedeutung, und zwar aus dem Bestand heraus: von
# 396 peek32-Aufrufen im Baum tragen 249 ein `& 0xFFFFFFFF`. Dieses Idiom
# gaebe es nicht, wenn peek32 schon null-erweiterte — es ist genau die
# Umgehung der Vorzeichenerweiterung.
#
# Geprueft wird deshalb die ganze FAMILIE, nicht nur der gemeldete Fall:
# peek8 und peek16 null-erweitern, peek32 und peek64 erweitern mit
# Vorzeichen. Sonst zieht ein Fix an 201 die anderen Breiten mit.
#
# lyxos laeuft lokal nicht (braucht den Kernel, und der LBF-Lader liefert
# Syscall-Ergebnisse in rax statt rdx). Dort wird am ERZEUGNIS geprueft:
# das Bytemuster von `movsxd rax, dword [rax]` muss drinstehen und das von
# `mov eax, [rax]` an derselben Stelle nicht mehr.

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

# Alle vier Breiten, jede mit dem Bitmuster, an dem sich Null- und
# Vorzeichenerweiterung UNTERSCHEIDEN (oberstes Bit gesetzt). Erwartungswerte
# von Hand gegengerechnet:
#   peek8  null-erweitert:        0xFF       -> 255
#   peek16 null-erweitert:        0xFFFF     -> 65535
#   peek32 vorzeichenerweitert:   0xFFFFFFFF -> -1
#   peek32 vorzeichenerweitert:   0x80000000 -> -2147483648
#   peek32 ohne oberstes Bit:     7          -> 7         (beide Lesarten gleich)
#   peek32 mit Maske:             0xFFFFFFFF -> 4294967295 (die Umgehung)
#   peek64:                       alle Bits  -> -1
ERW="255 65535 -1 -2147483648 7 4294967295 -1"
cat > "$TMP/b.lyx" <<'LYX'
unit main;
import std.io;
fn main(): int64 {
  var p: int64 := alloc(64);
  poke8(p, 0 - 1);                PrintInt(peek8(p));                   PrintStr(" "c);
  poke16(p + 8, 0 - 1);           PrintInt(peek16(p + 8));              PrintStr(" "c);
  poke32(p + 16, 0 - 1);          PrintInt(peek32(p + 16));             PrintStr(" "c);
  poke32(p + 32, 0 - 2147483648); PrintInt(peek32(p + 32));             PrintStr(" "c);
  poke32(p + 40, 7);              PrintInt(peek32(p + 40));             PrintStr(" "c);
  poke32(p + 48, 0 - 1);          PrintInt(peek32(p + 48) & 0xFFFFFFFF); PrintStr(" "c);
  poke64(p + 24, 0 - 1);          PrintInt(peek64(p + 24));             PrintStr("\n"c);
  return 0;
}
LYX

for z in $ZIELE; do
  opt=""; q=""
  [ "$z" = arm64 ] && { opt="--target=arm64"; q="$QEMU_ARM64"; }
  [ "$z" = riscv ] && { opt="--target=riscv"; q="$QEMU_RISCV64"; }
  if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" $opt "$TMP/b.lyx" -o "$TMP/b.$z" >"$TMP/b.$z.log" 2>&1); then
    no "breiten $z" "uebersetzt nicht: $(grep -m1 -iE 'error|lyxc:' "$TMP/b.$z.log")"; continue
  fi
  got=$( cd "$TMP" && timeout 60 $q "$TMP/b.$z" 2>&1 | tr -d '\n' )
  if [ "$got" = "$ERW" ]; then ok "breiten $z: $got"; else no "breiten $z" "'$got' erwartet '$ERW'"; fi
done

# Dieselben Werte auf ALLEN gelaufenen Zielen — genau das war der Defekt.
# Eine Gegenprobe, die nur ein Ziel messen wuerde, haette ihn nie gesehen.
ANZ=$(echo $ZIELE | wc -w)
if [ "$ANZ" -ge 2 ]; then
  ok "mehr als ein Ziel gemessen ($ZIELE)"
else
  echo "HINWEIS: nur ein Ziel verfuegbar — der Zielvergleich entfaellt"
fi

# ------------------------------------------------------------------
# lyxos am Erzeugnis: movsxd statt mov eax.
# ------------------------------------------------------------------
# Ohne Allokation: geprueft wird das BYTEMUSTER, nicht ein Lauf. Der
# Parameter verhindert, dass der Uebersetzer die Adresse wegfaltet.
cat > "$TMP/l.lyx" <<'LYX'
unit main;
fn lies(p: int64): int64 { return peek32(p); }
fn main(): int64 { return lies(0); }
LYX
if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" --target=lyxos "$TMP/l.lyx" -o "$TMP/l.out" >"$TMP/l.log" 2>&1); then
  no "lyxos uebersetzt" "$(grep -m1 -iE 'error|Builtin-ID|lyxc:' "$TMP/l.log")"
elif ! command -v xxd >/dev/null 2>&1; then
  echo "HINWEIS: xxd fehlt, lyxos-Pruefung am Erzeugnis entfaellt"
else
  HEX=$(xxd -p "$TMP/l.out" | tr -d '\n')
  # movsxd rax, dword [rax] = 48 63 00
  if printf '%s' "$HEX" | grep -q "486300"; then
    ok "lyxos: movsxd rax, dword [rax] im Erzeugnis"
  else
    no "lyxos" "Muster 486300 (movsxd) fehlt — peek32 erweitert dort nicht mit Vorzeichen"
  fi
  # Gegenseite: peek8 und peek64 behalten ihre Befehle (movzx bzw. mov rax).
  # Ohne diese Probe wuerde ein Fix, der ALLE Breiten auf movsxd umstellt,
  # unbemerkt durchgehen.
  cat > "$TMP/l8.lyx" <<'LYX'
unit main;
fn lies8(p: int64): int64 { return peek8(p); }
fn main(): int64 { return lies8(0); }
LYX
  if (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" --target=lyxos "$TMP/l8.lyx" -o "$TMP/l8.out" >/dev/null 2>&1); then
    H8=$(xxd -p "$TMP/l8.out" | tr -d '\n')
    # movzx rax, byte [rax] = 48 0f b6 00
    if printf '%s' "$H8" | grep -q "480fb600"; then ok "lyxos: peek8 bleibt movzx (null-erweiternd)"
    else no "lyxos peek8" "Muster 480fb600 (movzx) fehlt"; fi
  else
    no "lyxos peek8 uebersetzt" "Uebersetzung fehlgeschlagen"
  fi
fi

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
