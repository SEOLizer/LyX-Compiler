#!/usr/bin/env bash
# tests/integrity_test.sh — #1878/#1877/#1879: `@integrity` wird nachgewiesen.
#
# Bis 1.1.14G erzeugte `@integrity` eine Warnung und sonst NICHTS: das
# Erzeugnis war Byte fuer Byte dasselbe wie ohne das Attribut, und
# `src/ir/ir_safety.lyx` — die Datei mit `setIntegrity`, `getDAL`, `getWCET` —
# wurde nirgends importiert oder gebaut. Eine ungebaute Safety-Datei im Baum
# ist schlimmer als keine: sie taeuscht bei der Durchsicht Deckung vor.
#
# Gemessen wird deshalb die WIRKUNG, nicht das Vorhandensein:
#
#   software_lockstep — der Rueckgabeausdruck wird zweimal gerechnet und vor
#     dem `ret` verglichen. Nachweis: der Abbruchpfad steht im Erzeugnis und
#     fehlt ohne das Attribut; ein Ausdruck MIT Wirkung wird abgewiesen, statt
#     stillschweigend zweimal zu laufen.
#
#   scrubbed — ein SIGALRM-Zeitgeber prueft periodisch die GELADENEN Codeseiten
#     gegen dreifach abgelegte Referenzhashes. Nachweis: ein gekipptes Bit im
#     Code fuehrt zum Abbruch mit Code 135, waehrend dasselbe Programm ohne den
#     Kipper durchlaeuft. Das Programm liest dabei KEINE Datei — geprueft wird
#     der Speicher, nicht /proc/self/exe (#1879).
#
#   Mehrheit — EIN gekipptes Bit in EINER der drei Hashkopien aendert nichts
#     (die anderen beiden entscheiden), zwei verschiedene Kipper fuehren zu
#     Code 136. Ohne diese beiden Faelle waere die Redundanz aus #1877 nicht
#     von einer einzelnen Kopie zu unterscheiden.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok()   { echo "PASS $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL $1${2:+: $2}"; FAIL=$((FAIL+1)); }

# baut; erwartet ERFOLG
baut() { # name, quelltext, ziel
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$3"
  if "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$3" >"$TMP/out" 2>&1; then return 0; fi
  bad "$1" "Uebersetzung schlug fehl: $(head -3 "$TMP/out" | tr '\n' ' ')"; return 1
}

# baut; erwartet ABWEISUNG mit einem Meldungsteil
weist_ab() { # name, quelltext, meldungsteil
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  got="$("$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)"; rc=$?
  if [ $rc -eq 0 ]; then bad "$1" "wurde angenommen (rc=0)"; return; fi
  case "$got" in
    *"$3"*) ok "$1" ;;
    *) bad "$1" "andere Meldung: $(printf '%s' "$got" | grep -i error | head -1)" ;;
  esac
}

echo "=== software_lockstep ==="

LS='unit main;
import std.io;
@integrity(mode: software_lockstep)
fn Rechne(a: int64, b: int64): int64 { return a * b + 7; }
fn main(): int64 { PrintLn(IntToStr(Rechne(6, 7))); return 0; }'
OHNE='unit main;
import std.io;
fn Rechne(a: int64, b: int64): int64 { return a * b + 7; }
fn main(): int64 { PrintLn(IntToStr(Rechne(6, 7))); return 0; }'

if baut "lockstep uebersetzt" "$LS" "$TMP/ls"; then
  ok "lockstep uebersetzt"
  # 1. Das Ergebnis stimmt weiterhin — die doppelte Rechnung darf es nicht
  #    veraendern.
  if [ "$("$TMP/ls")" = "49" ]; then ok "lockstep: Ergebnis unveraendert (49)"
  else bad "lockstep: Ergebnis unveraendert" "$("$TMP/ls")"; fi
  # 2. Keine Warnung mehr — die Zusicherung wird nachgewiesen.
  if grep -q "NICHT nachgewiesen" "$TMP/out"; then
    bad "lockstep meldet keinen fehlenden Nachweis mehr" "Warnung steht noch da"
  else ok "lockstep meldet keinen fehlenden Nachweis mehr"; fi
fi

baut "gegenprobe" "$OHNE" "$TMP/ohne" && ok "Gegenprobe ohne Attribut uebersetzt"

# 3. Der Abbruchpfad steht IM Erzeugnis — und nur mit dem Attribut. Das ist
#    der Nachweis, dass ueberhaupt Code entstanden ist; die Groesse allein
#    waere zu schwach (sie schwankt auch aus anderen Gruenden).
if strings "$TMP/ls" | grep -q "software_lockstep.*stimmen nicht ueberein"; then
  ok "lockstep: Abbruchpfad im Erzeugnis"
else bad "lockstep: Abbruchpfad im Erzeugnis" "Meldung fehlt"; fi
if strings "$TMP/ohne" | grep -q "stimmen nicht ueberein"; then
  bad "ohne Attribut kein Abbruchpfad" "Meldung steht da"
else ok "ohne Attribut kein Abbruchpfad"; fi

# 4. Groessenvergleich als zweites, unabhaengiges Merkmal.
SZ_LS=$(stat -c%s "$TMP/ls"); SZ_OH=$(stat -c%s "$TMP/ohne")
if [ "$SZ_LS" -gt "$SZ_OH" ]; then ok "lockstep: Erzeugnis groesser ($SZ_LS > $SZ_OH)"
else bad "lockstep: Erzeugnis groesser" "$SZ_LS <= $SZ_OH"; fi

# 5. Ein Ausdruck MIT Wirkung laesst sich nicht zweimal rechnen. Ihn
#    stillschweigend doppelt laufen zu lassen waere der stille Default.
weist_ab "lockstep weist einen Aufruf im return ab" 'unit main;
import std.io;
fn Hilf(x: int64): int64 { return x + 1; }
@integrity(mode: software_lockstep)
fn F(a: int64): int64 { return Hilf(a); }
fn main(): int64 { return F(1); }' "laesst sich nicht zweimal rechnen"

weist_ab "lockstep weist new im return ab" 'unit main;
type P = class { v: int64; };
@integrity(mode: software_lockstep)
fn F(): int64 { return new P() as int64; }
fn main(): int64 { return 0; }' "laesst sich nicht zweimal rechnen"

echo
echo "=== Argumentformen ==="

weist_ab "@integrity ohne mode wird abgewiesen" 'unit main;
@integrity(interval: 100)
fn F(): int64 { return 1; }
fn main(): int64 { return F(); }' 'mode` fehlt'

weist_ab "unbekannter Schluessel wird abgewiesen" 'unit main;
@integrity(crc32)
fn F(): int64 { return 1; }
fn main(): int64 { return F(); }' "unbekannter Schluessel"

weist_ab "hardware_ecc wird als nicht umgesetzt abgewiesen" 'unit main;
@integrity(mode: hardware_ecc)
fn F(): int64 { return 1; }
fn main(): int64 { return F(); }' "nicht umgesetzt"

# Ein Intervall an software_lockstep ist ein Widerspruch: der Vergleich sitzt
# vor dem `ret`, es gibt dort keine Frist. Eine gesetzte Zahl wirkungslos
# liegen zu lassen waere derselbe Fehler in klein.
weist_ab "interval an software_lockstep wird abgewiesen" 'unit main;
@integrity(mode: software_lockstep, interval: 100)
fn F(): int64 { return 1; }
fn main(): int64 { return F(); }' "gilt nur fuer"

weist_ab "interval 0 wird abgewiesen" 'unit main;
@integrity(mode: scrubbed, interval: 0)
fn F(): int64 { return 1; }
fn main(): int64 { return F(); }' "zwischen 1 und 3600000"

echo
echo "=== scrubbed: Tabelle im Erzeugnis ==="

SC='unit main;
import std.io;
@integrity(mode: scrubbed, interval: 50)
fn Rechne(a: int64): int64 { return a * 3; }
fn main(): int64 {
  var i: int64 := 0; var s: int64 := 0;
  while (i < 30000000) { s := s + Rechne(i); i := i + 1; }
  PrintLn(IntToStr(s & 255));
  return 0;
}'
if baut "scrubbed uebersetzt" "$SC" "$TMP/sc"; then ok "scrubbed uebersetzt"; fi

python3 - "$TMP/sc" > "$TMP/tab.txt" <<'PY'
import struct, sys
d = open(sys.argv[1], 'rb').read()
o = d.find(b"METASAF2")
if o < 0:
    print("KEINE_TABELLE"); sys.exit(0)
pages, mode = struct.unpack_from("<II", d, o + 8)
codeLen, startVa, endVa = struct.unpack_from("<QQQ", d, o + 16)
interval, stride = struct.unpack_from("<II", d, o + 40)
kopien = []
for k in range(3):
    e = o + 64 + k * stride
    kopien.append(d[e:e + pages * 8])
print("OFF", o)
print("PAGES", pages)
print("MODE", mode)
print("CODELEN", codeLen)
print("STARTVA", startVa)
print("ENDVA", endVa)
print("INTERVAL", interval)
print("STRIDE", stride)
print("GLEICH", int(kopien[0] == kopien[1] == kopien[2]))
print("NICHTNULL", int(any(kopien[0])))
PY
feld() { grep "^$1 " "$TMP/tab.txt" | awk '{print $2}'; }

if grep -q KEINE_TABELLE "$TMP/tab.txt"; then
  bad "scrubbed: Hashtabelle im Erzeugnis" "keine METASAF2-Kennung"
else
  ok "scrubbed: Hashtabelle im Erzeugnis"
  # code_start_va MUSS die geladene Adresse des Codes sein: 0x400000 + 176.
  # Stuende hier ein Dateioffset, prueften wir die falsche Stelle.
  [ "$(feld STARTVA)" = "4194480" ] && ok "scrubbed: code_start_va = 0x4000b0" \
    || bad "scrubbed: code_start_va" "$(feld STARTVA)"
  [ "$(feld INTERVAL)" = "50" ] && ok "scrubbed: Intervall uebernommen" \
    || bad "scrubbed: Intervall uebernommen" "$(feld INTERVAL)"
  [ "$(feld MODE)" = "1" ] && ok "scrubbed: Modus 1 vermerkt" \
    || bad "scrubbed: Modus 1 vermerkt" "$(feld MODE)"
  [ "$(feld GLEICH)" = "1" ] && ok "scrubbed: drei Kopien gleich (#1877)" \
    || bad "scrubbed: drei Kopien gleich" "Kopien weichen ab"
  [ "$(feld NICHTNULL)" = "1" ] && ok "scrubbed: Hashes gefuellt" \
    || bad "scrubbed: Hashes gefuellt" "alles 0"
  # Der Abstand traegt die Aussage: liegen die Kopien auf derselben Seite,
  # trifft ein lokaler Defekt alle drei und die Mehrheit ist wertlos.
  ST=$(feld STRIDE)
  [ "$ST" -ge 4096 ] && [ $((ST % 4096)) -eq 0 ] && ok "scrubbed: Kopien seitenweise getrennt ($ST)" \
    || bad "scrubbed: Kopien seitenweise getrennt" "stride=$ST"
fi

if baut "gegenprobe scrubbed" "$OHNE" "$TMP/ohne2"; then
  if grep -q "METASAF2" "$TMP/ohne2" 2>/dev/null; then
    bad "ohne Attribut keine Tabelle" "METASAF2 steht da"
  else ok "ohne Attribut keine Tabelle"; fi
fi

echo
echo "=== scrubbed: der Sweep laeuft und greift ==="

if timeout 120 "$TMP/sc" >/dev/null 2>&1; then
  ok "scrubbed: heiles Programm laeuft durch (kein Fehlalarm)"
else
  bad "scrubbed: heiles Programm laeuft durch" "rc=$?"
fi

# Ein gekipptes Bit im CODE. Die Stelle liegt weit hinter dem ausgefuehrten
# Pfad — gemessen wird der Sweep, nicht ein Absturz an der Kippstelle.
mach_kaputt() { # ziel, offset, maske
  python3 - "$1" "$2" "$3" <<'PY'
import sys
p, off, m = sys.argv[1], int(sys.argv[2], 0), int(sys.argv[3], 0)
d = bytearray(open(p, 'rb').read()); d[off] ^= m
open(p, 'wb').write(d)
PY
  chmod +x "$1"
}

cp "$TMP/sc" "$TMP/sc_code"; mach_kaputt "$TMP/sc_code" 0x3000 1
timeout 120 "$TMP/sc_code" >"$TMP/o1" 2>&1; rc=$?
if [ "$rc" = "135" ] && grep -q "stimmt nicht mit dem Referenzhash" "$TMP/o1"; then
  ok "scrubbed: gekipptes Codebit wird erkannt (rc 135)"
else bad "scrubbed: gekipptes Codebit wird erkannt" "rc=$rc $(head -1 "$TMP/o1")"; fi

# EINE beschaedigte Hashkopie darf nichts aendern — dafuer sind es drei.
TABOFF=$(feld OFF)
cp "$TMP/sc" "$TMP/sc_h1"; mach_kaputt "$TMP/sc_h1" $((TABOFF + 68)) 1
timeout 120 "$TMP/sc_h1" >/dev/null 2>&1; rc=$?
if [ "$rc" = "0" ]; then ok "scrubbed: eine kaputte Hashkopie wird ueberstimmt (#1877)"
else bad "scrubbed: eine kaputte Hashkopie wird ueberstimmt" "rc=$rc"; fi

# Zwei verschieden beschaedigte Kopien: keine Mehrheit. Still auf die erste
# zu fallen waere der stille Default — es wird gemeldet.
cp "$TMP/sc_h1" "$TMP/sc_h2"; mach_kaputt "$TMP/sc_h2" $((TABOFF + 68 + $(feld STRIDE))) 2
timeout 120 "$TMP/sc_h2" >"$TMP/o2" 2>&1; rc=$?
if [ "$rc" = "136" ] && grep -q "keine Mehrheit" "$TMP/o2"; then
  ok "scrubbed: zwei kaputte Kopien werden gemeldet (rc 136)"
else bad "scrubbed: zwei kaputte Kopien werden gemeldet" "rc=$rc $(head -1 "$TMP/o2")"; fi

echo
echo "=== scrubbed unter @capabilities ==="

# Der Sweep braucht `setitimer`. Steht es nicht im Filter, stirbt das Programm
# an SIGSYS — die Freigabe haengt deshalb am Sweep und nicht am Basissatz.
CAPSC='unit main;
@capabilities([system.exit, system.memory.heap])
import std.io;
@integrity(mode: scrubbed, interval: 50)
fn F(a: int64): int64 { return a + 1; }
fn main(): int64 {
  var i: int64 := 0; var s: int64 := 0;
  while (i < 20000000) { s := s + F(i); i := i + 1; }
  return 0;
}'
if baut "scrubbed unter @capabilities uebersetzt" "$CAPSC" "$TMP/capsc"; then
  ok "scrubbed unter @capabilities uebersetzt"
  timeout 120 "$TMP/capsc" >/dev/null 2>&1; rc=$?
  if [ "$rc" = "0" ]; then ok "scrubbed unter @capabilities laeuft (setitimer freigegeben)"
  else bad "scrubbed unter @capabilities laeuft" "rc=$rc"; fi
fi

echo
echo "=== .meta_safe v2 (#1877) ==="

MS='unit main;
import std.io;
import std.meta_safe;
fn main(): int64 {
  PrintStr("v="c);  PrintLn(IntToStr(MetaSafeFormatVersion()));
  PrintStr("d="c);  PrintLn(IntToStr(MetaSafeVerify()));
  PrintStr("m="c);  PrintLn(IntToStr(MetaSafeVerifyMemory()));
  return 0;
}'
printf '%s\n' "$MS" > "$TMP/ms.lyx"
if "$LYXC" --std-path="$ROOT" "$TMP/ms.lyx" --meta-safe -o "$TMP/ms" >/dev/null 2>&1; then
  ok ".meta_safe uebersetzt"
  aus="$("$TMP/ms")"
  case "$aus" in *"v=2"*) ok ".meta_safe traegt Format 2" ;; *) bad ".meta_safe traegt Format 2" "$aus" ;; esac
  case "$aus" in *"d=0"*) ok ".meta_safe: Datei heil" ;;      *) bad ".meta_safe: Datei heil" "$aus" ;; esac
  # DAS ist die Aussage aus #1879: geprueft wird der geladene Code, nicht der
  # Dateiinhalt. v1 konnte diese Frage gar nicht beantworten — es fehlte
  # code_start_va.
  case "$aus" in *"m=0"*) ok ".meta_safe: geladener Code heil (#1879)" ;; *) bad ".meta_safe: geladener Code heil" "$aus" ;; esac

  cp "$TMP/ms" "$TMP/ms_kaputt"; mach_kaputt "$TMP/ms_kaputt" 0x2000 1
  aus2="$("$TMP/ms_kaputt" 2>&1)"
  case "$aus2" in *"d=-1"*) ok ".meta_safe: veraenderte Datei wird erkannt" ;; *) bad ".meta_safe: veraenderte Datei wird erkannt" "$aus2" ;; esac
else
  bad ".meta_safe uebersetzt" "Uebersetzung schlug fehl"
fi

# Ohne --meta-safe gibt es keine Sektion — und die Auskunft dazu muss ein
# eigener Wert sein, nicht "heil".
printf '%s\n' "$MS" > "$TMP/ms0.lyx"
if "$LYXC" --std-path="$ROOT" "$TMP/ms0.lyx" -o "$TMP/ms0" >/dev/null 2>&1; then
  aus3="$("$TMP/ms0")"
  case "$aus3" in *"v=-1"*) ok "ohne --meta-safe: keine Sektion gemeldet" ;; *) bad "ohne --meta-safe: keine Sektion gemeldet" "$aus3" ;; esac
  case "$aus3" in *"m=-2"*) ok "ohne --meta-safe: Speicherpruefung meldet -2 statt 0" ;; *) bad "ohne --meta-safe: Speicherpruefung meldet -2" "$aus3" ;; esac
fi

echo
echo "=== ir_safety.lyx ist weg ==="
# Die Datei trug setIntegrity/getDAL/getWCET und wurde nirgends gebaut. Sie
# stehen zu lassen hiesse, bei der naechsten Durchsicht wieder Deckung
# vorzutaeuschen, die es nicht gibt.
if [ -f "$ROOT/src/ir/ir_safety.lyx" ]; then
  bad "ungebaute Safety-Datei entfernt" "src/ir/ir_safety.lyx ist wieder da"
else ok "ungebaute Safety-Datei entfernt"; fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
