#!/usr/bin/env bash
# tests/ir_if_kette_test.sh — if/else-if-Ketten und Literale auf dem IR-Weg (#1757).
#
# Zwei Ursachen, beide in ir_lower, beide nur auf den IR-Backends sichtbar
# (lyxos, arm64, riscv, Cortex-M). Der x86-Produktiv-Codegen erzeugt direkt aus
# dem AST und benutzt ir_lower nicht — deshalb war dasselbe Programm als ELF
# richtig und als LBF falsch.
#
#   1. `else if` haengt im Parser als NK_IF an c2 (parser.lyx _parseIf), nicht
#      als Block. lowerIf rief darauf unbedingt lowerBlock — das lief ueber
#      Bedingung, Dann- und Sonst-Zweig, als waeren es Anweisungen. Wirkung:
#      die ganze Kette wurde uebersprungen, auch der zutreffende Zweig.
#
#   2. NK_LIT_BOOL, NK_LIT_CHAR und NK_LIT_NULL holten ihren Wert und
#      emittierten dann NICHTS. Der Aufrufer bekam einen frisch belegten
#      Temp-Slot mit zufaelligem Inhalt zurueck. `false` sprang deshalb in den
#      Dann-Zweig; `true` sah nur richtig aus, weil Muell meist ungleich 0 ist.
#
# Geprueft wird AUSGEFUEHRT (lyxos emittieren → lbf_run mmap RWX → Rueckgabe als
# Exit-Code) und zusaetzlich auf arm64 via qemu: der Fehler sass vor der
# Backend-Wahl, ein Nachweis auf nur einem Backend waere zu wenig.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

lyxos() {  # name, quelle, erwarteter Rueckgabewert
  printf "%s" "$2" > "$TMP/c.lyx"
  LYX_STD_PATH="$ROOT/std" "$LYXC" --target=lyxos "$TMP/c.lyx" -o "$TMP/c.lyxnative" >/dev/null 2>&1
  printf 'import src.tools.lbf.loader;\nfn main(): int64 { lbf_run("%s/c.lyxnative"c); return 111; }' "$TMP" > "$TMP/r.lyx"
  LYX_STD_PATH="$ROOT/std" "$LYXC" "$TMP/r.lyx" -o "$TMP/r" >/dev/null 2>&1
  timeout 5 "$TMP/r" >/dev/null 2>&1; local rc=$?
  if [ "$rc" -eq "$3" ]; then echo "PASS $1 (=$rc)"; PASS=$((PASS+1));
  else echo "FAIL $1: exit=$rc erwartet $3"; FAIL=$((FAIL+1)); fi
}

# --- Die fuenf Faelle aus dem Issue -------------------------------------
lyxos "F1_if_else" \
  'fn main(): int64 { var a: bool := false; if a { return 1; } else { return 3; } }' 3
lyxos "F2_else_if" \
  'fn main(): int64 { var a: bool := false; var b: bool := false; if a { return 1; } else if b { return 2; } else { return 3; } }' 3
lyxos "F3_zwei_else_if" \
  'fn main(): int64 { var a: bool := false; var b: bool := false; var c: bool := false; if a { return 1; } else if b { return 2; } else if c { return 3; } else { return 4; } }' 4
lyxos "F4_int_vergleiche" \
  'fn main(): int64 { var i: int64 := 9; if i == 1 { return 1; } else if i == 2 { return 2; } else if i == 3 { return 3; } else { return 4; } }' 4
lyxos "F5_erster_trifft" \
  'fn main(): int64 { var t: bool := true; var b: bool := false; if t { return 1; } else if b { return 2; } else { return 3; } }' 1

# --- Jeder Zweig der Kette wird auch wirklich erreicht -------------------
lyxos "K_zweiter_trifft" \
  'fn main(): int64 { var i: int64 := 2; if i == 1 { return 1; } else if i == 2 { return 2; } else { return 3; } }' 2
lyxos "K_dritter_trifft" \
  'fn main(): int64 { var i: int64 := 3; if i == 1 { return 1; } else if i == 2 { return 2; } else if i == 3 { return 3; } else { return 4; } }' 3
lyxos "K_verschachtelt" \
  'fn main(): int64 { var i: int64 := 2; var j: int64 := 5; if i == 1 { return 1; } else if i == 2 { if j == 5 { return 7; } else { return 8; } } else { return 3; } }' 7

# --- Die Literale einzeln ------------------------------------------------
lyxos "L_bool_false" 'fn main(): int64 { var a: bool := false; if a { return 1; } return 3; }' 3
lyxos "L_bool_true"  'fn main(): int64 { var a: bool := true;  if a { return 1; } return 3; }' 1
lyxos "L_bool_wert"  'fn main(): int64 { var a: bool := false; if a { return 1; } var b: bool := true; if b { return 2; } return 3; }' 2
lyxos "L_char"       "fn main(): int64 { var c: int64 := 'A' as int64; if c == 65 { return 1; } return 3; }" 1

# --- arm64: derselbe Fehler sass vor der Backend-Wahl -------------------
QEMU=""
command -v qemu-aarch64-static >/dev/null 2>&1 && QEMU=qemu-aarch64-static
command -v qemu-aarch64 >/dev/null 2>&1 && [ -z "$QEMU" ] && QEMU=qemu-aarch64
if [ -z "$QEMU" ]; then
  echo "SKIP arm64: qemu-aarch64 nicht vorhanden — ohne Laufzeit misst das nichts"
else
  arm() {  # name, quelle, erwarteter Rueckgabewert
    printf "%s" "$2" > "$TMP/a.lyx"
    if ! "$LYXC" --std-path="$ROOT" "$TMP/a.lyx" --target=arm64 -o "$TMP/a" >"$TMP/a.log" 2>&1; then
      echo "FAIL $1: uebersetzt nicht"; FAIL=$((FAIL+1)); return
    fi
    timeout 10 "$QEMU" "$TMP/a" >/dev/null 2>&1; local rc=$?
    if [ "$rc" -eq "$3" ]; then echo "PASS $1 (=$rc)"; PASS=$((PASS+1));
    else echo "FAIL $1: exit=$rc erwartet $3"; FAIL=$((FAIL+1)); fi
  }
  arm "A_else_if" \
    'fn main(): int64 { var i: int64 := 9; if i == 1 { return 1; } else if i == 2 { return 2; } else { return 3; } }' 3
  arm "A_bool_false" \
    'fn main(): int64 { var a: bool := false; if a { return 1; } return 3; }' 3
fi

echo "----"
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
