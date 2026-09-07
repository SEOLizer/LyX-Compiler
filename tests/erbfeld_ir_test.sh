#!/usr/bin/env bash
# #1985: Ein GEERBTES FELD ueber eine Unit-Grenze hinweg lag im IR-Weg auf der
# falschen Stelle.
#
# WAS WIRKLICH PASSIERTE — schaerfer als die Meldung sagte. `_fieldOffsetIn`
# lief die extends-Kette ueber `_findTypeDecl` hoch, und das sieht nur das
# gerade gesetzte Modul. Lag die Basis in einer anderen Unit, blieb der Versatz
# auf 0: die EIGENEN Felder der Ableitung begannen bei null und ueberlagerten
# die geerbten. Gemessen lieferte `HoleW()` deshalb nicht 0, sondern den Wert
# des daneben deklarierten eigenen Feldes — zwei Namen auf derselben Stelle.
#
# Dazu zaehlte `_typeSizeOf` die Basisfelder nicht mit; das Objekt war ZU
# KLEIN. Beide Funktionen muessen dieselbe Kette laufen, sonst rechnen sie mit
# verschiedenen Layouts.
#
# GEMESSEN WIRD AUSGEFUEHRT, mit ZWEI geerbten Feldern: bei nur einem faellt
# ein Versatz um genau eine Position nicht auf. Und mit der Ableitung in
# DERSELBEN Unit als Gegenprobe — die stimmte schon immer, und waere der Fix
# eine Verschlimmbesserung am Layout, faende sie es.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

QUELLE="$ROOT/tests/data/erbfeld"
# Erwartung im Klartext:
#   gleiche Unit:  w=44 (im Create gesetzt), z=22 (geerbt), eigen=5
#   andere Unit:   w=77 (im Create gesetzt), z=22 (geerbt), eigen=5
# Waere der Versatz falsch, traefe `self.eigen := 5` das Feld w oder z.
SOLL="44 22 5 77 22 5"

pruefe_ziel() {   # Name, lyxc-Argumente, Ausfuehrer
    local name="$1" args="$2" run="$3"
    if ! ( cd / && timeout 180 "$LYXC" $args --std-path="$ROOT" -I "$QUELLE" \
            "$QUELLE/main.lyx" -o "$TMP/p" ) >"$TMP/b.log" 2>&1; then
        nok "$name: uebersetzt nicht"; grep -v Copyright "$TMP/b.log" | sed -n '1,4p'; return
    fi
    local ist
    ist="$( ulimit -v 4000000; timeout 60 $run "$TMP/p" 2>&1 )"
    if [ "$ist" = "$SOLL" ]; then ok "$name"
    else nok "$name: erwartet '$SOLL', bekommen '$ist'"; fi
}

echo "--- geerbtes Feld ueber Unit-Grenze (#1985) ---"

# x86 geht direkt vom AST und war nie betroffen — misst den Bestand mit.
pruefe_ziel "x86 (direkt vom AST)" "" ""

if command -v qemu-aarch64-static >/dev/null 2>&1; then
    pruefe_ziel "arm64 (IR-Weg)" "--target=arm64" "qemu-aarch64-static"
else
    echo "HINWEIS qemu-aarch64-static fehlt — arm64 ungemessen"
fi

if command -v qemu-riscv64-static >/dev/null 2>&1; then
    pruefe_ziel "riscv (IR-Weg)" "--target=riscv" "qemu-riscv64-static"
else
    echo "HINWEIS qemu-riscv64-static fehlt — riscv ungemessen"
fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
