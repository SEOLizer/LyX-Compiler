#!/usr/bin/env bash
# tests/ir_argslots_test.sh — #1388: die IR-Strecke unter qemu MESSEN, nicht
# nur uebersetzen.
#
# Der fruehere Nachweis zu #1388 hat die erzeugten BYTES geprueft. Die Bytes
# entstanden auch — nur rechneten sie falsch:
#
#   * Aufrufargumente lagen in den Slots 0..N, wo die Parameter und
#     Temporaeren der Funktion selbst liegen. `fn f(p) { StrLen("abcd"c); return p; }`
#     lieferte fuer f(9) den Wert 44.
#   * peek/poke lasen Slot 0 statt des hohen Argumentblocks, den ir_lower
#     seit #839 benutzt — auf arm64 ein Segfault bei jedem peek8.
#   * `"abc"c` war vier Zeichen lang: die Laenge rechnete mit zwei
#     Anfuehrungszeichen und uebersah das `c` dahinter.
#   * STUR/LDUR kuerzten Offsets ausserhalb von simm9 still auf neun Bit —
#     ab Slot 32 traf der Zugriff eine fremde Stelle.
#
# Gemessen wird deshalb mit qemu-aarch64: der Rueckgabewert des Programms ist
# das Ergebnis der Rechnung.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$ROOT/tests/lib/lyxc_guard.sh"; [ -f "$_g" ] && . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1${2:+: $2}"; FAIL=$((FAIL+1)); }

QEMU=""
command -v qemu-aarch64-static >/dev/null 2>&1 && QEMU=qemu-aarch64-static
command -v qemu-aarch64 >/dev/null 2>&1 && [ -z "$QEMU" ] && QEMU=qemu-aarch64
if [ -z "$QEMU" ]; then
  echo "SKIP qemu-aarch64 nicht vorhanden — ohne Laufzeit misst dieser Test nichts"
  echo "----"; echo "0 PASS, 0 FAIL"; exit 0
fi

lauf() {   # Name, Quelle, erwarteter Rueckgabewert
  printf '%s' "$2" > "$TMP/t.lyx"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/t.lyx" --target=arm64 -o "$TMP/t" >"$TMP/t.log" 2>&1; then
    no "$1 uebersetzt" "$(grep -iE 'error|unbekannt' "$TMP/t.log" | head -1)"
    return
  fi
  "$QEMU" "$TMP/t" >/dev/null 2>"$TMP/t.err"
  local rc=$?
  if [ "$rc" = "$3" ]; then
    ok "$1 (= $3)"
  else
    no "$1" "erwartet $3, erhalten $rc$( [ $rc -ge 128 ] && echo ' (Signal)' )"
  fi
}

# ---- Der Kern: ein Builtin darf die Parameter nicht zerstoeren --------------
lauf "Parameter ueberlebt StrLen" 'fn f(p: int64): int64 {
  var s: pchar := "abcd"c;
  var l: int64 := StrLen(s);
  return p;
}
fn main(): int64 { return f(9); }' 9

lauf "zwei Parameter ueberleben zwei Builtins" 'fn g(a: int64, b: int64): int64 {
  var s: pchar := "xy"c;
  var l1: int64 := StrLen(s);
  var l2: int64 := StrLen("zzz"c);
  return a * 10 + b + l1 + l2;
}
fn main(): int64 { return g(3, 4); }' 39

lauf "lokale Werte ueberleben ein Builtin" 'fn main(): int64 {
  var a: int64 := 5;
  var b: int64 := 6;
  var l: int64 := StrLen("abc"c);
  return a + b + l;
}' 14

# ---- Literallaenge: das `c`-Suffix gehoert nicht zum Text -------------------
lauf "StrLen eines pchar-Literals"      'fn main(): int64 { return StrLen("abc"c); }' 3
lauf "StrLen eines langen Literals"     'fn main(): int64 { return StrLen("abcdefgh"c); }' 8
lauf "hinter dem Text steht die Null"   'fn main(): int64 {
  var s: pchar := "abc"c;
  return StrCharAt(s, 3);
}' 0

# ---- peek/poke: Adresse aus dem hohen Argumentblock ------------------------
lauf "poke8 und peek8" 'import std.alloc;
fn main(): int64 {
  var p: int64 := alloc(64);
  poke8(p, 65);
  return peek8(p);
}' 65

lauf "poke64 und peek64" 'import std.alloc;
fn main(): int64 {
  var p: int64 := alloc(64);
  poke64(p, 4242);
  var v: int64 := peek64(p);
  return v - 4200;
}' 42

lauf "StrSetChar und StrCharAt" 'import std.alloc;
fn main(): int64 {
  var p: int64 := alloc(64);
  poke8(p, 65); poke8(p + 1, 66); poke8(p + 2, 0);
  StrSetChar(p as pchar, 1, 67);
  return StrCharAt(p as pchar, 1);
}' 67

# ---- IntToStr ---------------------------------------------------------------
lauf "IntToStr einstellig"  'fn main(): int64 { return StrLen(IntToStr(7)); }' 1
lauf "IntToStr siebenstellig" 'fn main(): int64 { return StrLen(IntToStr(1234567)); }' 7
lauf "IntToStr Null"        'fn main(): int64 {
  var s: pchar := IntToStr(0);
  if (StrLen(s) != 1) { return 1; }
  return StrCharAt(s, 0);
}' 48
lauf "IntToStr negativ"     'fn main(): int64 {
  var s: pchar := IntToStr(0 - 42);
  if (StrLen(s) != 3) { return 1; }
  if (StrCharAt(s, 0) != 45) { return 2; }
  if (StrCharAt(s, 1) != 52) { return 3; }
  return StrCharAt(s, 2);
}' 50
lauf "zwei IntToStr teilen keinen Puffer" 'fn main(): int64 {
  var a: pchar := IntToStr(11);
  var b: pchar := IntToStr(22);
  return StrCharAt(a, 0) + StrCharAt(b, 0);
}' 99

# ---- Tiefer Rahmen: Offsets jenseits von simm9 -----------------------------
# Ab Slot 32 liegt der Zugriff bei -264 und passt nicht mehr in simm9. Bis
# 1.1.5C wurde still gekuerzt; der Wert landete 512 Byte daneben.
lauf "Funktion mit 40 lebenden Werten" 'fn main(): int64 {
  var v01: int64 := 1;  var v02: int64 := 2;  var v03: int64 := 3;  var v04: int64 := 4;
  var v05: int64 := 5;  var v06: int64 := 6;  var v07: int64 := 7;  var v08: int64 := 8;
  var v09: int64 := 9;  var v10: int64 := 10; var v11: int64 := 11; var v12: int64 := 12;
  var v13: int64 := 13; var v14: int64 := 14; var v15: int64 := 15; var v16: int64 := 16;
  var v17: int64 := 17; var v18: int64 := 18; var v19: int64 := 19; var v20: int64 := 20;
  var v21: int64 := 21; var v22: int64 := 22; var v23: int64 := 23; var v24: int64 := 24;
  var v25: int64 := 25; var v26: int64 := 26; var v27: int64 := 27; var v28: int64 := 28;
  var v29: int64 := 29; var v30: int64 := 30; var v31: int64 := 31; var v32: int64 := 32;
  var v33: int64 := 33; var v34: int64 := 34; var v35: int64 := 35; var v36: int64 := 36;
  var v37: int64 := 37; var v38: int64 := 38; var v39: int64 := 39; var v40: int64 := 40;
  return v01 + v20 + v33 + v40;
}' 94

echo "----"
echo "$PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
