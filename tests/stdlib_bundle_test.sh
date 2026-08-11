#!/usr/bin/env bash
# tests/stdlib_bundle_test.sh — #1259, #1269, #1270, #1243, #1244.
#
# Fuenf Defekte der Standardbibliothek, alle vom selben Zuschnitt:
# veroeffentlichte API, die uebersetzt, laeuft und etwas anderes tut als
# zugesagt — ohne Meldung.
#
# #1259 std.string: StrReplace verlor den Text ZWISCHEN zwei Treffern (ein
#       Zaehler diente als Ziel- UND Quellindex), und fuenf Funktionen
#       arbeiteten auf demselben 80-Zeichen-String-LITERAL — zwei Aufrufe
#       hintereinander lieferten denselben Zeiger.
# #1269 std.json: find_matching wurde mit dem Index NACH der oeffnenden
#       Klammer gerufen, zaehlte sie deshalb nie mit und lieferte immer -1.
#       Gueltiges JSON galt als ungueltig, `nonsense` als gueltig.
# #1270 std.pack: UnpackInt32/16/8 ohne Vorzeichen-Zuschnitt; UnpackString
#       zeigte auf das Laengenpraefix statt auf die Zeichen.
# #1243 std.result: die vier Higher-Order-Funktionen verpackten die ADRESSE
#       der uebergebenen Funktion, statt sie zu rufen. Bei AndThen wurde damit
#       aus einem Err ein Ok mit Muellwert.
# #1244 sieben leere pub-fn-Ruempfe: Log-Callback jetzt umgesetzt, die vier
#       ini/yaml-Huellen brechen sichtbar ab statt Erfolg vorzutaeuschen.

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
  got="$(timeout 10 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then no "$1" "ABSTURZ (rc=$rc)"; return; fi
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1" "'$got' erwartet '$3'"; fi
}

# ===========================================================================
# #1259 — std.string
# ===========================================================================

out "StrReplace behaelt den Text zwischen den Treffern" 'import std.io;
import std.string;
fn main(): int64 {
  var b1: pchar := alloc(64) as pchar;
  StrReplace(b1, "aXbXc"c, "X"c, "--"c); PrintLn(b1);
  var b2: pchar := alloc(64) as pchar;
  StrReplace(b2, "aXbXcXd"c, "X"c, "Y"c); PrintLn(b2);
  var b3: pchar := alloc(64) as pchar;
  StrReplace(b3, "aXbXcXd"c, "X"c, "YY"c); PrintLn(b3);
  return 0;
}' "a--b--c
aYbYcYd
aYYbYYcYYd"

# Gegenproben: die Faelle, die schon vorher stimmten, bleiben unveraendert.
out "StrReplace: Einzeltreffer, leerer Ersatz, kein Treffer" 'import std.io;
import std.string;
fn main(): int64 {
  var b1: pchar := alloc(64) as pchar;
  StrReplace(b1, "aXb"c, "X"c, "--"c); PrintLn(b1);
  var b2: pchar := alloc(64) as pchar;
  StrReplace(b2, "aXb"c, "X"c, ""c); PrintLn(b2);
  var b3: pchar := alloc(64) as pchar;
  StrReplace(b3, "keine"c, "X"c, "--"c); PrintLn(b3);
  return 0;
}' "a--b
ab
keine"

# Der zweite Teil von #1259: zwei Ergebnisse muessen unabhaengig sein.
out "zwei Char-Ergebnisse ueberschreiben sich nicht mehr" 'import std.io;
import std.string;
fn main(): int64 {
  var a: pchar := StrFirstCharToUpper("hallo"c);
  var b: pchar := StrFirstCharToUpper("welt"c);
  PrintLn(a);
  PrintLn(b);
  return 0;
}' "Hallo
Welt"

# ===========================================================================
# #1269 — std.json
# ===========================================================================

out "isValidJSON urteilt richtig" 'import std.io;
import std.json;
fn main(): int64 {
  if (isValidJSON("{\"a\":1}"c)) { PrintLn("obj ok"); } else { PrintLn("obj falsch"); }
  if (isValidJSON("[1,2,3]"c)) { PrintLn("arr ok"); } else { PrintLn("arr falsch"); }
  if (isValidJSON("nonsense"c)) { PrintLn("muell falsch"); } else { PrintLn("muell ok"); }
  if (isValidJSON("{unbalanced"c)) { PrintLn("offen falsch"); } else { PrintLn("offen ok"); }
  if (isValidJSON(""c)) { PrintLn("leer falsch"); } else { PrintLn("leer ok"); }
  return 0;
}' "obj ok
arr ok
muell ok
offen ok
leer ok"

# Die Literale und Zahlen, die der Standard kennt, bleiben gueltig — sonst
# waere die Verschaerfung zu weit gegangen.
out "Literale und Zahlen bleiben gueltiges JSON" 'import std.io;
import std.json;
fn main(): int64 {
  if (isValidJSON("true"c)) { PrintLn("true ok"); } else { PrintLn("true falsch"); }
  if (isValidJSON("42"c)) { PrintLn("zahl ok"); } else { PrintLn("zahl falsch"); }
  if (isValidJSON("-3.5"c)) { PrintLn("float ok"); } else { PrintLn("float falsch"); }
  return 0;
}' "true ok
zahl ok
float ok"

out "parseArray liefert die Elemente" 'import std.io;
import std.json;
fn main(): int64 {
  var d: pchar := alloc(128) as pchar;
  PrintLn(IntToStr(parseArray(d, "[1,2,3]"c)));
  PrintLn(d);
  return 0;
}' "0
1|2|3"

# ===========================================================================
# #1270 — std.pack
# ===========================================================================

out "negative Zahlen ueberleben den Roundtrip" 'import std.io;
import std.pack;
fn main(): int64 {
  var b: int64 := alloc(64);
  PackInt32(b, 0, 0 - 1000); PrintLn(IntToStr(UnpackInt32(b, 0)));
  PackInt16(b, 0, 0 - 300);  PrintLn(IntToStr(UnpackInt16(b, 0)));
  PackInt8(b, 0, 0 - 5);     PrintLn(IntToStr(UnpackInt8(b, 0)));
  return 0;
}' "-1000
-300
-5"

# Gegenprobe: positive Werte und die Grenzen bleiben richtig.
out "positive Werte und Grenzen unveraendert" 'import std.io;
import std.pack;
fn main(): int64 {
  var b: int64 := alloc(64);
  PackInt32(b, 0, 2147483647); PrintLn(IntToStr(UnpackInt32(b, 0)));
  PackInt16(b, 0, 32767);      PrintLn(IntToStr(UnpackInt16(b, 0)));
  PackInt8(b, 0, 127);         PrintLn(IntToStr(UnpackInt8(b, 0)));
  PackInt32(b, 0, 0);          PrintLn(IntToStr(UnpackInt32(b, 0)));
  return 0;
}' "2147483647
32767
127
0"

out "UnpackString zeigt hinter das Laengenpraefix" 'import std.io;
import std.pack;
fn main(): int64 {
  var b: int64 := alloc(64);
  PackString(b, 0, "Hallo"c);
  var sp: int64 := UnpackString(b, 0);
  PrintLn(IntToStr(sp - b));
  var sptr: pchar := sp as pchar;
  PrintLn(sptr);
  return 0;
}' "1
Hallo"

# ===========================================================================
# #1243 — std.result
# ===========================================================================

out "die Higher-Order-Funktionen rufen die Funktion" 'import std.io;
import std.result;
fn Verdopple(v: int64): int64 { return v * 2; }
fn Fehler(e: int64): int64 { return e + 9; }
fn Kette(v: int64): ResultInt64 { return OkInt64(v * 10); }
fn main(): int64 {
  PrintLn(IntToStr(ResultInt64Unwrap(ResultInt64Map(OkInt64(21), Verdopple as int64))));
  PrintLn(IntToStr(ResultInt64Error(ResultInt64MapErr(ErrInt64(2), Fehler as int64))));
  PrintLn(IntToStr(ResultInt64Unwrap(ResultInt64AndThen(OkInt64(42), Kette as int64))));
  return 0;
}' "42
11
420"

# Der schwerere Effekt aus dem Bericht: AndThen muss den Fehler durchreichen.
out "AndThen reicht den Fehler der verketteten Funktion durch" 'import std.io;
import std.result;
fn KetteErr(v: int64): ResultInt64 { return ErrInt64(7); }
fn main(): int64 {
  var r: ResultInt64 := ResultInt64AndThen(OkInt64(42), KetteErr as int64);
  if (ResultInt64IsOk(r)) { PrintLn("falsch ok"); } else { PrintLn("Err erkannt"); }
  return 0;
}' "Err erkannt"

# Gegenprobe: ein Err am Eingang wird NICHT durch die Funktion geschickt.
out "Map laesst ein Err unangetastet" 'import std.io;
import std.result;
fn Verdopple(v: int64): int64 { return v * 2; }
fn main(): int64 {
  var r: ResultInt64 := ResultInt64Map(ErrInt64(5), Verdopple as int64);
  PrintLn(IntToStr(ResultInt64Error(r)));
  return 0;
}' "5"

# ===========================================================================
# #1244 — leere pub-fn-Ruempfe
# ===========================================================================

out "Log-Callback wird registriert, gerufen und abgemeldet" 'import std.io;
import std.log;
fn MeinHandler(msg: pchar): void { PrintLn("HANDLER: ", msg); }
fn main(): int64 {
  if (has_log_callback()) { PrintLn("falsch: vorher gesetzt"); } else { PrintLn("vorher keiner"); }
  register_log_callback(MeinHandler as int64);
  if (has_log_callback()) { PrintLn("registriert"); } else { PrintLn("falsch: nicht registriert"); }
  log_info("hallo");
  unregister_log_callback();
  if (has_log_callback()) { PrintLn("falsch: noch gesetzt"); } else { PrintLn("abgemeldet"); }
  return 0;
}' "vorher keiner
registriert
[INFO] hallo
HANDLER: hallo
abgemeldet"

# Die vier nicht umgesetzten Huellen brechen sichtbar ab, statt Erfolg
# vorzutaeuschen. Geprueft wird der Abbruch, nicht nur die Meldung.
printf '%s\n' 'import std.io;
import std.yaml;
fn main(): int64 {
  SetArray(0, "a"c, "b"c, 1);
  PrintLn("haette nicht kommen duerfen");
  return 0;
}' > "$TMP/y.lyx"
if "$LYXC" --std-path="$ROOT" "$TMP/y.lyx" -o "$TMP/y" >/dev/null 2>&1; then
  got="$("$TMP/y" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] && echo "$got" | grep -q "nicht umgesetzt"; then
    ok "nicht umgesetzte Huelle bricht sichtbar ab"
  else
    no "nicht umgesetzte Huelle" "rc=$rc, Ausgabe '$got'"
  fi
else
  no "nicht umgesetzte Huelle" "uebersetzt nicht"
fi

echo
echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
