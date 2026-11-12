#!/usr/bin/env bash
# tests/obj_funktionssymbole_2146_test.sh — #2146 Stufe A: --emit=obj
# exportiert je Funktion und Methode ein Symbol.
#
# BEFUND. Ein mit --emit=obj erzeugtes Objekt exportierte GENAU EIN Symbol:
# `_start`. Alles andere waren UNDEF-Eintraege fuer externe Daten. Damit kann
# keine andere Einheit eine Funktion dieses Objekts aufrufen -- und genau das
# braucht der Objektcode in der .lyu (#2146, Stufen danach).
#
# WAS HIER GEPRUEFT WIRD, am ERZEUGNIS und an der WIRKUNG:
#   1. je `pub fn` ein GLOBAL/FUNC-Symbol, je Methode eines unter
#      `Klasse_Methode`
#   2. die Symboladresse trifft den Funktionsanfang (Prolog im Disassemblat)
#   3. ein FREMDES Objekt bindet dagegen und ruft zur Laufzeit -- der
#      eigentliche Beweis, denn ein Symbol, das nur im Verzeichnis steht,
#      nuetzt niemandem
#   4. Gegenseite: interne Marken (__lyx_*, anonyme) werden NICHT exportiert.
#      Ohne diese Haelfte waere der Test auch von "exportiere alles" erfuellt,
#      und der Binder bekaeme Namen, die niemand zusagt.
#
# WARUM objcopy IM TEST: --emit=obj verlangt heute ein `main`, ein reines
# Bibliotheksobjekt gibt es nicht. Fuer Schritt 3 werden `_start` und `main`
# deshalb lokalisiert, damit der C-Aufrufer seine eigenen mitbringen kann.
# Das ist eine Eigenheit des Pruefaufbaus, nicht der Aenderung.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

for w in nm objdump objcopy gcc; do
  command -v "$w" >/dev/null 2>&1 || { echo "SKIP: $w fehlt -- Objektpruefung nicht moeglich"; exit 0; }
done

cat > "$TMP/u.lyx" <<'EOF'
unit main;
type TBox = class {
  Zahl: int64;
  fn Create(): void { self.Zahl := 7; }
  fn Hol(): int64 { return self.Zahl; }
}
pub fn Verdopple(x: int64): int64 { return x * 2; }
pub fn Plus(a: int64, b: int64): int64 { return a + b; }
fn main(): int64 { var b: TBox := new TBox(); return Verdopple(21) + b.Hol(); }
EOF

if ! "$LYXC" --std-path="$ROOT" --emit=obj "$TMP/u.lyx" -o "$TMP/u.o" >"$TMP/o.log" 2>&1; then
  echo "FAIL --emit=obj scheitert:"
  grep -iE "error" "$TMP/o.log" | head -3 | sed 's/^/    /'
  echo "Ergebnis: 0 PASS, 1 FAIL"; exit 1
fi

echo "-- 1. Funktionen und Methoden sind exportiert --"
fehlt=""
for sym in Verdopple Plus TBox_Create TBox_Hol; do
  nm -g "$TMP/u.o" 2>/dev/null | grep -qE "^[0-9a-f]+ T $sym\$" || fehlt="$fehlt $sym"
done
if [ -z "$fehlt" ]; then
  echo "PASS Verdopple, Plus, TBox_Create und TBox_Hol als GLOBAL/FUNC"
  PASS=$((PASS+1))
else
  echo "FAIL nicht exportiert:$fehlt"
  nm "$TMP/u.o" 2>/dev/null | head -8 | sed 's/^/    /'
  FAIL=$((FAIL+1))
fi

echo "-- 2. die Symboladresse trifft den Funktionsanfang --"
# Ein Lyx-Funktionsprolog beginnt mit push %rbp; mov %rsp,%rbp.
adr="$(nm "$TMP/u.o" 2>/dev/null | awk '$3=="Verdopple"{print $1}' | sed 's/^0*//')"
if [ -z "$adr" ]; then
  echo "FAIL Adresse von Verdopple nicht lesbar"
  FAIL=$((FAIL+1))
else
  erste="$(objdump -d -z --no-show-raw-insn "$TMP/u.o" 2>/dev/null \
           | grep -A1 "^[[:space:]]*$adr:" | head -2 | tr '\n' ' ')"
  if printf '%s' "$erste" | grep -q "push" && printf '%s' "$erste" | grep -q "%rbp"; then
    echo "PASS Verdopple@$adr beginnt mit dem Prolog"
    PASS=$((PASS+1))
  else
    echo "FAIL Verdopple@$adr zeigt keinen Prolog: $erste"
    FAIL=$((FAIL+1))
  fi
fi

echo "-- 3. ein fremdes Objekt bindet dagegen und ruft zur Laufzeit --"
objcopy --localize-symbol=_start --localize-symbol=main "$TMP/u.o" "$TMP/lib.o" 2>/dev/null
cat > "$TMP/ruf.c" <<'EOF'
#include <stdio.h>
long Verdopple(long);
long Plus(long, long);
int main(void) {
  long a = Verdopple(21);
  long b = Plus(40, 2);
  printf("%ld %ld\n", a, b);
  return (a == 42 && b == 42) ? 0 : 1;
}
EOF
if gcc -O0 -o "$TMP/prog" "$TMP/ruf.c" "$TMP/lib.o" >"$TMP/ld.log" 2>&1; then
  got="$( ulimit -v 2000000 -c 0; timeout 30 "$TMP/prog" 2>&1 )"
  rc=$?
  if [ "$rc" = "0" ] && [ "$got" = "42 42" ]; then
    echo "PASS gebunden und gelaufen: '$got'"
    PASS=$((PASS+1))
  else
    echo "FAIL Lauf: rc=$rc, Ausgabe '$got' (erwartet '42 42')"
    FAIL=$((FAIL+1))
  fi
else
  echo "FAIL Binden scheitert:"
  grep -viE "RWX|warning" "$TMP/ld.log" | head -3 | sed 's/^/    /'
  FAIL=$((FAIL+1))
fi

echo "-- 4. Gegenseite: interne Marken bleiben drinnen --"
intern="$(nm -g "$TMP/u.o" 2>/dev/null | grep -cE "__lyx|__anon|\.L" || true)"
if [ "$intern" = "0" ]; then
  echo "PASS keine interne Marke exportiert"
  PASS=$((PASS+1))
else
  echo "FAIL $intern interne Marke(n) exportiert:"
  nm -g "$TMP/u.o" | grep -E "__lyx|__anon|\.L" | head -5 | sed 's/^/    /'
  FAIL=$((FAIL+1))
fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" = "0" ] || exit 1
echo "OK: --emit=obj exportiert Funktions- und Methodensymbole (#2146 Stufe A)"
exit 0
