#!/usr/bin/env bash
# tests/inttostr_2225_test.sh — IntToStr/StrFromInt belegen aus der Bump-Arena (#2225).
#
# Bis 1.2.19G holte jeder Aufruf ein eigenes mmap: eine ganze Seite und ein
# eigenes Mapping, nie freigegeben (StrFree ist ein No-op). 1000 Aufrufe
# kosteten 1000 mmap; nach rund einer Million war vm.max_map_count erschoepft
# und der Fehlerwert wurde als Puffer beschrieben — SIGSEGV, rc 139.
#
# Geprueft wird der WEG (Zahl der mmap je Aufruf) und die WIRKUNG (eine
# Million Aufrufe laufen durch), dazu die Werte an den Raendern: 0, negative
# Zahlen, der kleinste und der groesste int64. Der kleinste ist der Fall, an
# dem `0 - n` nicht mehr positiv wird.

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
  got="$( ulimit -c 0; ulimit -v 2000000; cd "$TMP" && timeout 60 "$TMP/$1" 2>&1 | tr '\n' ' ')"
  got="${got% }"
  if [ "$got" = "$3" ]; then ok "$1 ($got)"; else no "$1" "'$got' erwartet '$3'"; fi
}

out "Werte an den Raendern" 'import std.io;
fn main(): int64 {
  PrintStrLn(IntToStr(0));
  PrintStrLn(IntToStr(7));
  PrintStrLn(IntToStr(0 - 7));
  PrintStrLn(IntToStr(1234567890123));
  PrintStrLn(IntToStr(9223372036854775807));
  PrintStrLn(IntToStr(0 - 9223372036854775807 - 1));
  PrintStrLn(StrFromInt(0 - 42));
  return 0;
}' "0 7 -7 1234567890123 9223372036854775807 -9223372036854775808 -42"

# Viele lebende Ergebnisse gleichzeitig: keines darf ein anderes ueberschreiben.
out "1000 Ergebnisse bleiben gleichzeitig gueltig" 'import std.io;
import std.alloc;
fn main(): int64 {
  var t: int64 := alloc(1000 * 8);
  var i: int64 := 0;
  while (i < 1000) { poke64(t + i * 8, IntToStr(i * 1000003 - 500000000) as int64); i += 1; }
  var fehler: int64 := 0;
  i := 0;
  while (i < 1000) {
    var s: pchar := peek64(t + i * 8) as pchar;
    if (StrToInt(s) != i * 1000003 - 500000000) { fehler += 1; }
    i += 1;
  }
  PrintLn(fehler);
  return 0;
}' "0"

# Wirkung: 1,1 Mio Aufrufe — vorher SIGSEGV nach rund einer Million.
out "1,1 Mio Aufrufe laufen durch" 'import std.io;
fn main(): int64 {
  var i: int64 := 0; var sum: int64 := 0;
  while (i < 1100000) {
    var s: pchar := IntToStr(i);
    sum := sum + StrLen(s);
    StrFree(s);
    i += 1;
  }
  PrintLn(sum);
  return 0;
}' "6588890"

# Weg: 10000 Aufrufe duerfen nicht 10000 mmap kosten (Arena: 64-KiB-Bloecke).
if command -v strace >/dev/null 2>&1; then
  if bau weg 'import std.io;
fn main(): int64 {
  var i: int64 := 0; var sum: int64 := 0;
  while (i < 10000) { sum := sum + StrLen(IntToStr(i)); i += 1; }
  PrintLn(sum);
  return 0;
}'; then
    n=$(cd "$TMP" && strace -f -e trace=mmap "$TMP/weg" 2>&1 | grep -c '^mmap')
    if [ "$n" -le 20 ]; then ok "Weg: $n mmap fuer 10000 Aufrufe"
    else no "Weg" "$n mmap fuer 10000 Aufrufe (eins je Aufruf?)"; fi
  else no "Weg" "uebersetzt nicht"; fi
else
  no "Weg" "strace fehlt"
fi

echo "inttostr_2225: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
