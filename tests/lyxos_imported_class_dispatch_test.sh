#!/usr/bin/env bash
# tests/lyxos_imported_class_dispatch_test.sh — Methoden-Dispatch für IMPORTIERTE Klassen
# (--target=lyxos). Bug: eine Methode einer importierten Klasse (Panel in anderem Modul)
# kehrte sofort zurück statt ihren Body auszuführen — TForm.Run() (vui) returnte sofort,
# kein Fenster. Ursache: (a) _findTypeDecl scannt nur das aktuelle Modul → importierte
# Klasse unauflösbar am Call-Site → kein Dispatch; (b) Methoden importierter Klassen waren
# im transitiven Import-Pre-Pass nicht registriert → _findFuncByName(-1) wenn der Call VOR
# dem Import gelowert wird. Fix: _baseTypeNode liefert den Klassennamen auch bei importierten
# Klassen → statische Mangle "Class_method"; Pre-Pass registriert importierte Methoden mangled.
# Native via lbf_run (Klassen-Methode liefert Konstante → Exit-Code).

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

LYX_STD_PATH="$ROOT/std" "$LYXC" --target=lyxos "$ROOT/_impapp_test.lyx" -o "$TMP/app.lyxnative" >/dev/null 2>&1
printf 'import src.tools.lbf.loader;\nfn main(): int64 { lbf_run("%s/app.lyxnative"c); return 111; }' "$TMP" > "$TMP/r.lyx"
LYX_STD_PATH="$ROOT/std" "$LYXC" "$TMP/r.lyx" -o "$TMP/r" >/dev/null 2>&1
timeout 5 "$TMP/r" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 42 ]; then echo "PASS imported_method_dispatch (=42)"; PASS=$((PASS+1));
else echo "FAIL imported_method_dispatch: exit=$rc erwartet 42 (Methode importierter Klasse nicht korrekt dispatched)"; FAIL=$((FAIL+1)); fi

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
