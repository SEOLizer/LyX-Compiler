#!/usr/bin/env bash
# #1966: Was eine `.lyu` traegt — und was nicht.
#
# Eine `.lyu` enthaelt NAMEN und TYPEN, weder die Werte der Konstanten noch
# den Code der Funktionen. Bis 1.2.3A hat der Codegen einen Import, dessen
# `.lyx` er nicht lesen konnte, nur GEMELDET und dann uebergangen. Die
# Auswirkung war still und gefaehrlich: sema hatte die Unit ueber die `.lyu`
# aufgeloest, und jede Konstante daraus kam als 0 an — kein Fehler, kein
# Abbruch, das Programm lief und rechnete falsch.
#
# Gemessen wird deshalb der WERT im gueltigen Fall und die ABLEHNUNG im
# Fall ohne Quelle. Ein Test, der nur prueft, dass eine Meldung erscheint,
# waere auch von der alten Fassung erfuellt gewesen: die hat gemeldet UND
# weitergemacht.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

mkdir -p "$TMP/demo"
cat > "$TMP/demo/mathe.lyx" <<'EOF'
unit demo.mathe;
pub fn Verdoppeln(x: int64): int64 { return x * 2; }
pub fn Name(): pchar { return "hallo"; }
pub con ZWEI: int64 := 2;
EOF

cat > "$TMP/prog.lyx" <<'EOF'
unit main;
import std.io;
import demo.mathe;
fn main(): int64 {
  PrintStr(IntToStr(ZWEI)); PrintStr(" ");
  PrintStr(IntToStr(Verdoppeln(21))); PrintStr(" ");
  PrintLn(Name());
  return 0;
}
EOF

echo "--- .lyu erzeugen ---"
if ( cd "$ROOT" && timeout 120 "$LYXC" --compile-unit --std-path="$ROOT" "$TMP/demo/mathe.lyx" -o "$TMP/demo/mathe.lyu" ) >"$TMP/cu.log" 2>&1; then
    ok "--compile-unit erzeugt die .lyu"
else
    nok "--compile-unit schlaegt fehl"; sed -n '1,4p' "$TMP/cu.log"
fi

# --- 1. Rueckgabetypen in --unit-info ---------------------------------------
#
# sema traegt JEDE Funktion mit TY_VOID ein; der Rueckgabetyp steht in der
# Signaturtabelle. Wer SymTypeId dafuer nimmt, schreibt ueberall "void" — so
# stand es in jeder .lyu, auch in std/math.lyu.
info="$( cd "$ROOT" && timeout 60 "$LYXC" --unit-info "$TMP/demo/mathe.lyu" 2>&1 )"
if printf '%s' "$info" | grep -qE "fn[[:space:]]+Verdoppeln[[:space:]]+int64"; then
    ok "--unit-info nennt den Rueckgabetyp int64"
else
    nok "--unit-info: Verdoppeln nicht als int64 ($(printf '%s' "$info" | grep Verdoppeln))"
fi
if printf '%s' "$info" | grep -qE "fn[[:space:]]+Name[[:space:]]+pchar"; then
    ok "--unit-info nennt den Rueckgabetyp pchar"
else
    nok "--unit-info: Name nicht als pchar ($(printf '%s' "$info" | grep Name))"
fi

# --- 2. Mit Quelle: alles traegt, und die WERTE stimmen ----------------------
if ( cd / && timeout 120 "$LYXC" --std-path="$ROOT" --include-path="$TMP" "$TMP/prog.lyx" -o "$TMP/prog" ) >"$TMP/b1.log" 2>&1; then
    aus="$( ulimit -v 4000000; timeout 60 "$TMP/prog" 2>&1 )"
    if [ "$aus" = "2 42 hallo" ]; then
        ok "mit .lyx daneben: Konstante, Funktion und Zeichenkette stimmen"
    else
        nok "mit .lyx daneben: bekommen '$aus', erwartet '2 42 hallo'"
    fi
else
    nok "mit .lyx daneben: uebersetzt nicht"; sed -n '1,4p' "$TMP/b1.log"
fi

# --- 3. NUR die .lyu: Abbruch statt stiller 0 -------------------------------
#
# Gemessen wird BEIDES: der Abbruch UND dass kein Erzeugnis entsteht. Die alte
# Fassung meldete und baute trotzdem weiter — ein Test allein auf die Meldung
# haette sie nicht von der neuen unterschieden.
rm -f "$TMP/demo/mathe.lyx" "$TMP/prog2"
if ( cd / && timeout 120 "$LYXC" --std-path="$ROOT" --include-path="$TMP" "$TMP/prog.lyx" -o "$TMP/prog2" ) >"$TMP/b2.log" 2>&1; then
    nok "nur .lyu: uebersetzt durch, statt abzubrechen"
elif ! grep -q "Quelle der importierten Unit nicht lesbar" "$TMP/b2.log"; then
    nok "nur .lyu: falsche Meldung ($(grep -v Copyright "$TMP/b2.log" | head -1))"
elif [ -f "$TMP/prog2" ]; then
    nok "nur .lyu: Abbruch gemeldet, aber ein Erzeugnis liegt trotzdem da"
else
    ok "nur .lyu: Abbruch mit Begruendung, kein Erzeugnis"
fi

# Die Meldung muss den GRUND nennen, sonst sucht der naechste Leser die Unit.
if grep -q "weder die" "$TMP/b2.log" && grep -q "still als 0" "$TMP/b2.log"; then
    ok "die Meldung nennt Ursache und Folge"
else
    nok "die Meldung erklaert den Fall nicht"
fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
