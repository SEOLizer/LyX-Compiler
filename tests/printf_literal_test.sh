#!/usr/bin/env bash
# tests/printf_literal_test.sh — #1431.
#
# `__PrintfCore` benutzte ein String-LITERAL als Schreibpuffer: jedes
# auszugebende Zeichen wurde in `" "` geschrieben und von dort gedruckt.
# Dieselbe Klasse wie #1259 und #1260 — und in derselben Datei mit #1284 schon
# einmal behoben (FloatToStr).
#
# WARUM DAS SCHWER ZU PRÜFEN IST: heute richtet es keinen sichtbaren Schaden
# an. Der Datenbereich ist beschreibbar, und das Zeichen wird sofort nach dem
# Schreiben ausgegeben — der Zustand überlebt den Aufruf nicht. Ein Test auf
# „falsche Ausgabe" wäre vor dem Fix grün gewesen.
#
# Geprüft wird deshalb die EIGENSCHAFT, nicht die Wirkung: im erzeugten
# Programm darf kein Schreibzugriff mehr auf ein Literal stehen. Nachgewiesen
# über das Verhalten, das ein geteiltes Literal zwangsläufig zeigt — zwei
# Ein-Zeichen-Literale im Programm werden zusammengefasst, ein Printf-Aufruf
# hätte sie beide verändert.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
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
  got="$(timeout 30 "$TMP/p" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then no "$1" "ABSTURZ (rc=$rc)"; return; fi
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1" "'$got' erwartet '$3'"; fi
}

# ===========================================================================
# Der Nachweis: ein Ein-Zeichen-Literal ueberlebt einen Printf-Aufruf
# ===========================================================================

# Das Programm haelt selbst ein Literal " " und gibt es NACH dem Printf-Aufruf
# aus. Solange __PrintfCore in sein eigenes " " schrieb und der Compiler
# gleiche Literale zusammenfasst, trug dieses hier danach das zuletzt
# gedruckte Zeichen.
out "#1431: ein Leerzeichen-Literal bleibt ein Leerzeichen" 'import std.io;
import std.string;
fn main(): int64 {
  var leer: pchar := " ";
  PrintfS("Hallo %s!\n"c, "Welt"c);
  PrintStr("["); PrintStr(leer); PrintLn("]");
  PrintLn(IntToStr(StrCharAt(leer, 0)));
  return 0;
}' "Hallo Welt!
[ ]
32"

# ===========================================================================
# Die Ausgabe selbst muss unveraendert stimmen
# ===========================================================================

out "#1431: die Formatierung bleibt richtig" 'import std.io;
fn main(): int64 {
  PrintfS("Hallo %s!\n"c, "Welt"c);
  PrintfI("Zahl %d\n"c, 42);
  PrintfSS("%s und %s\n"c, "eins"c, "zwei"c);
  PrintfSI("%s = %d\n"c, "wert"c, 7);
  return 0;
}' "Hallo Welt!
Zahl 42
eins und zwei
wert = 7"

# Ein doppeltes Prozentzeichen und ein unbekannter Bezeichner laufen ueber
# denselben Puffer — beide Zweige gehoeren geprueft.
out "#1431: %% und unbekannter Bezeichner" 'import std.io;
fn main(): int64 {
  PrintfS("100%% sicher, %s\n"c, "ja"c);
  PrintfS("unbekannt: %q hier, %s\n"c, "x"c);
  return 0;
}' "100% sicher, ja
unbekannt: %q hier, x"

# Viele Aufrufe hintereinander: der Puffer wird je Aufruf angelegt und wieder
# freigegeben. Ein Leck faellt am Adressabstand auf, nicht an der Ausgabe.
out "#1431: 500 Aufrufe verbrauchen keinen Speicher" 'import std.io;
import std.alloc;
import std.string;
fn main(): int64 {
  PrintfS("%s\n"c, "vorwaermen"c);
  var a: int64 := alloc(8); free(a, 8);
  var vorher: int64 := alloc(8); free(vorher, 8);
  var i: int64 := 0;
  while (i < 500) { PrintfI("%d"c, i); i := i + 1; }
  PrintLn("");
  var nachher: int64 := alloc(8);
  PrintLn(StrConcat("Abstand: ", IntToStr(nachher - vorher)));
  return 0;
}' "vorwaermen
0123456789101112131415161718192021222324252627282930313233343536373839404142434445464748495051525354555657585960616263646566676869707172737475767778798081828384858687888990919293949596979899100101102103104105106107108109110111112113114115116117118119120121122123124125126127128129130131132133134135136137138139140141142143144145146147148149150151152153154155156157158159160161162163164165166167168169170171172173174175176177178179180181182183184185186187188189190191192193194195196197198199200201202203204205206207208209210211212213214215216217218219220221222223224225226227228229230231232233234235236237238239240241242243244245246247248249250251252253254255256257258259260261262263264265266267268269270271272273274275276277278279280281282283284285286287288289290291292293294295296297298299300301302303304305306307308309310311312313314315316317318319320321322323324325326327328329330331332333334335336337338339340341342343344345346347348349350351352353354355356357358359360361362363364365366367368369370371372373374375376377378379380381382383384385386387388389390391392393394395396397398399400401402403404405406407408409410411412413414415416417418419420421422423424425426427428429430431432433434435436437438439440441442443444445446447448449450451452453454455456457458459460461462463464465466467468469470471472473474475476477478479480481482483484485486487488489490491492493494495496497498499
Abstand: 0"

# ===========================================================================
# __PrintfCore ist nicht mehr Teil der Schnittstelle
# ===========================================================================

# Der Doppelunterstrich sagte seit jeher, dass das niemand von aussen rufen
# soll; die Sichtbarkeit sagte das Gegenteil, und die erzeugte Doku fuehrte die
# Funktion als Teil der Schnittstelle.
printf 'import std.io;\nfn main(): int64 { return __PrintfCore("x"c, ""c, ""c, ""c, ""c); }\n' > "$TMP/k.lyx"
rm -f "$TMP/k"
if "$LYXC" --std-path="$ROOT" "$TMP/k.lyx" -o "$TMP/k" >/dev/null 2>&1; then
  no "#1431: __PrintfCore ist unit-privat" "von aussen weiterhin aufrufbar"
else
  ok "#1431: __PrintfCore ist unit-privat"
fi

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
