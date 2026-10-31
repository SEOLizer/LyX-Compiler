#!/usr/bin/env bash
# tests/autovektor_2194_test.sh — #2194: elementweise Schleifen vektorisieren.
#
# Der Codegen erkennt
#
#   while (i < n) { pokeW(c + idx, (peekW(a + idx) OP peekW(b + idx)) & maskeW); i += 1; }
#
# und legt sie auf den vorhandenen Vektorrechner (cg_emitSSE2BinOp /
# cg_emitAVX2BinOp, #2199/#2247). Weil a, b und c gewoehnliche Zeiger sind —
# meist Parameter —, steht davor eine UEBERLAPPUNGSPRUEFUNG zur Laufzeit:
# ueberschneiden sich Ziel und Quelle, laeuft die skalare Fassung.
#
# Geprueft wird deshalb in drei Richtungen, und alle drei sind noetig:
#
#   1. WERTE bei getrennten Feldern, je Breite und Operation, mit Laengen
#      rund um die Blockgroesse (Rest-Durchgang: 1, 15, 16, 17, 31, 33).
#   2. WERTE bei UEBERLAPPUNG (c = a+1, c = a, c = a-1). Hier zeigt sich, ob
#      die Laufzeitpruefung greift. Ohne sie liefert die Vektorfassung etwas
#      anderes als die skalare — ein stiller falscher Wert, die Art Defekt,
#      die #1966 teuer gemacht hat.
#   3. AM ERZEUGNIS, beide Seiten: im vektorisierbaren Programm MUSS PADDB
#      stehen, im nicht vektorisierbaren DARF es nicht. Ein Test, der nur
#      Werte prueft, waere auch erfuellt, wenn gar nicht vektorisiert wird —
#      er wuerde also den Verlust der Beschleunigung nicht melden.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ulimit -c 0
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

baue() {  # name quelle
  printf '%s' "$2" > "$TMP/$1.lyx"
  (cd "$TMP" && timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/$1.lyx" -o "$TMP/$1" >"$TMP/$1.log" 2>&1)
}

paddb() {  # datei -> Anzahl PADDB/PADDW/PADDD (SSE2 oder VEX)
  # Gezaehlt wird ueber ROHE BYTES, weil ein Lyx-Erzeugnis keine Sektionen
  # hat und `objdump -d` daran gar nichts disassembliert.
  #
  # Das ist die Falle aus #1370, und sie hat hier zugeschlagen: die erste
  # Fassung suchte `C4|C5` und ZWEI Bytes weiter den Opcode, ohne die
  # VEX-Struktur zu pruefen. Am 2026-10-31 traf das `e8 c5 d3 fe ff` — ein
  # `call rel32`, dessen Verschiebung mit C5 beginnt und zwei Bytes weiter
  # FE (PADDW) enthaelt. Rot wurde der Test, weil eine Aenderung am Codegen
  # (#2330) eine Sprungweite verschoben hat. Vorher war er GRUEN DURCH
  # ZUFALL — derselbe Befund wie bei #2244.
  #
  # Jetzt wird die Praefix-STRUKTUR geprueft, nicht ein einzelnes Byte:
  #   * 2-Byte-VEX:  C5 <R vvvv L pp> opc
  #                  pp muss 01 sein (Praefix 66), sonst ist es kein
  #                  PADD-Opcode-Raum.
  #   * 3-Byte-VEX:  C4 <RXB mmmmm> <W vvvv L pp> opc
  #                  mmmmm muss 00001 sein (0F-Karte), pp muss 01 sein —
  #                  und der OPCODE steht an i+3. Die erste Fassung las ihn
  #                  an i+2 und konnte den 3-Byte-VEX damit ueberhaupt
  #                  nicht erkennen: ein zweiter Fehler im selben Zaehler.
  # Ein Falschtreffer braucht damit drei zusammenpassende Bytes statt zwei.
  python3 -I - "$1" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
OPC = (0xFC, 0xFD, 0xFE)                 # PADDB / PADDW / PADDD
n = 0
for i in range(len(d) - 3):
    if d[i] == 0x66 and d[i+1] == 0x0F and d[i+2] in OPC:
        n += 1
    elif d[i] == 0xC5 and (d[i+1] & 3) == 1 and d[i+2] in OPC:
        n += 1
    elif d[i] == 0xC4 and (d[i+1] & 0x1F) == 1 and (d[i+2] & 3) == 1 and d[i+3] in OPC:
        n += 1
print(n)
PY
}

# ---------------------------------------------------------------- 1 + 2
# Ein Programm, das alles rechnet: getrennte Felder in sieben Laengen, dann
# die drei Ueberlappungsformen. Die Erwartungswerte sind unten hergeleitet.
Q_WERTE='unit main;
import std.io;
fn add8(a: int64, b: int64, c: int64, n: int64): void {
  var i: int64 := 0;
  while (i < n) { poke8(c + i, (peek8(a + i) + peek8(b + i)) & 0xFF); i := i + 1; }
}
fn sub8(a: int64, b: int64, c: int64, n: int64): void {
  var i: int64 := 0;
  while (i < n) { poke8(c + i, (peek8(a + i) - peek8(b + i)) & 0xFF); i := i + 1; }
}
fn add16(a: int64, b: int64, c: int64, n: int64): void {
  var i: int64 := 0;
  while (i < n) { poke16(c + i * 2, (peek16(a + i * 2) + peek16(b + i * 2)) & 0xFFFF); i := i + 1; }
}
fn mul32(a: int64, b: int64, c: int64, n: int64): void {
  var i: int64 := 0;
  while (i < n) { poke32(c + i * 4, (peek32(a + i * 4) * peek32(b + i * 4)) & 0xFFFFFFFF); i := i + 1; }
}
fn f8(p: int64, n: int64, s: int64): void {
  var i: int64 := 0;
  while (i < n) { poke8(p + i, (s + i) & 0x3F); i := i + 1; }
}
fn s8(p: int64, n: int64): int64 {
  var s: int64 := 0; var i: int64 := 0;
  while (i < n) { s := s + (peek8(p + i) & 0xFF); i := i + 1; }
  return s;
}
fn s16(p: int64, n: int64): int64 {
  var s: int64 := 0; var i: int64 := 0;
  while (i < n) { s := s + (peek16(p + i * 2) & 0xFFFF); i := i + 1; }
  return s;
}
fn s32(p: int64, n: int64): int64 {
  var s: int64 := 0; var i: int64 := 0;
  while (i < n) { s := s + (peek32(p + i * 4) & 0xFFFFFFFF); i := i + 1; }
  return s;
}
fn main(): int64 {
  var p: int64 := alloc(65536);
  var L: int64 := alloc(64);
  poke64(L, 1); poke64(L + 8, 15); poke64(L + 16, 16); poke64(L + 24, 17);
  poke64(L + 32, 31); poke64(L + 40, 33); poke64(L + 48, 1000);
  var k: int64 := 0;
  while (k < 7) {
    var n: int64 := peek64(L + k * 8);
    f8(p, n, 3); f8(p + 8192, n, 11);
    add8(p, p + 8192, p + 16384, n);
    sub8(p, p + 8192, p + 24576, n);
    PrintStr("add8 "); PrintInt(n); PrintStr(" "); PrintInt(s8(p + 16384, n));
    PrintStr(" sub8 "); PrintInt(s8(p + 24576, n)); PrintStr("\n");
    k := k + 1;
  }
  f8(p, 2000, 5); f8(p + 8192, 2000, 7);
  add16(p, p + 8192, p + 16384, 300);
  PrintStr("add16 "); PrintInt(s16(p + 16384, 300)); PrintStr("\n");
  mul32(p, p + 8192, p + 24576, 200);
  PrintStr("mul32 "); PrintInt(s32(p + 24576, 200)); PrintStr("\n");
  f8(p + 32768, 64, 1);
  add8(p + 32768, p + 32768, p + 32769, 64);
  PrintStr("ueb_c_gleich_a_plus_1 "); PrintInt(s8(p + 32769, 64)); PrintStr("\n");
  f8(p + 40960, 64, 1);
  add8(p + 40960, p + 40960, p + 40960, 64);
  PrintStr("ueb_c_gleich_a "); PrintInt(s8(p + 40960, 64)); PrintStr("\n");
  f8(p + 49153, 64, 1);
  add8(p + 49153, p + 49153, p + 49152, 64);
  PrintStr("ueb_c_gleich_a_minus_1 "); PrintInt(s8(p + 49152, 64)); PrintStr("\n");
  return 0;
}'

if ! baue werte "$Q_WERTE"; then
  no "werte uebersetzen" "$(grep -v Copyright "$TMP/werte.log" | grep -m1 -iE 'error|lyxc:')"
else
  ok "werte uebersetzen"
  ist=$( cd "$TMP" && timeout 60 ./werte 2>&1 )
  # Hergeleitet: f8(p,n,3) legt (3+i)&63 ab, f8(p+8192,n,11) legt (11+i)&63.
  # add8 summiert beides je Element und schneidet auf 8 Bit; sub8 subtrahiert.
  # Die Erwartung wird NICHT nachgerechnet, sondern gegen die SKALARE Fassung
  # geprueft (unten, Teil 4) — eine von Hand gerechnete Zahl waere hier eine
  # zweite Fehlerquelle. Hier nur: es laeuft und liefert ueberhaupt Zeilen.
  z=$(printf '%s' "$ist" | grep -c .)
  if [ "$z" -eq 12 ]; then ok "werte: 12 Zeilen"; else no "werte" "$z Zeilen statt 12: $ist"; fi
  printf '%s' "$ist" > "$TMP/ist_vektor.txt"
fi

# ---------------------------------------------------------------- 3a: PADDB da
if [ -f "$TMP/werte" ]; then
  n=$(paddb "$TMP/werte")
  if [ "$n" -ge 1 ]; then ok "erzeugnis: $n Vektoraddition(en) im Code"
  else no "erzeugnis" "kein PADDB/PADDW/PADDD — es wurde nicht vektorisiert"; fi
fi

# ---------------------------------------------------------------- 3b: Gegenseite
# Dieselbe Rechnung, aber mit Schrittweite 2 in der Fortschaltung. Die Form ist
# damit nicht mehr die erkannte, und es darf KEIN Vektorbefehl entstehen.
Q_NEIN='unit main;
import std.io;
fn add8z(a: int64, b: int64, c: int64, n: int64): void {
  var i: int64 := 0;
  while (i < n) { poke8(c + i, (peek8(a + i) + peek8(b + i)) & 0xFF); i := i + 2; }
}
fn main(): int64 {
  var p: int64 := alloc(4096);
  poke8(p, 7); poke8(p + 1024, 9);
  add8z(p, p + 1024, p + 2048, 64);
  PrintInt(peek8(p + 2048) & 0xFF); PrintStr("\n");
  return 0;
}'
if ! baue nein "$Q_NEIN"; then
  no "gegenseite uebersetzen" "$(grep -v Copyright "$TMP/nein.log" | grep -m1 -iE 'error|lyxc:')"
else
  aus=$( cd "$TMP" && timeout 30 ./nein 2>&1 )
  if [ "$aus" = "16" ]; then ok "gegenseite: Wert 16"; else no "gegenseite" "'$aus' erwartet '16'"; fi
  n=$(paddb "$TMP/nein")
  if [ "$n" -eq 0 ]; then ok "gegenseite: kein Vektorbefehl (i += 2 ist nicht die erkannte Form)"
  else no "gegenseite" "$n Vektorbefehl(e), obwohl die Form nicht erkannt sein darf"; fi
fi

# ---------------------------------------------------------------- 4: gegen die skalare Fassung
# Entscheidend: dieselbe Rechnung, aber so geschrieben, dass die Erkennung NICHT
# greift (Hilfsvariable im Rumpf). Die Ausgaben muessen Zeichen fuer Zeichen
# uebereinstimmen — damit ist belegt, dass die Vektorfassung dasselbe rechnet,
# einschliesslich der drei Ueberlappungsfaelle.
Q_SKALAR=$(printf '%s' "$Q_WERTE" | sed 's|poke8(c + i, (peek8(a + i) + peek8(b + i)) \& 0xFF); i := i + 1;|var t: int64 := peek8(a + i) + peek8(b + i); poke8(c + i, t \& 0xFF); i := i + 1;|; s|poke8(c + i, (peek8(a + i) - peek8(b + i)) \& 0xFF); i := i + 1;|var t: int64 := peek8(a + i) - peek8(b + i); poke8(c + i, t \& 0xFF); i := i + 1;|; s|poke16(c + i \* 2, (peek16(a + i \* 2) + peek16(b + i \* 2)) \& 0xFFFF); i := i + 1;|var t: int64 := peek16(a + i * 2) + peek16(b + i * 2); poke16(c + i * 2, t \& 0xFFFF); i := i + 1;|; s|poke32(c + i \* 4, (peek32(a + i \* 4) \* peek32(b + i \* 4)) \& 0xFFFFFFFF); i := i + 1;|var t: int64 := peek32(a + i * 4) * peek32(b + i * 4); poke32(c + i * 4, t \& 0xFFFFFFFF); i := i + 1;|')
if ! baue skalar "$Q_SKALAR"; then
  no "skalare Fassung uebersetzen" "$(grep -v Copyright "$TMP/skalar.log" | grep -m1 -iE 'error|lyxc:')"
else
  ns=$(paddb "$TMP/skalar")
  if [ "$ns" -eq 0 ]; then ok "skalare Fassung: kein Vektorbefehl (Vergleichsweg ist wirklich skalar)"
  else no "skalare Fassung" "$ns Vektorbefehl(e) — der Vergleich waere wertlos"; fi
  aus=$( cd "$TMP" && timeout 60 ./skalar 2>&1 )
  printf '%s' "$aus" > "$TMP/ist_skalar.txt"
  if [ -f "$TMP/ist_vektor.txt" ] && cmp -s "$TMP/ist_vektor.txt" "$TMP/ist_skalar.txt"; then
    ok "vektorisiert und skalar liefern dasselbe (12 Zeilen, inkl. der drei Ueberlappungsfaelle)"
  else
    no "vergleich" "Vektorfassung und skalare Fassung weichen ab:
$(diff "$TMP/ist_vektor.txt" "$TMP/ist_skalar.txt" 2>&1 | head -6)"
  fi
fi

echo "=== PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
