#!/usr/bin/env bash
# tests/stdlib_z20_test.sh — #1533, #1585, #1563, #1564, #1578.
#
# Fuenf Maengel in der Ausruestung der Standardbibliothek:
#
#   #1533 FileModTime las Offset 80 (st_atime_nsec) statt 88 (st_mtime) und
#         lieferte damit fuer JEDE Datei 0. In lpm lief eine 1-Stunden-TTL nie
#         ab — der Spiegel galt als "nie gesetzt", jeder Aufruf ging ins Netz.
#         Die Offset-Tabelle im Quelltext war selbst falsch (die _nsec-Felder
#         fehlten), sie ist mitkorrigiert.
#   #1585 std/cpu/dispatch.lyx hatte 13 Funktionen und KEIN einziges pub — die
#         Unit liess sich importieren, aber nichts daraus benutzen.
#   #1563 Die kompilierte Regex-API war doppelt unbenutzbar: es gab keinen
#         Erzeuger fuer den Bytecode, UND der Leser las das Programm mit
#         StrSafeCharAt, das seine Grenze per StrLen bestimmt — der Kopf traegt
#         bei Offset 3 eine Null, also endete jedes Programm nach drei Bytes.
#   #1564 REGEX_FLAG_MULTILINE wurde entgegengenommen, aber vom Abgleich nie
#         ausgewertet: `^` und `$` meinten weiter Textanfang und -ende.
#   #1578 SinF64/CosF64 ohne Argumentreduktion in der ausgelieferten std.
#
# GEMESSEN WIRD GEGEN EINE REFERENZ: die Zeitstempel gegen `stat -c %Y`, die
# Winkelfunktionen gegen bekannte Werte, die kompilierte Regex-API gegen die
# Muster-API. Ein Test, der nur die eigene Bibliothek gegen sich selbst
# haelt, haette #1578 nicht gefunden.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >"$TMP/c.log" 2>&1; then
    no "$1" "uebersetzt nicht: $(grep -m1 -iE 'error|sema|Parse' "$TMP/c.log")"; return
  fi
  got="$(timeout 30 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then no "$1" "ABSTURZ rc=$rc"; return; fi
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1" "'$got' erwartet '$3'"; fi
}

# ===========================================================================
# #1533 — FileModTime gegen `stat` als Referenz
# ===========================================================================
PROBE="$TMP/mtime-probe"
: > "$PROBE"
touch -d '2020-01-02 03:04:05' "$PROBE"
ECHT="$(stat -c %Y "$PROBE")"

printf 'import std.io;\nimport std.fs;\nfn main(): int64 { PrintLn(IntToStr(FileModTime("%s"c))); return 0; }\n' "$PROBE" > "$TMP/mt.lyx"
if timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/mt.lyx" -o "$TMP/mt" >"$TMP/mt.log" 2>&1; then
  got="$("$TMP/mt" 2>&1)"
  if [ "$got" = "$ECHT" ]; then ok "#1533: FileModTime stimmt mit stat ueberein ($ECHT)"
  else no "#1533: FileModTime" "'$got' erwartet '$ECHT'"; fi
else
  no "#1533: FileModTime" "$(grep -m1 -i error "$TMP/mt.log")"
fi

# Gegenprobe: FileAccessTime (Offset 72) war immer richtig und muss es bleiben.
ATIME="$(stat -c %X "$PROBE")"
printf 'import std.io;\nimport std.fs;\nfn main(): int64 { PrintLn(IntToStr(FileAccessTime("%s"c))); return 0; }\n' "$PROBE" > "$TMP/at.lyx"
if timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/at.lyx" -o "$TMP/at" >/dev/null 2>&1; then
  got="$("$TMP/at" 2>&1)"
  if [ "$got" = "$ATIME" ]; then ok "#1533: FileAccessTime unveraendert richtig"
  else no "#1533: FileAccessTime" "'$got' erwartet '$ATIME'"; fi
else
  no "#1533: FileAccessTime" "uebersetzt nicht"
fi

# Und der Fall, um den es ging: eine TTL kann jetzt ablaufen.
printf 'import std.io;\nimport std.fs;\nfn main(): int64 {\n  var m: int64 := FileModTime("%s"c);\n  if (m > 1500000000) { PrintLn("plausibel"); } else { PrintLn("null-oder-muell"); }\n  return 0;\n}\n' "$PROBE" > "$TMP/ttl.lyx"
if timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/ttl.lyx" -o "$TMP/ttl" >/dev/null 2>&1; then
  got="$("$TMP/ttl" 2>&1)"
  [ "$got" = "plausibel" ] && ok "#1533: Zeitstempel taugt fuer eine TTL" \
                           || no "#1533: TTL" "'$got'"
else
  no "#1533: TTL" "uebersetzt nicht"
fi

# ===========================================================================
# #1585 — std.cpu.dispatch ist von aussen benutzbar
# ===========================================================================
out "#1585: dispatch und features sind exportiert" 'import std.io;
import std.cpu.dispatch;
import std.cpu.features;
fn main(): int64 {
  var a: int64 := SimdAlloc(4);
  SimdSet(a, 0, 7); SimdSet(a, 1, 35);
  PrintStr(IntToStr(SimdLen(a))); PrintStr(" ");
  PrintStr(IntToStr(SimdGet(a, 0) + SimdGet(a, 1))); PrintStr(" ");
  if (CpuDispatchLevel() >= 0) { PrintStr("level-ok "); }
  if (CpuHasSSE2() == 0 || CpuHasSSE2() == 1) { PrintLn("sse2-abfragbar"); }
  return 0;
}' "4 42 level-ok sse2-abfragbar"

# ===========================================================================
# #1564 — MULTILINE wirkt auf ^ und $
# ===========================================================================
out "#1564: ^ und $ je Zeile mit MULTILINE, sonst unveraendert" 'import std.io;
import std.regex;
fn main(): int64 {
  var t: pchar := "abc\ndef";
  PrintStr(IntToStr(RegexSearchEx("^def", t, REGEX_FLAG_MULTILINE))); PrintStr(" ");
  PrintStr(IntToStr(RegexSearchEx("abc$", t, REGEX_FLAG_MULTILINE))); PrintStr(" ");
  PrintStr(IntToStr(RegexSearchEx("^abc", t, REGEX_FLAG_MULTILINE))); PrintStr(" ");
  PrintStr(IntToStr(RegexSearch("^def", t))); PrintStr(" ");
  PrintLn(IntToStr(RegexSearch("def$", t)));
  return 0;
}' "4 0 0 -1 4"

# ===========================================================================
# #1563 — die kompilierte API gegen die Muster-API
# ===========================================================================
# Die Pruefung aus dem Issue: fuer jedes Muster muss
# RegexSearchCompiled(RegexCompile(p), t) == RegexSearch(p, t) gelten.
out "#1563: kompilierte API deckt sich mit der Muster-API" 'import std.io;
import std.regex;
import std.alloc;
var fehler: int64 := 0;
fn Vgl(p: pchar, t: pchar) {
  var buf: int64 := alloc(8192);
  var n: int64 := RegexCompile(p, buf as pchar, 8192);
  var erwartet: int64 := RegexSearch(p, t);
  if (n == 0) {
    PrintStr("KEIN-BYTECODE:"); PrintLn(p);
    fehler := fehler + 1;
    return;
  }
  var bekommen: int64 := RegexSearchCompiled(buf as pchar, n, t);
  if (bekommen != erwartet) {
    PrintStr("ABWEICHUNG:"); PrintStr(p); PrintStr(" ");
    PrintStr(IntToStr(bekommen)); PrintStr("!="); PrintLn(IntToStr(erwartet));
    fehler := fehler + 1;
  }
}
fn main(): int64 {
  Vgl("abc", "xxabc");
  Vgl("a+b", "aaab");
  Vgl("a*b", "b");
  Vgl("ab?c", "ac");
  Vgl("a.c", "xazc");
  Vgl("[0-9]+", "abc123");
  Vgl("[^0-9]+", "123abc");
  Vgl("\\d+", "xx42");
  Vgl("\\w+", "  wort");
  Vgl("\\s", "ab cd");
  Vgl("^abc", "abcdef");
  Vgl("abc$", "xxabc");
  Vgl("(ab)+", "xabab");
  Vgl("a|b", "zzb");
  Vgl("cat|dog", "hotdog");
  Vgl("[a-z]+@[a-z]+", "mail: user@host");
  Vgl("x", "keintreffer");
  Vgl("qqq", "abc");
  PrintStr("abweichungen="); PrintLn(IntToStr(fehler));
  return 0;
}' "abweichungen=0"

# Der Leser fuer sich: ein Programm enthaelt Nullbytes, es ist keine
# Zeichenkette. Genau daran scheiterte er (StrLen stoppt bei Offset 3).
out "#1563: Bytecode mit Nullbytes wird vollstaendig gelesen" 'import std.io;
import std.regex;
import std.alloc;
fn main(): int64 {
  var buf: int64 := alloc(4096);
  var n: int64 := RegexCompile("ab"c, buf as pchar, 4096);
  PrintStr(IntToStr(n)); PrintStr(" ");
  PrintStr(IntToStr(peek8(buf + 3)));   // Nullbyte im Kopf
  PrintStr(" ");
  PrintLn(IntToStr(RegexSearchCompiled(buf as pchar, n, "xab"c)));
  return 0;
}' "37 0 1"

# Gegenprobe: ein Muster, das der Uebersetzer nicht kennt, liefert 0 statt
# eines halben Programms.
out "#1563: unuebersetzbares Muster liefert 0" 'import std.io;
import std.regex;
import std.alloc;
fn main(): int64 {
  var buf: int64 := alloc(4096);
  PrintStr(IntToStr(RegexCompile("(unfertig"c, buf as pchar, 4096))); PrintStr(" ");
  PrintLn(IntToStr(RegexCompile("ab"c, buf as pchar, 4)));   // Puffer zu klein
  return 0;
}' "0 0"

# ===========================================================================
# #1578 — Winkelfunktionen gegen bekannte Werte
# ===========================================================================
# Referenzwerte aus Python (math.sin/math.cos), auf 9 Stellen.
out "#1578: SinF64/CosF64 mit Argumentreduktion" 'import std.io;
import std.math;
fn main(): int64 {
  PrintStr(FloatToStr(SinF64(0.0 - 6.282895), 9)); PrintStr(" ");
  PrintStr(FloatToStr(CosF64(0.3), 9)); PrintStr(" ");
  PrintLn(FloatToStr(SinF64(5.7), 9));
  return 0;
}' "0.000290307 0.955336489 -0.550685543"

# Der Wertebereich muss halten — daran ist der Fehler aufgefallen (-11.89).
out "#1578: |sin| <= 1 ueber mehrere Perioden" 'import std.io;
import std.math;
fn main(): int64 {
  var x: f64 := 0.0 - 20.0;
  var schlecht: int64 := 0;
  while (x < 20.0) {
    var s: f64 := SinF64(x);
    var c: f64 := CosF64(x);
    if (s > 1.0 || s < 0.0 - 1.0) { schlecht := schlecht + 1; }
    if (c > 1.0 || c < 0.0 - 1.0) { schlecht := schlecht + 1; }
    x := x + 0.1;
  }
  PrintStr("ausreisser="); PrintLn(IntToStr(schlecht));
  return 0;
}' "ausreisser=0"

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
