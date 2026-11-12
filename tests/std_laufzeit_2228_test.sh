#!/usr/bin/env bash
# tests/std_laufzeit_2228_test.sh — std-Schleifen schneller, Werte unveraendert (#2228).
#
# Umgeschrieben wurden: die Zeichenkettensuche (eine _strSuche statt zweier
# Kopien, StrCount ohne StrLen je Durchlauf — vorher quadratisch), CRC32
# ueber eine Tabelle statt bitweise, FNV-1a in einem Durchlauf, base64 mit
# einer Kodierschleife fuer beide Alphabete, Sortieren auf Zeigern,
# StringBuilder mit memcpy.
#
# Eine Beschleunigung, die etwas anderes rechnet, ist schlimmer als keine.
# Der Kern dieses Tests sind deshalb die WERTE gegen unabhaengige Referenzen
# (zlib/Python fuer CRC und FNV, RFC 4648 fuer base64, ein Vergleich gegen
# Einfuegesortierung fuer SortInt64) samt Randfaellen. Die WIRKUNG prueft
# eine Schranke, die nur der quadratische Fall reisst: StrCount ueber 2 MB
# brauchte vorher Minuten, jetzt Millisekunden — Faktor > 1000, also auf
# jeder Maschine eindeutig.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

out() { # name quelle erwartet [timeout]
  printf '%s\n' "$2" > "$TMP/p.lyx"; rm -f "$TMP/p"
  if ! (cd "$ROOT" && "$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p" >"$TMP/p.log" 2>&1); then
    no "$1" "uebersetzt nicht: $(head -3 "$TMP/p.log" | tr '\n' ' ')"; return
  fi
  local got
  got="$( ulimit -c 0; ulimit -v 4000000; cd "$TMP" && timeout "${4:-60}" "$TMP/p" 2>&1 | tr '\n' ' ')"
  got="${got% }"
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1" "'$got' erwartet '$3'"; fi
}

out "Suche: StrFind/StrIndexOf/StrContains, Randfaelle" 'import std.io;
import std.string;
fn main(): int64 {
  PrintLn(StrFind("hello world", "world"));
  PrintLn(StrFind("hello", ""));
  PrintLn(StrFind("ab", "abc"));
  PrintLn(StrFind("aaab", "aab"));
  PrintLn(StrFind("abc", "c"));
  PrintLn(StrFind("abc", "x"));
  PrintLn(StrIndexOf("abcabc", "bc", 2));
  PrintLn(StrIndexOf("abcabc", "bc", 5));
  PrintLn(StrIndexOf("abcabc", "bc", 0 - 3));
  PrintLn(StrIndexOf("abc", "", 2));
  if (StrContains("Lyx-Compiler", "Comp")) { PrintLn(1); } else { PrintLn(0); }
  return 0;
}' "6 0 -1 1 2 -1 4 -1 1 0 1"

out "Suche: StrCount ohne Ueberlappung" 'import std.io;
import std.string;
fn main(): int64 {
  PrintLn(StrCount("aaaa", "aa"));
  PrintLn(StrCount("abcabcab", "abc"));
  PrintLn(StrCount("abc", ""));
  PrintLn(StrCount("", "a"));
  PrintLn(StrCount("xyz", "xyzz"));
  return 0;
}' "2 2 0 0 0"

# Wirkung: 2 MB Text, jedes vierte Zeichen ein Treffer. Quadratisch waeren
# das ~5e11 Schritte.
out "Wirkung: StrCount ueber 2 MB in Millisekunden" 'import std.io;
import std.alloc;
import std.string;
fn main(): int64 {
  var n: int64 := 2000000;
  var b: int64 := alloc(n + 1);
  var i: int64 := 0;
  while (i < n) { if (i % 4 == 0) { poke8(b + i, 120); } else { poke8(b + i, 46); } i += 1; }
  poke8(b + n, 0);
  PrintLn(StrCount(b as pchar, "x."));
  return 0;
}' "500000" 20

out "CRC32: Pruefwert, leer, alle Bytewerte (gegen zlib)" 'import std.io;
import std.alloc;
import std.zlib;
fn main(): int64 {
  PrintLn(CRC32("123456789", 9));
  PrintLn(CRC32("", 0));
  var b: int64 := alloc(256);
  var i: int64 := 0;
  while (i < 256) { poke8(b + i, i); i += 1; }
  PrintLn(CRC32(b as pchar, 256));
  return 0;
}' "3421780262 0 688229491"

out "FNV-1a 32/64, mit und ohne Laenge (gegen Python)" 'import std.io;
import std.hash;
fn main(): int64 {
  PrintLn(HashFNV1a64(""));
  PrintLn(HashFNV1a64("a"));
  PrintLn(HashFNV1a64("foobar"));
  PrintLn(HashFNV1a64Bytes("foobarXYZ", 6));
  PrintLn(HashFNV1a32("a"));
  PrintLn(HashFNV1a32("foobar"));
  PrintLn(HashFNV1a32Bytes("foobarXYZ", 6));
  return 0;
}' "-3750763034362895579 -5808556873153909620 -8821353812377114648 -8821353812377114648 3826002220 3214735720 3214735720"

out "base64: RFC-4648-Vektoren, URL-sicher, Rueckweg" 'import std.io;
import std.alloc;
import std.base64;
fn zeige(s: pchar) {
  var o: int64 := alloc(64);
  var n: int64 := Encode(s, o as pchar);
  Print(n); Print(":"); PrintLn(o as pchar);
}
fn main(): int64 {
  zeige("f"); zeige("fo"); zeige("foo"); zeige("foob"); zeige("fooba"); zeige("foobar");
  var o: int64 := alloc(64);
  PrintLn(Encode("", o as pchar));
  var u: int64 := alloc(64);
  PrintLn(EncodeUrlSafe("\xfb\xff", u as pchar));
  PrintLn(u as pchar);
  var d: int64 := alloc(64);
  var m: int64 := Decode("Zm9vYmE=", d as pchar, 64);
  poke8(d + m, 0);
  Print(m); Print(":"); PrintLn(d as pchar);
  return 0;
}' "4:Zg== 4:Zm8= 4:Zm9v 8:Zm9vYg== 8:Zm9vYmE= 8:Zm9vYmFy 0 3 -_8 5:fooba"

out "SortInt64 gegen Einfuegesortierung (Zufall, Duplikate, sortiert, umgekehrt)" 'import std.io;
import std.alloc;
import std.sort;
fn pruefe(a: int64, n: int64): int64 {
  var r: int64 := alloc(n * 8 + 8);
  var i: int64 := 0;
  while (i < n) { poke64(r + i * 8, peek64(a + i * 8)); i += 1; }
  i := 1;
  while (i < n) {
    var k: int64 := peek64(r + i * 8);
    var j: int64 := i - 1;
    while (j >= 0) {
      if (peek64(r + j * 8) <= k) { break; }
      poke64(r + j * 8 + 8, peek64(r + j * 8));
      j -= 1;
    }
    poke64(r + j * 8 + 8, k);
    i += 1;
  }
  SortInt64(a, n);
  var f: int64 := 0;
  i := 0;
  while (i < n) { if (peek64(a + i * 8) != peek64(r + i * 8)) { f += 1; } i += 1; }
  return f;
}
fn main(): int64 {
  var n: int64 := 3000;
  var a: int64 := alloc(n * 8);
  var x: int64 := 99;
  var fehler: int64 := 0;
  var art: int64 := 0;
  while (art < 4) {
    var i: int64 := 0;
    while (i < n) {
      x := x * 6364136223846793005 + 1442695040888963407;
      var v: int64 := x >> 20;
      if (art == 1) { v := (x >> 33) % 7; }
      if (art == 2) { v := i; }
      if (art == 3) { v := n - i; }
      poke64(a + i * 8, v);
      i += 1;
    }
    fehler := fehler + pruefe(a, n);
    var k: int64 := 1;
    while (k < 12) { fehler := fehler + pruefe(a, k); k += 1; }
    art += 1;
  }
  PrintLn(fehler);
  return 0;
}' "0"

out "StringBuilder: ueber die Kapazitaet hinaus, Zahlen" 'import std.io;
import std.string;
fn main(): int64 {
  var sb: StringBuilder := new StringBuilder();
  sb.Init(4);
  var i: int64 := 0;
  while (i < 300) { sb.Append("ab"); sb.AppendInt(i - 150); sb.AppendChar(59); i += 1; }
  var s: pchar := sb.ToString();
  PrintLn(sb.Length());
  PrintLn(StrCount(s, ";"));
  PrintLn(StrFind(s, "ab-150;ab-149;"));
  PrintLn(StrFind(s, "ab149;"));
  return 0;
}' "1732 300 0 1726"

echo "std_laufzeit_2228: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
