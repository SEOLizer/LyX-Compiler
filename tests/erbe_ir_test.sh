#!/usr/bin/env bash
# #1976: Eine GEERBTE Methode, aufgerufen ueber den ABGELEITETEN Typ, lieferte
# auf dem IR-Weg still 0 — kein Fehler, kein Absturz, nur der falsche Wert.
#
# Das Issue meldete es fuer --target=lyxos. Nachgemessen betrifft es JEDES
# Ziel, das ueber ir_lower geht (arm64 und riscv zeigen dasselbe Bild); der
# x86-Codegen geht direkt vom AST und war nie betroffen. Die Praemisse
# "lyxos-Bug" war also zu eng — wie schon bei #1786, #1787 und #1798.
#
# URSACHE: `_resolveMethodIdx` lief die extends-Kette ueber `_findTypeDecl`
# hoch, und das sieht nur das GERADE GESETZTE Modul. Lag die Basisklasse in
# einer anderen Unit, endete die Kette, die Aufloesung lieferte -1 — und die
# Aufrufstelle emittierte daraufhin GAR KEINEN Aufruf. Das Ergebnisregister
# behielt seine 0.
#
# GEMESSEN WIRD AUSGEFUEHRT und ueber ZWEI Modulgrenzen: TAbl (Programm)
# erbt von TMitte (eigene Unit), das von TBasis (eigene Unit) erbt. Bei nur
# einer Stufe wuerde ein Fehler in der FORTSETZUNG der Kette nicht auffallen.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

QUELLE="$ROOT/tests/data/erbe"
SOLL="14 21 100 14 14"

# Erwartung im Klartext:
#   a.Doppelt()  = 14   geerbt aus TBasis, zwei Stufen hoch
#   a.Dreifach() = 21   ebenso
#   a.Eigen()    = 100  aus TMitte, eine Stufe hoch
#   b.Doppelt()  = 14   dasselbe Objekt ueber die Basis — war schon immer richtig
#   c.Doppelt()  = 14   Basis direkt — war schon immer richtig
#
# Die letzten beiden sind die GEGENPROBE: waere der Fix eine Verschlimmbesserung
# an der Dispatch, faenden sie es.

pruefe_ziel() {   # Name, lyxc-Argumente, Ausfuehrer
    local name="$1" args="$2" run="$3"
    if ! ( cd / && timeout 180 "$LYXC" $args --std-path="$ROOT" -I "$QUELLE" \
            "$QUELLE/main.lyx" -o "$TMP/p" ) >"$TMP/b.log" 2>&1; then
        nok "$name: uebersetzt nicht"; sed -n '1,4p' "$TMP/b.log"; return
    fi
    local ist
    ist="$( ulimit -v 4000000; timeout 60 $run "$TMP/p" 2>&1 )"
    if [ "$ist" = "$SOLL" ]; then ok "$name"
    else nok "$name: erwartet '$SOLL', bekommen '$ist'"; fi
}

echo "--- geerbte Methode ueber den abgeleiteten Typ (#1976) ---"

# x86: war nie betroffen, misst also den unveraenderten Bestand mit.
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

# Eine Methode, die es NIRGENDS gibt, muss laut scheitern. Vorher wurde bei
# misslungener Aufloesung einfach nichts emittiert — dieselbe stille 0.
cat > "$TMP/fehlt.lyx" <<'EOF'
import rp.basis;
import std.io;
type TX = class extends TBasis {
  fn Create(): void { super.Create(); }
}
fn main(): int64 { var a: TX := new TX(); PrintLn(IntToStr(a.GibtEsNicht())); return 0; }
EOF
if ( cd / && timeout 180 "$LYXC" --target=arm64 --std-path="$ROOT" -I "$QUELLE" \
      "$TMP/fehlt.lyx" -o "$TMP/fehlt" ) >"$TMP/f.log" 2>&1; then
    nok "unbekannte Methode: uebersetzt durch, statt zu melden"
elif grep -qi "nicht aufloesbar\|undefined\|unbekannt" "$TMP/f.log"; then
    ok "unbekannte Methode wird gemeldet"
else
    nok "unbekannte Methode: falsche Meldung ($(grep -v Copyright "$TMP/f.log" | head -1))"
fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
