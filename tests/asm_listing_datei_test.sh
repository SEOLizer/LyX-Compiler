#!/bin/bash
# #1862: --asm-listing schreibt nach <ausgabe>.asm, nicht nach stdout.
#
# Hilfetext und Changelog nannten die Datei, der Code setzte den Pfad aber nur
# fuer --emit-asm. Gemessen wird deshalb, WO die Auflistung landet — dass sie
# entsteht, war nie die Frage.
#
# Drei Schalter, drei Ziele, und jeder braucht seine Gegenprobe:
#   --dump-asm     stdout, KEINE Datei
#   --emit-asm     Datei
#   --asm-listing  Datei, zusaetzlich mit Quellzeilen

cd "$(dirname "$0")/.." || exit 1
LYXC="${LYXC:-./lyxc}"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

cat > "$TMP/t.lyx" <<'EOF'
unit main;
fn zwei(): int64 { return 2; }
fn main(): int64 { return zwei(); }
EOF

bau() {   # Schalter... → stdout in $TMP/out.txt, Ausgabe $TMP/bin
    rm -f "$TMP/bin" "$TMP/bin.asm"
    $LYXC "$TMP/t.lyx" -o "$TMP/bin" "$@" > "$TMP/out.txt" 2> "$TMP/err.txt"
}

ok()   { echo "PASS $1"; PASS=$((PASS + 1)); }
nok()  { echo "FAIL $1"; FAIL=$((FAIL + 1)); }

# --- --asm-listing: Datei, nicht stdout -----------------------------------
bau --asm-listing
if [ -s "$TMP/bin.asm" ]; then ok "--asm-listing legt <ausgabe>.asm an"; else
    nok "--asm-listing legt <ausgabe>.asm an — Datei fehlt oder ist leer"; fi
if grep -q "Lyx-Disassemblat" "$TMP/bin.asm" 2>/dev/null; then
    ok "--asm-listing: die Auflistung steht in der Datei"; else
    nok "--asm-listing: in der Datei steht keine Auflistung"; fi
if ! grep -q "Lyx-Disassemblat" "$TMP/out.txt"; then
    ok "--asm-listing schreibt NICHT nach stdout"; else
    nok "--asm-listing schreibt weiterhin nach stdout (#1862)"; fi
# Das Unterscheidungsmerkmal gegenueber --emit-asm: die Quellzeilen.
if grep -q "Quelle Zeile" "$TMP/bin.asm" 2>/dev/null; then
    ok "--asm-listing nennt die Quellzeilen"; else
    nok "--asm-listing nennt die Quellzeilen — sonst ist es nur --emit-asm"; fi

# --- --emit-asm: unveraendert Datei, ohne Quellzeilen ----------------------
bau --emit-asm
if [ -s "$TMP/bin.asm" ]; then ok "--emit-asm legt <ausgabe>.asm an"; else
    nok "--emit-asm legt <ausgabe>.asm an"; fi
if ! grep -q "Quelle Zeile" "$TMP/bin.asm" 2>/dev/null; then
    ok "--emit-asm bleibt ohne Quellzeilen"; else
    nok "--emit-asm nennt jetzt Quellzeilen — die Schalter sind verschmolzen"; fi

# --- --dump-asm: stdout, KEINE Datei --------------------------------------
# Gegenprobe zur Aenderung: der Schalter fuer stdout muss stdout bleiben.
bau --dump-asm
if grep -q "Lyx-Disassemblat" "$TMP/out.txt"; then
    ok "--dump-asm schreibt nach stdout"; else
    nok "--dump-asm schreibt nicht mehr nach stdout"; fi
if [ ! -e "$TMP/bin.asm" ]; then ok "--dump-asm legt keine Datei an"; else
    nok "--dump-asm legt jetzt eine Datei an"; fi

# --- beides zusammen: Datei gewinnt, und der Lauf sagt es -----------------
bau --dump-asm --asm-listing
if [ -s "$TMP/bin.asm" ]; then ok "--dump-asm --asm-listing: Datei entsteht"; else
    nok "--dump-asm --asm-listing: Datei entsteht"; fi
if grep -q "steht in" "$TMP/err.txt"; then
    ok "--dump-asm --asm-listing: der Lauf nennt den Ablageort"; else
    nok "--dump-asm --asm-listing: stdout bleibt wortlos leer"; fi

echo
echo "$PASS PASS, $FAIL FAIL"
[ "$FAIL" = "0" ] || exit 1
echo "OK: asm-Auflistung landet, wo der Hilfetext es sagt"
exit 0
