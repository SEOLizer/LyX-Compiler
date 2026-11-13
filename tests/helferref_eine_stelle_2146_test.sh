#!/bin/bash
# #2146 Stufe C, Vorarbeit: jede Referenz auf den Helferblock geht durch
# cg_helferRel32 — schreiben UND vermerken an einer Stelle.
#
# Warum ein Waechter: das Abbild einer einzelnen Unit (Art 9) enthaelt den
# Helferblock NICHT (`_lyx_bumpalloc` fuehrt einen globalen Zeiger, eine zweite
# Kopie waere ein zweiter Haldenzustand). Der Binder muss jede Helferreferenz
# darin verschieben und kann nur verschieben, was aufgeschrieben ist. Bis
# 1.2.38A schrieben 65 Stellen den rel32 selbst; eine davon beim Vermerken zu
# vergessen gibt kein Fehlersignal, sondern ein Abbild, das an einer Stelle in
# den Helferblock des ERZEUGERS zeigt.
cd "$(dirname "$0")/.." || exit 1
PASS=0; FAIL=0
pr() { if [ "$1" = ok ]; then PASS=$((PASS+1)); echo "PASS $2"; else FAIL=$((FAIL+1)); echo "FAIL $2"; fi; }

SRC=src/codegen_x86.lyx

# 1) Keine rohe Helferreferenz mehr: weder poke32 noch cg_e32 rechnen selbst.
ROH=$(grep -n 'poke32(self\.code + [A-Za-z0-9_]*, CG_H_[A-Z0-9_]* -' "$SRC"; \
      grep -n 'cg_e32(CG_H_[A-Z0-9_]* -' "$SRC"; \
      grep -n 'rel32: int64 := CG_H_[A-Z0-9_]* -' "$SRC")
if [ -z "$ROH" ]; then pr ok "keine rohe Helfer-rel32-Rechnung in $SRC"
else pr no "rohe Helfer-rel32-Rechnung in $SRC: $ROH"; fi

# 1b) Auch NICHT roh, wenn der Offset in einer VARIABLEN steckt. Genau daran
#     ist die erste Fassung vorbeigegangen: sechs Stellen hielten den
#     Helferoffset in `hStr`/`hInt` (je nach stdout/stderr), rechneten den
#     rel32 selbst und wurden darum nicht vermerkt. Im Abbild fehlte die
#     Relokation, der gebackene rel32 des Erzeugers blieb stehen, und ein
#     gebundenes std.io sprang mitten in fremden Code -- SIGILL nach
#     korrekter Ausgabe. Gefunden hat das erst ein Lauf gegen die echte
#     stdlib, kein Test.
#
#     Geprueft wird: jede Variable, die einen CG_H_*-Wert zugewiesen bekommt,
#     darf in keiner rel32-Rechnung auftauchen.
HVARS="$(grep -oE 'var [A-Za-z0-9_]+: int64 := CG_H_[A-Z0-9_]+' "$SRC" \
         | awk '{print $2}' | sed 's/:$//' | sort -u)"
HVARS="$HVARS $(grep -oE '^[[:space:]]*[A-Za-z0-9_]+ := CG_H_[A-Z0-9_]+' "$SRC" \
                | awk '{print $1}' | sort -u)"
ROHVAR=""
for v in $HVARS; do
  [ -n "$v" ] || continue
  if grep -qE "poke32\(self\.code \+ [A-Za-z0-9_]+, $v - [A-Za-z0-9_]+ - 4\)" "$SRC" \
     || grep -qE "cg_e32\($v - [A-Za-z0-9_]+ - 4\)" "$SRC"; then
    ROHVAR="$ROHVAR $v"
  fi
done
if [ -z "$ROHVAR" ]; then
  pr ok "keine Variable mit Helferoffset rechnet selbst ($(printf '%s' "$HVARS" | wc -w) geprueft)"
else
  pr no "Helferoffset in Variable, rel32 selbst gerechnet:$ROHVAR"
fi

# 2) Die Funktion gibt es, und sie vermerkt.
if grep -q 'fn cg_helferRel32(pp: int64, hOff: int64)' "$SRC" \
   && grep -A3 'fn cg_helferRel32(pp: int64, hOff: int64)' "$SRC" | grep -q 'CG_PATCH_HELFER'; then
  pr ok "cg_helferRel32 schreibt und vermerkt (CG_PATCH_HELFER)"
else pr no "cg_helferRel32 fehlt oder vermerkt nicht"; fi

# 3) Die Stellen rufen sie wirklich — gezaehlt, nicht vermutet.
N=$(grep -c 'self\.cg_helferRel32(' "$SRC")
if [ "$N" -ge 60 ]; then pr ok "Helferreferenzen durch die Funktion: $N"
else pr no "nur $N Aufrufe von cg_helferRel32 — zu wenige, Stellen rechnen wieder selbst"; fi

# 4) cg_patchAll faellt nicht mehr still auf CG_PATCH_STR durch.
if grep -q 'kind == CG_PATCH_STR' "$SRC" && grep -q 'unbekannte Patch-Art' "$SRC"; then
  pr ok "cg_patchAll nennt CG_PATCH_STR und meldet unbekannte Arten laut"
else pr no "cg_patchAll hat wieder einen Catch-all-Zweig"; fi

# 5) WIRKUNG, nicht Vorhandensein: ein Programm, das die Helfer wirklich
#    braucht, muss die richtigen WERTE liefern. StrLen (SIMD-Helfer), StrSub
#    und die Ausgabehelfer in einem Lauf.
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cat > "$T/h.lyx" <<'LYX'
import std.io;
fn main(): int64 {
  var s: pchar := "Donaudampfschiff";
  PrintInt(StrLen(s)); PrintStrLn("");
  PrintStrLn(StrSub(s, 5, 5));
  PrintInt(StrLen(StrSub(s, 0, 6))); PrintStrLn("");
  return 0;
}
LYX
if ./lyxc --std-path=. "$T/h.lyx" -o "$T/h" > "$T/build.log" 2>&1; then
  AUS=$("$T/h" 2>&1)
  ERW=$'16\ndampf\n6'
  if [ "$AUS" = "$ERW" ]; then pr ok "Helferaufrufe liefern die richtigen Werte (16/dampf/6)"
  else pr no "falsche Werte: $(echo "$AUS" | tr '\n' '|') erwartet $(echo "$ERW" | tr '\n' '|')"; fi
else pr no "Testprogramm uebersetzt nicht: $(tail -3 "$T/build.log")"; fi

# 6) ZWEISEITIG: jeder Helfer, der cg_helferRel32 erreicht, muss in
#    cg_helferTab einen Namen haben. Sonst steht im geschnittenen Abbild
#    (#2146 Stufe C2b) eine Relokation gegen ein Symbol, das der Binder nicht
#    kennt -- oder der Lauf bricht erst beim Uebersetzen einer fremden Unit ab.
#    Gelesen wird die TABELLE (cg_helferTab), aus der beide Richtungen
#    bedient werden: Offset->Name beim Erzeugen, Name->Offset beim Binden.
OHNE=""
for h in $(grep -o 'cg_helferRel32([A-Za-z0-9_]*, CG_H_[A-Z0-9_]*)' "$SRC" | sed 's/.*, //; s/)//' | sort -u); do
  grep -q "poke64(offBox, $h)" "$SRC" || OHNE="$OHNE $h"
done
if [ -z "$OHNE" ]; then
  pr ok "jeder benutzte Helfer steht in cg_helferTab"
else
  pr no "Helfer ohne Eintrag in cg_helferTab:$OHNE"
fi

# 7) Und die Tabelle hat genau EINE Stelle: zwei Aufzaehlungen derselben
#    Helfer waeren die Fehlerklasse, die diesen Waechter ueberhaupt
#    gerechtfertigt hat.
if [ "$(grep -c 'fn cg_helferTab(' "$SRC")" = "1" ] \
   && [ "$(grep -c 'fn cg_helferName(' "$SRC")" = "1" ] \
   && [ "$(grep -c 'fn cg_helferOffset(' "$SRC")" = "1" ]; then
  pr ok "eine Tabelle, zwei Leser (cg_helferName, cg_helferOffset)"
else
  pr no "cg_helferTab/Name/Offset nicht je genau einmal vorhanden"
fi

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "OK: Helferreferenzen gehen durch eine Stelle (#2146 Stufe C, Vorarbeit)"
