#!/usr/bin/env bash
# tests/stdlib_rechnen_test.sh — #1454, #1458, #1449, #1465, #1460, #1462,
#                                #1463, #1456, #1457.
#
# Neun Meldungen aus sieben Units. Der gemeinsame Nenner: es kommt ein
# plausibler Wert zurück, nur der falsche.
#
#   #1454  PgpArmorEncode ignoriert outMax → Heap-Overflow
#   #1458  SortInt64 sortiert falsch (448 von 500 Zufallsarrays)
#   #1449  ExpF64/LogF64/Log10F64/PowF64 ohne Argumentreduktion
#   #1465  SECOND ist in Mikrosekunden, Sleep will Millisekunden
#   #1460  ArgvGet prüft den Index nicht → liest die Umgebung
#   #1462  PackFloat64 speichert die gerundete Zahl statt der IEEE-Bits
#   #1463  WriteVarInt zerstört negative Werte
#   #1456  SafeDiv(MIN, -1) → SIGFPE
#   #1457  UnwrapOrElse liefert die Codeadresse statt des Aufrufergebnisses
#
# ZUR AUSSAGEKRAFT: bei #1449 wird gegen python `math` gerechnet, nicht gegen
# selbst hingeschriebene Sollwerte. Bei #1458 laufen 500 Arrays durch, nicht
# eines — der Fehler traf ein bis zwei Elemente, ein einzelnes Beispiel kann
# ihn verfehlen. Bei #1454 wird der Nachbarblock geprüft, nicht der
# Rückgabewert.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/p.lyx"; rm -f "$TMP/p"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p" >/dev/null 2>&1; then
    no "$1" "uebersetzt nicht: $("$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p" 2>&1 | grep -i error | head -1)"
    return
  fi
  got="$(timeout 60 "$TMP/p" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then no "$1" "ABSTURZ (rc=$rc)"; return; fi
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1" "'$got' erwartet '$3'"; fi
}

# ===========================================================================
# #1458 — SortInt64
# ===========================================================================

# Das deterministische Beispiel aus der Meldung.
out "#1458: das Beispiel aus der Meldung sortiert" 'import std.io;
import std.sort;
import std.alloc;
import std.string;
fn zeige(arr: int64, n: int64): void {
  var i: int64 := 0; var s: pchar := "";
  while (i < n) { s := StrConcat(s, StrConcat(IntToStr(peek64(arr + i*8)), " ")); i := i + 1; }
  PrintLn(s);
}
fn main(): int64 {
  var w: int64 := alloc(10 * 8);
  poke64(w,    33); poke64(w+8,  18); poke64(w+16, 43); poke64(w+24,  7);
  poke64(w+32, 45); poke64(w+40,  8); poke64(w+48, 28); poke64(w+56, 15);
  poke64(w+64,  1); poke64(w+72, 35);
  SortInt64(w, 10);
  zeige(w, 10);
  return 0;
}' "1 7 8 15 18 28 33 35 43 45 "

# 500 Arrays wechselnder Laenge. Der Fehler traf ein bis zwei Elemente — ein
# einzelnes Beispiel kann ihn verfehlen, 500 nicht.
out "#1458: 500 Zufallsarrays sind sortiert und vollstaendig" 'import std.io;
import std.sort;
import std.alloc;
fn main(): int64 {
  var seed: int64 := 12345;
  var unsortiert: int64 := 0;
  var verloren: int64 := 0;
  var t: int64 := 0;
  while (t < 500) {
    var n: int64 := 5 + (t % 45);
    var a: int64 := alloc(n * 8);
    var summe: int64 := 0;
    var k: int64 := 0;
    while (k < n) {
      seed := (seed * 1103515245 + 12345) % 2147483648;
      var v: int64 := seed % 1000;
      poke64(a + k*8, v);
      summe := summe + v;
      k := k + 1;
    }
    SortInt64(a, n);
    var summe2: int64 := 0;
    k := 0;
    while (k < n) { summe2 := summe2 + peek64(a + k*8); k := k + 1; }
    if (summe != summe2) { verloren := verloren + 1; }
    k := 1;
    var schlecht: int64 := 0;
    while (k < n) {
      if (peek64(a + (k-1)*8) > peek64(a + k*8)) { schlecht := 1; }
      k := k + 1;
    }
    if (schlecht == 1) { unsortiert := unsortiert + 1; }
    free(a, n * 8);
    t := t + 1;
  }
  PrintStr(IntToStr(unsortiert)); PrintStr(" "); PrintLn(IntToStr(verloren));
  return 0;
}' "0 0"

# ===========================================================================
# #1454 — PgpArmorEncode
# ===========================================================================

out "#1454: zu kleiner Puffer meldet -1 und schreibt nichts" 'import std.io;
import std.pgp.core;
import std.pgp.armor;
import std.alloc;
import std.string;
fn main(): int64 {
  var len: int64 := 200;
  var data: int64 := alloc(len);
  var i: int64 := 0;
  while (i < len) { poke8(data + i, 65 + (i % 26)); i := i + 1; }
  var tiny: int64 := alloc(40);
  var guard: int64 := alloc(64);
  var j: int64 := 0;
  while (j < 64) { poke8(guard + j, 0xAA); j := j + 1; }
  PrintStr(IntToStr(PgpArmorEncode(data, len, PGP_ARMOR_MESSAGE, tiny, 40))); PrintStr(" ");
  var zerstoert: int64 := 0;
  j := 0;
  while (j < 64) { if (peek8(guard + j) != 0xAA) { zerstoert := zerstoert + 1; } j := j + 1; }
  PrintLn(IntToStr(zerstoert));
  return 0;
}' "-1 0"

# Mit ausreichendem Puffer muss es weiterhin gehen — und die vorab gerechnete
# Laenge muss stimmen, sonst waere die Pruefung entweder zu streng oder nutzlos.
out "#1454: passender Puffer, Laenge vorab richtig gerechnet" 'import std.io;
import std.pgp.core;
import std.pgp.armor;
import std.alloc;
import std.string;
fn main(): int64 {
  var len: int64 := 200;
  var data: int64 := alloc(len);
  var i: int64 := 0;
  while (i < len) { poke8(data + i, 65 + (i % 26)); i := i + 1; }
  var noetig: int64 := PgpArmorEncodedLen(len, PGP_ARMOR_MESSAGE);
  var big: int64 := alloc(noetig);
  var r: int64 := PgpArmorEncode(data, len, PGP_ARMOR_MESSAGE, big, noetig);
  PrintStr(IntToStr(noetig - r)); PrintStr(" ");
  PrintStr(IntToStr(StrLen(big as pchar) - r)); PrintStr(" ");
  PrintLn(IntToStr(PgpArmorEncode(data, len, PGP_ARMOR_MESSAGE, big, noetig - 1)));
  return 0;
}' "1 0 -1"

# ===========================================================================
# #1449 — Exp, Log, Pow
# ===========================================================================

# Gegen python gerechnet: dieselben Argumente, Abweichung unter 1e-6 relativ.
printf 'import std.io;\nimport std.math;\nfn z(v: f64): void { PrintStr(FloatToStr(v, 9)); PrintStr("\\n"); }\nfn main(): int64 {\n  z(ExpF64(1 as f64));\n  z(ExpF64(3 as f64));\n  z(ExpF64(5 as f64));\n  z(ExpF64(0 as f64 - (2 as f64)));\n  z(LogF64(3 as f64));\n  z(LogF64(10 as f64));\n  z(LogF64(100 as f64));\n  z(Log10F64(100 as f64));\n  z(PowF64(2 as f64, 10 as f64));\n  z(PowF64(2 as f64, 0.5));\n  return 0;\n}\n' > "$TMP/m.lyx"
if "$LYXC" --std-path="$ROOT" "$TMP/m.lyx" -o "$TMP/m" >/dev/null 2>&1; then
  ist="$("$TMP/m")"
  soll="$(python3 -c '
import math
for v in [math.exp(1), math.exp(3), math.exp(5), math.exp(-2),
          math.log(3), math.log(10), math.log(100), math.log10(100),
          2.0**10, 2.0**0.5]:
    print("%.9f" % v)')"
  schlecht="$(python3 - "$TMP/ist" <<PY
ist = """$ist""".split()
soll = """$soll""".split()
bad = []
for a, b in zip(ist, soll):
    fa, fb = float(a), float(b)
    if abs(fa - fb) > max(1e-6, abs(fb) * 1e-6):
        bad.append("%s!=%s" % (a, b))
print(" ".join(bad))
PY
)"
  if [ -z "$schlecht" ]; then ok "#1449: Exp/Log/Log10/Pow stimmen mit python (1e-6)"
  else no "#1449: Exp/Log/Log10/Pow stimmen mit python (1e-6)" "$schlecht"; fi
else
  no "#1449: Exp/Log/Log10/Pow stimmen mit python (1e-6)" "uebersetzt nicht"
fi

# Ganzzahlige Exponenten laufen ueber wiederholtes Quadrieren und muessen
# deshalb EXAKT sein — nicht nur nahe dran.
out "#1449: ganzzahlige Exponenten sind exakt" 'import std.io;
import std.math;
fn main(): int64 {
  PrintStr(FloatToStr(PowF64(2 as f64, 10 as f64), 1)); PrintStr(" ");
  PrintStr(FloatToStr(PowF64(3 as f64, 5 as f64), 1)); PrintStr(" ");
  PrintStr(FloatToStr(PowF64(2 as f64, 0 as f64 - (2 as f64)), 4)); PrintStr(" ");
  PrintLn(FloatToStr(PowF64(0 as f64 - (2 as f64), 3 as f64), 1));
  return 0;
}' "1024.0 243.0 0.2500 -8.0"

# ===========================================================================
# #1465 — die Einheit steht im Namen
# ===========================================================================

out "#1465: US_* und MS_* tragen ihre Einheit" 'import std.io;
import std.time;
fn main(): int64 {
  PrintStr(IntToStr(US_SECOND)); PrintStr(" ");
  PrintStr(IntToStr(MS_SECOND)); PrintStr(" ");
  PrintStr(IntToStr(US_MINUTE)); PrintStr(" ");
  PrintLn(IntToStr(MS_MINUTE));
  return 0;
}' "1000000 1000 60000000 60000"

# Der alte Name ist WEG, nicht bloss ergaenzt — sonst bliebe die Falle stehen.
printf 'import std.time;\nfn main(): int64 { return SECOND; }\n' > "$TMP/s.lyx"
rm -f "$TMP/s"
if "$LYXC" --std-path="$ROOT" "$TMP/s.lyx" -o "$TMP/s" >/dev/null 2>&1; then
  no "#1465: SECOND gibt es nicht mehr" "uebersetzt weiterhin"
else
  ok "#1465: SECOND gibt es nicht mehr"
fi

# Und Sleep tut mit MS_* das Erwartete: 50 ms sind messbar kurz.
out "#1465: Sleep(MS_SECOND / 20) kehrt zurueck" 'import std.io;
import std.time;
fn main(): int64 {
  var vorher: int64 := NowMs();
  Sleep(MS_SECOND / 20);
  var d: int64 := NowMs() - vorher;
  if (d >= 40 && d < 2000) { PrintLn("ok"); } else { PrintLn(IntToStr(d)); }
  return 0;
}' "ok"

# ===========================================================================
# #1460 — ArgvGet prueft den Index
# ===========================================================================

printf 'import std.io;\nimport std.env;\nfn main(): int64 {\n  PrintStr(IntToStr(GetArgC())); PrintStr(" ");\n  if ((ArgvGet(GetArgV(), 0) as int64) != 0) { PrintStr("ja "); } else { PrintStr("nein "); }\n  PrintStr(IntToStr(ArgvGet(GetArgV(), GetArgC()) as int64)); PrintStr(" ");\n  PrintStr(IntToStr(ArgvGet(GetArgV(), GetArgC() + 1) as int64)); PrintStr(" ");\n  PrintLn(IntToStr(ArgvGet(GetArgV(), 0 - 1) as int64));\n  return 0;\n}\n' > "$TMP/av.lyx"
if "$LYXC" --std-path="$ROOT" "$TMP/av.lyx" -o "$TMP/av" >/dev/null 2>&1; then
  got="$("$TMP/av" eins zwei 2>&1)"
  if [ "$got" = "3 ja 0 0 0" ]; then ok "#1460: jenseits von argc kommt 0, auch bei negativem Index"
  else no "#1460: jenseits von argc kommt 0, auch bei negativem Index" "$got"; fi
else
  no "#1460: jenseits von argc kommt 0, auch bei negativem Index" "uebersetzt nicht"
fi

# ===========================================================================
# #1462, #1463 — std.pack
# ===========================================================================

out "#1462: f64 und f32 ueberstehen den Rundlauf" 'import std.io;
import std.pack;
import std.alloc;
fn main(): int64 {
  var b: int64 := alloc(32);
  PackFloat64(b, 0, 3.5);          PrintStr(FloatToStr(UnpackFloat64(b, 0), 4)); PrintStr(" ");
  PackFloat64(b, 0, 0.0 - 0.125);  PrintStr(FloatToStr(UnpackFloat64(b, 0), 4)); PrintStr(" ");
  PackFloat32(b, 0, 3.5);          PrintStr(FloatToStr(UnpackFloat32(b, 0), 4)); PrintStr(" ");
  PackFloat32(b, 0, 0.0 - 0.125);  PrintLn(FloatToStr(UnpackFloat32(b, 0), 4));
  return 0;
}' "3.5000 -0.1250 3.5000 -0.1250"

out "#1463: negative VarInts ueberstehen den Rundlauf" 'import std.io;
import std.pack;
import std.alloc;
fn p(v: int64): void {
  var b: int64 := alloc(32);
  WriteVarInt(b, 0, v);
  PrintStr(IntToStr(ReadVarInt(b, 0))); PrintStr(" ");
}
fn main(): int64 {
  p(0); p(1); p(127); p(128); p(300);
  p(0 - 1); p(0 - 127); p(0 - 1000000);
  PrintLn("");
  return 0;
}' "0 1 127 128 300 -1 -127 -1000000 "

# ===========================================================================
# #1456, #1457 — std.result
# ===========================================================================

out "#1456: MIN / -1 meldet Ueberlauf statt SIGFPE" 'import std.io;
import std.result;
fn main(): int64 {
  var mn: int64 := 0 - 9223372036854775807 - 1;
  var r: ResultInt64 := SafeDiv(mn, 0 - 1);
  if (r.success) { PrintStr("ok "); } else { PrintStr(IntToStr(r.error_code)); PrintStr(" "); }
  var r2: ResultInt64 := SafeMod(mn, 0 - 1);
  if (r2.success) { PrintStr("ok "); } else { PrintStr(IntToStr(r2.error_code)); PrintStr(" "); }
  var r3: ResultInt64 := SafeDiv(10, 3);
  PrintStr(IntToStr(r3.value)); PrintStr(" ");
  var r4: ResultInt64 := SafeDiv(10, 0);
  PrintLn(IntToStr(r4.error_code));
  return 0;
}' "5 5 3 4"

out "#1457: UnwrapOrElse ruft die Funktion" 'import std.io;
import std.result;
fn fallback(): int64 { return 4711; }
fn main(): int64 {
  var e: ResultInt64 := ErrInt64(4);
  PrintStr(IntToStr(ResultInt64UnwrapOrElse(e, fallback as int64))); PrintStr(" ");
  var o: ResultInt64 := OkInt64(7);
  PrintLn(IntToStr(ResultInt64UnwrapOrElse(o, fallback as int64)));
  return 0;
}' "4711 7"

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
