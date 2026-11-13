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
#    cg_helferName einen Namen haben. Sonst steht im geschnittenen Abbild
#    (#2146 Stufe C2b) eine Relokation gegen ein Symbol, das der Binder nicht
#    kennt -- oder der Lauf bricht erst beim Uebersetzen einer fremden Unit ab.
OHNE=""
for h in $(grep -o 'cg_helferRel32([A-Za-z0-9_]*, CG_H_[A-Z0-9_]*)' "$SRC" | sed 's/.*, //; s/)//' | sort -u); do
  grep -q "hOff == $h)" "$SRC" || OHNE="$OHNE $h"
done
if [ -z "$OHNE" ]; then
  pr ok "jeder benutzte Helfer hat in cg_helferName einen Namen"
else
  pr no "Helfer ohne Namen in cg_helferName:$OHNE"
fi

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "OK: Helferreferenzen gehen durch eine Stelle (#2146 Stufe C, Vorarbeit)"
