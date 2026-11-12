#!/usr/bin/env bash
# tests/bit_builtins_alle_ziele_test.sh — popcount/clz/ctz/rotl32/rotr32 auf
# den 32-Bit-Zielen esp32 (Xtensa) und arm-cm4 (Cortex-M4) (#2228, Punkt 4).
#
# Bis hierher brachen beide Backends bei Builtin-ID 255 … 262 laut ab
# (#1388). Beide halten einen int64-Wert als EIN 32-Bit-Wort, gelesen als
# Vorzeichenerweiterung — gemessen wird darum mit Eingaben in [-2^31, 2^31),
# fuer die das Ergebnis dem auf x86 GLEICHEN muss:
#
#   1. die WERTE: popcount/clz/ctz fuer zwoelf Eingaben (0, -1, INT32_MIN …)
#      gegen feste Erwartungen, rotl32/rotr32 fuer vier Eingaben und alle
#      Weiten -40..70 gegen eine Referenz aus Schieben und Maskieren. Dasselbe
#      Programm laeuft auf x86 (Bezug), arm-cm4 (qemu-system-arm, Semihosting)
#      und esp32 (qemu-xtensa ueber tests/lib/xtensa_huelle.py, Rueckgabewert);
#   2. dass bswap64/rotl/rotr auf beiden Zielen LAUT abgewiesen werden: ihr
#      Ergebnis hat auf einem 32-Bit-Wort keine Darstellung. Gemessen an der
#      Meldung (der Uebersetzer scheitert);
#   3. auf x86 den Weg fuer KONSTANTE Weiten (Rotation mit Direktwert, ohne
#      %cl) und dass er dieselben Werte liefert wie der allgemeine Weg.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
. "$(dirname "$0")/lib/qemu.sh"   # #2048
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ulimit -c 0
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

QARM="$(command -v qemu-system-arm || true)"
HUELLE="$ROOT/tests/lib/xtensa_huelle.py"

# pruefe() liefert 0, wenn alles stimmt, sonst die Nummer der ersten
# Abweichung (1..36 Einzelwerte, 37 = Rotationsfehler, 38 = Rotationsanzahl,
# 39..42 Rotations-Einzelwerte). Rueckgabewert statt Ausgabe, weil die
# Xtensa-Huelle nur den Exit-Code meldet.
#
# Erwartungen (int64 auf x86): popcount(-1) = 64, popcount(INT32_MIN) = 33
# (0xFFFFFFFF80000000), popcount(-0x12345678) = 32 + popcount(0xEDCBA988)
# = 49; clz(0) = ctz(0) = 64; clz negativer Werte 0.
python3 - "$TMP" <<'PY'
import sys
xs = [0, 1, -1, 255, 8, 0x7FFFFFFF, -2147483648, 0x12345678, -0x12345678, 0x10000, 0x40000000, -16]
def u(x): return x & 0xFFFFFFFFFFFFFFFF
def pc(x): return bin(u(x)).count('1')
def clz(x): return 64 - u(x).bit_length()
def ctz(x): return 64 if x == 0 else (u(x) & -u(x)).bit_length() - 1
lit = lambda v: str(v) if v >= 0 else "(0 - %d)" % (-v)
L = ["fn ref_rotl32(x: int64, n: int64): int64 {",
     "  var k: int64 := n & 31; var w: int64 := x & 0xFFFFFFFF;",
     "  if (k == 0) { return w; }",
     # #2236: vorzeichenlos schieben. Auf esp32/arm-cm ist int64 ein Wort;
     # `x & 0xFFFFFFFF` mit gesetztem Bit 31 ist dort NEGATIV, und `>>` auf
     # einem vorzeichenbehafteten Wert ist seit #2236 auf jedem Ziel
     # arithmetisch (vorher auf diesen Zielen still logisch).
     "  return ((w << k) | ((w as uint32) >> (32 - k))) & 0xFFFFFFFF;",
     "}",
     ]
# Je Rechenwerk eine eigene Funktion: auf xtensa erreicht L32I nur 255 Worte
# Rahmen (#2140, laut), eine einzige grosse Funktion uebersetzte dort nicht.
i = 1
for f, fn in (("popcount", pc), ("clz", clz), ("ctz", ctz)):
    L.append("fn pruefe_%s(): int64 {" % f)
    L.append("  var x: int64 := 0; var r: int64 := 0;")
    for x in xs:
        L.append("  x := %s; r := %s(x); if (r != %d) { return %d; }" % (lit(x), f, fn(x), i))
        i += 1
    L += ["  return 0;", "}"]
L += ["fn pruefe_rot(): int64 {", "  var x: int64 := 0; var r: int64 := 0;",
      "  var fehler: int64 := 0; var werte: int64 := 0; var xi: int64 := 0;",
      "  while (xi < 4) {",
      "    if (xi == 0) { x := 0x12345678; }",
      "    if (xi == 1) { x := 0 - 1698898191; }",
      "    if (xi == 2) { x := 1; }",
      "    if (xi == 3) { x := 0 - 2147483647 - 1; }",
      "    var n: int64 := 0 - 40;",
      "    while (n <= 70) {",
      "      var l1: int64 := rotl32(x, n); var l2: int64 := ref_rotl32(x, n);",
      "      if (l1 != l2) { fehler += 1; }",
      "      var r1: int64 := rotr32(x, n); var r2: int64 := ref_rotl32(x, 0 - n);",
      "      if (r1 != r2) { fehler += 1; }",
      "      werte += 2; n += 1;",
      "    }",
      "    xi += 1;",
      "  }",
      "  if (fehler != 0) { return 37; }",
      "  if (werte != 888) { return 38; }",
      "  x := 0x80000001; r := rotl32(x, 1); if (r != 3) { return 39; }",
      "  r := rotr32(x, 1); if (r != 3221225472) { return 40; }",
      "  x := 0x12345678; r := rotl32(x, 4); if (r != 0x23456781) { return 41; }",
      "  r := rotr32(x, 0 - 4); if (r != 0x23456781) { return 42; }",
      "  return 0;", "}",
      "fn pruefe(): int64 {",
      "  var e: int64 := pruefe_popcount(); if (e != 0) { return e; }",
      "  e := pruefe_clz(); if (e != 0) { return e; }",
      "  e := pruefe_ctz(); if (e != 0) { return e; }",
      "  e := pruefe_rot(); return e;", "}"]
open(sys.argv[1] + "/kern.lyx", "w").write("\n".join(L) + "\n")
PY
{ cat "$TMP/kern.lyx"; echo 'fn main(): int64 { var e: int64 := pruefe(); PrintInt(e); PrintLn(""c); return 0; }'; } > "$TMP/druck.lyx"
{ cat "$TMP/kern.lyx"; echo 'fn main(): int64 { return pruefe(); }'; } > "$TMP/rc.lyx"

uebersetze() { # quelle, ziel(leer = x86), ausgabe
  local opt=""; [ -n "$2" ] && opt="--target=$2"
  (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" $opt "$1" -o "$3" >"$3.log" 2>&1)
}

# --- x86: Bezug, und Gegenprobe der Erwartungen selbst ----------------------
if uebersetze "$TMP/rc.lyx" "" "$TMP/rc.x86"; then
  (cd "$TMP" && timeout 20 "$TMP/rc.x86" >/dev/null 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then ok "x86 (Bezug) rc=0"; else no "x86 (Bezug)" "Abweichung Nr. $rc"; fi
else no "x86" "uebersetzt nicht: $(grep -v Copyright "$TMP/rc.x86.log" | head -2 | tr '\n' ' ')"; fi

# --- arm-cm4 ----------------------------------------------------------------
if uebersetze "$TMP/druck.lyx" arm-cm4 "$TMP/d.cm4"; then
  if [ -z "$QARM" ]; then echo "HINWEIS: qemu-system-arm fehlt — arm-cm4 nur uebersetzt."; ok "arm-cm4 uebersetzt"
  else
    got="$(timeout 20 "$QARM" -M olimex-stm32-h405 -nographic -semihosting -kernel "$TMP/d.cm4" 2>&1 </dev/null | tr -d '\r' | grep -vE 'terminating on signal|^qemu-system-arm:|^qemu:' | head -1)"
    if [ "$got" = "0" ]; then ok "arm-cm4 Werte (Ausgabe 0)"; else no "arm-cm4 Werte" "Ausgabe '$got' (Nummer der ersten Abweichung) erwartet '0'"; fi
  fi
else no "arm-cm4" "uebersetzt nicht: $(grep -m1 -iE 'error|Builtin-ID' "$TMP/d.cm4.log")"; fi

# --- esp32 ------------------------------------------------------------------
if uebersetze "$TMP/rc.lyx" esp32 "$TMP/rc.esp"; then
  if [ -z "$QEMU_XTENSA" ]; then echo "HINWEIS: qemu-xtensa fehlt — esp32 nur uebersetzt."; ok "esp32 uebersetzt"
  elif ! python3 "$HUELLE" "$TMP/rc.esp" "$TMP/rc.run" >/dev/null 2>&1; then no "esp32" "Huelle konnte das Abbild nicht umpacken"
  else
    (cd "$TMP" && timeout 60 "$QEMU_XTENSA" "$TMP/rc.run" >/dev/null 2>&1); rc=$?
    if [ "$rc" -eq 0 ]; then ok "esp32 Werte (rc=0)"; else no "esp32 Werte" "rc=$rc (Nummer der ersten Abweichung) erwartet 0"; fi
  fi
else no "esp32" "uebersetzt nicht: $(grep -m1 -iE 'error|Builtin-ID' "$TMP/rc.esp.log")"; fi

# Eine Abweichung muss die Messung auch SEHEN: ein falscher Erwartungswert
# liefert seine Nummer, nicht 0 (sonst waere rc=0 ein Zeichen fuer nichts).
sed 's/r := popcount(x); if (r != 64) { return 3; }/r := popcount(x); if (r != 32) { return 3; }/' "$TMP/rc.lyx" > "$TMP/falsch.lyx"
if ! grep -q 'r != 32) { return 3; }' "$TMP/falsch.lyx"; then no "Gegenprobe" "Ersetzung griff nicht"
elif [ -n "$QEMU_XTENSA" ] && uebersetze "$TMP/falsch.lyx" esp32 "$TMP/f.esp" && python3 "$HUELLE" "$TMP/f.esp" "$TMP/f.run" >/dev/null 2>&1; then
  (cd "$TMP" && timeout 60 "$QEMU_XTENSA" "$TMP/f.run" >/dev/null 2>&1); rc=$?
  if [ "$rc" -eq 3 ]; then ok "Gegenprobe esp32: popcount(-1) != 32 erkannt (rc=3)"; else no "Gegenprobe esp32" "rc=$rc erwartet 3"; fi
fi

# --- 64-Bit-Formen: laut abgewiesen -------------------------------------------
for f in "bswap64(x)" "rotl(x, 3)" "rotr(x, 3)"; do
  printf 'fn main(): int64 { var x: int64 := 5; var r: int64 := %s; return r; }\n' "$f" > "$TMP/w64.lyx"
  for t in esp32 arm-cm4; do
    rm -f "$TMP/w64.out"
    if uebersetze "$TMP/w64.lyx" "$t" "$TMP/w64.out"; then no "$t $f" "uebersetzt — haette abgewiesen werden muessen"
    elif ! grep -q 'braucht 64 Bit' "$TMP/w64.out.log"; then no "$t $f" "falsche Meldung: $(grep -m1 -i error "$TMP/w64.out.log")"
    else ok "$t $f laut abgewiesen"; fi
  done
done

# --- x86: konstante Weite (#2228) ---------------------------------------------
# rotl/rotr/rotl32/rotr32 mit fester Weite gehen auf x86 einen eigenen Weg
# (Rotation mit Direktwert). Gemessen: derselbe WERT wie ueber eine Variable
# (allgemeiner Weg, `rol %cl`) fuer Weiten um 0/32/64 und negative, UND der
# WEG — eine feste Weite bringt `ror $imm` und kein `%cl` mehr.
python3 - "$TMP" <<'PY'
import sys
L = ["import std.io;", "fn main(): int64 {",
     "  var x: int64 := 0x123456789ABCDEF1; var r: int64 := 0; var v: int64 := 0; var n: int64 := 0;"]
i = 1
for xv in ("0x123456789ABCDEF1", "(0 - 2)", "0x80000001"):
    L.append("  x := %s;" % xv)
    for f in ("rotl", "rotr", "rotl32", "rotr32"):
        for k in (-65, -64, -33, -32, -31, -1, 0, 1, 7, 31, 32, 33, 63, 64, 65, 100):
            lit = str(k) if k >= 0 else "(0 - %d)" % -k
            L.append("  n := %s; r := %s(x, %s); v := %s(x, n); if (r != v) { return %d; }" % (lit, f, lit, f, i % 250 + 1))
            i += 1
L += ["  return 0;", "}"]
open(sys.argv[1] + "/kw.lyx", "w").write("\n".join(L) + "\n")
PY
if uebersetze "$TMP/kw.lyx" "" "$TMP/kw.x86"; then
  (cd "$TMP" && timeout 20 "$TMP/kw.x86" >/dev/null 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then ok "x86 feste Weite == variable Weite (192 Faelle)"; else no "x86 feste Weite" "Abweichung Nr. $rc"; fi
else no "x86 feste Weite" "uebersetzt nicht"; fi
weg() { # quelle -> "ror_imm ror_cl"
  printf '%s\n' "$1" > "$TMP/kz.lyx"
  (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" --emit=obj "$TMP/kz.lyx" -o "$TMP/kz.o" >/dev/null 2>&1) || { echo "X X"; return; }
  local d; d="$(objdump -d -z --no-show-raw-insn "$TMP/kz.o" 2>/dev/null)"
  echo "$(grep -cE 'ro[lr] +\$0x7,%eax' <<<"$d") $(grep -cE 'ro[lr] +%cl,%eax' <<<"$d")"
}
read -r ki kc <<<"$(weg 'fn main(): int64 { var x: int64 := 0x11112222; var r: int64 := rotr32(x, 7); return r; }')"
read -r vi vc <<<"$(weg 'fn main(): int64 { var x: int64 := 0x11112222; var n: int64 := 7; var r: int64 := rotr32(x, n); return r; }')"
if [ "$ki" = 1 ] && [ "$kc" = 0 ] && [ "$vi" = 0 ] && [ "$vc" = 1 ]; then ok "Weg x86: feste Weite -> ror \$imm, variable -> ror %cl"
else no "Weg x86" "fest: imm=$ki cl=$kc, variabel: imm=$vi cl=$vc (erwartet 1 0 / 0 1)"; fi

echo "bit_builtins_alle_ziele: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
