#!/usr/bin/env bash
# tests/alloc_pool_test.sh — #1258: std/alloc.lyx bedient kleine Anforderungen
# aus einem Pool statt aus je einem mmap.
#
# Der Bericht vermutete die Ursache der Laufzeit in der SHA-256-Kompression von
# SLH-DSA. Sie lag woanders: alloc() setzte JEDE Anforderung in ein eigenes
# mmap um, free() in ein munmap. Gemessen an SLHParamsMini-KeyGen — 18.080 mmap
# und 18.074 munmap fuer einen einzigen Schluessel. Bei SLHParams128s waren es
# hochgerechnet ueber eine Million Paare; von 94 s Laufzeit entfielen 58,8 s auf
# den Kernel und nur 31,9 s auf das Rechnen.
#
# Geprueft wird deshalb der WEG, nicht die Laufzeit: die Zahl der Syscalls. Eine
# Zeitmessung waere auf einer anderen Maschine ein anderer Wert und auf einer
# ausgelasteten unbrauchbar; die Zahl der mmap-Aufrufe ist die Eigenschaft, um
# die es geht.
#
# Die Korrektheitsproben sind der eigentliche Kern: ein Allokator, der schnell
# ist und falschen Speicher herausgibt, waere ungleich schlimmer als der langsame
# davor. Besonders die Null-Garantie — allocZeroed() ist nur ein anderer Name
# fuer alloc(), und der Bestand verlaesst sich darauf.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    no "$1" "uebersetzt nicht"; return
  fi
  got="$(timeout 120 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then no "$1" "ABSTURZ (rc=$rc)"; return; fi
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1" "'$got' erwartet '$3'"; fi
}

# ===========================================================================
# Korrektheit
# ===========================================================================

out "frischer und wiederverwendeter Speicher sind genullt" 'import std.io;
import std.alloc;
fn main(): int64 {
  var a: int64 := alloc(64);
  var nz: int64 := 0;
  var i: int64 := 0;
  while (i < 64) { if (peek8(a + i) != 0) { nz := nz + 1; } i := i + 1; }
  PrintLn(IntToStr(nz));
  i := 0; while (i < 64) { poke8(a + i, 255); i := i + 1; }
  free(a, 64);
  var b: int64 := alloc(64);
  nz := 0; i := 0;
  while (i < 64) { if (peek8(b + i) != 0) { nz := nz + 1; } i := i + 1; }
  PrintLn(IntToStr(nz));
  PrintLn(IntToStr(a == b));
  return 0;
}' "0
0
1"

# Die zweite Null oben ist der Kern: der Block wurde vor dem free mit 255
# vollgeschrieben und kommt trotzdem genullt zurueck. Die dritte Zeile belegt,
# dass er ueberhaupt wiederverwendet wurde — sonst haette die Probe nichts
# gemessen.

out "gleichzeitig gehaltene Bloecke ueberlappen nicht" 'import std.io;
import std.alloc;
fn main(): int64 {
  var p: int64 := alloc(64);
  var q: int64 := alloc(64);
  var r: int64 := alloc(64);
  poke64(p, 1111); poke64(q, 2222); poke64(r, 3333);
  PrintLn(IntToStr(peek64(p)));
  PrintLn(IntToStr(peek64(q)));
  PrintLn(IntToStr(peek64(r)));
  return 0;
}' "1111
2222
3333"

# Die Grenze zwischen Pool und eigenem mmap (APOOL_MAX = 4096) ist die Stelle,
# an der ein Fehler am ehesten sitzt: beide Wege muessen benutzbaren Speicher
# liefern, und free() muss beide richtig behandeln.
out "beide Wege an der Groessengrenze" 'import std.io;
import std.alloc;
fn main(): int64 {
  var s: int64 := alloc(4096);
  var l: int64 := alloc(4097);
  poke64(s, 7); poke64(l, 9);
  PrintLn(IntToStr(peek64(s)));
  PrintLn(IntToStr(peek64(l)));
  free(s, 4096);
  free(l, 4097);
  var s2: int64 := alloc(4096);
  poke64(s2, 5);
  PrintLn(IntToStr(peek64(s2)));
  return 0;
}' "7
9
5"

out "verschiedene Groessenklassen bleiben unterscheidbar" 'import std.io;
import std.alloc;
fn main(): int64 {
  var a: int64 := alloc(8);
  var b: int64 := alloc(200);
  var c: int64 := alloc(1000);
  var d: int64 := alloc(3000);
  poke64(a, 11); poke64(b, 22); poke64(c, 33); poke64(d, 44);
  PrintLn(IntToStr(peek64(a)));
  PrintLn(IntToStr(peek64(b)));
  PrintLn(IntToStr(peek64(c)));
  PrintLn(IntToStr(peek64(d)));
  return 0;
}' "11
22
33
44"

# Ein free vor dem ersten alloc darf nicht abstuerzen — die Kopftabelle der
# Freilisten wird von beiden Seiten gebraucht.
out "free vor dem ersten alloc" 'import std.io;
import std.alloc;
fn main(): int64 {
  var p: int64 := alloc(32);
  free(p, 32);
  free(0, 64);
  var q: int64 := alloc(32);
  poke64(q, 5);
  PrintLn(IntToStr(peek64(q)));
  return 0;
}' "5"

# 200.000 Runden: ohne Wiederverwendung waere hier der Adressraum aufgebraucht
# oder der Prozess vom Speicherlimit erschlagen worden.
out "viele Runden alloc/free wachsen nicht unbegrenzt" 'import std.io;
import std.alloc;
fn main(): int64 {
  var k: int64 := 0;
  while (k < 200000) {
    var t: int64 := alloc(128);
    poke64(t, k);
    free(t, 128);
    k := k + 1;
  }
  PrintLn("durch");
  return 0;
}' "durch"

# Die Schutzwaelle aus WP-26 muessen erhalten geblieben sein.
out "Zero-Alloc-Guard und 1-GB-Grenze unveraendert" 'import std.io;
import std.alloc;
fn main(): int64 {
  var z: int64 := alloc(0);
  if (z != 0) { PrintLn("0 liefert Speicher"); } else { PrintLn("0 lieferte nichts"); }
  PrintLn(IntToStr(alloc(1073741825)));
  return 0;
}' "0 liefert Speicher
0"

# ===========================================================================
# Der Weg: Zahl der Syscalls
# ===========================================================================
# Ohne diese Probe waeren alle Korrektheitspruefungen oben auch mit dem alten
# Allokator gruen — gemessen werden soll aber genau die Aenderung.

if command -v strace >/dev/null 2>&1; then
  printf '%s\n' 'import std.io;
import std.alloc;
fn main(): int64 {
  var k: int64 := 0;
  while (k < 20000) {
    var t: int64 := alloc(64);
    poke64(t, k);
    free(t, 64);
    k := k + 1;
  }
  PrintLn("durch");
  return 0;
}' > "$TMP/sys.lyx"
  if "$LYXC" --std-path="$ROOT" "$TMP/sys.lyx" -o "$TMP/sys" >/dev/null 2>&1; then
    n=$(timeout 120 strace -c -e trace=mmap "$TMP/sys" 2>&1 | awk '/ mmap$/ {print $4}')
    [ -z "$n" ] && n=0
    # 20.000 Runden: vorher 20.000 mmap, jetzt eine Handvoll (Programmstart,
    # ein Pool-Block, die Kopftabelle). Die Schwelle ist bewusst grosszuegig —
    # gemessen wird die Groessenordnung, nicht eine exakte Zahl.
    if [ "$n" -lt 100 ]; then
      ok "20.000 alloc/free brauchen $n mmap statt 20.000"
    else
      no "Syscall-Zahl" "$n mmap fuer 20.000 Runden — der Pool greift nicht"
    fi
  else
    no "Syscall-Zahl" "uebersetzt nicht"
  fi
else
  echo "SKIP Syscall-Zahl (strace nicht vorhanden)"
fi

# ===========================================================================
# Der Anlass: SLH-DSA
# ===========================================================================
# Geprueft wird die Syscall-Zahl der Mini-Variante, nicht die Laufzeit von
# 128s — die dauert auch nach dem Fix 13 s und waere als Dauertest zu teuer.

if command -v strace >/dev/null 2>&1; then
  printf '%s\n' 'import std.io;
import std.crypto.pqc.slhdsa;
fn main(): int64 {
  var ps: int64 := alloc(SLH_PS);
  SLHParamsMini(ps);
  var skseed: int64 := alloc(32);
  var skprf:  int64 := alloc(32);
  var pkseed: int64 := alloc(32);
  var sk: int64 := alloc(64);
  var pk: int64 := alloc(32);
  SLHDSAKeyGen(ps, skseed, skprf, pkseed, sk, pk);
  PrintLn("keygen fertig");
  return 0;
}' > "$TMP/slh.lyx"
  if "$LYXC" --std-path="$ROOT" "$TMP/slh.lyx" -o "$TMP/slh" >/dev/null 2>&1; then
    got="$(timeout 120 "$TMP/slh" 2>&1)"
    if [ "$got" != "keygen fertig" ]; then
      no "SLH-DSA KeyGen" "'$got'"
    else
      n=$(timeout 120 strace -c -e trace=mmap "$TMP/slh" 2>&1 | awk '/ mmap$/ {print $4}')
      [ -z "$n" ] && n=0
      if [ "$n" -lt 100 ]; then
        ok "SLH-DSA Mini-KeyGen braucht $n mmap statt 18.080"
      else
        no "SLH-DSA Syscalls" "$n mmap — vorher 18.080, erwartet unter 100"
      fi
    fi
  else
    no "SLH-DSA" "uebersetzt nicht"
  fi
fi

echo
echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
