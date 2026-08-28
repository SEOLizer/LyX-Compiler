#!/usr/bin/env bash
# tests/lyxos_imported_class_dispatch_test.sh — Methoden-Dispatch für IMPORTIERTE Klassen
# (--target=lyxos). Bug: eine Methode einer importierten Klasse (Panel in anderem Modul)
# kehrte sofort zurück statt ihren Body auszuführen — TForm.Run() (vui) returnte sofort,
# kein Fenster. Ursache: (a) _findTypeDecl scannt nur das aktuelle Modul → importierte
# Klasse unauflösbar am Call-Site → kein Dispatch; (b) Methoden importierter Klassen waren
# im transitiven Import-Pre-Pass nicht registriert → _findFuncByName(-1) wenn der Call VOR
# dem Import gelowert wird. Fix: _baseTypeNode liefert den Klassennamen auch bei importierten
# Klassen → statische Mangle "Class_method"; Pre-Pass registriert importierte Methoden mangled.
#
# #1848: Bis 1.1.12H fuhr dieser Test das lyxos-Abbild durch den lokalen
# LBF-Lader. Das ging nur zufaellig gut: der Lader fuehrt unter LINUX aus, wo
# das Ergebnis eines Syscalls in rax steht, waehrend das Abbild rdx liest
# (#1832) — der Zeiger aus `new` war dort IMMER Muell. Angefasst hat ihn nur
# niemand, weil `Answer()` kein Feld liest. Seit `new` den Speicher nullt,
# schreibt schon die Zuteilung dorthin, und der Lader faultet (139).
#
# Gemessen wird deshalb, wo es ehrlich geht: die AUSFUEHRUNG auf arm64 und
# riscv, die denselben Weg durch ir_lower gehen, und auf lyxos das ERZEUGNIS.
# Das ist dieselbe Aufteilung wie in #1786/#1787/#1798 — und sie misst mehr
# als vorher, nicht weniger: zwei laufende Ziele statt eines geliehenen.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -f "$ROOT/_implib_test.lyx" "$ROOT/_impapp_test.lyx"; rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

# Klasse in einem separaten Modul (cwd-relativ auflösbar von ROOT).
cat > "$ROOT/_implib_test.lyx" <<'LYX'
pub type Panel = class {
  a: int64; b: int64; c: int64; d: int64;
  fn Id(): int64 { return self.a; }
  fn Answer(): int64 { return 42; }
};
LYX
cat > "$ROOT/_impapp_test.lyx" <<'LYX'
import _implib_test;
fn main(): int64 { var w: Panel := new Panel(); return w.Answer(); }
LYX

# Ausfuehrung auf den IR-Zielen, die laufen.
for ziel in arm64 riscv; do
  q=""
  if [ "$ziel" = "arm64" ]; then
    command -v qemu-aarch64-static >/dev/null 2>&1 && q=qemu-aarch64-static
    [ -z "$q" ] && command -v qemu-aarch64 >/dev/null 2>&1 && q=qemu-aarch64
  else
    command -v qemu-riscv64-static >/dev/null 2>&1 && q=qemu-riscv64-static
    [ -z "$q" ] && command -v qemu-riscv64 >/dev/null 2>&1 && q=qemu-riscv64
  fi
  if [ -z "$q" ]; then echo "SKIP $ziel/imported_method_dispatch: qemu fehlt — ohne Laufzeit misst das nichts"; continue; fi
  if ! LYX_STD_PATH="$ROOT/std" timeout 200 "$LYXC" --target="$ziel" "$ROOT/_impapp_test.lyx" -o "$TMP/app.$ziel" >"$TMP/c.log" 2>&1; then
    echo "FAIL $ziel/imported_method_dispatch: uebersetzt nicht: $(grep -im1 'error\|unbekannt' "$TMP/c.log")"; FAIL=$((FAIL+1)); continue
  fi
  timeout 30 $q "$TMP/app.$ziel" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 42 ]; then echo "PASS $ziel/imported_method_dispatch (=42)"; PASS=$((PASS+1));
  else echo "FAIL $ziel/imported_method_dispatch: exit=$rc erwartet 42 (Methode importierter Klasse nicht korrekt dispatched)"; FAIL=$((FAIL+1)); fi
done

# lyxos: am Erzeugnis. Der Aufruf muss als CALL im Abbild stehen — ein
# Dispatch, der ins Leere geht, erzeugt hier gar keinen (das war der
# urspruengliche Defekt: _findFuncByName lieferte -1).
if LYX_STD_PATH="$ROOT/std" timeout 200 "$LYXC" --target=lyxos "$ROOT/_impapp_test.lyx" -o "$TMP/app.lyxnative" >"$TMP/l.log" 2>&1 && [ -s "$TMP/app.lyxnative" ]; then
  # Geprueft wird der RUMPF der importierten Methode, nicht bloss "ein CALL":
  # `return 42` wird zu MOV rax, imm64 (48 B8 2A 00...). War die Methode nicht
  # aufloesbar, wurde ihr Rumpf gar nicht erst emittiert — genau der Defekt,
  # den dieser Test bewacht. Ein Zaehler auf E8 haette auch der leere Fall
  # erfuellt, weil `main` ohnehin ruft (#1789: Vorhandensein ist keine
  # Aussage ueber Richtigkeit).
  if xxd -p "$TMP/app.lyxnative" | tr -d '\n' | grep -q '48b82a00000000000000'; then
    echo "PASS lyxos/erzeugnis_enthaelt_methodenrumpf"; PASS=$((PASS+1))
  else
    echo "FAIL lyxos/erzeugnis_enthaelt_methodenrumpf: MOV rax,42 fehlt — Rumpf nicht emittiert"; FAIL=$((FAIL+1))
  fi
else
  echo "FAIL lyxos/uebersetzt: $(grep -im1 'error\|unbekannt' "$TMP/l.log")"; FAIL=$((FAIL+1))
fi

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
