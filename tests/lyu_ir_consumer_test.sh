#!/usr/bin/env bash
# #1977: IR aus einer .lyu UEBERNEHMEN.
#
# #1974 legt das IR einer Unit in den IRCodeOffset-Abschnitt. Hier wird es beim
# Import gelesen und an das IR-Modul des Programms angehaengt — damit liefert
# eine Bibliothek, die NUR als .lyu vorliegt, endlich benutzbare Funktionen.
#
# GEMESSEN WIRD AUSGEFUEHRT, mit geloeschter Quelle. Ein Test, der nur prueft,
# dass es uebersetzt, waere auch von der alten Fassung erfuellt gewesen: die
# hat gewarnt ("Import nicht lesbar, seine Funktionen fehlen") und weitergebaut.
#
# ZWEI Units, nicht eine. Beim Anhaengen muessen alle Verweise um die Basis des
# Zielmoduls erhoeht werden; bei nur EINER importierten Unit ist jede Basis 0
# und ein vergessener Fall faellt nicht auf. Erst die zweite deckt es auf —
# besonders bei den Labelnummern, die sonst mit denen der ersten kollidieren.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

cat > "$TMP/eins.lyx" <<'EOF'
unit demo.eins;
pub fn Verdoppeln(x: int64): int64 { return x * 2; }
pub fn Wahl(x: int64): int64 { if (x > 10) { return 1; } return 2; }
EOF
cat > "$TMP/zwei.lyx" <<'EOF'
unit demo.zwei;
pub fn Dreifach(x: int64): int64 { return x * 3; }
pub fn Wahl2(x: int64): int64 { if (x > 5) { return 30; } return 40; }
EOF
cat > "$TMP/prog.lyx" <<'EOF'
import demo.eins;
import demo.zwei;
import std.io;
fn main(): int64 {
  PrintStr(IntToStr(Verdoppeln(21))); PrintStr(" ");
  PrintStr(IntToStr(Dreifach(5)));    PrintStr(" ");
  PrintStr(IntToStr(Wahl(20)));       PrintStr(" ");
  PrintLn(IntToStr(Wahl2(1)));
  return 0;
}
EOF
SOLL="42 15 1 40"
# Wahl(20)=1 und Wahl2(1)=40 kommen aus VERZWEIGUNGEN: sie belegen, dass die
# Labelnummern beider Units umnummeriert wurden. Ohne das spraenge der zweite
# Test ins Sprungziel des ersten — und zwar in einem Programm, das laeuft.

pruefe_ziel() {   # Name, --target-Wert, Ausfuehrer
    local name="$1" ziel="$2" run="$3"
    local dir="$TMP/$name"
    mkdir -p "$dir/demo"
    # #1982: Die .lyu wird FUER DIESES ZIEL gebaut — das IR-Lowering ist
    # zielabhaengig, und der Consumer weist eine fremde Architektur ab.
    local u
    for u in eins zwei; do
        if ! ( cd "$ROOT" && timeout 120 "$LYXC" --compile-unit --target="$ziel" \
                --std-path="$ROOT" "$TMP/$u.lyx" -o "$dir/demo/$u.lyu" ) >"$dir/cu.log" 2>&1; then
            nok "$name: --compile-unit fuer $u schlaegt fehl"
            grep -v Copyright "$dir/cu.log" | sed -n '1,3p'
            return
        fi
    done
    # Die QUELLEN liegen NICHT im Suchpfad dieses Ziels — nur die .lyu.
    if ! ( cd / && timeout 180 "$LYXC" --target="$ziel" --std-path="$ROOT" -I "$dir" \
            "$TMP/prog.lyx" -o "$dir/p" ) >"$dir/b.log" 2>&1; then
        nok "$name: uebersetzt nicht"; grep -v Copyright "$dir/b.log" | sed -n '1,4p'; return
    fi
    # Die Warnung der alten Fassung darf NICHT mehr kommen: sie hiesse, dass
    # der Rumpf fehlt und das Erzeugnis unvollstaendig ist.
    if grep -q "Import nicht lesbar" "$dir/b.log"; then
        nok "$name: warnt weiterhin ueber den unlesbaren Import"; return
    fi
    local ist
    ist="$( ulimit -v 4000000; timeout 60 $run "$dir/p" 2>&1 )"
    if [ "$ist" = "$SOLL" ]; then ok "$name (nur .lyu, Quellen ausserhalb des Suchpfads)"
    else nok "$name: erwartet '$SOLL', bekommen '$ist'"; fi
}

echo "--- .lyu-only auf dem IR-Weg (#1977) ---"
if command -v qemu-aarch64-static >/dev/null 2>&1; then
    pruefe_ziel "arm64" "arm64" "qemu-aarch64-static"
else
    echo "HINWEIS qemu-aarch64-static fehlt — arm64 ungemessen"
fi
if command -v qemu-riscv64-static >/dev/null 2>&1; then
    pruefe_ziel "riscv" "riscv" "qemu-riscv64-static"
else
    echo "HINWEIS qemu-riscv64-static fehlt — riscv ungemessen"
fi

# #1982: Eine .lyu fuer ein FREMDES Ziel darf nicht benutzt werden. Das IR ist
# zielabhaengig; arm64-IR auf riscv waere stiller Unsinn. Erwartet wird die
# Meldung UND das Ausbleiben eines brauchbaren Erzeugnisses.
if command -v qemu-riscv64-static >/dev/null 2>&1 && [ -d "$TMP/arm64/demo" ]; then
    if ( cd / && timeout 180 "$LYXC" --target=riscv --std-path="$ROOT" -I "$TMP/arm64" \
          "$TMP/prog.lyx" -o "$TMP/fremd" ) >"$TMP/fremd.log" 2>&1; then
        if grep -q "andere Architektur" "$TMP/fremd.log"; then
            ok "eine .lyu fuer ein fremdes Ziel wird gemeldet und ihr IR nicht benutzt"
        else
            nok "fremde Architektur: keine Meldung ($(grep -v Copyright "$TMP/fremd.log" | head -1))"
        fi
    else
        # Auch ein Abbruch ist in Ordnung — Hauptsache nicht stillschweigend
        # falsches IR.
        if grep -q "andere Architektur" "$TMP/fremd.log"; then
            ok "eine .lyu fuer ein fremdes Ziel wird gemeldet und ihr IR nicht benutzt"
        else
            nok "fremde Architektur: unerwarteter Abbruch ($(grep -v Copyright "$TMP/fremd.log" | head -1))"
        fi
    fi
fi

# --- Waechter: jeder Opcode ist klassifiziert -------------------------------
#
# Die Relokation kennt elf Opcodes, deren Felder in modulweite Puffer zeigen.
# Kommt ein neuer hinzu, MUSS jemand entscheiden, ob er dazugehoert. Ohne
# diesen Waechter faellt ein vergessener Fall erst am laufenden Programm auf —
# als Basis, die auf eine Zahl addiert wurde, die keine Adresse ist.
TAB="$ROOT/tests/data/ir_opcode_reloc.txt"
grep -oE "^pub con IRO_[A-Z0-9_]+" "$ROOT/src/ir.lyx" | awk '{print $3}' | sed 's/:$//' | sort -u > "$TMP/ist.txt"
grep -v "^#" "$TAB" | awk 'NF {print $1}' | sort -u > "$TMP/soll.txt"
comm -23 "$TMP/ist.txt" "$TMP/soll.txt" > "$TMP/neu.txt"
comm -13 "$TMP/ist.txt" "$TMP/soll.txt" > "$TMP/weg.txt"

if [ -s "$TMP/neu.txt" ]; then
    nok "$(wc -l < "$TMP/neu.txt") Opcode(s) ohne Klassifizierung:"
    sed 's/^/    /' "$TMP/neu.txt"
    echo "  In tests/data/ir_opcode_reloc.txt eintragen — abgelesen am BACKEND,"
    echo "  nicht am Kommentar: traegt ein Feld einen Index oder Offset in einen"
    echo "  modulweiten Puffer (func, str, global, label), gehoert es in die"
    echo "  Relokation von _irUebernehmeLyu."
else
    ok "alle $(wc -l < "$TMP/ist.txt") Opcodes sind klassifiziert"
fi

if [ -s "$TMP/weg.txt" ]; then
    nok "$(wc -l < "$TMP/weg.txt") klassifizierte(r) Opcode(s) gibt es nicht mehr:"
    sed 's/^/    /' "$TMP/weg.txt"
else
    ok "kein veralteter Eintrag in der Tabelle"
fi

# Die elf relokationspflichtigen muessen in _irUebernehmeLyu auch VORKOMMEN.
# Sonst steht die Tabelle richtig da und der Code tut es nicht.
fehlend=""
while read -r op klasse; do
    case "$klasse" in
        -|"") continue ;;
    esac
    if ! grep -q "$op" "$ROOT/src/ir_lower.lyx"; then fehlend="$fehlend $op"; fi
done < <(grep -v "^#" "$TAB" | awk 'NF')
if [ -n "$fehlend" ]; then
    nok "in _irUebernehmeLyu nicht behandelt:$fehlend"
else
    ok "jeder relokationspflichtige Opcode kommt im Umrechner vor"
fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
