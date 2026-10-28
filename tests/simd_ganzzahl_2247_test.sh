#!/usr/bin/env bash
# tests/simd_ganzzahl_2247_test.sh — #2247 Hebel 1: `parallel Array` traegt
# Ganzzahlen.
#
# Bis 1.2.24D nahm die Form nur f32 und f64; Ganzzahlarten wies sema ab
# (#2199/#2224), weil die Ablage keine Schrittweite und die Vektorschleife
# keine Operation dafuer hatte. Beides gibt es jetzt:
#
#   +  int8/16/32/64   PADDB/W/D/Q   bzw. NEON ADD   (baseline)
#   -  int8/16/32/64   PSUBB/W/D/Q        NEON SUB   (baseline)
#   *  int16           PMULLW             NEON MUL   (baseline)
#   *  int32           PMULLD             NEON MUL   (braucht sse4)
#
# NICHT umgesetzt, weil die CPU keinen Befehl hat, und deshalb in sema
# abgewiesen statt emuliert: `*` fuer int8 und int64, `/` und `%` fuer jede
# Ganzzahlbreite. Das wird hier mitgeprueft — eine Umsetzung, die still
# etwas anderes rechnet, waere der teure Fall.
#
# Vier Dinge, auf die dieser Test besonders achtet:
#
#   1. JEDE Breite einzeln. int32 ist der truegerische Fall: seine
#      Schrittweite ist 4 und entspricht damit der alten f32-Annahme — er
#      war schon richtig, als int8/int16/int64 noch falsch lagen. Ein Test
#      nur mit int32 haette die Luecke nicht gesehen.
#   2. Werte am RAND der Breite (127, 32767, 2147483647). Nur dort zeigt
#      sich, ob wirklich abgeschnitten und vorzeichenerweitert wird; mit
#      kleinen Zahlen ist jede Breite gruen.
#   3. Mehr Elemente als ein Vektorblock fasst. 16 Byte sind vier int32,
#      aber sechzehn int8 — mit zu wenigen Elementen laeuft der REST-
#      Durchgang nie, und der ist fuer Ganzzahlen eigener Code
#      (Allzweckregister statt der skalaren SSE-Form).
#   4. Beide Ziele, die den Vektorweg haben, mit DENSELBEN Werten. Zwei
#      Fehler dieser Arbeit sassen im gemeinsamen IR und waren auf x86
#      unsichtbar, weil der Schnellweg dort nicht vorbeikommt: der Wert
#      wurde unbedingt nach f64 gewandelt, und jeder Indexzugriff galt als
#      Gleitkomma-Ausdruck (`as int64` machte daraus ein FCVTZS, aus der
#      abgelegten 7 wurde 0). Beides fiel erst auf arm64 auf.
#
# lyxos laeuft lokal nicht (braucht den Kernel; der LBF-Lader liefert
# Syscall-Ergebnisse in rax statt rdx) und wird am ERZEUGNIS geprueft.
# riscv hat keinen Vektorweg und weist `parallel Array` laut ab (#1339,
# vorbestehend) — es wird hier deshalb nicht gemessen, und die Abweisung
# wird AUCH NICHT zugesichert: sonst wuerde dieser Test rot, sobald riscv
# einen Vektorweg bekommt.

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

fall() { # name erwartet [zusatzschalter]   (Quelle auf stdin)
  local name="$1" erw="$2" extra="$3"
  cat > "$TMP/$name.lyx"
  local z
  for z in $ZIELE; do
    local opt="" q=""
    [ "$z" = arm64 ] && { opt="--target=arm64"; q="$QEMU_ARM64"; }
    if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" $opt $extra "$TMP/$name.lyx" -o "$TMP/$name.$z" >"$TMP/$name.$z.log" 2>&1); then
      no "$name $z" "uebersetzt nicht: $(grep -m1 -iE 'error|lyxc:' "$TMP/$name.$z.log")"; continue
    fi
    local got
    got=$( cd "$TMP" && timeout 60 $q "$TMP/$name.$z" 2>&1 | tr '\n' ' ' ); got="${got% }"
    if [ "$got" = "$erw" ]; then ok "$name $z: $got"; else no "$name $z" "'$got' erwartet '$erw'"; fi
  done
}

weist_ab() { # name, teilstring der meldung   (Quelle auf stdin)
  local name="$1" teil="$2"
  cat > "$TMP/$name.lyx"
  if (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/$name.lyx" -o "$TMP/$name" >"$TMP/$name.log" 2>&1); then
    no "$name" "uebersetzt durch — es gibt keinen Befehl dafuer, das muesste gemeldet werden"
  elif grep -q "$teil" "$TMP/$name.log"; then
    ok "$name"
  else
    no "$name" "abgewiesen, aber mit anderer Meldung: $(grep -m1 -iE 'error' "$TMP/$name.log" | head -c 90)"
  fi
}

# ------------------------------------------------------------------
# A. Addition je Breite, Werte am Rand, mehr Elemente als ein Block.
#    Gegengerechnet: der Rand plus 1 kippt ins Negative, die anderen
#    Elemente ebenso (alle tragen denselben Wert).
# ------------------------------------------------------------------
fall add_int8 "-128 -128 -128" <<'LYX'
unit main;
import std.io;
fn main(): int64 {
  var a: parallel Array<int8> = parallel Array<int8>(20);
  var b: parallel Array<int8> = parallel Array<int8>(20);
  var i: int64 := 0;
  while (i < 20) { a[i] := 127; b[i] := 1; i := i + 1; }
  var c: parallel Array<int8> = a + b;
  PrintInt(c[0] as int64); PrintStr(" "c);
  PrintInt(c[15] as int64); PrintStr(" "c);
  PrintInt(c[19] as int64); PrintStr("\n"c);
  return 0;
}
LYX

fall add_int16 "-32768 -32768 -32768" <<'LYX'
unit main;
import std.io;
fn main(): int64 {
  var a: parallel Array<int16> = parallel Array<int16>(11);
  var b: parallel Array<int16> = parallel Array<int16>(11);
  var i: int64 := 0;
  while (i < 11) { a[i] := 32767; b[i] := 1; i := i + 1; }
  var c: parallel Array<int16> = a + b;
  PrintInt(c[0] as int64); PrintStr(" "c);
  PrintInt(c[7] as int64); PrintStr(" "c);
  PrintInt(c[10] as int64); PrintStr("\n"c);
  return 0;
}
LYX

fall add_int32 "-2147483648 -2147483648 -2147483648" <<'LYX'
unit main;
import std.io;
fn main(): int64 {
  var a: parallel Array<int32> = parallel Array<int32>(7);
  var b: parallel Array<int32> = parallel Array<int32>(7);
  var i: int64 := 0;
  while (i < 7) { a[i] := 2147483647; b[i] := 1; i := i + 1; }
  var c: parallel Array<int32> = a + b;
  PrintInt(c[0] as int64); PrintStr(" "c);
  PrintInt(c[3] as int64); PrintStr(" "c);
  PrintInt(c[6] as int64); PrintStr("\n"c);
  return 0;
}
LYX

# int64 traegt Werte, die in 32 Bit NICHT passen — genau der Fall, den die
# alte 4-Byte-Ablage still halbiert hat (#2199).
fall add_int64 "1000000000001 1000000000001 1000000000001" <<'LYX'
unit main;
import std.io;
fn main(): int64 {
  var a: parallel Array<int64> = parallel Array<int64>(5);
  var b: parallel Array<int64> = parallel Array<int64>(5);
  var i: int64 := 0;
  while (i < 5) { a[i] := 1000000000000; b[i] := 1; i := i + 1; }
  var c: parallel Array<int64> = a + b;
  PrintInt(c[0] as int64); PrintStr(" "c);
  PrintInt(c[2] as int64); PrintStr(" "c);
  PrintInt(c[4] as int64); PrintStr("\n"c);
  return 0;
}
LYX

# ------------------------------------------------------------------
# B. Subtraktion und Multiplikation. Je Element ein ANDERER Wert, damit
#    eine vertauschte Schrittweite auffaellt — mit gleichen Werten
#    ueberall waere ein Zugriff an der falschen Stelle unsichtbar.
# ------------------------------------------------------------------
fall sub_int8 "50 35 31" <<'LYX'
unit main;
import std.io;
fn main(): int64 {
  var a: parallel Array<int8> = parallel Array<int8>(20);
  var b: parallel Array<int8> = parallel Array<int8>(20);
  var i: int64 := 0;
  while (i < 20) { a[i] := 50; b[i] := i; i := i + 1; }
  var c: parallel Array<int8> = a - b;
  PrintInt(c[0] as int64); PrintStr(" "c);
  PrintInt(c[15] as int64); PrintStr(" "c);
  PrintInt(c[19] as int64); PrintStr("\n"c);
  return 0;
}
LYX

# 100*7 = 700, 104*7 = 728, 108*7 = 756 — von Hand gegengerechnet.
fall mul_int16 "700 728 756" <<'LYX'
unit main;
import std.io;
fn main(): int64 {
  var a: parallel Array<int16> = parallel Array<int16>(9);
  var b: parallel Array<int16> = parallel Array<int16>(9);
  var i: int64 := 0;
  while (i < 9) { a[i] := 100 + i; b[i] := 7; i := i + 1; }
  var c: parallel Array<int16> = a * b;
  PrintInt(c[0] as int64); PrintStr(" "c);
  PrintInt(c[4] as int64); PrintStr(" "c);
  PrintInt(c[8] as int64); PrintStr("\n"c);
  return 0;
}
LYX

# 1000*3 = 3000, 1004*3 = 3012, 1006*3 = 3018.
#
# Die 32-Bit-Multiplikation braucht PMULLD und damit sse4; auf arm64 ist
# NEON MUL Grundbestand, der Schalter stoert dort nicht. Die Gegenprobe
# darunter zeigt, dass es OHNE die Zusage gemeldet wird — ein stiller
# Rueckfall auf etwas Langsameres waere nach #2191 genau falsch.
fall mul_int32 "3000 3012 3018" "--target-cpu=sse4" <<'LYX'
unit main;
import std.io;
fn main(): int64 {
  var a: parallel Array<int32> = parallel Array<int32>(7);
  var b: parallel Array<int32> = parallel Array<int32>(7);
  var i: int64 := 0;
  while (i < 7) { a[i] := 1000 + i; b[i] := 3; i := i + 1; }
  var c: parallel Array<int32> = a * b;
  PrintInt(c[0] as int64); PrintStr(" "c);
  PrintInt(c[4] as int64); PrintStr(" "c);
  PrintInt(c[6] as int64); PrintStr("\n"c);
  return 0;
}
LYX

# ------------------------------------------------------------------
# C. Element lesen und schreiben, ohne Vektoroperation. Das ist der Weg,
#    der bei int8/int16 an der falschen Stelle las (Schrittweite 4) und
#    bei int64 die obere Haelfte verlor.
# ------------------------------------------------------------------
fall elemzugriff "7 -1 9 -1 300 -1 5000000000 -1" <<'LYX'
unit main;
import std.io;
fn main(): int64 {
  var a: parallel Array<int8> = parallel Array<int8>(8);
  a[0] := 7; a[7] := 0 - 1;
  PrintInt(a[0] as int64); PrintStr(" "c); PrintInt(a[7] as int64); PrintStr(" "c);
  var b: parallel Array<int16> = parallel Array<int16>(8);
  b[0] := 9; b[7] := 0 - 1;
  PrintInt(b[0] as int64); PrintStr(" "c); PrintInt(b[7] as int64); PrintStr(" "c);
  var c: parallel Array<int32> = parallel Array<int32>(8);
  c[0] := 300; c[7] := 0 - 1;
  PrintInt(c[0] as int64); PrintStr(" "c); PrintInt(c[7] as int64); PrintStr(" "c);
  var d: parallel Array<int64> = parallel Array<int64>(8);
  d[0] := 5000000000; d[7] := 0 - 1;
  PrintInt(d[0] as int64); PrintStr(" "c); PrintInt(d[7] as int64); PrintStr("\n"c);
  return 0;
}
LYX

# ------------------------------------------------------------------
# D. Gegenseite: was die CPU nicht kann, wird GEMELDET.
# ------------------------------------------------------------------
# Ohne sse4 gibt es PMULLD nicht — und das wird gemeldet, nicht umgangen.
# Diese Probe ist die zweite Haelfte des Falls darueber: sie zeigt, dass die
# Zusage wirklich verlangt wird und nicht nur mitgenommen.
weist_ab mul_int32_ohne_sse4 "braucht sse4" <<'LYX'
unit main;
fn main(): int64 {
  var a: parallel Array<int32> = parallel Array<int32>(7);
  var b: parallel Array<int32> = parallel Array<int32>(7);
  var c: parallel Array<int32> = a * b;
  return 0;
}
LYX

weist_ab mul_int8_weg "nur fuer int16 und int32" <<'LYX'
unit main;
fn main(): int64 {
  var a: parallel Array<int8> = parallel Array<int8>(4);
  var b: parallel Array<int8> = parallel Array<int8>(4);
  var c: parallel Array<int8> = a * b;
  return 0;
}
LYX

weist_ab mul_int64_weg "nur fuer int16 und int32" <<'LYX'
unit main;
fn main(): int64 {
  var a: parallel Array<int64> = parallel Array<int64>(4);
  var b: parallel Array<int64> = parallel Array<int64>(4);
  var c: parallel Array<int64> = a * b;
  return 0;
}
LYX

weist_ab div_weg "Division und Restrechnung" <<'LYX'
unit main;
fn main(): int64 {
  var a: parallel Array<int32> = parallel Array<int32>(4);
  var b: parallel Array<int32> = parallel Array<int32>(4);
  var c: parallel Array<int32> = a / b;
  return 0;
}
LYX

weist_ab mod_weg "Division und Restrechnung" <<'LYX'
unit main;
fn main(): int64 {
  var a: parallel Array<int32> = parallel Array<int32>(4);
  var b: parallel Array<int32> = parallel Array<int32>(4);
  var c: parallel Array<int32> = a % b;
  return 0;
}
LYX

# Gleitkomma bleibt unberuehrt — die Multiplikation, die fuer int8 gemeldet
# wird, muss fuer f32 weiter rechnen. Ohne diese Gegenprobe koennte die
# Abweisung zu weit greifen.
fall f32_unberuehrt "6.00" <<'LYX'
unit main;
import std.io;
fn main(): int64 {
  var a: parallel Array<f32> = parallel Array<f32>(8);
  var b: parallel Array<f32> = parallel Array<f32>(8);
  a[0] := 1.5; b[0] := 4.0;
  var c: parallel Array<f32> = a * b;
  PrintLn(FloatToStr(c[0], 2));
  return 0;
}
LYX

# ------------------------------------------------------------------
# E. lyxos am Erzeugnis: die Ganzzahlbefehle stehen drin, die
#    Gleitkommaform nicht — und umgekehrt bei f32.
# ------------------------------------------------------------------
lyxosmuster() { # name, typ, hex, soll-vorhanden(1/0)
  local name="$1" typ="$2" hex="$3" soll="$4"
  cat > "$TMP/lo.lyx" <<LYXEOF
unit main;
fn rechne(a: parallel Array<$typ>, b: parallel Array<$typ>): int64 {
  var c: parallel Array<$typ> = a + b;
  return c[0] as int64;
}
fn main(): int64 { return 0; }
LYXEOF
  if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" --target=lyxos "$TMP/lo.lyx" -o "$TMP/lo" >"$TMP/lo.log" 2>&1); then
    no "$name" "uebersetzt nicht: $(grep -m1 -iE 'error|Opcode' "$TMP/lo.log" | head -c 90)"; return
  fi
  local n
  n=$(xxd -p "$TMP/lo" | tr -d '\n' | grep -c "$hex")
  if [ "$soll" = "1" ] && [ "$n" -ge 1 ]; then ok "$name"
  elif [ "$soll" = "0" ] && [ "$n" -eq 0 ]; then ok "$name"
  else no "$name" "Muster $hex: $n Fundstellen, erwartet $([ "$soll" = 1 ] && echo "mindestens eine" || echo keine)"; fi
}

if ! command -v xxd >/dev/null 2>&1; then
  echo "HINWEIS: xxd fehlt, lyxos-Pruefung am Erzeugnis entfaellt"
else
  lyxosmuster "lyxos int32: PADDD (66 0F FE)"        int32 "660ffe" 1
  lyxosmuster "lyxos int32: MOVDQA (66 0F 6F)"       int32 "660f6f" 1
  lyxosmuster "lyxos int32: KEIN ADDPS (0F 58 C1)"   int32 "0f58c1" 0
  lyxosmuster "lyxos int8: PADDB (66 0F FC)"         int8  "660ffc" 1
  lyxosmuster "lyxos int64: PADDQ (66 0F D4)"        int64 "660fd4" 1
  # Gegenrichtung: mit f32 stehen die Ganzzahlbefehle NICHT drin. Ohne diese
  # Probe waere auch eine Fassung gruen, die immer PADDD erzeugt.
  lyxosmuster "lyxos f32: ADDPS vorhanden"           f32   "0f58c1" 1
  lyxosmuster "lyxos f32: KEIN PADDD"                f32   "660ffe" 0
fi

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
