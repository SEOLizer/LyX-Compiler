#!/usr/bin/env bash
# #1998: Eine GEERBTE, NICHT-VIRTUELLE Methode lieferte 0, sobald die
# Basisklasse in einem anderen Modul steht UND irgendeine virtuelle Methode
# traegt. Streicht man das `virtual` daneben, stimmt derselbe Aufruf.
#
# Das Issue meldete es fuer --target=lyxos. Nachgemessen betrifft es JEDES
# Ziel ueber ir_lower — arm64 und riscv zeigen dasselbe Bild, der x86-Codegen
# geht direkt vom AST und war nie betroffen. Dieselbe zu enge Praemisse wie
# bei #1786, #1787, #1798 und zuletzt #1976.
#
# URSACHE, und sie ist NICHT die von #1976: der Aufruf wurde sehr wohl
# emittiert, `self` kam richtig an (nachgemessen ueber eine geerbte Methode,
# die `self as int64` zurueckgibt — dieselbe Adresse). Falsch war das
# SPEICHERLAYOUT. `_hasVmt` lief die extends-Kette ueber `_findTypeDecl` hoch,
# und das sieht nur das gerade gesetzte Modul; an der Modulgrenze endete die
# Kette mit "keine VMT". Das erbende Modul legte die Felder deshalb ab Offset
# 0, das Modul der Basis las sie ab +8.
#
# Dieselbe Luecke steckte in _methodVirtual (eine geerbte virtuelle Methode
# galt als nicht-virtuell — faellt erst auf, wenn die Ableitung sie
# ueberschreibt) und in _classImplements. Mit _extendsClassG, _resolveMethodIdx
# (#1976), _fieldOffsetIn und _typeSizeOf (#1985) sind es SECHS Kettenlaeufe,
# die uebereinstimmen muessen.
#
# GEMESSEN WIRD AUSGEFUEHRT, und beide Seiten:
#   * dasselbe Feld aus BEIDEN Modulen gelesen — der Kern des Fehlers,
#   * die virtuelle Dispatch bleibt richtig (Ueberschreiben wirkt, auch ueber
#     den Basiszeiger). Ohne diese Haelfte waere der Test auch von einer
#     Fassung erfuellt, die die Dispatch abschaltet.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

QUELLE="$ROOT/tests/data/erbevmt"
SOLL="77 77 77 222 222 11 111"

# Erwartung im Klartext:
#   a.Wert()   = 77   geerbt, nicht virtuell, im Modul der BASIS uebersetzt
#   a.Eigen()  = 77   dasselbe Feld, im ERBENDEN Modul uebersetzt
#   a.w        = 77   dasselbe Feld, von aussen
#   a.VWert()  = 222  ueberschrieben
#   ueberBasis = 222  virtuelle Dispatch ueber den Basiszeiger
#   b.Wert()   = 11   Basis allein — war schon immer richtig
#   b.VWert()  = 111  Basis allein, virtuell — ebenso
#
# Die ersten drei muessen UEBEREINSTIMMEN. Genau das taten sie nicht: 0, 77, 77.

pruefe_ziel() {   # Name, lyxc-Argumente, Ausfuehrer
    local name="$1" args="$2" run="$3"
    if ! ( cd / && timeout 180 "$LYXC" $args --std-path="$ROOT" -I "$QUELLE" \
            "$QUELLE/main.lyx" -o "$TMP/p" ) >"$TMP/b.log" 2>&1; then
        nok "$name: uebersetzt nicht"; sed -n '1,4p' "$TMP/b.log"; return
    fi
    local ist
    # Zeilenumbrueche zu Leerzeichen — der Sollwert steht oben einzeilig.
    ist="$( ulimit -v 4000000; timeout 60 $run "$TMP/p" 2>&1 | tr '\n' ' ' | sed 's/ *$//' )"
    if [ "$ist" = "$SOLL" ]; then ok "$name"
    else nok "$name: erwartet '$SOLL', bekommen '$ist'"; fi
}

echo "--- geerbte Methode bei virtueller Basis ueber die Modulgrenze (#1998) ---"

# x86: war nie betroffen, misst also den unveraenderten Bestand mit und dient
# zugleich als Sollwertgeber.
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

# Und fuer lyxos, das hier nicht laufen kann, wenigstens die Uebersetzbarkeit.
# Sie war schon vorher gegeben — der Defekt war ein Laufzeitfehler —, aber ein
# Fix, der das Ziel bricht, faellt so auf.
if ( cd / && timeout 180 "$LYXC" --target=lyxos --std-path="$ROOT" -I "$QUELLE" \
        "$QUELLE/main.lyx" -o "$TMP/lx" ) >/dev/null 2>&1; then
    ok "lyxos uebersetzt weiterhin (nicht ausfuehrbar auf dem Buildhost)"
else
    nok "lyxos uebersetzt nicht mehr"
fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
