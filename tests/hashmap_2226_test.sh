#!/usr/bin/env bash
# tests/hashmap_2226_test.sh — std.hash HashMap (#2226).
#
# Bis 1.2.19G drei Defekte, alle hier gemessen:
#   * Set nach Del legte ein Duplikat an: Set schrieb in den ERSTEN Grabstein,
#     ohne weiter hinten nach dem Schluessel zu suchen. In der Probe unten
#     (20 Startbuchstaben x 5 geloeschte) waren 29 von 100 Zaehlern falsch, das
#     Referenzmodell zaehlte 201603 Abweichungen in 200000 Schritten.
#   * Der Hash lief bis zur Null statt ueber keyLen — Set(hm, "keyvalue", 3)
#     und Get(hm, "key", 3) trafen sich nicht (0 statt 42).
#   * Grow kopierte jeden Schluessel neu und liess die alte Kopie liegen, Del
#     gab die Kopie nie frei. Gemessen als Netto-Mappings (mmap - munmap): mit
#     100 Runden 25, mit 600 Runden 64 — es waechst mit der Laufzeit. Danach 18
#     und 18.
#
# Die Speicherprobe misst deshalb das WACHSTUM zwischen zwei Rundenzahlen,
# nicht eine absolute Zahl: die haengt an der Laufzeitumgebung, das Wachstum
# nicht.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

bau() { # name quelle -> $TMP/name
  printf '%s\n' "$2" > "$TMP/$1.lyx"
  (cd "$ROOT" && "$LYXC" --std-path="$ROOT" "$TMP/$1.lyx" -o "$TMP/$1" >"$TMP/$1.log" 2>&1)
}

out() { # name quelle erwartet
  if ! bau "$1" "$2"; then no "$1" "uebersetzt nicht: $(head -3 "$TMP/$1.log" | tr '\n' ' ')"; return; fi
  got="$( ulimit -c 0; ulimit -v 4000000; cd "$TMP" && timeout 60 "$TMP/$1" 2>&1 | tr '\n' ' ')"; rc=${PIPESTATUS[0]}
  got="${got% }"
  if [ "$got" = "$3" ]; then ok "$1 ($got)"; else no "$1" "'$got' erwartet '$3'"; fi
}

out "Set nach Del: kein Duplikat (Repro aus #2226)" 'import std.io;
import std.alloc;
import std.hash;
fn main(): int64 {
  var ks: pchar := "abcdefghijklmnopqrstuvwxyz";
  var kb: int64 := alloc(64);
  var base: int64 := 0;
  var bad: int64 := 0;
  while (base < 20) {
    var dk: int64 := 0;
    while (dk < 5) {
      var hm: int64 := HashMapNew(8);
      var j: int64 := 0;
      while (j < 5) { HashMapSet(hm, (ks as int64 + base + j) as pchar, 1, j); j += 1; }
      HashMapDel(hm, (ks as int64 + base + dk) as pchar, 1);
      j := 0;
      while (j < 5) { if (j != dk) { HashMapSet(hm, (ks as int64 + base + j) as pchar, 1, 100 + j); } j += 1; }
      if (HashMapCount(hm) != 4) { bad += 1; }
      dk += 1;
    }
    base += 1;
  }
  PrintLn(bad);
  return 0;
}' "0"

out "Hash ueber keyLen, nicht bis zur Null" 'import std.io;
import std.hash;
fn main(): int64 {
  var hm: int64 := HashMapNew(8);
  var text: pchar := "keyvalue";
  HashMapSet(hm, text, 3, 42);
  PrintLn(HashMapGet(hm, "key", 3));
  PrintLn(HashMapGet(hm, "keyvalue", 8));
  PrintLn(HashMapCount(hm));
  return 0;
}' "42 0 1"

# Referenzmodell: 200000 zufaellige Set/Del/Get ueber 64 Schluessel. Erste
# Zeile Abweichungen, zweite der Endbestand (aus dem Modell, nicht der Map).
out "Referenzmodell, 200000 Schritte" 'import std.io;
import std.alloc;
import std.hash;
// Zufallsfolge aus Set/Del/Get gegen ein Referenzmodell (Feld je Schluessel).
fn main(): int64 {
  var keys: int64 := alloc(64 * 4);
  var i: int64 := 0;
  while (i < 64) {
    poke8(keys + i * 4, 107);                 // '\''k'\''
    poke8(keys + i * 4 + 1, 48 + i / 10);
    poke8(keys + i * 4 + 2, 48 + i % 10);
    poke8(keys + i * 4 + 3, 0);
    i += 1;
  }
  var da: int64 := alloc(64 * 8);   // 1 = vorhanden
  var wert: int64 := alloc(64 * 8);
  var hm: int64 := HashMapNew(4);
  var x: int64 := 12345;
  var fehler: int64 := 0;
  var n: int64 := 0;
  var op: int64 := 0;
  while (op < 200000) {
    x := (x * 6364136223846793005 + 1442695040888963407);
    var r: int64 := (x >> 33) & 0x7FFFFFFF;
    var k: int64 := r % 64;
    var art: int64 := (r / 64) % 3;
    var kp: pchar := (keys + k * 4) as pchar;
    if (art == 0) {
      HashMapSet(hm, kp, 3, op);
      if (peek64(da + k * 8) == 0) { n += 1; }
      poke64(da + k * 8, 1); poke64(wert + k * 8, op);
    } else if (art == 1) {
      HashMapDel(hm, kp, 3);
      if (peek64(da + k * 8) != 0) { n -= 1; }
      poke64(da + k * 8, 0);
    } else {
      var hat: bool := HashMapHas(hm, kp, 3);
      if (peek64(da + k * 8) != 0) {
        if (!hat) { fehler += 1; }
        if (HashMapGet(hm, kp, 3) != peek64(wert + k * 8)) { fehler += 1; }
      } else {
        if (hat) { fehler += 1; }
      }
    }
    if (HashMapCount(hm) != n) { fehler += 1; }
    op += 1;
  }
  PrintLn(fehler);
  PrintLn(n);
  HashMapFree(hm);
  return 0;
}' "0 35"

# Speicher: Netto-Mappings duerfen mit der Rundenzahl nicht wachsen.
if command -v strace >/dev/null 2>&1; then
  netto() {
    local src="${SPEICHER//RUNDEN/$1}"
    if ! bau "sp$1" "$src"; then echo "X"; return; fi
    local o; o="$(cd "$TMP" && strace -f -e trace=mmap,munmap "$TMP/sp$1" 2>&1)"
    echo $(( $(grep -c '^mmap' <<<"$o") - $(grep -c '^munmap' <<<"$o") ))
  }
  SPEICHER='import std.io;
import std.alloc;
import std.hash;
// Del gibt die Schluesselkopie frei, Grow kopiert nicht neu: 300 Runden mit je
// 2000 Schluesseln (mehrfaches Wachsen) und 2000 Set/Del-Paaren.
fn main(): int64 {
  var buf: int64 := alloc(16);
  var runde: int64 := 0;
  var summe: int64 := 0;
  while (runde < RUNDEN) {
    var hm: int64 := HashMapNew(8);
    var i: int64 := 0;
    while (i < 2000) {
      poke64(buf, i + runde * 7919);
      HashMapSet(hm, buf as pchar, 8, i);
      i += 1;
    }
    i := 0;
    while (i < 2000) {
      poke64(buf, 0 - i - 1);
      HashMapSet(hm, buf as pchar, 8, i);
      HashMapDel(hm, buf as pchar, 8);
      i += 1;
    }
    summe := summe + HashMapCount(hm);
    HashMapFree(hm);
    runde += 1;
  }
  PrintLn(summe);
  return 0;
}'
  a=$(netto 100); b=$(netto 600)
  if [ "$a" = X ] || [ "$b" = X ]; then no "Speicher" "uebersetzt nicht"
  elif [ $((b - a)) -le 1 ]; then ok "Speicher: Netto-Mappings konstant ($a bei 100, $b bei 600 Runden)"
  else no "Speicher" "Netto-Mappings wachsen: $a bei 100, $b bei 600 Runden"; fi
else
  no "Speicher" "strace fehlt"
fi

echo "hashmap_2226: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
