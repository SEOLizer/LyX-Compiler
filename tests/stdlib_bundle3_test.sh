#!/usr/bin/env bash
# tests/stdlib_bundle3_test.sh — #1310, #1313, #1312, #1309, #1318.
#
# Fuenf Defekte der Standardbibliothek. Drei davon toeteten den Prozess, zwei
# lieferten still Falsches — und zwei der Ursachen sind dieselbe Klasse, die
# schon #1191 hatte: eine Bindung an die libc in einem Programm, das statisch
# gelinkt ist.
#
# #1310 std.base64: die Umkehrtabelle beider Decode-Wege wurde ueber
#       `extern fn libc_malloc` angelegt. Es gibt keine libc, an die gebunden
#       werden koennte — der Aufruf lieferte keinen Speicher, der erste
#       StrSetChar darauf toetete den Prozess.
#
# #1313 std.regex: drei Befunde. Der Anker `^` wurde nur VOR der Suchschleife
#       geprueft, nicht in ihr — `^[a-z]+$` scheiterte an `Hallo` beim `H`,
#       setzte dahinter neu an und fand `allo`. Fuer Eingabepruefung, wo
#       `^...$` fast immer steht, liess das zu viel durch. Gruppen und
#       Alternation gab es ueberhaupt nicht: `atomLen` gab fuer `(` eine 1
#       zurueck, `atomMatches` verglich die Klammer daraufhin WOERTLICH.
#
# #1312 std.yaml: `_yamlFindKey` suchte den ganzen Pfad als EINEN Schluessel und
#       nur auf oberster Ebene; eingerueckte Zeilen wurden ausdruecklich
#       uebersprungen. Jede verschachtelte Struktur war damit unerreichbar.
#       Dazu ein zweiter, unabhaengiger Fehler: der Schreibweg legt das
#       geaenderte Dokument in denselben Puffer zurueck und nimmt 65536 Byte an,
#       ParseString legte aber nur len+1 an — Zurueckgelesenes war verstuemmelt.
#
# #1309 std.net.socket: SocketCanRead gab fdSet frei und las danach mit FDIsSet
#       daraus. Auffallen konnte das nur, wenn select einen bereiten Deskriptor
#       meldet — bei Timeout kehrt die Funktion vorher zurueck. Deshalb starb
#       HTTPGet zuverlaessig, sobald der Server antwortete.
#
# #1318 std.crypto.sha256: die 64 Rundenkonstanten wurden vor JEDEM Block neu
#       geschrieben, und sha256Rotr32 wurde rund 576 Mal je Block gerufen.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
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
  got="$(timeout 60 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then no "$1" "ABSTURZ (rc=$rc)"; return; fi
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1" "'$got' erwartet '$3'"; fi
}

# ===========================================================================
# #1310 — std.base64
# ===========================================================================
# Geprueft wird gegen die Ausgabe von base64(1), nicht gegen den eigenen
# Roundtrip: Encode und Decode koennten auch zueinander konsistent und
# gemeinsam falsch sein.

out "Base64 kodiert wie base64(1) und der Roundtrip stimmt" 'import std.io;
import std.base64;
fn main(): int64 {
  var e: pchar := alloc(64) as pchar;
  Encode("Hallo Welt"c, e);
  PrintLn(e);
  var d: pchar := alloc(64) as pchar;
  Decode(e, d, 64);
  PrintLn(d);
  return 0;
}' "SGFsbG8gV2VsdA==
Hallo Welt"

out "die URL-sichere Variante ebenso" 'import std.io;
import std.base64;
fn main(): int64 {
  var u: pchar := alloc(64) as pchar;
  EncodeUrlSafe("ab~c?d"c, u);
  PrintLn(u);
  var du: pchar := alloc(64) as pchar;
  DecodeUrlSafe(u, du, 64);
  PrintLn(du);
  return 0;
}' "YWJ-Yz9k
ab~c?d"

# ===========================================================================
# #1313 — std.regex
# ===========================================================================

out "Anker gilt auch beim Neuansetzen" 'import std.io;
import std.regex;
fn t(p: pchar, s: pchar): void { PrintLn(IntToStr(RegexMatch(p, s))); }
fn main(): int64 {
  t("^[a-z]+$"c, "Hallo"c);
  t("^[a-z]+$"c, "hallo"c);
  t("^[a-z]$"c, "H"c);
  t("^[a-z]+$"c, "hallo123"c);
  return 0;
}' "0
1
0
0"

out "Gruppen und Alternation matchen" 'import std.io;
import std.regex;
fn t(p: pchar, s: pchar): void { PrintLn(IntToStr(RegexMatch(p, s))); }
fn main(): int64 {
  t("(a)(b)"c, "ab"c);
  t("a(b)c"c, "abc"c);
  t("a|b"c, "b"c);
  t("a|b"c, "a"c);
  t("(ab|cd)e"c, "cde"c);
  t("(ab)+"c, "ababab"c);
  t("(a|b)*c"c, "abac"c);
  t("^(foo|bar)$"c, "bar"c);
  t("^(foo|bar)$"c, "baz"c);
  return 0;
}' "1
1
1
1
1
1
1
1
0"

# Gegenprobe: alles, was der Bericht ausdruecklich als in Ordnung nennt, muss
# unveraendert bleiben — sonst waere die Erweiterung zu weit gegangen.
out "Klassen, Quantoren, Escapes, Suche und Ersetzung unveraendert" 'import std.io;
import std.regex;
fn t(p: pchar, s: pchar): void { PrintLn(IntToStr(RegexMatch(p, s))); }
fn main(): int64 {
  t("[a-z]+"c, "hallo"c);
  t("[^0-9]+"c, "abc"c);
  t("a{2,4}"c, "aaa"c);
  t("\\d+"c, "123"c);
  t("\\w+"c, "ab_1"c);
  t("abc$"c, "xxabc"c);
  PrintLn(IntToStr(RegexSearch("[0-9]+"c, "ab12cd"c)));
  PrintLn(IntToStr(RegexReplace("[0-9]+"c, "a1b22c"c, "#"c)));
  return 0;
}' "1
1
1
1
1
1
2
2"

# ===========================================================================
# #1312 — std.yaml
# ===========================================================================

out "verschachtelte Pfade werden gelesen" 'import std.io;
import std.yaml;
fn main(): int64 {
  var d: int64 := ParseString("name: test\nserver:\n  host: localhost\n  port: 8080\n");
  PrintLn(GetString(d, "name"c, "VORGABE"c));
  PrintLn(GetString(d, "server.host"c, "VORGABE"c));
  PrintLn(IntToStr(GetInt(d, "server.port"c, 0 - 1)));
  PrintLn(IntToStr(HasPath(d, "server.host"c)));
  return 0;
}' "test
localhost
8080
1"

# Der zweite, unabhaengige Fehler: nach dem Schreiben kam Verstuemmeltes
# zurueck ("example.oex" statt "example.org"), weil der Zielpuffer zu klein war.
out "Schreiben trifft die Struktur und laesst den Rest stehen" 'import std.io;
import std.yaml;
fn main(): int64 {
  var d: int64 := ParseString("name: test\nserver:\n  host: localhost\n  port: 8080\n");
  SetString(d, "server.host"c, "example.org"c);
  PrintLn(GetString(d, "server.host"c, "VORGABE"c));
  PrintLn(IntToStr(GetInt(d, "server.port"c, 0 - 1)));
  SetString(d, "name"c, "neu"c);
  PrintLn(GetString(d, "name"c, "VORGABE"c));
  SetString(d, "db.user"c, "admin"c);
  PrintLn(GetString(d, "db.user"c, "VORGABE"c));
  return 0;
}' "example.org
8080
neu
admin"

# Ein nicht vorhandener Pfad muss weiterhin die Vorgabe liefern — sonst waere
# die Aufloesung zu grosszuegig.
out "fehlender Pfad liefert die Vorgabe" 'import std.io;
import std.yaml;
fn main(): int64 {
  var d: int64 := ParseString("server:\n  host: localhost\n");
  PrintLn(GetString(d, "server.nix"c, "VORGABE"c));
  PrintLn(GetString(d, "nix.host"c, "VORGABE"c));
  PrintLn(IntToStr(HasPath(d, "server.nix"c)));
  return 0;
}' "VORGABE
VORGABE
0"

# ===========================================================================
# #1318 — std.crypto.sha256
# ===========================================================================
# Die Vektoren sind der Kern: eine Beschleunigung, die den Hash aendert, waere
# ungleich schlimmer als die Langsamkeit davor. Geprueft werden leerer String,
# ein Block, zwei Bloecke und vier Bloecke — die Blockgrenze ist die Stelle, an
# der ein wiederverwendeter Kratzpuffer auffallen wuerde.

out "SHA-256 stimmt ueber Blockgrenzen hinweg" 'import std.io;
import std.crypto.sha256;
fn zeig(s: pchar, n: int64): void {
  var out: pchar := alloc(80) as pchar;
  SHA256Hex(s as int64, n, out as int64);
  PrintLn(out);
}
fn main(): int64 {
  zeig(""c, 0);
  zeig("abc"c, 3);
  zeig("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"c, 56);
  var lang: pchar := alloc(300) as pchar;
  var i: int64 := 0;
  while (i < 200) { StrSetChar(lang, i, 97 + (i % 26)); i := i + 1; }
  StrSetChar(lang, 200, 0);
  zeig(lang, 200);
  return 0;
}' "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1
8013a82140d916576e2cf550b27449a368abec66cc154a7d9f599019d33aa3d2"

# Zwei Aufrufe hintereinander: der Kratzpuffer wird jetzt wiederverwendet, ein
# Rest aus dem Vorlauf muesste hier auffallen.
out "aufeinanderfolgende Hashes beeinflussen sich nicht" 'import std.io;
import std.crypto.sha256;
fn zeig(s: pchar, n: int64): void {
  var out: pchar := alloc(80) as pchar;
  SHA256Hex(s as int64, n, out as int64);
  PrintLn(out);
}
fn main(): int64 {
  zeig("abc"c, 3);
  zeig("abc"c, 3);
  zeig(""c, 0);
  zeig("abc"c, 3);
  return 0;
}' "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

# ===========================================================================
# #1309 — std.net.socket / std.net.http
# ===========================================================================
# SocketCanRead laesst sich ohne Netz pruefen: ein Socket-Paar, in das
# geschrieben wurde, MUSS als lesbar gemeldet werden. Genau dieser Zweig
# (select meldet einen bereiten Deskriptor) fuehrte in den Absturz — der
# Timeout-Zweig kehrte vorher zurueck und blieb deshalb unauffaellig.

out "SocketCanRead ueberlebt den Fall, in dem Daten anliegen" 'import std.io;
import std.net.socket;
fn main(): int64 {
  var sv: int64 := alloc(16);
  if (sys_socketpair(1, 1, 0, sv) < 0) { PrintLn("socketpair fehlt"); return 0; }
  var a: int64 := peek32(sv);
  var b: int64 := peek32(sv + 4);
  var msg: int64 := alloc(8);
  poke8(msg, 88);
  sys_write(b, msg, 1);
  PrintLn("vor SocketCanRead");
  PrintLn(IntToStr(SocketCanRead(a, 1000)));
  PrintLn("nach SocketCanRead");
  return 0;
}' "vor SocketCanRead
1
nach SocketCanRead"

# Der Repro aus dem Bericht braucht Netz. Ohne Netz wird uebersprungen statt
# rot gemeldet — ein Test, der an der Umgebung scheitert, misst nichts.
printf '%s\n' 'import std.io;
import std.net.http;
fn main(): int64 {
  var resp: HTTPResponse := HTTPGet("example.com"c, "/"c);
  PrintLn(IntToStr(resp.statusCode));
  return 0;
}' > "$TMP/h.lyx"
if "$LYXC" --std-path="$ROOT" "$TMP/h.lyx" -o "$TMP/h" >/dev/null 2>&1; then
  got="$(timeout 30 "$TMP/h" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then
    no "HTTPGet" "ABSTURZ (rc=$rc) — der Repro aus #1309"
  elif [ "$got" -gt 0 ] 2>/dev/null; then
    ok "HTTPGet liefert einen Statuscode ($got)"
  else
    echo "SKIP HTTPGet (kein Netz erreichbar, statusCode=$got)"
  fi
else
  no "HTTPGet" "uebersetzt nicht"
fi

echo
echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
