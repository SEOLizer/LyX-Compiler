#!/usr/bin/env bash
# tests/ir_match_test.sh — match und switch auf dem IR-Weg (#1825).
#
# `match` waehlte auf jedem Ziel, das ueber die IR geht (lyxos, arm64, riscv,
# Cortex-M), KEINEN Zweig — auch nicht den Auffangfall `case _`. Das Programm
# lief durch und gab aus dem match nichts aus. Still, ohne Meldung beim
# Uebersetzen. Auf x86 war es richtig: der Produktiv-Codegen erzeugt dort
# direkt aus dem AST und benutzt ir_lower nicht.
#
# Zwei Ursachen, beide in src/ir_lower.lyx:
#   1. lowerMatch war eine Huelle. Die Schritte standen als Kommentare da
#      ("Emit: if matched goto nextCaseLbl", "Emit: body") — es wurde weder
#      verglichen noch gesprungen, und die Rumpfe wurden nicht einmal
#      gelowert. lowerPatternMatch gab ein nie beschriebenes Temp zurueck.
#   2. `match` als ANWEISUNG erreichte lowerStmt gar nicht: die Knotenart
#      fehlte in der Kette, und lowerStmt hat keinen Auffangzweig.
#
# Beim Beheben fiel lowerSwitch daneben auf — dort war es nicht unvollstaendig,
# sondern falsch herum: der Vergleich fehlte, der Fallrumpf wurde aber
# UNBEDINGT gelowert und der Standardfall danach ebenfalls. Ein `switch` lief
# also ALLE Zweige nacheinander durch.
#
# Geprueft wird AUSGEFUEHRT. Der Rueckgabewert benennt den gewaehlten Zweig —
# ein Test, der nur die Uebersetzung prueft, waere vorher gruen gewesen: es gab
# ja keine Meldung.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ulimit -c 0 2>/dev/null   # Kernabzuege kosten mehr Zeit als der Zeitdeckel erlaubt

# lyxos: Abbild bauen und ueber den lokalen Lader ausfuehren. Nur Ganzzahlen —
# allokierende Builtins gehen so nicht, weil LyxOS Syscall-Ergebnisse in rdx
# liefert und Linux in rax.
lyxos() {  # name, quelltext, erwarteter Rueckgabewert
  printf '%s' "$2" > "$TMP/c.lyx"
  if ! LYX_STD_PATH="$ROOT/std" timeout 200 "$LYXC" --target=lyxos "$TMP/c.lyx" -o "$TMP/c.lyxnative" >"$TMP/c.log" 2>&1; then
    echo "FAIL lyxos/$1: uebersetzt nicht: $(grep -im1 error "$TMP/c.log")"; FAIL=$((FAIL+1)); return
  fi
  printf 'import src.tools.lbf.loader;\nfn main(): int64 { lbf_run("%s/c.lyxnative"c); return 111; }' "$TMP" > "$TMP/r.lyx"
  LYX_STD_PATH="$ROOT/std" timeout 200 "$LYXC" "$TMP/r.lyx" -o "$TMP/r" >/dev/null 2>&1
  timeout 10 "$TMP/r" >/dev/null 2>&1; local rc=$?
  if [ "$rc" -eq "$3" ]; then echo "PASS lyxos/$1 (=$rc)"; PASS=$((PASS+1));
  else echo "FAIL lyxos/$1: exit=$rc erwartet $3"; FAIL=$((FAIL+1)); fi
}

# Dasselbe Programm auf einem zweiten und dritten IR-Ziel: der Defekt sass vor
# der Backend-Wahl, ein Nachweis auf nur einem waere zu wenig (#1786, #1787,
# #1798 waren dreimal als "lyxos-Bug" gemeldet und lagen im gemeinsamen Weg).
ziel() {  # name, ziel, qemu, quelltext, erwarteter Rueckgabewert
  local q=""
  command -v "$3-static" >/dev/null 2>&1 && q="$3-static"
  [ -z "$q" ] && command -v "$3" >/dev/null 2>&1 && q="$3"
  if [ -z "$q" ]; then echo "SKIP $2/$1: $3 fehlt — ohne Laufzeit misst das nichts"; return; fi
  printf '%s' "$4" > "$TMP/t.lyx"
  if ! timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/t.lyx" --target="$2" -o "$TMP/t" >"$TMP/t.log" 2>&1; then
    echo "FAIL $2/$1: uebersetzt nicht: $(grep -im1 error "$TMP/t.log")"; FAIL=$((FAIL+1)); return
  fi
  timeout 20 "$q" "$TMP/t" >/dev/null 2>&1; local rc=$?
  if [ "$rc" -eq "$5" ]; then echo "PASS $2/$1 (=$rc)"; PASS=$((PASS+1));
  else echo "FAIL $2/$1: exit=$rc erwartet $5"; FAIL=$((FAIL+1)); fi
}

alle() {  # name, quelltext, erwarteter Rueckgabewert
  lyxos "$1" "$2" "$3"
  ziel "$1" arm64 qemu-aarch64 "$2" "$3"
  ziel "$1" riscv qemu-riscv64 "$2" "$3"
}

# --- match: der zutreffende Fall wird gewaehlt ---------------------------
alle "zweiter_fall_trifft" \
  'fn main(): int64 { var k: int64 := 2; match (k) { case 1 => { return 1; } case 2 => { return 2; } case _ => { return 9; } } return 0; }' 2
alle "erster_fall_trifft" \
  'fn main(): int64 { var k: int64 := 1; match (k) { case 1 => { return 1; } case 2 => { return 2; } case _ => { return 9; } } return 0; }' 1
# Der Auffangfall war der schwerste Teil des Befunds: auch er lief nicht.
alle "auffangfall_trifft" \
  'fn main(): int64 { var k: int64 := 7; match (k) { case 1 => { return 1; } case 2 => { return 2; } case _ => { return 9; } } return 0; }' 9
# Trifft nichts, muss das Programm normal weiterlaufen — nicht abstuerzen und
# nicht in einen fremden Zweig fallen.
alle "kein_fall_trifft_laeuft_weiter" \
  'fn main(): int64 { var k: int64 := 7; match (k) { case 1 => { return 1; } case 2 => { return 2; } } return 5; }' 5
# Bereichsmuster und Oder-Muster gehen denselben Weg.
alle "bereichsmuster" \
  'fn main(): int64 { var k: int64 := 4; match (k) { case 1 => { return 1; } case 2..6 => { return 6; } case _ => { return 9; } } return 0; }' 6
alle "bereich_unterhalb_trifft_nicht" \
  'fn main(): int64 { var k: int64 := 1; match (k) { case 2..6 => { return 6; } case _ => { return 9; } } return 0; }' 9

# --- switch: genau EIN Zweig, nicht alle ---------------------------------
# Der Rueckgabewert zaehlt mit, wie oft ein Rumpf gelaufen ist: vorher liefen
# alle drei, die Summe war also 111 statt 10.
alle "switch_waehlt_genau_einen" \
  'fn main(): int64 { var s: int64 := 3; var n: int64 := 0; switch (s) { case 1: { n := n + 1; break; } case 3: { n := n + 10; break; } case 4: { n := n + 100; break; } } return n; }' 10
alle "switch_standardfall" \
  'fn main(): int64 { var s: int64 := 8; var n: int64 := 0; switch (s) { case 1: { n := n + 1; break; } default: { n := n + 7; break; } } return n; }' 7
# `break` im switch beendet den switch, nicht eine umgebende Schleife: die
# Schleife muss alle drei Durchlaeufe machen.
alle "break_beendet_nur_den_switch" \
  'fn main(): int64 { var i: int64 := 0; var n: int64 := 0; while (i < 3) { switch (i) { case 1: { n := n + 10; break; } default: { break; } } n := n + 1; i := i + 1; } return n; }' 13

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
