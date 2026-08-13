#!/usr/bin/env bash
# tests/base64_haerte_test.sh — #1406, #1407, #1408, #1409.
#
# Vier Meldungen zu std.base64, alle in derselben Datei, drei davon derselbe
# Fehlertyp: eine Prüfung, die zwar dasteht, aber nie zutrifft.
#
#   #1406  max_output_len wurde durchgereicht und nirgends ausgewertet
#          → Heap-Overflow beim Dekodieren fremder Daten
#   #1407  Umkehrtabelle markiert ungültige Zeichen mit -1, gelesen wird sie
#          mit StrCharAt (vorzeichenlos) → aus -1 wird 255, `v < 0` nie wahr
#   #1408  128-Byte-Tabelle je Decode-Aufruf, nie freigegeben
#   #1409  HasValidPadding: drei Zweige, alle `true`, `return false` tot
#
# Der gemeinsame Nenner ist NICHT "vergessene Prüfung", sondern eine Prüfung,
# die vorhanden und richtig gedacht ist und trotzdem nicht greift. Ein Test,
# der nur den Gutfall prüft, wäre in allen vier Fällen grün geblieben —
# deshalb steht hier jeweils der SCHLECHTE Fall im Mittelpunkt.
#
# Die Reproduktionen sind aus den Issues übernommen, nicht nacherzählt.

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
# #1406 — max_output_len wird ausgewertet
# ===========================================================================

# Die Reproduktion aus dem Issue: 40 Byte in einen 8-Byte-Puffer. Geprüft wird
# NICHT nur der Rückgabewert, sondern der Nachbarblock — ein Dekoder, der -2
# meldet und trotzdem schreibt, fällt hier auf.
out "#1406: zu kleiner Puffer meldet -2 und laesst den Nachbarn in Ruhe" 'import std.io;
import std.base64;
import std.alloc;
import std.string;

fn main(): int64 {
    var klein: int64 := alloc(8);
    var wache: int64 := alloc(64);
    var i: int64 := 0;
    while (i < 64) { poke8(wache + i, 0x7A); i := i + 1; }

    var lang: pchar := "MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MDEyMzQ1Njc4OQ=="c;
    var n: int64 := Decode(lang, klein as pchar, 8);
    PrintLn(StrConcat("Rueckgabe: ", IntToStr(n)));
    PrintLn(StrConcat("Nachbarbyte (erwartet 122): ", IntToStr(peek8(wache))));
    return 0;
}' "Rueckgabe: -2
Nachbarbyte (erwartet 122): 122"

# Genau passend darf nicht abgewiesen werden — sonst waere aus dem Fix ein
# Fehler in der Gegenrichtung geworden (Grenze off-by-one).
out "#1406: genau passender Puffer wird nicht abgewiesen" 'import std.io;
import std.base64;
import std.alloc;
import std.string;
fn main(): int64 {
    var o: int64 := alloc(16);
    PrintStr(IntToStr(Decode("Zm9vYmFy"c, o as pchar, 6))); PrintStr(" ");
    PrintLn(IntToStr(Decode("Zm9vYmFy"c, o as pchar, 5)));
    return 0;
}' "6 -2"

out "#1406: max_output_len 0 schreibt auch keine Null" 'import std.io;
import std.base64;
import std.alloc;
import std.string;
fn main(): int64 {
    var o: int64 := alloc(8);
    poke8(o, 77);
    PrintStr(IntToStr(Decode(""c, o as pchar, 0))); PrintStr(" ");
    PrintLn(IntToStr(peek8(o)));
    return 0;
}' "-2 77"

# ===========================================================================
# #1407 — ungueltige Zeichen werden erkannt
# ===========================================================================

# Reproduktion aus dem Issue. Der dritte Wert belegt die Ursache: StrCharAt
# liefert vorzeichenlos, deshalb konnte `v < 0` nie zutreffen. Er bleibt 255 —
# geaendert wurde nicht StrCharAt, sondern die Pruefung.
out "#1407: ungueltige Zeichen liefern -1" 'import std.io;
import std.base64;
import std.alloc;
import std.string;

fn main(): int64 {
    var out: int64 := alloc(256);
    PrintLn(StrConcat("Decode(***=):        ", IntToStr(Decode("***="c, out as pchar, 256))));
    PrintLn(StrConcat("Decode(-_-_):        ", IntToStr(Decode("-_-_"c, out as pchar, 256))));

    var t: int64 := alloc(16);
    StrSetChar(t as pchar, 0, 0 - 1);
    PrintLn(StrConcat("StrSetChar(-1) -> StrCharAt: ", IntToStr(StrCharAt(t as pchar, 0))));
    return 0;
}' "Decode(***=):        -1
Decode(-_-_):        -1
StrSetChar(-1) -> StrCharAt: 255"

# Der URL-sichere Dekoder muss dieselbe Eingabe annehmen, die der Standard
# abweist — sonst waere die Sperre zu weit geraten.
out "#1407: DecodeUrlSafe nimmt -_-_ weiterhin an" 'import std.io;
import std.base64;
import std.alloc;
import std.string;
fn main(): int64 {
    var o: int64 := alloc(64);
    PrintLn(IntToStr(DecodeUrlSafe("-_-_"c, o as pchar, 64)));
    return 0;
}' "3"

# Gutfall: gueltige Daten kommen unveraendert durch (Gegenprobe gegen eine zu
# scharfe Sperre).
out "#1407: gueltige Eingabe bleibt unveraendert" 'import std.io;
import std.base64;
import std.alloc;
import std.string;
fn main(): int64 {
    var o: int64 := alloc(64);
    var n: int64 := Decode("SGFsbG8gV2VsdA=="c, o as pchar, 64);
    StrSetChar(o as pchar, n, 0);
    PrintStr(IntToStr(n)); PrintStr(" "); PrintLn(o as pchar);
    return 0;
}' "10 Hallo Welt"

# Zeichen jenseits von 127 laufen nicht in die 128-Byte-Tabelle hinein.
out "#1407: Zeichen ueber 127 werden abgewiesen" 'import std.io;
import std.base64;
import std.alloc;
import std.string;
fn main(): int64 {
    var e: int64 := alloc(8);
    StrSetChar(e as pchar, 0, 200); StrSetChar(e as pchar, 1, 65);
    StrSetChar(e as pchar, 2, 65);  StrSetChar(e as pchar, 3, 65);
    StrSetChar(e as pchar, 4, 0);
    var o: int64 := alloc(64);
    PrintLn(IntToStr(Decode(e as pchar, o as pchar, 64)));
    return 0;
}' "-1"

# ===========================================================================
# #1408 — die Umkehrtabelle wird wiederverwendet
# ===========================================================================

# Reproduktion aus dem Issue: der Adressabstand der 128-Byte-Klasse vor und
# nach 1000 Dekodierungen. Vorher 128000, jetzt 0.
out "#1408: 1000 Decode-Aufrufe verbrauchen keinen Speicher" 'import std.io;
import std.base64;
import std.alloc;
import std.string;

fn main(): int64 {
    var out: int64 := alloc(64);
    Decode("Zm9vYmFy"c, out as pchar, 64);   // einmal vorwaermen: die Tabelle
                                             // entsteht genau einmal
    var a: int64 := alloc(128); free(a, 128);
    var vorher: int64 := alloc(128); free(vorher, 128);

    var i: int64 := 0;
    while (i < 1000) { Decode("Zm9vYmFy"c, out as pchar, 64); i := i + 1; }

    var nachher: int64 := alloc(128);
    PrintLn(StrConcat("Adressabstand der 128-Byte-Klasse: ", IntToStr(nachher - vorher)));
    return 0;
}' "Adressabstand der 128-Byte-Klasse: 0"

# Beide Tabellen im Wechsel — die Zwischenspeicher duerfen sich nicht
# gegenseitig ueberschreiben.
out "#1408: beide Tabellen im Wechsel bleiben richtig" 'import std.io;
import std.base64;
import std.alloc;
import std.string;
fn main(): int64 {
    var o: int64 := alloc(64);
    var i: int64 := 0;
    var s: int64 := 0;
    while (i < 50) {
      s := s + Decode("Zm9vYmFy"c, o as pchar, 64);
      s := s + DecodeUrlSafe("-_-_"c, o as pchar, 64);
      i := i + 1;
    }
    PrintStr(IntToStr(s)); PrintStr(" ");
    PrintLn(IntToStr(Decode("-_-_"c, o as pchar, 64)));
    return 0;
}' "450 -1"

# ===========================================================================
# #1409 — HasValidPadding urteilt wirklich
# ===========================================================================

out "#1409: a=b= und ==== sind ungueltig" 'import std.io;
import std.base64;
fn main(): int64 {
    if (HasValidPadding("a=b="c)) { PrintStr("true "); } else { PrintStr("false "); }
    if (HasValidPadding("===="c)) { PrintStr("true "); } else { PrintStr("false "); }
    if (IsValid("a=b="c))         { PrintLn("true"); }  else { PrintLn("false"); }
    return 0;
}' "false false false"

out "#1409: gueltiges Padding bleibt gueltig" 'import std.io;
import std.base64;
fn main(): int64 {
    if (HasValidPadding("Zm9vYmFy"c)) { PrintStr("true "); } else { PrintStr("false "); }
    if (HasValidPadding("Zm9vYmE="c)) { PrintStr("true "); } else { PrintStr("false "); }
    if (HasValidPadding("Zm9v"c))     { PrintStr("true "); } else { PrintStr("false "); }
    if (HasValidPadding("SGFsbG8gV2VsdA=="c)) { PrintLn("true"); } else { PrintLn("false"); }
    return 0;
}' "true true true true"

out "#1409: IsValid urteilt ueber echte Eingaben" 'import std.io;
import std.base64;
fn main(): int64 {
    if (IsValid("SGFsbG8gV2VsdA=="c)) { PrintStr("ja "); } else { PrintStr("nein "); }
    if (IsValid("Zm9vYmFy"c))         { PrintStr("ja "); } else { PrintStr("nein "); }
    if (IsValid("Zm9v="c))            { PrintStr("ja "); } else { PrintStr("nein "); }
    if (IsValid("=Zm9v"c))            { PrintLn("ja"); }  else { PrintLn("nein"); }
    return 0;
}' "ja ja nein nein"

# ===========================================================================
# Der Rundlauf bleibt heil — die eigentliche Gegenprobe zu allen vier Fixes
# ===========================================================================

out "Rundlauf ueber alle Restlaengen" 'import std.io;
import std.base64;
import std.alloc;
import std.string;
fn main(): int64 {
    var e: int64 := alloc(64);
    var d: int64 := alloc(64);
    EncodeBytes("a"c, 1, e as pchar);      PrintStr(e as pchar); PrintStr(" ");
    EncodeBytes("ab"c, 2, e as pchar);     PrintStr(e as pchar); PrintStr(" ");
    EncodeBytes("abc"c, 3, e as pchar);    PrintStr(e as pchar); PrintStr(" ");
    var n: int64 := Decode(e as pchar, d as pchar, 64);
    StrSetChar(d as pchar, n, 0);
    PrintLn(d as pchar);
    return 0;
}' "YQ== YWI= YWJj abc"

out "Basic-Auth-Rundlauf mit Freigabe" 'import std.io;
import std.base64;
import std.alloc;
import std.string;
fn main(): int64 {
    var hdr: int64 := alloc(256);
    var u: int64 := alloc(64);
    var p: int64 := alloc(64);
    var i: int64 := 0;
    while (i < 200) {
      EncodeBasicAuth("aladdin"c, "opensesame"c, hdr as pchar);
      DecodeBasicAuth(hdr as pchar, u as pchar, p as pchar);
      i := i + 1;
    }
    PrintStr(hdr as pchar); PrintStr(" ");
    PrintStr(u as pchar); PrintStr(" "); PrintLn(p as pchar);
    return 0;
}' "Basic YWxhZGRpbjpvcGVuc2VzYW1l aladdin opensesame"

# Derselbe Fehlertyp wie #1406, nur nicht gemeldet: der 512-Byte-Puffer in
# EncodeBasicAuth wurde ungeprueft beschrieben.
out "EncodeBasicAuth weist ein zu langes Paar ab" 'import std.io;
import std.base64;
import std.alloc;
import std.string;
fn main(): int64 {
    var lang: int64 := alloc(600);
    var i: int64 := 0;
    while (i < 599) { StrSetChar(lang as pchar, i, 120); i := i + 1; }
    StrSetChar(lang as pchar, 599, 0);
    var hdr: int64 := alloc(2048);
    PrintLn(IntToStr(EncodeBasicAuth("u"c, lang as pchar, hdr as pchar)));
    return 0;
}' "-2"

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
