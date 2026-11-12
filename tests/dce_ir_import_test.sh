#!/usr/bin/env bash
# tests/dce_ir_import_test.sh — #2451.
#
# Beim Import ueber eine .lyu haengt ir_lower das IR der GANZEN Unit an das
# Modul (#1977), und `emit()` der IR-Backends lief ueber jede Funktion darin.
# Gemessen vor dem Fix (lyxc 1.2.34B, arm64):
#
#   import std.io; PrintLn("x")        -> Erzeugnis 112 048 Byte fuer einen
#                                         Einzeiler
#   import std.fs; return SEEK_END     -> "error: arm64: Builtin-ID 236 wird im
#                                         Linux-Zweig nicht behandelt", obwohl
#                                         keine fs-Funktion gerufen wird
#
# Der zweite Fall ist der schlimmere: eine Luecke im Backend in Code, den
# niemand braucht, machte das ganze Programm unuebersetzbar.
#
# Geprueft wird die WIRKUNG in BEIDE Richtungen, auf BEIDEN IR-Zielen (arm64
# und riscv gehen denselben Weg, deshalb deckt eines allein nichts ab):
#
#   1. Das Benutzte ist vollstaendig da -- am WERT gemessen, nicht am
#      Uebersetzen. Die Summe ist stellenwertig (8 + 800 + 20000 + 7 = 20815),
#      damit eine fehlende Teilsumme nicht von einer anderen verdeckt wird.
#      Enthalten sind die Wege, auf denen eine Funktion erreichbar ist, OHNE
#      dass ihr Name an einer Aufrufstelle steht: ueber einen Funktionszeiger
#      (IRO_FUNC_ADDR) und als virtuelles Override (auf dem IR-Weg eine
#      Vergleichskette ueber die type-id mit direkten Aufrufen).
#   2. Toter Code mit einer Backend-Luecke uebersetzt. `fence_sfence` ist auf
#      arm64 nicht gelowert; in der Unit, aber unerreichbar, darf es nicht
#      stoeren.
#   3. Dieselbe Funktion LEBEND scheitert weiter laut. Ohne diese Haelfte waere
#      der Test auch von einem Compiler erfuellt, der die Luecke verschweigt.
#   4. Der Gewinn ist messbar: das Erzeugnis des Verbrauchers ist kleiner als
#      die Unit, aus der es stammt. Eine Pruefung, die nur "uebersetzt" sagt,
#      waere auch von einem Compiler erfuellt, der weiter alles emittiert.
#
# x86 ist nicht betroffen (eigener Weg direkt vom AST) und dient hier als
# Gegenrechnung fuer den Erwartungswert.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
# #2048: die Emulatoren EINMAL und unter beiden Paketnamen finden
# (qemu-user-static liefert qemu-aarch64-static, qemu-user nennt dasselbe
# Programm qemu-aarch64). Wer selbst sucht, laeuft auf der einen Maschine
# gruen durch, ohne die Wirkung zu messen -- tests/qemu_name_test.sh wacht
# darueber und hat genau das hier gemeldet.
. "$(dirname "$0")/lib/qemu.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()   { echo "PASS $1"; PASS=$((PASS+1)); }
nok()  { echo "FAIL $1"; FAIL=$((FAIL+1)); }
skip() { echo "UEBERSPRUNGEN $1"; }

cp -r "$ROOT/tests/data/dce2451/." "$TMP/"
cd "$TMP" || exit 1

echo "--- #2451: der IR-Import nimmt nur das Benutzte ---"

ERWARTET=20815

# --- Erwartungswert gegenrechnen (x86, nicht betroffen) ----------------------
if (ulimit -v 4000000; "$LYXC" prog.lyx -o p.x86 -I . --std-path="$ROOT") >x.log 2>&1; then
  g="$( (ulimit -v 2000000; ./p.x86) 2>/dev/null | tail -1)"
  if [ "$g" = "$ERWARTET" ]; then
    ok "x86 liefert $ERWARTET (Erwartungswert gegengerechnet)"
  else
    nok "x86 liefert '$g', erwartet $ERWARTET — der Test selbst ist falsch"
  fi
else
  nok "x86 uebersetzt nicht: $(grep -m1 -iE 'error' x.log | cut -c1-90)"
fi

for ziel in arm64 riscv; do
  case "$ziel" in
    arm64) lauf="$QEMU_ARM64" ;;
    riscv) lauf="$QEMU_RISCV64" ;;
  esac
  if [ -z "$lauf" ]; then
    skip "$ziel: qemu fehlt — ohne Laufzeit misst das nichts"
    continue
  fi

  # --- 1 + 2: uebersetzt (trotz toter Backend-Luecke) und liefert den Wert ---
  if (ulimit -v 4000000; "$LYXC" prog.lyx --target="$ziel" -o "p.$ziel" -I . --std-path="$ROOT") >"c.$ziel" 2>&1; then
    g="$( (ulimit -v 2000000; $lauf "./p.$ziel") 2>/dev/null | tail -1)"
    if [ "$g" = "$ERWARTET" ]; then
      ok "$ziel: $ERWARTET — Zeiger-Aufruf und virtuelles Override sind erhalten"
    else
      nok "$ziel: liefert '$g', erwartet $ERWARTET — etwas Benutztes fehlt"
    fi
  else
    nok "$ziel uebersetzt nicht: $(grep -m1 -iE 'error' "c.$ziel" | cut -c1-90)"
    continue
  fi

  # --- 4: der Gewinn ist messbar ------------------------------------------
  # Verglichen werden ZWEI Programme derselben Unit: prog_gross ruft die
  # Funktionen, die in prog tot sind. Faellt Unerreichbares weg, ist prog
  # kleiner. Ein Vergleich gegen die .lyu waere falsch — ein Erzeugnis traegt
  # ELF-Kopf, Startweg und std.io als festen Grundaufwand, den die .lyu nicht
  # hat; genau daran ist diese Pruefung beim ersten Anlauf falsch rot gewesen.
  if (ulimit -v 4000000; "$LYXC" prog_gross.lyx --target="$ziel" -o "g.$ziel" -I . \
        --std-path="$ROOT") >"cg.$ziel" 2>&1; then
    pSz="$(stat -c%s "p.$ziel")"
    gSz="$(stat -c%s "g.$ziel")"
    if [ "$pSz" -lt "$gSz" ]; then
      ok "$ziel: $pSz B gegen $gSz B — die ungerufenen Funktionen fehlen ($((gSz - pSz)) B)"
    else
      nok "$ziel: $pSz B, mit den Aufrufen $gSz B — kein Unterschied, es wird weiter alles emittiert"
    fi
  else
    nok "$ziel: prog_gross uebersetzt nicht: $(grep -m1 -iE 'error' "cg.$ziel" | cut -c1-80)"
  fi
done

# --- 3: dieselbe Luecke LEBEND muss weiter scheitern ------------------------
printf 'import std.io;\nimport dce2451.helfer;\nfn main(): int64 { return LueckeImBackend(); }\n' > lebt.lyx
if (ulimit -v 4000000; "$LYXC" lebt.lyx --target=arm64 -o q -I . --std-path="$ROOT") >lebt.log 2>&1; then
  nok "die Backend-Luecke uebersetzt auch LEBEND — der Schnitt wirft Benutztes weg oder verschweigt die Luecke"
else
  if grep -q "nicht behandelt" lebt.log; then
    ok "lebende Backend-Luecke scheitert weiter laut"
  else
    nok "lebende Luecke scheitert, aber anders: $(grep -m1 -iE 'error' lebt.log | cut -c1-90)"
  fi
fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
