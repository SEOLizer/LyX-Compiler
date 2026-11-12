#!/usr/bin/env bash
# tests/strsplit_ir_2305_test.sh — #2305: StrSplit liefert auf ALLEN Zielen
# dasselbe.
#
# Bis 1.2.25B gab `StrSplit(s, delim)` auf arm64 und riscv eine leere Liste
# zurueck — still, ohne jede Meldung. Nicht weil ein Builtin fehlte und in
# einen Catch-all fiel (der ist laut), sondern weil die VIER-Parameter-Fassung
# aus std/string.lyx gerufen wurde:
#
#   pub fn StrSplit(s: pchar, delim: pchar, out: int64, maxParts: int64): int64
#
# Mit zwei uebergebenen Argumenten waren `out` und `maxParts` undefiniert, die
# Funktion schrieb ins Nichts und gab 0 zurueck. Auf x86 hielt die Weiche
# `cg_builtinArity` das ab; im IR-Weg fehlte der Name in der fbWant-Liste.
#
# Gemessen wird deshalb der WERT auf allen drei Zielen, nicht das Vorhandensein
# einer Umsetzung — eine leere Liste ist ein plausibles Ergebnis, das jeder
# Invariantentest durchgelassen haette ("len >= 0", "Felder sind Zeiger").
# Jeder Fall nennt mehr als ein Feld UND dessen Inhalt: eine Fassung, die nur
# das erste oder nur das letzte Feld traegt, faellt dadurch auf.
#
# Die Randfaelle sind die eigentliche Pruefung, weil sie die Zerlegung
# festnageln: leere Felder BLEIBEN erhalten (",a" -> "", "a"), die leere
# Eingabe ergibt ein leeres Feld, und ein leerer Trenner ergibt ein Feld mit
# der ganzen Zeichenkette (ohne diesen Sonderfall passt die leere Folge an
# jeder Stelle und die Schleife laeuft endlos).
#
# Dazu die Gegenseite: die VIER-Argument-Form muss weiter die Unit-Funktion
# aus std/string.lyx rufen. Ein Test, der nur die Zwei-Argument-Form prueft,
# waere auch von einer Senkung erfuellt, die jeden StrSplit-Aufruf abfaengt.

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

# ------------------------------------------------------------------
# A. Die Zerlegung selbst, Feld fuer Feld.
#
# Die Erwartungswerte sind am x86-Helfer `_lyx_strsplit` (CG_H_STRSPLIT)
# abgelesen, der seit WP-BI-05 unveraendert ist — nicht ausgedacht.
# ------------------------------------------------------------------
fall normal "len=3 [a] [bb] [ccc]" <<'LYX'
unit main;
import std.io;
fn main(): int64 {
  var t: pchar[] = StrSplit("a,bb,ccc"c, ","c);
  PrintStr("len="c); PrintInt(len(t));
  var i: int64 := 0;
  while (i < len(t)) { PrintStr(" ["c); PrintStr(t[i]); PrintStr("]"c); i := i + 1; }
  PrintStr("\n"c);
  return 0;
}
LYX

fall trenner_vorn "len=3 [] [a] [b]" <<'LYX'
unit main;
import std.io;
fn main(): int64 {
  var t: pchar[] = StrSplit(",a,b"c, ","c);
  PrintStr("len="c); PrintInt(len(t));
  var i: int64 := 0;
  while (i < len(t)) { PrintStr(" ["c); PrintStr(t[i]); PrintStr("]"c); i := i + 1; }
  PrintStr("\n"c);
  return 0;
}
LYX

fall trenner_hinten "len=3 [a] [b] []" <<'LYX'
unit main;
import std.io;
fn main(): int64 {
  var t: pchar[] = StrSplit("a,b,"c, ","c);
  PrintStr("len="c); PrintInt(len(t));
  var i: int64 := 0;
  while (i < len(t)) { PrintStr(" ["c); PrintStr(t[i]); PrintStr("]"c); i := i + 1; }
  PrintStr("\n"c);
  return 0;
}
LYX

fall trenner_doppelt "len=3 [a] [] [b]" <<'LYX'
unit main;
import std.io;
fn main(): int64 {
  var t: pchar[] = StrSplit("a,,b"c, ","c);
  PrintStr("len="c); PrintInt(len(t));
  var i: int64 := 0;
  while (i < len(t)) { PrintStr(" ["c); PrintStr(t[i]); PrintStr("]"c); i := i + 1; }
  PrintStr("\n"c);
  return 0;
}
LYX

fall trenner_fehlt "len=1 [abc]" <<'LYX'
unit main;
import std.io;
fn main(): int64 {
  var t: pchar[] = StrSplit("abc"c, ","c);
  PrintStr("len="c); PrintInt(len(t));
  var i: int64 := 0;
  while (i < len(t)) { PrintStr(" ["c); PrintStr(t[i]); PrintStr("]"c); i := i + 1; }
  PrintStr("\n"c);
  return 0;
}
LYX

fall eingabe_leer "len=1 []" <<'LYX'
unit main;
import std.io;
fn main(): int64 {
  var t: pchar[] = StrSplit(""c, ","c);
  PrintStr("len="c); PrintInt(len(t));
  var i: int64 := 0;
  while (i < len(t)) { PrintStr(" ["c); PrintStr(t[i]); PrintStr("]"c); i := i + 1; }
  PrintStr("\n"c);
  return 0;
}
LYX

fall nur_trenner "len=2 [] []" <<'LYX'
unit main;
import std.io;
fn main(): int64 {
  var t: pchar[] = StrSplit(","c, ","c);
  PrintStr("len="c); PrintInt(len(t));
  var i: int64 := 0;
  while (i < len(t)) { PrintStr(" ["c); PrintStr(t[i]); PrintStr("]"c); i := i + 1; }
  PrintStr("\n"c);
  return 0;
}
LYX

# Mehrbyte-Trenner: faellt eine Fassung auf, die dlen ignoriert und je Byte
# trennt (die hiesse hier len=5 mit leeren Feldern).
fall trenner_mehrbyte "len=3 [a] [b] [c]" <<'LYX'
unit main;
import std.io;
fn main(): int64 {
  var t: pchar[] = StrSplit("a::b::c"c, "::"c);
  PrintStr("len="c); PrintInt(len(t));
  var i: int64 := 0;
  while (i < len(t)) { PrintStr(" ["c); PrintStr(t[i]); PrintStr("]"c); i := i + 1; }
  PrintStr("\n"c);
  return 0;
}
LYX

# Leerer Trenner: ohne den Sonderfall passt die leere Folge an jeder Stelle.
# Steht der Fall nicht, laeuft das Programm in eine Endlosschleife und das
# `timeout` im Gestell meldet es.
fall trenner_leer "len=1 [abc]" <<'LYX'
unit main;
import std.io;
fn main(): int64 {
  var t: pchar[] = StrSplit("abc"c, ""c);
  PrintStr("len="c); PrintInt(len(t));
  var i: int64 := 0;
  while (i < len(t)) { PrintStr(" ["c); PrintStr(t[i]); PrintStr("]"c); i := i + 1; }
  PrintStr("\n"c);
  return 0;
}
LYX

# Mehr Felder als Finger: eine Fassung mit festem Puffer oder mit
# `maxParts`-Rest faellt hier auf.
fall viele_felder "len=12 [a] [l]" <<'LYX'
unit main;
import std.io;
fn main(): int64 {
  var t: pchar[] = StrSplit("a,b,c,d,e,f,g,h,i,j,k,l"c, ","c);
  PrintStr("len="c); PrintInt(len(t));
  PrintStr(" ["c); PrintStr(t[0]); PrintStr("]"c);
  PrintStr(" ["c); PrintStr(t[11]); PrintStr("]"c);
  PrintStr("\n"c);
  return 0;
}
LYX

# Verschachtelt: der innere Aufruf darf dem aeusseren die Slots nicht
# wegnehmen — dieselbe Falle wie bei StrConcat (#2028).
fall verschachtelt "len=2 [x] [y] innen=2" <<'LYX'
unit main;
import std.io;
fn main(): int64 {
  var a: pchar[] = StrSplit("x;y"c, ";"c);
  var b: pchar[] = StrSplit(StrConcat(a[0], ",z"c), ","c);
  PrintStr("len="c); PrintInt(len(a));
  PrintStr(" ["c); PrintStr(a[0]); PrintStr("]"c);
  PrintStr(" ["c); PrintStr(a[1]); PrintStr("]"c);
  PrintStr(" innen="c); PrintInt(len(b));
  PrintStr("\n"c);
  return 0;
}
LYX

# ------------------------------------------------------------------
# B. Die Gegenseite: die VIER-Argument-Form ist die Unit-Funktion aus
#    std/string.lyx und bleibt es. Sie schreibt in den uebergebenen Puffer
#    und gibt die Anzahl zurueck — eine Senkung, die jeden StrSplit-Aufruf
#    abfaengt, liefert hier etwas anderes.
# ------------------------------------------------------------------
fall vier_argumente "n=3 erstes=a drittes=c" <<'LYX'
unit main;
import std.io;
import std.string;
fn main(): int64 {
  var buf: int64 := alloc(8 * 8);
  var n: int64 := StrSplit("a,b,c"c, ","c, buf, 8);
  PrintStr("n="c); PrintInt(n);
  PrintStr(" erstes="c); PrintStr(peek64(buf) as pchar);
  PrintStr(" drittes="c); PrintStr(peek64(buf + 16) as pchar);
  PrintStr("\n"c);
  return 0;
}
LYX

echo "=== PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
