#!/usr/bin/env bash
# tests/xxhash_2235_test.sh — xxHash in std/hash.lyx gegen REFERENZWERTE (#2235).
#
# XXHash64 schob in der Schlussdurchmischung `h64 >> 33/29/32` auf int64 —
# arithmetisch. xxHash verlangt logische Shifts; jeder Wert mit gesetztem
# Bit 63 nach dem Multiplizieren kam falsch heraus (XXH64("abc") lieferte
# 6833185961996073490 statt 0x44BC2CF5AD770999). Die bisherige Pruefung war
# "unveraendert", nicht "richtig" — sie haette den falschen Wert festgeschrieben.
#
# Daneben standen zwei weitere "xxHash"-Funktionen, die gar keine waren:
# HashxxHash64 (Murmur-artige Runde, Konstanten mit abgeschnittener letzter
# Ziffer) und HashxxHash32 (64-Bit-Primzahlen, arithmetische Shifts). Beide
# rechnen jetzt den echten Algorithmus.
#
# Erwartungswerte: XXH64/XXH32 nach der Spezifikation (xxhash_spec.md), in
# Python nachgerechnet; die Python-Fassung wurde vorher gegen die
# veroeffentlichten Vektoren geprueft (XXH64("")=0xEF46DB3751D8E999,
# XXH64("a")=0xD24EC4F1A98C6E5B, XXH64("abc")=0x44BC2CF5AD770999,
# XXH64("Nobody inspects the spammish repetition")=0xFBCEA83C8A378BF1,
# XXH32("")=0x02CC5D05, XXH32("abc")=0x32D153FF, XXH32(Nobody…)=0xE2293B2F).
# Die Eingaben decken alle Wege ab: leer, 1/3/14 Byte (nur Restbytes),
# 39 Byte (Streifen + 4- und 1-Byte-Rest), 131 Byte (vier Streifen, 8er-Rest),
# Seed 0, 1 und 2654435761.
#
# Gemessen auf x86-64 und riscv (unter qemu), XXH32 zusaetzlich auf arm64 —
# zu arm64 und XXH64 siehe unten.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
. "$(dirname "$0")/lib/qemu.sh"   # #2048
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# 1) Die vorhandene Schnittstelle: XXHash64, XXHash64Str, HashxxHash64,
#    HashxxHash32.
cat > "$TMP/a.lyx" <<'LYX'
import std.io;
import std.alloc;
import std.hash;
fn lang(): int64 {
  var b: int64 := alloc(131);
  var i: int64 := 0;
  while (i < 131) { poke8(b + i, (i * 7 + 3) & 255); i += 1; }
  return b;
}
fn drei(p: int64, n: int64) {
  var h0: int64 := XXHash64(p, n, 0);
  var h1: int64 := XXHash64(p, n, 2654435761);
  var h2: int64 := XXHash64(p, n, 1);
  PrintLn(h0); PrintLn(h1); PrintLn(h2);
}
fn main(): int64 {
  var nb: pchar := "Nobody inspects the spammish repetition";
  drei("" as int64, 0);
  drei("a" as int64, 1);
  drei("abc" as int64, 3);
  drei("message digest" as int64, 14);
  drei(lang(), 131);
  drei(nb as int64, StrLen(nb));
  var s1: int64 := XXHash64Str("abc"); PrintLn(s1);
  var s2: int64 := XXHash64Str(nb);    PrintLn(s2);
  var x0: int64 := HashxxHash64("");    PrintLn(x0);
  var x1: int64 := HashxxHash64("abc"); PrintLn(x1);
  var x2: int64 := HashxxHash64(nb);    PrintLn(x2);
  var y0: int64 := HashxxHash32("");    PrintLn(y0);
  var y1: int64 := HashxxHash32("abc"); PrintLn(y1);
  var y2: int64 := HashxxHash32(nb);    PrintLn(y2);
  var y3: int64 := HashxxHash32("abcdefghijklmnopqrstuvwxyz"); PrintLn(y3);
  return 0;
}
LYX
ERW_A="-1205034819632174695 -6019626452224632849 -3049013831022690741 -3292477735350538661 4124638339981780891 -2395144786285869370 4952883123889572249 1376095083568989693 -4708009277469325048 463544382707905470 -6832327093462858866 -3772832630442176259 201266910080804742 -4095597128940739913 -8062881689169791485 -302119147016844303 6258634441271611719 4896579671221947830 4952883123889572249 -302119147016844303 -1205034819632174695 4952883123889572249 -302119147016844303 46947589 852579327 3794352943 1671515487"

# 2) XXHash32 mit Zeiger, Laenge und Seed — die Schwester von XXHash64.
cat > "$TMP/b.lyx" <<'LYX'
import std.io;
import std.alloc;
import std.hash;
fn main(): int64 {
  var b: int64 := alloc(131);
  var i: int64 := 0;
  while (i < 131) { poke8(b + i, (i * 7 + 3) & 255); i += 1; }
  var a0: int64 := XXHash32("abc" as int64, 3, 0);          PrintLn(a0);
  var a1: int64 := XXHash32("abc" as int64, 3, 2654435761); PrintLn(a1);
  var l0: int64 := XXHash32(b, 131, 0);                     PrintLn(l0);
  var l1: int64 := XXHash32(b, 131, 2654435761);            PrintLn(l1);
  return 0;
}
LYX
ERW_B="852579327 2712565513 2810341049 3288869804"

ziel() { # prog name target runner erwartet
  local prog="$1" name="$2" t="$3" run="$4" erw="$5" opt=""
  [ -n "$t" ] && opt="--target=$t"
  if ! (cd "$ROOT" && timeout 300 "$LYXC" --std-path="$ROOT" $opt "$TMP/$prog.lyx" -o "$TMP/$prog.$name" >"$TMP/$prog.$name.log" 2>&1); then
    no "$prog $name" "uebersetzt nicht: $(grep -v Copyright "$TMP/$prog.$name.log" | grep -iv "^warn" | head -2 | tr '\n' ' ')"; return
  fi
  if [ "$name" != x86 ] && [ -z "$run" ]; then
    echo "HINWEIS: qemu fuer $name fehlt — nur uebersetzt."; ok "$prog $name uebersetzt"; return
  fi
  local got; got=$( ulimit -c 0; cd "$TMP" && timeout 60 $run "$TMP/$prog.$name" 2>/dev/null | tr '\n' ' ' ); got="${got% }"
  if [ "$got" = "$erw" ]; then
    ok "$prog Werte $name"
  else
    # Erste abweichende Stelle nennen, damit der Fehler lesbar bleibt.
    local i=1 g e
    for e in $erw; do
      g=$(echo "$got" | cut -d' ' -f$i)
      [ "$g" != "$e" ] && break
      i=$((i+1))
    done
    no "$prog Werte $name" "Wert $i ist '$g', erwartet '$e' (gesamt: '$got')"
  fi
}
# Programm a NICHT auf arm64: dort schiebt IRO_SHR immer arithmetisch (ASRV),
# auch fuer uint64 — `(h as uint64) >> 33` liefert also den alten falschen
# Wert. Umgekehrt schiebt riscv IMMER logisch (SRL), auch fuer int64. Das
# IR fuehrt beim Rechtsshift keine Vorzeichenart mit (IRO_SHR); ein eigener
# Defekt der IR-Backends, nicht von std.hash: #2236. Ein Test darf nicht an
# einem fremden offenen Defekt haengen; sobald #2236 behoben ist, gehoert
# arm64 hier wieder dazu.
# Programm b (XXH32) rechnet nur mit nichtnegativen Werten und laeuft
# deshalb auch auf arm64.
ziel a x86 "" "" "$ERW_A"
ziel a riscv riscv "$QEMU_RISCV64" "$ERW_A"
ziel b x86 "" "" "$ERW_B"
ziel b arm64 arm64 "$QEMU_ARM64" "$ERW_B"
ziel b riscv riscv "$QEMU_RISCV64" "$ERW_B"

# 3) Keine zweite Primzahl-Tabelle unter demselben Namen. Vor dem Fix stand
#    XXH_PRIME1..5 zweimal in hash.lyx, einmal mit abgeschnittener Ziffer
#    (0x9e3779b185ebc87) — welche gilt, entschied die Reihenfolge, nicht der
#    Quelltext.
n=$(grep -c "^con XXH_PRIME1:" "$ROOT/std/hash.lyx")
if [ "$n" = 1 ]; then ok "XXH_PRIME1 genau einmal definiert"; else no "XXH_PRIME1" "$n Definitionen in std/hash.lyx"; fi

echo "----"
echo "$PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
