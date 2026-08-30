#!/usr/bin/env bash
# tests/disasm_test.sh — --dump-asm / --emit-asm / --asm-listing (#1370).
#
# Die drei Schalter wiesen bis 1.1.12C laut ab. Umgesetzt sind sie jetzt ueber
# einen Disassembler fuer den Befehlsvorrat des Codegens
# (src/tools/disasm/x86.lyx); das Issue nannte als Gegenentwurf, die Mnemonics
# waehrend der Emission mitzuschreiben — das haette jede der rund zweitausend
# Emissionsstellen beruehrt.
#
# WIE HIER GEMESSEN WIRD: nicht am Text, sondern an den BEFEHLSGRENZEN gegen
# objdump. Ein Disassembler, der eine Laenge falsch bemisst, verschiebt alles
# danach — die Auflistung waere dann nicht unvollstaendig, sondern
# irrefuehrend. Deckungsgleiche Adressen sind der Nachweis, dass jede Laenge
# stimmt; wie die Operanden geschrieben werden, ist demgegenueber Geschmack.
#
# Drei Fehler hat genau diese Messung gefunden, die eine Textpruefung nicht
# gesehen haette: pxor (0F EF) fehlte, der Auffangzweig fuer unbekannte
# 0F-Opcodes zaehlte das ModRM-Byte nicht mit, und die Drei-Byte-Escapes
# 0F 38 / 0F 3A (roundsd) fehlten ganz.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }
ulimit -c 0 2>/dev/null

if ! command -v objdump >/dev/null 2>&1; then
  echo "SKIP: objdump fehlt — ohne Gegenstueck misst der Vergleich nichts"
  exit 0
fi

# grenzen <name> <quelltext>
# Uebersetzt mit --map-file --dump-asm, schneidet den .text heraus und
# vergleicht die Befehlsanfaenge mit objdump.
grenzen() {
  local name="$1"
  printf '%s' "$2" > "$TMP/$name.lyx"
  if ! timeout 300 "$LYXC" --std-path="$ROOT" --map-file --dump-asm \
        "$TMP/$name.lyx" -o "$TMP/$name" > "$TMP/$name.asm" 2>"$TMP/$name.err"; then
    no "$name" "uebersetzt nicht: $(grep -im1 error "$TMP/$name.err")"; return
  fi
  local len
  len="$(grep -A3 '^Sektionen' "$TMP/$name.map" 2>/dev/null | grep '\.text' | awk '{print $3}')"
  if [ -z "$len" ]; then no "$name" "keine .text-Laenge in der Karte"; return; fi

  python3 - "$TMP/$name" "$len" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
n = int(sys.argv[2])
open(sys.argv[1] + '.text', 'wb').write(d[176:176+n])
PY

  # -z: objdump kuerzt lange Nullfolgen sonst mit "..." ab und disassembliert
  # den Rest gar nicht. --no-show-raw-insn: sonst brechen Befehle ueber sieben
  # Byte ihre Bytes auf eine Folgezeile um, die ebenfalls mit einer Adresse
  # beginnt — beides hat den Vergleich beim ersten Anlauf verfaelscht.
  objdump -D -z -b binary -m i386:x86-64 -M intel --no-show-raw-insn \
          --adjust-vma=0x4000b0 "$TMP/$name.text" 2>/dev/null \
    | awk '/^ /{sub(":","",$1); print $1}' > "$TMP/$name.od"
  grep -oE '^  [0-9a-f]{16}' "$TMP/$name.asm" | sed 's/^  //;s/^0*//' > "$TMP/$name.my"

  local o m d2
  o="$(wc -l < "$TMP/$name.od")"; m="$(wc -l < "$TMP/$name.my")"
  d2="$(diff "$TMP/$name.od" "$TMP/$name.my" | grep -c '^[<>]')"
  if [ "$o" -lt 100 ]; then no "$name" "objdump lieferte nur $o Befehle — Vergleich waere aussagelos"; return; fi
  if [ "$d2" -eq 0 ]; then
    ok "$name: $o Befehlsgrenzen deckungsgleich mit objdump"
  else
    no "$name" "$d2 abweichende Grenzen (objdump $o, Lyx $m) — erste: $(diff "$TMP/$name.od" "$TMP/$name.my" | grep -m1 '^[<>]')"
  fi
}

grenzen "grund" 'fn zwei(a: int64): int64 { return a * 2; }
fn main(): int64 { var x: int64 := zwei(21); if (x > 40) { return x; } return 0; }'

# Gleitkomma bringt die SSE-Formen und die Drei-Byte-Escapes ins Spiel; Klassen
# bringen VMT-Aufrufe, Zeichenketten die Kopierbefehle.
grenzen "breit" 'import std.io;
import std.math;
type P = class { X: int64; Y: f64; fn Create(): void { self.X := 1; self.Y := 2.5; } virtual fn W(): f64 { return self.Y * 2.0; } }
fn main(): int64 {
  var p: P := new P();
  var s: f64 := 0.0;
  var i: int64 := 0;
  while (i < 10) { s := s + p.W() + SqrtF64(i as f64); i := i + 1; }
  PrintFloatLn(s);
  PrintLn(StrConcat("a"c, "b"c));
  return 0;
}'

# --- Die drei Schalter tun, was ihr Name sagt ------------------------------
printf 'fn main(): int64 { return 0; }' > "$TMP/s.lyx"

if timeout 300 "$LYXC" --std-path="$ROOT" --emit-asm "$TMP/s.lyx" -o "$TMP/s" >/dev/null 2>&1; then
  if [ -s "$TMP/s.asm" ]; then ok "--emit-asm schreibt <ziel>.asm"; else no "--emit-asm" "keine Datei entstanden"; fi
else
  no "--emit-asm" "uebersetzt nicht"
fi

# #1862: Die Auflistung steht seit 1.1.14B in <ausgabe>.asm, nicht auf stdout.
# Bis dahin las diese Pruefung den Strom — und haette damit rot gemeldet, sobald
# der Schalter tut, was der Hilfetext sagt.
rm -f "$TMP/s2.asm"
if timeout 300 "$LYXC" --std-path="$ROOT" --asm-listing "$TMP/s.lyx" -o "$TMP/s2" >/dev/null 2>&1 \
   && grep -q "Quelle Zeile" "$TMP/s2.asm" 2>/dev/null; then
  ok "--asm-listing nennt die Quellzeile in <ziel>.asm"
else
  no "--asm-listing" "keine Quellzeile in $TMP/s2.asm"
fi

# Und der Schalter darf nicht mehr als "nicht umgesetzt" abweisen — genau das
# war der Zustand, den dieses Issue beschrieben hat.
for sch in --dump-asm --emit-asm --asm-listing; do
  if timeout 300 "$LYXC" --std-path="$ROOT" "$sch" "$TMP/s.lyx" -o "$TMP/s3" 2>&1 | grep -q "nicht umgesetzt"; then
    no "$sch" "wird weiterhin als nicht umgesetzt abgewiesen"
  else
    ok "$sch wird angenommen"
  fi
done

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
