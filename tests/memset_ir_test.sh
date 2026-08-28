#!/usr/bin/env bash
# tests/memset_ir_test.sh — MemSet auf dem gemeinsamen IR-Weg (#1842).
#
# `MemSet(p, 65, 16)` brach die Uebersetzung ab:
#   lyxc: --target=lyxos: unbekannter Builtin/Funktion: MemSet
# Gemeldet war das als lyxos-Luecke. Nachgemessen brechen arm64 und riscv mit
# derselben Meldung ab — es ist der gemeinsame IR-Weg, wie schon bei #1786,
# #1787 und #1798. `--target=linux` uebersetzt dieselbe Quelle: der x86-Codegen
# erzeugt direkt aus dem AST und geht gar nicht durch ir_lower.
#
# URSACHE: eine unvollstaendige Aufzaehlung. `src/ir_lower.lyx` kannte
# memcpy/MemCopy (ID 210), MemSet daneben nicht — und die drei Backends, die
# 210 umsetzen, hatten entsprechend kein Gegenstueck.
#
# Gemessen wird die WIRKUNG, nicht die Uebersetzbarkeit: eine ID, die im
# Emitter nur "behandelt" ist, aber nichts schreibt, kaeme sonst gruen durch
# (#1789: IRO_DIV stand in der Liste, der Rumpf war `MOVI T0, 0`).
#
# KEIN lyxos hier: der lokale LBF-Lader fuehrt das Abbild unter LINUX aus und
# liefert Syscall-Ergebnisse in rax statt rdx — `alloc` bekaeme eine
# Muelladresse. Dieselbe Grenze wie in #1832/#1835. lyxos wird stattdessen am
# ERZEUGNIS geprueft (Bytemuster des `rep stosb`), arm64 und riscv laufen.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ulimit -c 0 2>/dev/null

fall() {  # name, rumpf, erwarteter Rueckgabewert
  printf 'import std.alloc;\n%s\n' "$2" > "$TMP/s.lyx"
  for ziel in linux arm64 riscv; do
    local q=""
    if [ "$ziel" = "arm64" ]; then
      command -v qemu-aarch64-static >/dev/null 2>&1 && q=qemu-aarch64-static
      [ -z "$q" ] && command -v qemu-aarch64 >/dev/null 2>&1 && q=qemu-aarch64
      if [ -z "$q" ]; then echo "SKIP arm64/$1: qemu fehlt — ohne Laufzeit misst das nichts"; continue; fi
    elif [ "$ziel" = "riscv" ]; then
      command -v qemu-riscv64-static >/dev/null 2>&1 && q=qemu-riscv64-static
      [ -z "$q" ] && command -v qemu-riscv64 >/dev/null 2>&1 && q=qemu-riscv64
      if [ -z "$q" ]; then echo "SKIP riscv/$1: qemu fehlt — ohne Laufzeit misst das nichts"; continue; fi
    fi
    if ! timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/s.lyx" --target="$ziel" -o "$TMP/s.out" >"$TMP/s.log" 2>&1; then
      echo "FAIL $ziel/$1: uebersetzt nicht: $(grep -im1 'error\|unbekannt' "$TMP/s.log")"; FAIL=$((FAIL+1)); continue
    fi
    timeout 30 $q "$TMP/s.out" >/dev/null 2>&1; local rc=$?
    if [ "$rc" -eq "$3" ]; then echo "PASS $ziel/$1 (=$rc)"; PASS=$((PASS+1));
    else echo "FAIL $ziel/$1: exit=$rc erwartet $3"; FAIL=$((FAIL+1)); fi
  done
}

# Das erste Byte — der Fall, der ueberhaupt nicht uebersetzte.
fall "memset_erstes_byte" \
  'fn main(): int64 { var p: int64 := alloc(64); MemSet(p, 65, 16); return peek8(p); }' 65

# Das LETZTE geschriebene Byte. Ein Emitter, der die Laenge ignoriert und nur
# ein Byte setzt, kaeme durch den Fall darueber gruen.
fall "memset_letztes_byte" \
  'fn main(): int64 { var p: int64 := alloc(64); MemSet(p, 65, 16); return peek8(p + 15); }' 65

# Die Grenze dahinter muss UNBERUEHRT bleiben — sonst waere `rep stosb` mit
# falscher Zaehlung (oder eine Schleife ohne Abbruch) nicht zu erkennen.
fall "memset_schreibt_nicht_zu_weit" \
  'fn main(): int64 { var p: int64 := alloc(64); MemSet(p, 0, 64); MemSet(p, 65, 16); return peek8(p + 16); }' 0

# Laenge 0 darf gar nichts schreiben.
fall "memset_laenge_null" \
  'fn main(): int64 { var p: int64 := alloc(64); MemSet(p, 0, 64); MemSet(p, 65, 0); return peek8(p); }' 0

# Nur das niederwertige Byte des Wertes zaehlt (C-Semantik von memset).
fall "memset_nur_unterstes_byte" \
  'fn main(): int64 { var p: int64 := alloc(64); MemSet(p, 321, 8); return peek8(p); }' 65

# Rueckgabe ist der Zielzeiger, wie bei memcpy daneben.
fall "memset_gibt_zeiger_zurueck" \
  'fn main(): int64 { var p: int64 := alloc(64); var r: int64 := MemSet(p, 65, 8); if (r == p) { return 7; } return 8; }' 7

# Gegenprobe: MemCopy muss weiterhin gehen — die beiden teilen sich die
# argBase-Konvention, und ein Fehler in der Slot-Zaehlung traefe beide.
fall "memcopy_unveraendert" \
  'fn main(): int64 { var p: int64 := alloc(64); MemSet(p, 65, 16); MemCopy(p + 16, p, 16); return peek8(p + 31); }' 65

# lyxos: nicht ausfuehrbar (LBF-Lader, rax/rdx), also am ERZEUGNIS gemessen.
# F3 AA ist `rep stosb` — steht das Muster nicht im Abbild, hat der Emitter die
# ID zwar angenommen, aber nichts geschrieben.
printf 'import std.alloc;\nfn main(): int64 { var p: int64 := alloc(64); MemSet(p, 65, 16); return peek8(p); }\n' > "$TMP/l.lyx"
if timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/l.lyx" --target=lyxos -o "$TMP/l.lbf" >"$TMP/l.log" 2>&1; then
  if xxd -p "$TMP/l.lbf" | tr -d '\n' | grep -q 'f3aa'; then
    echo "PASS lyxos/erzeugnis_enthaelt_rep_stosb"; PASS=$((PASS+1))
  else
    echo "FAIL lyxos/erzeugnis_enthaelt_rep_stosb: F3 AA fehlt im Abbild"; FAIL=$((FAIL+1))
  fi
else
  echo "FAIL lyxos/uebersetzt: $(grep -im1 'error\|unbekannt' "$TMP/l.log")"; FAIL=$((FAIL+1))
fi

echo "== memset_ir_test: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
