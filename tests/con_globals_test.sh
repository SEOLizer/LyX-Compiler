#!/usr/bin/env bash
# tests/con_globals_test.sh — Modul-Konstanten tragen auf den IR-Backends (#1751).
#
# `con` auf Modulebene wurde in ir_lower nicht in den Namensraum der Globalen
# aufgenommen: dort stand nur eine Pruefung auf NK_VAR_DECL, und eine
# con-Deklaration hat zwar denselben Aufbau (Name via _ssv, Typ in c0, Wert in
# c1), aber die Sorte NK_CON_DECL. Folge: jede Modul-Konstante war 0.
#
# Der x86-Pfad blieb heil, weil er Konstanten frueher faltet — sichtbar wurde
# es erst auf lyxos, und dort auch nur mittelbar: bin/bsys.lyx legt seine
# Feld-Offsets als `con B_OFF_NR/A0/A1/A2/A3` an. Waren alle 0, landete jeder
# poke64 auf blk+0, die Syscall-Nummer wurde von den Argumenten ueberschrieben,
# und LBF-Programme gaben wortlos nichts aus (lyx-os, Commit 976691b).
#
# Geprueft wird deshalb AUSGEFUEHRT, nicht uebersetzt: lyxos-Code emittieren,
# per lbf_run (mmap RWX) starten, Rueckgabewert als Exit-Code lesen. Ein reiner
# Uebersetzungstest waere gruen gewesen — der Fehler lag im erzeugten Code.
# Vor dem Fix lieferte jeder dieser Faelle 0.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

run() { # name, source, expected-exit
  printf "%s" "$2" > "$TMP/c.lyx"
  LYX_STD_PATH="$ROOT/std" "$LYXC" --target=lyxos "$TMP/c.lyx" -o "$TMP/c.lyxnative" >/dev/null 2>&1
  printf 'import src.tools.lbf.loader;\nfn main(): int64 { lbf_run("%s/c.lyxnative"c); return 111; }' "$TMP" > "$TMP/r.lyx"
  LYX_STD_PATH="$ROOT/std" "$LYXC" "$TMP/r.lyx" -o "$TMP/r" >/dev/null 2>&1
  timeout 5 "$TMP/r" >/dev/null 2>&1; local rc=$?
  if [ "$rc" -eq "$3" ]; then echo "PASS $1 (=$rc)"; PASS=$((PASS+1));
  else echo "FAIL $1: exit=$rc erwartet $3"; FAIL=$((FAIL+1)); fi
}

run "C_init"     'con K: int64 := 7; fn main(): int64 { return K; }' 7
run "C_ausdruck" 'con A: int64 := 6; fn main(): int64 { return A * 7; }' 42
run "C_zwei"     'con A: int64 := 3; con B: int64 := 4; fn main(): int64 { return A * B; }' 12
run "C_neben_var" 'con K: int64 := 5; var g: int64 := 2; fn main(): int64 { g := g + K; return g; }' 7
run "C_in_schleife" 'con S: int64 := 2; fn main(): int64 { var i: int64 := 0; var a: int64 := 0; while i < 3 { a := a + S; i := i + 1; } return a; }' 6
# Das Muster aus bsys.lyx (mehrere Offset-Konstanten nebeneinander) deckt
# C_zwei ab: zwei verschiedene con muessen beide ihren Wert tragen, sonst
# faellt das Produkt auf 0. Der Aufruf MIT alloc/poke laesst sich hier nicht
# ausfuehren -- dieselbe Zeile mit Literalen statt con bricht im Pruefstand
# ebenso weg (lbf_run kehrt zurueck, exit=111), weil alloc ausserhalb von
# LyxOS keinen Speicher liefert. Der Pruefstand traegt skalare Rechnung und
# Globale, nicht mehr; das ist bei tests/lyxos_wp3_globals_test.sh genauso.
# Reihenfolge: con NACH der Nutzung deklariert.
run "C_spaet"    'fn main(): int64 { return L; } con L: int64 := 9;' 9

# --- arm64: derselbe Fehler, anderes Backend (#1751) --------------------
# Die Registrierung sitzt in ir_lower und gilt fuer ALLE IR-Backends. Ohne
# eine zweite Messung waere das eine Behauptung: gemessen mit dem Seed von
# vor dem Fix lieferte `con K := 7` auch unter qemu-aarch64 eine 0.
QEMU=""
command -v qemu-aarch64-static >/dev/null 2>&1 && QEMU=qemu-aarch64-static
command -v qemu-aarch64 >/dev/null 2>&1 && [ -z "$QEMU" ] && QEMU=qemu-aarch64
if [ -z "$QEMU" ]; then
  echo "SKIP arm64: qemu-aarch64 nicht vorhanden — ohne Laufzeit misst das nichts"
else
  runarm() {  # name, source, expected-exit
    printf "%s" "$2" > "$TMP/a.lyx"
    if ! "$LYXC" --std-path="$ROOT" "$TMP/a.lyx" --target=arm64 -o "$TMP/a" >"$TMP/a.log" 2>&1; then
      echo "FAIL $1: uebersetzt nicht"; FAIL=$((FAIL+1)); return
    fi
    timeout 10 "$QEMU" "$TMP/a" >/dev/null 2>&1; local rc=$?
    if [ "$rc" -eq "$3" ]; then echo "PASS $1 (=$rc)"; PASS=$((PASS+1));
    else echo "FAIL $1: exit=$rc erwartet $3"; FAIL=$((FAIL+1)); fi
  }
  runarm "A_init"     'con K: int64 := 7; fn main(): int64 { return K; }' 7
  runarm "A_ausdruck" 'con A: int64 := 6; fn main(): int64 { return A * 7; }' 42
  runarm "A_zwei"     'con A: int64 := 3; con B: int64 := 4; fn main(): int64 { return A * B; }' 12
fi

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
