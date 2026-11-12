#!/usr/bin/env bash
# tests/schleifenverwaltung_2247_test.sh — #2247: Inkrement und Vergleich
# registerresidenter Locals ohne Umweg ueber rax.
#
# Bis 1.2.23C lief die Verwaltung jeder Zaehlschleife komplett ueber rax,
# obwohl beide Werte schon in Registern lagen (#2114):
#
#   mov %r12,%rax ; add $0x1,%rax ; mov %rax,%r12     (i += 1)
#   mov %r12,%rax ; cmp %r15,%rax                     (i < n)
#
# Fuenf Befehle, von denen drei nur transportieren. Jetzt:
#
#   add $0x1,%r12
#   cmp %r15,%r12
#
# Gemessen an sum32 aus bench/arr_int.lyx: 73 auf 62 Befehle in der Funktion.
#
# Der Schnellweg hat zwei scharfe Kanten, und beide sind hier die eigentliche
# Pruefung:
#
#   1. Das INKREMENT umgeht den allgemeinen Zuweisungsweg und damit dessen
#      Haken (Bereichspruefung, Verschmaelerung, Einheitentyp, f64-Angleichung,
#      Vektorablage, Satz, Methodentyp, Struct-Kopie). Eintrittskarte ist
#      deshalb der Typname `int64` GENAU — nicht eine Aufzaehlung der Haken,
#      denn eine unvollstaendige Aufzaehlung ist in diesem Uebersetzer dreimal
#      belegt. Geprueft wird die Gegenseite: ein schmaler Typ, ein
#      Bereichstyp und @overflow_check(true) duerfen den Schnellweg NICHT
#      nehmen, ihre Wirkung muss erhalten bleiben.
#   2. Der VERGLEICH tauscht das Registerfeld des Befehls. Wer dabei reg und
#      rm verwechselt, dreht `<` in `>` — und zwar NUR bei zwei Locals im
#      Register, also genau im Schleifentest. Geprueft werden alle sechs
#      Vergleiche in beiden Operandenreihenfolgen.
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

bricht_ab() { # name teilstring_der_meldung   (Quelle auf stdin)
  local name="$1" teil="$2"
  cat > "$TMP/$name.lyx"
  if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/$name.lyx" -o "$TMP/$name" >"$TMP/$name.log" 2>&1); then
    no "$name" "uebersetzt nicht: $(grep -m1 -iE 'error|lyxc:' "$TMP/$name.log")"; return
  fi
  local got rc
  got=$( cd "$TMP" && timeout 20 "$TMP/$name" 2>&1 ); rc=$?
  if [ "$rc" -eq 0 ]; then no "$name" "laeuft durch (rc=0) — die Pruefung fiel aus"; return; fi
  if printf '%s' "$got" | grep -q "DANACH"; then
    no "$name" "rechnet nach dem Abbruch weiter"; return
  fi
  if printf '%s' "$got" | grep -q "$teil"; then
    ok "$name (rc=$rc: $(printf '%s' "$got" | tail -1))"
  else
    no "$name" "bricht ab, aber ohne '$teil' — '$(printf '%s' "$got" | tail -1)'"
  fi
}

# ------------------------------------------------------------------
# A. Am Erzeugnis: die beiden Formen stehen wirklich im Code.
# ------------------------------------------------------------------
cat > "$TMP/zs.lyx" <<'LYX'
unit main;
import std.io;
fn zaehl(n: int64): int64 {
  var s: int64 := 0;
  var i: int64 := 0;
  while (i < n) { s := s + i; i := i + 1; }
  return s;
}
fn main(): int64 { PrintInt(zaehl(10)); PrintStr("\n"c); return 0; }
LYX
if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/zs.lyx" -o "$TMP/zs" --map-file >"$TMP/zs.log" 2>&1); then
  no "erzeugnis" "uebersetzt nicht: $(grep -m1 -iE 'error|lyxc:' "$TMP/zs.log")"
elif ! command -v objdump >/dev/null 2>&1; then
  echo "HINWEIS: objdump fehlt, Pruefung am Erzeugnis entfaellt"
else
  # Spalte 1 der Karte ist die VIRTUELLE Adresse; der Datei-Versatz fuer
  # `objdump -b binary` ist Adresse minus Ladebasis (statisches ELF,
  # 0x400000). Spalte 2 ist .text-relativ und laege 176 Byte daneben.
  VON=$(awk '$NF=="zaehl"{printf "%d", strtonum($1) - 4194304}' "$TMP/zs.map" | head -1)
  BIS=$(awk -v v="$VON" '$NF!="zaehl" && NF>=4 {o=strtonum($1) - 4194304; if (o>v) print o}' \
        "$TMP/zs.map" | sort -n | head -1)
  if [ -z "$VON" ] || [ -z "$BIS" ]; then
    no "erzeugnis" "zaehl nicht in der Karte gefunden"
  else
    DIS=$(objdump -D -z -b binary -m i386:x86-64 --no-show-raw-insn \
            --start-address="$VON" --stop-address="$BIS" "$TMP/zs" 2>/dev/null)
    # Inkrement unmittelbar auf r12..r15 — vor dem Fix ging es immer ueber rax,
    # diese Form kam also gar nicht vor.
    NI=$(printf '%s\n' "$DIS" | grep -cE 'add +\$0x1,%r1[2-5]$')
    if [ "$NI" -ge 1 ]; then ok "erzeugnis: Inkrement auf dem Register ($NI Vorkommen)"
    else no "erzeugnis Inkrement" "kein 'add \$0x1,%r1[2-5]' — Umweg ueber rax noch da"; fi
    # Vergleich zwischen ZWEI erweiterten Registern; vorher stand links rax.
    NC=$(printf '%s\n' "$DIS" | grep -cE 'cmp +%r1[2-5],%r1[2-5]$')
    if [ "$NC" -ge 1 ]; then ok "erzeugnis: Vergleich Register gegen Register ($NC Vorkommen)"
    else no "erzeugnis Vergleich" "kein 'cmp %r1x,%r1x' — Umweg ueber rax noch da"; fi
  fi
fi

# ------------------------------------------------------------------
# B. Am Wert.
# ------------------------------------------------------------------

# 1. Zaehlschleifen: Schrittweite 1, groesser als imm8, groesser als imm32
#    (dort muss der Schnellweg ausfallen) und abwaerts. Erwartungswerte von
#    Hand gegengerechnet.
fall zaehlen "45 10 2000 20 6442450944 2 0 -5" <<'LYX'
unit main;
import std.io;
fn main(): int64 {
  // Summe 0+1+..+9 = 45 bei 10 Durchlaeufen
  var s: int64 := 0;  var i: int64 := 0;  var n: int64 := 10;
  var d: int64 := 0;
  while (i < n) { s := s + i; i := i + 1; d := d + 1; }
  PrintInt(s); PrintStr("\n"c);
  PrintInt(d); PrintStr("\n"c);
  // Schrittweite 100 > imm8: 0,100,..,1900 -> 20 Schritte, Summe 19000?
  // gegengerechnet: 100*(0+1+..+19) = 100*190 = 19000; hier nur der Zaehler
  // und die Endsumme der Schritte.
  var j: int64 := 0;  var c2: int64 := 0;
  while (j < 2000) { j := j + 100; c2 := c2 + 1; }
  PrintInt(j); PrintStr("\n"c);     // 2000
  PrintInt(c2); PrintStr("\n"c);    // 20
  // Schrittweite 3221225472 > imm32 (2147483647): der Schnellweg faellt aus,
  // der allgemeine Weg muss dasselbe rechnen. 2 * 3221225472 = 6442450944
  var g: int64 := 0;  var c3: int64 := 0;
  while (g < 6000000000) { g := g + 3221225472; c3 := c3 + 1; }
  PrintInt(g); PrintStr("\n"c);     // 6442450944
  PrintInt(c3); PrintStr("\n"c);    // 2
  // Abwaerts mit negativer Schrittweite
  var k: int64 := 10;
  while (k > 0) { k := k - 2; }
  PrintInt(k); PrintStr("\n"c);     // 0
  var m: int64 := 5;
  while (m > -5) { m := m - 1; }
  PrintInt(m); PrintStr("\n"c);     // -5
  return 0;
}
LYX

# 2. Vergleichsrichtung. Alle sechs Vergleiche zwischen zwei int64-Locals,
#    JEDE in beiden Operandenreihenfolgen — ein verwechseltes Registerfeld
#    dreht genau das um und faellt sonst nirgends auf.
#    a := 3, b := 7.
fall vergleich "1 0 1 0 0 1 0 1 0 1 1 0" <<'LYX'
unit main;
import std.io;
fn z(b: bool): int64 { if (b) { return 1; } return 0; }
fn main(): int64 {
  var a: int64 := 3;
  var b: int64 := 7;
  PrintInt(z(a < b)); PrintStr("\n"c);    // 3 < 7  -> 1
  PrintInt(z(b < a)); PrintStr("\n"c);    // 7 < 3  -> 0
  PrintInt(z(a <= b)); PrintStr("\n"c);   // 1
  PrintInt(z(b <= a)); PrintStr("\n"c);   // 0
  PrintInt(z(a > b)); PrintStr("\n"c);    // 0
  PrintInt(z(b > a)); PrintStr("\n"c);    // 1
  PrintInt(z(a >= b)); PrintStr("\n"c);   // 0
  PrintInt(z(b >= a)); PrintStr("\n"c);   // 1
  PrintInt(z(a == b)); PrintStr("\n"c);   // 0
  PrintInt(z(a != b)); PrintStr("\n"c);   // 1
  var c: int64 := 3;
  PrintInt(z(a == c)); PrintStr("\n"c);   // 1
  PrintInt(z(a != c)); PrintStr("\n"c);   // 0
  return 0;
}
LYX

# 3. Gegenseite Verschmaelerung: ein SCHMALER Typ darf den Schnellweg nicht
#    nehmen, sonst entfaellt das Abschneiden. int32 laeuft bei 2147483647 + 1
#    auf -2147483648 ueber; der Schnellweg wuerde 2147483648 stehen lassen.
fall schmal "-2147483648 -32768 -128 2147483647" <<'LYX'
unit main;
import std.io;
fn main(): int64 {
  var a: int32 := 2147483647;
  a := a + 1;
  PrintInt(a as int64); PrintStr("\n"c);     // -2147483648
  var b: int16 := 32767;
  b := b + 1;
  PrintInt(b as int64); PrintStr("\n"c);     // -32768
  var c: int8 := 127;
  c := c + 1;
  PrintInt(c as int64); PrintStr("\n"c);     // -128
  // int64 daneben: KEIN Abschneiden, der Schnellweg greift hier.
  var d: int64 := 2147483646;
  d := d + 1;
  PrintInt(d); PrintStr("\n"c);              // 2147483647
  return 0;
}
LYX

# 4. Gegenseite Bereichstyp: der Typname ist `Alt`, nicht `int64` — der
#    Schnellweg faellt aus und die Laufzeitpruefung bleibt wirksam.
bricht_ab bereich "Bereichstyp Alt" <<'LYX'
unit main;
import std.io;
type Alt = int64 range 0..100;
fn main(): int64 {
  var a: Alt := 99;
  var i: int64 := 0;
  while (i < 5) { a := a + 1; i := i + 1; }
  PrintStr("DANACH\n"c);
  PrintInt(a as int64); PrintStr("\n"c);
  return 0;
}
LYX

# 5. Gegenseite Ueberlaufpruefung: mit @overflow_check(true) braucht das
#    Ergebnis den allgemeinen Weg samt Panik-Zweig.
bricht_ab ueberlauf "" <<'LYX'
unit main;
import std.io;
@overflow_check(true);
fn main(): int64 {
  var a: int64 := 9223372036854775807;
  a := a + 1;
  PrintStr("DANACH\n"c);
  PrintInt(a); PrintStr("\n"c);
  return 0;
}
LYX

# 6. Verschiedene Locals: `x := y + 1` darf nicht als Inkrement von x gelten.
fall fremd "8 7 3 4" <<'LYX'
unit main;
import std.io;
fn main(): int64 {
  var x: int64 := 1;
  var y: int64 := 7;
  x := y + 1;
  PrintInt(x); PrintStr("\n"c);   // 8, nicht 2
  PrintInt(y); PrintStr("\n"c);   // 7 unberuehrt
  // und umgekehrt, mit einem Local als Summanden statt einer Konstante
  var p: int64 := 1;
  var q: int64 := 2;
  p := p + q;
  PrintInt(p); PrintStr("\n"c);   // 3
  p := p + 1;
  PrintInt(p); PrintStr("\n"c);   // 4
  return 0;
}
LYX

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
