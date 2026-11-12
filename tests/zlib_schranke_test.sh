#!/usr/bin/env bash
# tests/zlib_schranke_test.sh — #1951: entpacken schreibt nie ueber den Puffer.
#
# Drei Pfade entpackten FREMDE Daten in einen festen Puffer, ohne die Groesse
# an den Entpacker weiterzugeben:
#
#   ZlibDecompressToBuffer  prueft `max_out` erst NACH dem Schreiben
#   std/zip.lyx             schrankte auf die im Archiv DEKLARIERTE Groesse
#   std/image/png.lyx       gab die Puffergroesse gar nicht weiter
#
# Der Inflater kennt seit #1070 eine Schranke (`out_max`), und sein eigener
# Kommentar sagt, warum: "Ohne sie schreibt der Inflater so weit, wie der
# Strom es verlangt — bei fremden Daten also ueber jeden Puffer hinaus."
#
# GEMESSEN WIRD DER UEBERLAUF SELBST, nicht ein Rueckgabewert. Hinter dem
# Zielpuffer liegt ein Waechterfeld aus 0xA5; wird davon auch nur ein Byte
# ueberschrieben, ist der Ueberlauf bewiesen. Ein Test, der nur den
# Rueckgabewert ansieht, waere blind fuer genau den Fall, um den es geht — der
# alte Pfad lieferte fuer dieselbe Bombe eine PLAUSIBLE Zahl (4399) und hatte
# dabei laengst hinter den Puffer geschrieben.
#
# BEIDE RICHTUNGEN: die Bombe muss abgewiesen werden UND gueltige Daten
# muessen unveraendert richtig entpackt werden. Ohne die zweite Haelfte waere
# auch eine Fassung gruen, die jede Eingabe ablehnt.
#
# Alle Laeufe stehen unter `ulimit -v`.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

command -v python3 >/dev/null 2>&1 || {
  echo "UEBERSPRUNGEN std.zlib-Schranke: python3 fehlt (erzeugt die Bombe)"; exit 0; }

echo "--- std.zlib: entpacken schreibt nie ueber den Puffer (#1951) ---"

# Die Bombe: 2 MB Nullen werden zu rund 2 kB. Der Zielpuffer fasst 4096 Byte.
python3 -c "
import zlib
open('$TMP/bombe.bin','wb').write(zlib.compress(b'\x00' * (2*1024*1024), 9))
klein = b'HALLO ZLIB' * 10
open('$TMP/klein.bin','wb').write(zlib.compress(klein, 9))
" || { echo "UEBERSPRUNGEN std.zlib-Schranke: Bombe liess sich nicht erzeugen"; exit 0; }

gross=$(stat -c%s "$TMP/bombe.bin" 2>/dev/null || echo 0)
if [ "$gross" -gt 0 ] && [ "$gross" -lt 4096 ]; then
  ok "die Bombe ist mit $gross Byte kleiner als der Zielpuffer und entfaltet sich auf 2 MB"
else
  nok "die Bombe hat $gross Byte — der Fall waere nicht der gemeinte"
fi

cat > "$TMP/sonde.lyx" <<'EOF'
unit main;
import std.zlib;
import std.io;
import std.alloc;

fn main(): int64 {
  // 8192 Byte: die ersten 4096 sind das Ziel, dahinter das Waechterfeld.
  var block: int64 := alloc(8192);
  var i: int64 := 0;
  while (i < 8192) { poke8(block + i, 0xA5); i := i + 1; }

  var fd: int64 := open("BOMBE"c, 0, 0);
  if (fd < 0) { PrintLn("bombe_offen=0"); return 1; }
  var komp: int64 := alloc(1048576);
  var len: int64 := read(fd, komp as pchar, 1048576);
  close(fd);
  PrintLn(StrConcat("eingabe=", IntToStr(len)));

  var r: int64 := ZlibDecompressBounded(komp as pchar, len, block as pchar, 4096);
  PrintLn(StrConcat("bombe=", IntToStr(r)));

  var heil: int64 := 0;
  var k: int64 := 4096;
  while (k < 8192) {
    if ((peek8(block + k) & 255) == 0xA5) { heil := heil + 1; }
    k := k + 1;
  }
  PrintLn(StrConcat("waechter=", IntToStr(4096 - heil)));

  // Gegenprobe mit gueltigen Daten.
  var fd2: int64 := open("KLEIN"c, 0, 0);
  var k2: int64 := alloc(65536);
  var len2: int64 := read(fd2, k2 as pchar, 65536);
  close(fd2);
  var z2: int64 := alloc(4096);
  var r2: int64 := ZlibDecompressBounded(k2 as pchar, len2, z2 as pchar, 4096);
  PrintLn(StrConcat("klein=", IntToStr(r2)));
  if (r2 > 0) {
    poke8(z2 + r2, 0);
    PrintLn(StrConcat("inhalt=", z2 as pchar));
  }

  // Und ueber den alten Namen, der jetzt dieselbe Schranke tragen muss.
  var z3: int64 := alloc(4096);
  PrintLn(StrConcat("ueberalten=",
          IntToStr(ZlibDecompressToBuffer(komp as pchar, len, z3 as pchar, 4096))));
  return 0;
}
EOF
sed -i "s|BOMBE|$TMP/bombe.bin|; s|KLEIN|$TMP/klein.bin|" "$TMP/sonde.lyx"

if ! ( cd "$ROOT" && timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/sonde.lyx" -o "$TMP/sonde" ) >"$TMP/build.log" 2>&1; then
  nok "die Sonde uebersetzt nicht"; sed -n '1,5p' "$TMP/build.log"
  echo; echo "Ergebnis: $PASS PASS, $FAIL FAIL"; exit 1
fi

AUS="$( ulimit -v 2097152; timeout 120 "$TMP/sonde" 2>/dev/null )"; rc=$?
if [ "$rc" -eq 0 ]; then
  ok "die Sonde laeuft durch, ohne abzustuerzen"
else
  nok "die Sonde bricht ab (rc=$rc) — der Ueberlauf ist zurueck"
  echo; echo "Ergebnis: $PASS PASS, $FAIL FAIL"; exit 1
fi
printf '%s\n' "$AUS" > "$TMP/aus.txt"
hole() { grep -oP "^$1=\K.*" "$TMP/aus.txt" | head -1; }

# Der eigentliche Nachweis: kein Byte hinter dem Zielpuffer wurde angefasst.
if [ "$(hole waechter)" = "0" ]; then
  ok "kein Byte hinter dem Zielpuffer wurde ueberschrieben"
else
  nok "$(hole waechter) Byte(s) hinter dem Zielpuffer ueberschrieben"
fi

# -2 heisst "Puffer zu klein" und ist von -1 ("Strom kaputt") zu unterscheiden.
if [ "$(hole bombe)" = "-2" ]; then
  ok "die Bombe wird als 'Puffer zu klein' (-2) abgewiesen"
else
  nok "die Bombe liefert '$(hole bombe)', erwartet -2"
fi

if [ "$(hole ueberalten)" = "-2" ]; then
  ok "auch ZlibDecompressToBuffer weist sie ab (die Schranke wirkt jetzt dort)"
else
  nok "ZlibDecompressToBuffer liefert '$(hole ueberalten)', erwartet -2"
fi

# Zweite Richtung: gueltige Daten muessen unveraendert durchgehen.
if [ "$(hole klein)" = "100" ]; then
  ok "gueltige Daten werden weiterhin richtig entpackt (100 Byte)"
else
  nok "gueltige Daten liefern '$(hole klein)' Byte, erwartet 100"
fi
if [ "$(hole inhalt)" = "HALLO ZLIBHALLO ZLIBHALLO ZLIBHALLO ZLIBHALLO ZLIBHALLO ZLIBHALLO ZLIBHALLO ZLIBHALLO ZLIBHALLO ZLIB" ]; then
  ok "und ihr Inhalt stimmt"
else
  nok "Inhalt weicht ab: '$(hole inhalt)'"
fi

# Kein ungeschrankter Aufruf mehr im Bestand. Die Funktion selbst bleibt --
# wer die entpackte Groesse sicher kennt, darf sie nutzen -- aber keine Unit
# darf fremde Daten ohne Schranke entpacken.
offen="$(grep -rn 'InflateDEFLATE(' --include=*.lyx "$ROOT/std" 2>/dev/null | grep -v '^.*std/zlib.lyx' | tr '\n' ' ')"
if [ -z "$offen" ]; then
  ok "keine Unit ruft den ungeschrankten Inflater mehr"
else
  nok "ungeschrankte Aufrufe: $offen"
fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
