#!/usr/bin/env bash
# tests/beispiel_aes_vector_test.sh — examples/test_aes_vector.lyx laeuft und
# besteht, auf x86_64, arm64 und riscv.
#
# Das Beispiel war auf dreierlei Weise kaputt, und keine davon fiel auf, weil
# es in keinem Lauf vorkam:
#
#   * Es schrieb mit StrSetChar in String-LITERALE. Ein Literal ist kein
#     Schreibpuffer; auf riscv stuerzte das Programm beim ersten Schreibzugriff
#     ab.
#   * Der expandierte AES-128-Schluessel (176 Byte) lief in ein Literal von 64
#     Zeichen. Auf arm64 ueberschrieb das, was dahinter lag — das Programm
#     endete nach 53 richtigen Zeilen mit "Illegal instruction".
#   * Der ERWARTUNGSWERT war falsch: sechzehn Bytes, von denen nur die ersten
#     drei zum Vektor aus FIPS-197, Anhang B, gehoerten. Auf x86 lief das
#     Programm deshalb durch und meldete FAILED — mit rc 0.
#
# Der dritte Punkt ist der Grund, warum hier die MELDUNG geprueft wird und
# nicht der Rueckgabewert: der war immer 0.
#
# Die Bibliothek selbst rechnete die ganze Zeit richtig; das belegt
# tests/stdlib_bundle2_test.sh fuer x86 gegen FIPS-197. Dieser Test fuegt die
# beiden IR-Ziele hinzu — AES ist dort sonst nirgends gemessen.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
. "$(dirname "$0")/lib/qemu.sh"   # #2048: beide Paketnamen
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }
SRC="examples/test_aes_vector.lyx"

echo "--- $SRC ---"
for ziel in x86_64 arm64 riscv; do
  pre=""
  case "$ziel" in
    arm64) pre="$QEMU_ARM64" ;;
    riscv) pre="$QEMU_RISCV64" ;;
  esac
  if ! ( cd "$ROOT" && timeout 300 "$LYXC" --target="$ziel" "$SRC" -o "$TMP/aes_$ziel" ) >"$TMP/bl.log" 2>&1; then
    nok "[$ziel] uebersetzt nicht ($(grep -m1 -E '^lyxc:|error' "$TMP/bl.log"))"; continue
  fi
  if [ "$ziel" != "x86_64" ] && [ -z "$pre" ]; then
    nok "[$ziel] qemu fehlt — NICHT gemessen"; continue
  fi
  ( timeout 60 $pre "$TMP/aes_$ziel" > "$TMP/aus_$ziel" 2>&1; echo $? > "$TMP/rc_$ziel" ) 2>/dev/null
  rc="$(cat "$TMP/rc_$ziel")"
  if [ "$rc" != "0" ]; then
    nok "[$ziel] endet mit rc=$rc statt 0 (letzte Zeile: $(tail -1 "$TMP/aus_$ziel" | cut -c1-60))"; continue
  fi
  if grep -aq 'AES BLOCK TEST PASSED' "$TMP/aus_$ziel"; then ok "[$ziel] Verschluesselung trifft den Vektor aus FIPS-197"
  else nok "[$ziel] Verschluesselung: $(grep -a -m1 -E 'BLOCK TEST' "$TMP/aus_$ziel" || echo 'keine Meldung')"; fi
  if grep -aq 'DECRYPT TEST PASSED' "$TMP/aus_$ziel"; then ok "[$ziel] Entschluesselung liefert den Klartext zurueck"
  else nok "[$ziel] Entschluesselung: $(grep -a -m1 -E 'DECRYPT TEST' "$TMP/aus_$ziel" || echo 'keine Meldung')"; fi
done

# Die Ziele duerfen nicht auseinanderlaufen: dieselbe Ausgabe, Byte fuer Byte.
for ziel in arm64 riscv; do
  [ -f "$TMP/aus_$ziel" ] && [ -f "$TMP/aus_x86_64" ] || continue
  if cmp -s "$TMP/aus_x86_64" "$TMP/aus_$ziel"; then ok "[$ziel] Ausgabe wie auf x86_64 ($(wc -l < "$TMP/aus_$ziel") Zeilen)"
  else nok "[$ziel] Ausgabe weicht von x86_64 ab: $(diff "$TMP/aus_x86_64" "$TMP/aus_$ziel" | grep -m1 '^>' | cut -c1-70)"; fi
done

echo
echo "--- der Erwartungswert stimmt mit einer unabhaengigen Quelle ---"
#
# Der Fehler im Beispiel war ein falscher Erwartungswert. Damit sich das nicht
# wiederholt, wird der Vektor hier gegen openssl gerechnet — wo es openssl
# gibt. Fehlt es, ist das ein Hinweis und kein Fehlschlag: die Pruefung oben
# haengt nicht daran.
if command -v openssl >/dev/null 2>&1 && command -v xxd >/dev/null 2>&1; then
  ref="$(printf '\x32\x43\xf6\xa8\x88\x5a\x30\x8d\x31\x31\x98\xa2\xe0\x37\x07\x34' \
         | openssl enc -aes-128-ecb -nopad -K 2b7e151628aed2a6abf7158809cf4f3c 2>/dev/null | xxd -p)"
  # Die sechzehn Bytes aus den StrSetChar(expected, …)-Zeilen des Beispiels.
  ist="$(grep -oE 'StrSetChar\(expected, [0-9]+, 0x[0-9a-fA-F]{2}\)' "$ROOT/$SRC" \
         | sed -E 's/.*0x([0-9a-fA-F]{2})\)/\1/' | tr -d '\n' | tr 'A-F' 'a-f')"
  if [ -n "$ref" ] && [ "$ist" = "$ref" ]; then ok "der Erwartungswert im Beispiel ist der von openssl ($ref)"
  else nok "Erwartungswert im Beispiel [$ist] weicht von openssl [$ref] ab"; fi
else
  echo "HINWEIS openssl oder xxd fehlt — der Erwartungswert wurde nicht gegengerechnet"
fi

echo
echo "--- kein Puffer des Beispiels ist ein String-Literal ---"
#
# `var x: pchar := "    ";` gefolgt von StrSetChar(x, …) war der eigentliche
# Fehler. Die Puffer kommen aus alloc().
# Kommentarzeilen zaehlen nicht — der Kopf des Beispiels zitiert die alte
# Schreibweise.
lit="$(grep -vE '^[[:space:]]*//' "$ROOT/$SRC" | grep -cE 'var [a-z_]+: pchar := "' || true)"
if [ "$lit" = "0" ]; then ok "keine pchar-Variable wird mit einem Literal angelegt"
else nok "$lit pchar-Variable(n) werden mit einem Literal angelegt — Schreibzugriffe darauf sind undefiniert"; fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
