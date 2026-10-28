#!/usr/bin/env bash
# tests/peek32_vorzeichenlos_2247_test.sh — #2247: `peek32(adr) & 0xFFFFFFFF`
# ist EIN Ladebefehl.
#
# peek32 erweitert mit Vorzeichen; die Maske schneidet die oberen 32 Bit
# wieder ab. Bis 1.2.24B waren das zwei Befehle:
#
#   movslq (%r14,%r12,4),%rax ; mov %eax,%eax
#
# Ein 32-Bit-Ladebefehl null-erweitert von sich aus, macht also beides:
#
#   mov (%r14,%r12,4),%eax
#
# Gemessen an sum32 aus bench/arr_int.lyx 58 auf 55 Befehle, im Rumpf 6 auf
# 5 je Element — der letzte reine Transportbefehl der Schleife.
#
# Das VORZEICHEN ist hier die ganze Prüfung, und zwar auf beiden Seiten:
#
#   - MIT Maske muss ein negativ abgelegter Wert vorzeichenLOS herauskommen
#     (-1 als int32 abgelegt -> 4294967295). Ein Ladebefehl, der weiter
#     vorzeichenerweitert, liefert hier -1.
#   - OHNE Maske muss peek32 weiter vorzeichenerweitern (-1 bleibt -1). Wer
#     den Ladebefehl pauschal umstellt, bricht genau das.
#
# Dazu die Faelle, in denen die Verschmelzung NICHT greifen darf: eine andere
# Maske, ein anderer Aufruf links, eine verdeckende Funktion der eigenen Unit
# und --runtime-checks (dort traegt peek32 eine Nullzeigerpruefung). In allen
# muss der Wert derselbe sein.
#
# Dieselben Werte auf arm64 und riscv: die Aenderung sitzt im x86-Codegen,
# die beiden anderen Ziele sind der unveraenderte Gegenstand.
#
# AUSNAHME, #2300: `peek32` OHNE Maske erweitert nur auf x86 mit Vorzeichen;
# arm64 und riscv erweitern mit Null (Builtin 201 im jeweiligen Backend,
# vorbestehend und unabhaengig von dieser Aenderung). Die beiden Faelle, die
# den unmaskierten Wert messen, laufen deshalb NUR auf x86 — ein Test darf
# nicht an einem fremden offenen Defekt haengen, und er darf auch nicht
# voraussetzen, dass die Luecke offen bleibt: nach dem Fix von #2300 gehoert
# die Einschraenkung hier weg und die Faelle laufen auf allen drei Zielen.
# Alles andere in dieser Datei wird weiter auf allen drei Zielen geprueft —
# die MASKIERTE Form stimmt ueberall ueberein, und genau sie aendert sich.

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

fall() { # name erwartet [zusatzschalter] [ziele]   (Quelle auf stdin)
  local name="$1" erw="$2" extra="$3" ziele="${4:-$ZIELE}"
  cat > "$TMP/$name.lyx"
  local z
  for z in $ziele; do
    local opt="" q=""
    [ "$z" = arm64 ] && { opt="--target=arm64"; q="$QEMU_ARM64"; }
    [ "$z" = riscv ] && { opt="--target=riscv"; q="$QEMU_RISCV64"; }
    if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" $opt $extra "$TMP/$name.lyx" -o "$TMP/$name.$z" >"$TMP/$name.$z.log" 2>&1); then
      no "$name $z" "uebersetzt nicht: $(grep -m1 -iE 'error|lyxc:' "$TMP/$name.$z.log")"; continue
    fi
    local got
    got=$( cd "$TMP" && timeout 60 $q "$TMP/$name.$z" 2>&1 | tr '\n' ' ' ); got="${got% }"
    if [ "$got" = "$erw" ]; then ok "$name $z: $got"; else no "$name $z" "'$got' erwartet '$erw'"; fi
  done
}

# ------------------------------------------------------------------
# A. Am Erzeugnis: EIN Ladebefehl, und der alte Zweiklang ist weg.
# ------------------------------------------------------------------
cat > "$TMP/u.lyx" <<'LYX'
unit main;
import std.io;
fn summe(a: int64, n: int64): int64 {
  var s: int64 := 0;
  var i: int64 := 0;
  while (i < n) { s := s + (peek32(a + i * 4) & 0xFFFFFFFF); i := i + 1; }
  return s;
}
fn main(): int64 {
  var p: int64 := alloc(64);
  var i: int64 := 0;
  while (i < 8) { poke32(p + i * 4, i + 1); i := i + 1; }
  PrintInt(summe(p, 8)); PrintStr("\n"c);
  return 0;
}
LYX
if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/u.lyx" -o "$TMP/u" --map-file >"$TMP/u.log" 2>&1); then
  no "erzeugnis" "uebersetzt nicht: $(grep -m1 -iE 'error|lyxc:' "$TMP/u.log")"
elif ! command -v objdump >/dev/null 2>&1; then
  echo "HINWEIS: objdump fehlt, Pruefung am Erzeugnis entfaellt"
else
  # Spalte 1 der Karte ist die VIRTUELLE Adresse; der Datei-Versatz fuer
  # `objdump -b binary` ist Adresse minus Ladebasis (statisches ELF,
  # 0x400000). Spalte 2 ist .text-relativ und laege 176 Byte daneben.
  VON=$(awk '$NF=="summe"{printf "%d", strtonum($1) - 4194304}' "$TMP/u.map" | head -1)
  BIS=$(awk -v v="$VON" '$NF!="summe" && NF>=4 {o=strtonum($1) - 4194304; if (o>v) print o}' \
        "$TMP/u.map" | sort -n | head -1)
  if [ -z "$VON" ] || [ -z "$BIS" ]; then
    no "erzeugnis" "summe nicht in der Karte gefunden"
  else
    DIS=$(objdump -D -z -b binary -m i386:x86-64 --no-show-raw-insn \
            --start-address="$VON" --stop-address="$BIS" "$TMP/u" 2>/dev/null)
    NL=$(printf '%s\n' "$DIS" | grep -cE 'mov +\(%r1[2-5],%r1[2-5],[1248]\),%eax$')
    if [ "$NL" -ge 1 ]; then ok "erzeugnis: 32-Bit-Ladebefehl mit Null-Erweiterung ($NL Vorkommen)"
    else no "erzeugnis" "kein 'mov (…),%eax' — Maske laeuft noch als eigener Befehl"; fi
    NM=$(printf '%s\n' "$DIS" | grep -cE 'mov +%eax,%eax$')
    if [ "$NM" -eq 0 ]; then ok "erzeugnis: kein 'mov %eax,%eax' mehr"
    else no "erzeugnis" "$NM mal noch der Maskenbefehl 'mov %eax,%eax'"; fi
  fi
fi

# ------------------------------------------------------------------
# B. Am Wert — das Vorzeichen, beide Seiten.
# ------------------------------------------------------------------

# 1. MIT Maske vorzeichenlos, OHNE Maske vorzeichenbehaftet. Dieselbe Zelle,
#    derselbe Lauf — ein Ladebefehl, der pauschal umgestellt waere, faellt an
#    der zweiten Zeile auf.
#    0xFFFFFFFF = 4294967295, als int32 gelesen -1.
#    0x80000000 = 2147483648, als int32 gelesen -2147483648.
fall vorzeichen "4294967295 -1 2147483648 -2147483648 7 7" "" "x86" <<'LYX'
unit main;
import std.io;
fn main(): int64 {
  var p: int64 := alloc(32);
  poke32(p, 0 - 1);
  PrintInt(peek32(p) & 0xFFFFFFFF); PrintStr("\n"c);   // 4294967295
  PrintInt(peek32(p)); PrintStr("\n"c);                // -1
  poke32(p, 0 - 2147483648);
  PrintInt(peek32(p) & 0xFFFFFFFF); PrintStr("\n"c);   // 2147483648
  PrintInt(peek32(p)); PrintStr("\n"c);                // -2147483648
  poke32(p, 7);
  PrintInt(peek32(p) & 0xFFFFFFFF); PrintStr("\n"c);   // 7
  PrintInt(peek32(p)); PrintStr("\n"c);                // 7
  return 0;
}
LYX

# 2. Beide Adressformen: die zerlegbare (Schnellweg) und eine, die der
#    Schnellweg nicht nimmt. Der Wert muss derselbe sein.
fall adressformen "4294967295 4294967295 4294967295" <<'LYX'
unit main;
import std.io;
fn streu(x: int64): int64 { return x; }
fn main(): int64 {
  var p: int64 := alloc(64);
  var i: int64 := 3;
  poke32(p + i * 4, 0 - 1);
  // zerlegbar: Basis + Index * 4, Index in einem Register
  PrintInt(peek32(p + i * 4) & 0xFFFFFFFF); PrintStr("\n"c);
  // nicht zerlegbar: die Adresse kommt aus einem Aufruf
  PrintInt(peek32(streu(p + 12)) & 0xFFFFFFFF); PrintStr("\n"c);
  // nicht zerlegbar: Produkt mit einem Faktor, den x86 nicht traegt
  var j: int64 := 1;
  PrintInt(peek32(p + 12 * j) & 0xFFFFFFFF); PrintStr("\n"c);
  return 0;
}
LYX

# 3. Nicht verschmelzen: andere Maske, anderer Aufruf links, Maske auf einem
#    gewoehnlichen Ausdruck. Erwartungswerte von Hand gegengerechnet.
fall keine_verschmelzung "65535 4294967295 4294967295 255" <<'LYX'
unit main;
import std.io;
fn neg(): int64 { return 0 - 1; }
fn main(): int64 {
  var p: int64 := alloc(32);
  poke32(p, 0 - 1);
  PrintInt(peek32(p) & 0xFFFF); PrintStr("\n"c);     // 65535, nicht 4294967295
  PrintInt(neg() & 0xFFFFFFFF); PrintStr("\n"c);     // 4294967295 (anderer Aufruf)
  var v: int64 := 0 - 1;
  PrintInt(v & 0xFFFFFFFF); PrintStr("\n"c);         // 4294967295 (kein Aufruf)
  PrintInt(peek8(p) & 0xFFFFFFFF); PrintStr("\n"c);  // peek8 null-erweitert: 255
  return 0;
}
LYX

# 4. Verschachtelt: der Wunsch darf nicht in die Auswertung des ARGUMENTS
#    durchsickern. Das innere peek32 liefert eine Adresse und muss dabei
#    seine eigene Behandlung bekommen.
fall verschachtelt "4294967295 42" <<'LYX'
unit main;
import std.io;
fn main(): int64 {
  var p: int64 := alloc(64);
  var z: int64 := alloc(32);
  poke32(z, 0 - 1);
  PrintInt(peek32(z) & 0xFFFFFFFF); PrintStr("\n"c);   // 4294967295
  // Das innere peek32 liest einen Zeigerversatz, das aeussere den Wert.
  poke32(p, 42);
  poke32(z, 0);
  PrintInt(peek32(p + (peek32(z) & 0xFFFFFFFF)) & 0xFFFFFFFF); PrintStr("\n"c);   // 42
  return 0;
}
LYX

# 5. Verdeckende Funktion der EIGENEN Unit: der Builtin gilt dann nicht, und
#    die Maske muss auf deren Ergebnis wirken (#2082).
fall verdeckt "4294967295" <<'LYX'
unit main;
import std.io;
fn peek32(a: int64): int64 { return 0 - 1; }
fn main(): int64 {
  var p: int64 := alloc(32);
  PrintInt(peek32(p) & 0xFFFFFFFF); PrintStr("\n"c);   // 4294967295
  return 0;
}
LYX

# 6. Mit --runtime-checks traegt peek32 eine Nullzeigerpruefung und nimmt den
#    Schnellweg nicht. Derselbe Wert.
fall runtime_checks "4294967295 -1" "--runtime-checks" "x86" <<'LYX'
unit main;
import std.io;
fn main(): int64 {
  var p: int64 := alloc(32);
  var i: int64 := 0;
  poke32(p + i * 4, 0 - 1);
  PrintInt(peek32(p + i * 4) & 0xFFFFFFFF); PrintStr("\n"c);   // 4294967295
  PrintInt(peek32(p + i * 4)); PrintStr("\n"c);                // -1
  return 0;
}
LYX

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
