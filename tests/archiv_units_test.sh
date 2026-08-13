#!/usr/bin/env bash
# tests/archiv_units_test.sh — #1400, #1401, #1402, #1403, #1404.
#
# Fünf Meldungen zu den vier Archiv-Units. Drei davon sind derselbe Fehler:
# die Unit nimmt etwas an, was sie nicht kann, meldet Erfolg und liefert
# stillschweigend etwas anderes ab.
#
#   #1400  tar   kürzt Pfade über 100 Byte — das Archiv trägt einen anderen
#                Namen als übergeben, die Datei ist darin nicht auffindbar
#   #1401  iso   ersetzt '/' durch '_' — aus einem Unterverzeichnis wird eine
#                umbenannte Datei im Wurzelverzeichnis
#   #1402  rar   überspringt komprimierte Einträge ohne jedes Signal — ein
#                Archiv aus lauter gepackten Dateien sieht leer aus
#   #1403  zip   nimmt Pfade als int64, die Nachbarn als pchar (#1264)
#   #1404  zip   schreibt in jeden Eintrag den 1. Januar 2017
#
# WICHTIG für die Aussagekraft: bei #1400 und #1401 wird gegen ein FREMDES
# Werkzeug geprüft (GNU tar), nicht nur gegen den eigenen Reader. Ein Reader,
# der denselben Fehler macht wie der Writer, wäre sonst der Kronzeuge für sich
# selbst — genau das war bei tar der Fall: er las den gekürzten Namen zurück
# und bestätigte ihn.

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
  got="$(cd "$TMP" && timeout 60 ./p 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then no "$1" "ABSTURZ (rc=$rc)"; return; fi
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1" "'$got' erwartet '$3'"; fi
}

# ===========================================================================
# #1400 — tar: das prefix-Feld statt stiller Kuerzung
# ===========================================================================

# Reproduktion aus dem Issue, 110 Zeichen.
out "#1400: 110-Byte-Pfad kommt vollstaendig im Archiv an" 'import std.io;
import std.tar;
import std.string;
fn main(): int64 {
  var t: int64 := TarWriterNew();
  var lang: pchar := "ein/sehr/tiefer/pfad/der/ueber/hundert/zeichen/lang/ist/damit/das/ustar/format/an/seine/grenze/kommt/datei.txt"c;
  PrintLn(StrConcat("Laenge:   ", IntToStr(StrLen(lang))));
  PrintLn(StrConcat("Add rc:   ", IntToStr(TarWriterAdd(t, lang as int64, "x"c as int64, 1))));
  PrintLn(StrConcat("Save rc:  ", IntToStr(TarWriterSave(t, "lang.tar"c))));
  TarWriterFree(t);
  var h: int64 := TarOpen("lang.tar"c);
  PrintLn(StrConcat("Name:     ", TarName(h, 0) as pchar));
  TarClose(h);
  return 0;
}' "Laenge:   110
Add rc:   0
Save rc:  0
Name:     ein/sehr/tiefer/pfad/der/ueber/hundert/zeichen/lang/ist/damit/das/ustar/format/an/seine/grenze/kommt/datei.txt"

# GNU tar als unabhaengiger Zeuge. Der eigene Reader allein genuegt nicht: er
# las vorher denselben gekuerzten Namen und bestaetigte damit den Fehler.
if [ -f "$TMP/lang.tar" ]; then
  gnu="$(tar tf "$TMP/lang.tar" 2>/dev/null | head -1)"
  if [ "$gnu" = "ein/sehr/tiefer/pfad/der/ueber/hundert/zeichen/lang/ist/damit/das/ustar/format/an/seine/grenze/kommt/datei.txt" ]; then
    ok "#1400: GNU tar liest denselben vollstaendigen Pfad"
  else
    no "#1400: GNU tar liest denselben vollstaendigen Pfad" "$gnu"
  fi
else
  no "#1400: GNU tar liest denselben vollstaendigen Pfad" "kein Archiv erzeugt"
fi

# Was sich auch mit prefix nicht unterbringen laesst, wird GEMELDET (5) —
# beim Hinzufuegen, nicht erst beim Schreiben.
out "#1400: unteilbarer Pfad wird beim Hinzufuegen abgewiesen" 'import std.io;
import std.tar;
import std.string;
import std.alloc;
fn main(): int64 {
  var t: int64 := TarWriterNew();
  var n: int64 := alloc(140);
  var i: int64 := 0;
  while (i < 130) { poke8(n + i, 120); i := i + 1; }
  poke8(n + 130, 0);
  PrintStr(IntToStr(TarWriterAdd(t, n, "x"c as int64, 1))); PrintStr(" ");
  PrintLn(IntToStr(TarCount(0)));
  return 0;
}' "5 0"

# Kurze Pfade duerfen sich nicht aendern — Gegenprobe gegen eine Teilung,
# die zu frueh greift.
out "#1400: kurzer Pfad bleibt unveraendert" 'import std.io;
import std.tar;
import std.string;
fn main(): int64 {
  var t: int64 := TarWriterNew();
  TarWriterAdd(t, "kurz/datei.txt"c as int64, "abc"c as int64, 3);
  TarWriterSave(t, "kurz.tar"c);
  TarWriterFree(t);
  var h: int64 := TarOpen("kurz.tar"c);
  PrintStr(IntToStr(TarCount(h))); PrintStr(" ");
  PrintLn(TarName(h, 0) as pchar);
  TarClose(h);
  return 0;
}' "1 kurz/datei.txt"

# Genau an der Grenze: 100 Byte gehen ohne Teilung, 101 mit.
out "#1400: Grenze 100/101 Byte" 'import std.io;
import std.tar;
import std.string;
import std.alloc;
fn main(): int64 {
  var t: int64 := TarWriterNew();
  var a: int64 := alloc(120);
  var i: int64 := 0;
  while (i < 100) { poke8(a + i, 97); i := i + 1; }
  poke8(a + 50, 47);
  poke8(a + 100, 0);
  PrintStr(IntToStr(TarWriterAdd(t, a, "x"c as int64, 1))); PrintStr(" ");
  poke8(a + 100, 97); poke8(a + 101, 0);
  PrintLn(IntToStr(TarWriterAdd(t, a, "x"c as int64, 1)));
  return 0;
}' "0 0"

# ===========================================================================
# #1401 — iso: Schraegstrich melden statt umbenennen
# ===========================================================================

# Reproduktion aus dem Issue: beide Namen wurden bisher angenommen und still
# veraendert. Jetzt: 6 = ISO_ERR_NODIRS, 5 = ISO_ERR_NAMETOOLONG.
out "#1401: Schraegstrich und Level-1-Grenze werden gemeldet" 'import std.io;
import std.iso;
import std.string;
fn main(): int64 {
  var w: int64 := IsoWriterNew();
  PrintStr(IntToStr(IsoWriterAdd(w, "EinLangerName.txt"c as int64, "abc"c as int64, 3))); PrintStr(" ");
  PrintStr(IntToStr(IsoWriterAdd(w, "unterordner/a.txt"c as int64, "def"c as int64, 3))); PrintStr(" ");
  PrintLn(IntToStr(IsoWriterAdd(w, "OK.TXT"c as int64, "ghi"c as int64, 3)));
  return 0;
}' "5 6 0"

# Was Level 1 erlaubt, muss weiterhin durchgehen und lesbar sein.
out "#1401: gueltiger 8.3-Name wird geschrieben und gelesen" 'import std.io;
import std.iso;
import std.string;
fn main(): int64 {
  var w: int64 := IsoWriterNew();
  IsoWriterAdd(w, "DATEI.TXT"c as int64, "abc"c as int64, 3);
  PrintStr(IntToStr(IsoWriterSave(w, "t.iso"c))); PrintStr(" ");
  IsoWriterFree(w);
  var h: int64 := IsoOpen("t.iso"c);
  PrintStr(IntToStr(IsoCount(h))); PrintStr(" ");
  PrintLn(IsoName(h, 0) as pchar);
  IsoClose(h);
  return 0;
}' "0 1 DATEI.TXT"

# ===========================================================================
# #1402 — rar: uebersprungene Eintraege sind zaehlbar
# ===========================================================================

# Das Archiv aus dem Issue: ein gespeicherter, ein komprimierter Eintrag.
if [ -f "$ROOT/tests/data/mixed.rar" ]; then
  cp "$ROOT/tests/data/mixed.rar" "$TMP/mixed.rar"
  out "#1402: ein uebersprungener Eintrag wird gemeldet" 'import std.io;
import std.rar;
import std.string;
fn main(): int64 {
  var h: int64 := RarOpen("mixed.rar"c);
  if (h == 0) { PrintLn("kein Archiv"); return 1; }
  PrintStr(IntToStr(RarCount(h))); PrintStr(" ");
  PrintStr(IntToStr(RarSkippedCount(h))); PrintStr(" ");
  PrintStr(IntToStr(RarLastError(h))); PrintStr(" ");
  PrintLn(RarName(h, 0) as pchar);
  RarClose(h);
  return 0;
}' "1 1 4 stored.txt"
else
  no "#1402: ein uebersprungener Eintrag wird gemeldet" "tests/data/mixed.rar fehlt"
fi

# ===========================================================================
# #1403 — zip nimmt den Pfad als pchar, wie die drei Nachbarn
# ===========================================================================

out "#1403: ZipOpen und ZipWriterSave nehmen pchar" 'import std.io;
import std.zip;
import std.string;
fn main(): int64 {
  var w: int64 := ZipWriterNew();
  ZipWriterAdd(w, "a.txt"c as int64, "hallo"c as int64, 5);
  PrintStr(IntToStr(ZipWriterSave(w, "a.zip"c))); PrintStr(" ");
  ZipWriterFree(w);
  var h: int64 := ZipOpen("a.zip"c);
  PrintStr(IntToStr(ZipCount(h))); PrintStr(" ");
  PrintStr(ZipName(h, 0) as pchar); PrintStr(" ");
  PrintLn(IntToStr(ZipFind(h, "a.txt"c as int64)));
  ZipClose(h);
  return 0;
}' "0 1 a.txt 0"

# Die vier Units nebeneinander mit derselben Schreibweise — das war der
# eigentliche Punkt der Meldung.
out "#1403: alle vier Units nehmen den Pfad gleich" 'import std.io;
import std.zip;
import std.tar;
import std.iso;
import std.rar;
fn main(): int64 {
  var z: int64 := ZipWriterNew(); ZipWriterAdd(z, "x"c as int64, "a"c as int64, 1);
  var t: int64 := TarWriterNew(); TarWriterAdd(t, "x"c as int64, "a"c as int64, 1);
  var i: int64 := IsoWriterNew(); IsoWriterAdd(i, "X.TXT"c as int64, "a"c as int64, 1);
  PrintStr(IntToStr(ZipWriterSave(z, "v.zip"c))); PrintStr(" ");
  PrintStr(IntToStr(TarWriterSave(t, "v.tar"c))); PrintStr(" ");
  PrintStr(IntToStr(IsoWriterSave(i, "v.iso"c))); PrintStr(" ");
  PrintLn(IntToStr(RarOpen("gibtesnicht.rar"c)));
  return 0;
}' "0 0 0 0"

# ===========================================================================
# #1404 — zip traegt die echte Zeit
# ===========================================================================

# Geprueft wird gegen unzip(1), also gegen ein fremdes Werkzeug, und gegen das
# heutige Datum. Ein Festwert faellt damit auf, egal welcher.
printf 'import std.io;\nimport std.zip;\nfn main(): int64 { var w: int64 := ZipWriterNew(); ZipWriterAdd(w, "n.txt"c as int64, "hallo"c as int64, 5); ZipWriterSave(w, "n.zip"c); return 0; }\n' > "$TMP/n.lyx"
if "$LYXC" --std-path="$ROOT" "$TMP/n.lyx" -o "$TMP/n" >/dev/null 2>&1 && (cd "$TMP" && ./n); then
  datum="$(cd "$TMP" && unzip -l n.zip 2>/dev/null | awk '/n\.txt/{print $2}')"
  heute="$(date -u +%Y-%m-%d)"
  if [ "$datum" = "$heute" ]; then ok "#1404: der Zeitstempel ist das heutige Datum (UTC)"
  else no "#1404: der Zeitstempel ist das heutige Datum (UTC)" "'$datum' erwartet '$heute'"; fi
else
  no "#1404: der Zeitstempel ist das heutige Datum (UTC)" "uebersetzt oder laeuft nicht"
fi

# Der Festwert bleibt erreichbar — reproduzierbare Archive muessen moeglich
# bleiben, sonst waere der Fix ein neuer Mangel.
printf 'import std.io;\nimport std.zip;\nfn main(): int64 { var w: int64 := ZipWriterNew(); ZipWriterAddAt(w, "f.txt"c as int64, "hallo"c as int64, 5, ZIP_TIME_2017); ZipWriterSaveStore(w, "f.zip"c); return 0; }\n' > "$TMP/f.lyx"
if "$LYXC" --std-path="$ROOT" "$TMP/f.lyx" -o "$TMP/f" >/dev/null 2>&1 && (cd "$TMP" && ./f); then
  d2="$(cd "$TMP" && unzip -l f.zip 2>/dev/null | awk '/f\.txt/{print $2}')"
  if [ "$d2" = "2017-01-01" ]; then ok "#1404: ZipWriterAddAt setzt den Zeitstempel fest"
  else no "#1404: ZipWriterAddAt setzt den Zeitstempel fest" "'$d2' erwartet '2017-01-01'"; fi
else
  no "#1404: ZipWriterAddAt setzt den Zeitstempel fest" "uebersetzt oder laeuft nicht"
fi

# Zwei Laeufe mit festem Stempel muessen bitgleich sein — das ist der Zweck.
if [ -f "$TMP/f.zip" ]; then
  cp "$TMP/f.zip" "$TMP/f1.zip"; (cd "$TMP" && ./f)
  if cmp -s "$TMP/f1.zip" "$TMP/f.zip"; then ok "#1404: fester Stempel ergibt bitgleiche Archive"
  else no "#1404: fester Stempel ergibt bitgleiche Archive" "Archive unterscheiden sich"; fi
else
  no "#1404: fester Stempel ergibt bitgleiche Archive" "kein Archiv"
fi

# Die Umrechnung selbst, an einem bekannten Zeitpunkt: 2017-01-01 00:00:00 UTC
# ist Unix 1483228800 und muss GENAU den alten Festwert 0x4A210000 ergeben.
# Das belegt die Bitaufteilung, ohne sich auf die Systemuhr zu verlassen — und
# es war die Pruefung, die den Jahresfehler in std.time ans Licht gebracht hat
# (siehe tests/time_civil_test.sh): sie lieferte einen um 2^25 kleineren Wert,
# also ein Jahr zu wenig.
# Der dritte Wert ist Unix 0 = 1970-01-01, vor der DOS-Epoche 1980 — dafuer
# der frueheste darstellbare Zeitpunkt 0x00210000 = 2162688.
out "#1404: ZipDosTimeFromUnix rechnet nachpruefbar" 'import std.io;
import std.zip;
fn main(): int64 {
  PrintStr(IntToStr(ZipDosTimeFromUnix(1483228800))); PrintStr(" ");
  PrintStr(IntToStr(ZIP_TIME_2017)); PrintStr(" ");
  PrintLn(IntToStr(ZipDosTimeFromUnix(0)));
  return 0;
}' "1243676672 1243676672 2162688"

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
