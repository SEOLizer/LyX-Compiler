#!/usr/bin/env bash
# tests/akkumulator_register_2247_test.sh — #2247: der Akkumulator rechnet
# unmittelbar in seinem Register.
#
# `s := s + <Ausdruck>` ist der Rumpf jeder Summenschleife. Bis 1.2.24A
# blieben nach dem Operandentausch (#2247, PR #2297) zwei Befehle:
#
#   add %r13,%rax ; mov %rax,%r13
#
# Das Ergebnis ging durch rax und wurde von dort gespeichert. x86 kann es
# unmittelbar: `add %rax,%r13`. Gemessen an sum32 aus bench/arr_int.lyx
# 62 auf 58 Befehle in der Funktion, im Rumpf 7 auf 6 je Element.
#
# Zwei scharfe Kanten, und beide sind hier die eigentliche Pruefung:
#
#   1. Die RICHTUNG. Das Local ist ZIEL, rax die Quelle. Bei MINUS muss
#      `rX - rax` herauskommen, nicht `rax - rX` — wer die Operanden
#      verwechselt, dreht jede Subtraktion um. `imul` hat nur die andere
#      Befehlsform (reg <- reg * r/m), dort steht das Local im reg-Feld.
#   2. Der Schnellweg umgeht den allgemeinen Zuweisungsweg samt dessen Haken
#      (Bereichspruefung, Verschmaelerung, Einheitentyp, f64-Angleichung,
#      Vektorablage, Satz, Methodentyp, Struct-Kopie). Eintrittskarte ist
#      deshalb der Typname `int64` genau (cg_lokalIstInt64), nicht eine
#      Aufzaehlung der Haken. Geprueft wird die Gegenseite: schmaler Typ,
#      Bereichstyp und @overflow_check(true) duerfen den Schnellweg NICHT
#      nehmen.
#
# Division, Modulo und Schiebungen sind in dieser Befehlsform nicht
# erzeugbar (cg_regOpMoeglich) und muessen weiter richtig rechnen.
#
# Dieselben Werte auf arm64 und riscv: die Aenderung sitzt im x86-Codegen,
# die beiden anderen Ziele sind der unveraenderte Gegenstand.

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

fall() { # name erwartet   (Quelle auf stdin)
  local name="$1" erw="$2"
  cat > "$TMP/$name.lyx"
  local z
  for z in $ZIELE; do
    local opt="" q=""
    [ "$z" = arm64 ] && { opt="--target=arm64"; q="$QEMU_ARM64"; }
    [ "$z" = riscv ] && { opt="--target=riscv"; q="$QEMU_RISCV64"; }
    if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" $opt "$TMP/$name.lyx" -o "$TMP/$name.$z" >"$TMP/$name.$z.log" 2>&1); then
      no "$name $z" "uebersetzt nicht: $(grep -m1 -iE 'error|lyxc:' "$TMP/$name.$z.log")"; continue
    fi
    local got
    got=$( cd "$TMP" && timeout 60 $q "$TMP/$name.$z" 2>&1 | tr '\n' ' ' ); got="${got% }"
    if [ "$got" = "$erw" ]; then ok "$name $z: $got"; else no "$name $z" "'$got' erwartet '$erw'"; fi
  done
}

bricht_ab() { # name teilstring   (Quelle auf stdin)
  local name="$1" teil="$2"
  cat > "$TMP/$name.lyx"
  if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/$name.lyx" -o "$TMP/$name" >"$TMP/$name.log" 2>&1); then
    no "$name" "uebersetzt nicht: $(grep -m1 -iE 'error|lyxc:' "$TMP/$name.log")"; return
  fi
  local got rc
  got=$( cd "$TMP" && timeout 20 "$TMP/$name" 2>&1 ); rc=$?
  if [ "$rc" -eq 0 ]; then no "$name" "laeuft durch (rc=0) — die Pruefung fiel aus"; return; fi
  if printf '%s' "$got" | grep -q "DANACH"; then no "$name" "rechnet nach dem Abbruch weiter"; return; fi
  if printf '%s' "$got" | grep -q "$teil"; then ok "$name (rc=$rc)"
  else no "$name" "bricht ab, aber ohne '$teil' — '$(printf '%s' "$got" | tail -1)'"; fi
}

# ------------------------------------------------------------------
# A. Am Erzeugnis: die Form steht wirklich im Code.
# ------------------------------------------------------------------
cat > "$TMP/ak.lyx" <<'LYX'
unit main;
import std.io;
fn summe(a: int64, n: int64): int64 {
  var s: int64 := 0;
  var i: int64 := 0;
  while (i < n) { s := s + peek32(a + i * 4); i := i + 1; }
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
if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/ak.lyx" -o "$TMP/ak" --map-file >"$TMP/ak.log" 2>&1); then
  no "erzeugnis" "uebersetzt nicht: $(grep -m1 -iE 'error|lyxc:' "$TMP/ak.log")"
elif ! command -v objdump >/dev/null 2>&1; then
  echo "HINWEIS: objdump fehlt, Pruefung am Erzeugnis entfaellt"
else
  # Spalte 1 der Karte ist die VIRTUELLE Adresse; der Datei-Versatz fuer
  # `objdump -b binary` ist Adresse minus Ladebasis (statisches ELF,
  # 0x400000). Spalte 2 ist .text-relativ und laege 176 Byte daneben.
  VON=$(awk '$NF=="summe"{printf "%d", strtonum($1) - 4194304}' "$TMP/ak.map" | head -1)
  BIS=$(awk -v v="$VON" '$NF!="summe" && NF>=4 {o=strtonum($1) - 4194304; if (o>v) print o}' \
        "$TMP/ak.map" | sort -n | head -1)
  if [ -z "$VON" ] || [ -z "$BIS" ]; then
    no "erzeugnis" "summe nicht in der Karte gefunden"
  else
    DIS=$(objdump -D -z -b binary -m i386:x86-64 --no-show-raw-insn \
            --start-address="$VON" --stop-address="$BIS" "$TMP/ak" 2>/dev/null)
    # rax ALS QUELLE auf ein Halteregister — vor dem Fix gab es nur die
    # Gegenrichtung (`add %r13,%rax`) plus ein `mov %rax,%r13` danach.
    NA=$(printf '%s\n' "$DIS" | grep -cE 'add +%rax,%r1[2-5]$')
    if [ "$NA" -ge 1 ]; then ok "erzeugnis: Akkumulator im Register ($NA Vorkommen)"
    else no "erzeugnis" "kein 'add %rax,%r1[2-5]' — Ergebnis laeuft noch ueber rax"; fi
    # und der Umweg ist weg: kein `mov %rax,%r1x` unmittelbar nach einem add
    NM=$(printf '%s\n' "$DIS" | grep -cE 'add +%r1[2-5],%rax$')
    if [ "$NM" -eq 0 ]; then ok "erzeugnis: kein 'add %r1x,%rax' mehr"
    else no "erzeugnis" "$NM mal noch die alte Richtung 'add %r1x,%rax'"; fi
  fi
fi

# ------------------------------------------------------------------
# B. Am Wert.
# ------------------------------------------------------------------

# 1. Alle sechs erzeugbaren Operationen mit einem AUSDRUCK rechts. Die
#    Richtung ist der Punkt: MINUS muss `s - f()` rechnen. Erwartungswerte
#    von Hand gegengerechnet.
fall richtung "36 64 40320 12 255 170" <<'LYX'
unit main;
import std.io;
fn geb(i: int64): int64 { return i + 1; }
fn main(): int64 {
  var p: int64 := alloc(64);
  var i: int64 := 0;
  while (i < 8) { poke32(p + i * 4, i + 1); i := i + 1; }
  // PLUS mit Aufruf rechts: 1+2+..+8 = 36
  var s: int64 := 0;  i := 0;
  while (i < 8) { s := s + peek32(p + i * 4); i := i + 1; }
  PrintInt(s); PrintStr("\n"c);
  // MINUS: 100 - 1 - 2 - ... - 8 = 100 - 36 = 64, NICHT umgekehrt
  var m: int64 := 100;  i := 0;
  while (i < 8) { m := m - peek32(p + i * 4); i := i + 1; }
  PrintInt(m); PrintStr("\n"c);
  // STAR: 8! = 40320
  var t: int64 := 1;  i := 0;
  while (i < 8) { t := t * geb(i); i := i + 1; }
  PrintInt(t); PrintStr("\n"c);
  var a: int64 := 0x0F0F;
  a := a & geb(11);
  PrintInt(a); PrintStr("\n"c);          // 0x0F0F & 12 = 12
  var b: int64 := 0x00F0;
  b := b | geb(14);
  PrintInt(b); PrintStr("\n"c);          // 0xF0 | 15 = 255
  var c: int64 := 0x00FF;
  c := c ^ geb(84);
  PrintInt(c); PrintStr("\n"c);          // 0xFF ^ 85 = 170
  return 0;
}
LYX

# 2. Nicht erzeugbar in dieser Befehlsform: Division, Modulo, Schiebungen.
#    Sie muessen weiter den allgemeinen Weg gehen und richtig rechnen —
#    insbesondere mit der RICHTUNG `x <op> f()`, nicht `f() <op> x`.
fall nicht_erzeugbar "14 2 800 12" <<'LYX'
unit main;
import std.io;
fn geb(i: int64): int64 { return i + 1; }
fn main(): int64 {
  var a: int64 := 100;
  a := a / geb(6);
  PrintInt(a); PrintStr("\n"c);     // 100 / 7 = 14   (umgekehrt: 0)
  var b: int64 := 100;
  b := b % geb(6);
  PrintInt(b); PrintStr("\n"c);     // 100 % 7 = 2  (100 = 14*7 + 2)
  var c: int64 := 100;
  c := c << geb(2);
  PrintInt(c); PrintStr("\n"c);     // 100 << 3 = 800
  var d: int64 := 100;
  d := d >> geb(2);
  PrintInt(d); PrintStr("\n"c);     // 100 >> 3 = 12
  return 0;
}
LYX

# 3. Gegenseite Verschmaelerung: ein schmaler Typ darf den Schnellweg nicht
#    nehmen, sonst entfaellt das Abschneiden.
fall schmal "-2147483648 -32768 -128" <<'LYX'
unit main;
import std.io;
fn geb(i: int64): int64 { return i + 1; }
fn main(): int64 {
  var a: int32 := 2147483647;
  a := a + geb(0);
  PrintInt(a as int64); PrintStr("\n"c);     // -2147483648
  var b: int16 := 32767;
  b := b + geb(0);
  PrintInt(b as int64); PrintStr("\n"c);     // -32768
  var c: int8 := 127;
  c := c + geb(0);
  PrintInt(c as int64); PrintStr("\n"c);     // -128
  return 0;
}
LYX

# 4. Gegenseite Bereichstyp: der Typname ist `Alt`, nicht `int64`.
bricht_ab bereich "Bereichstyp Alt" <<'LYX'
unit main;
import std.io;
type Alt = int64 range 0..100;
fn geb(i: int64): int64 { return i + 1; }
fn main(): int64 {
  var a: Alt := 99;
  var i: int64 := 0;
  while (i < 5) { a := a + geb(0); i := i + 1; }
  PrintStr("DANACH\n"c);
  PrintInt(a as int64); PrintStr("\n"c);
  return 0;
}
LYX

# 5. Gegenseite Ueberlaufpruefung.
bricht_ab ueberlauf "overflow" <<'LYX'
unit main;
import std.io;
@overflow_check(true);
fn geb(i: int64): int64 { return i + 1; }
fn main(): int64 {
  var a: int64 := 9223372036854775807;
  a := a + geb(0);
  PrintStr("DANACH\n"c);
  PrintInt(a); PrintStr("\n"c);
  return 0;
}
LYX

# 6. Reihenfolge und fremdes Local. Der Schnellweg wertet die rechte Seite
#    VOR dem Lesen des Locals aus; fuer ein Local im Register ist das
#    folgenlos (keine Adresse, r12..r15 ueberleben den Aufruf). Ein Local
#    MIT genommener Adresse liegt dagegen im Rahmen, nimmt den Schnellweg
#    nicht und sieht weiter den Wert von VOR dem Aufruf.
fall reihenfolge "11 9 8" <<'LYX'
unit main;
import std.io;
fn setz(p: int64): int64 { poke64(p, 100); return 1; }
fn geb(i: int64): int64 { return i + 1; }
fn main(): int64 {
  var a: int64 := 10;
  var pa: int64 := @a;
  a := a + setz(pa);
  PrintInt(a); PrintStr("\n"c);     // 10 + 1 = 11, nicht 100 + 1
  // fremdes Local rechts: keine Verwechslung mit dem Akkumulator
  var x: int64 := 1;
  var y: int64 := 8;
  x := y + geb(0);
  PrintInt(x); PrintStr("\n"c);     // 9
  PrintInt(y); PrintStr("\n"c);     // 8 — unberuehrt
  return 0;
}
LYX

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
