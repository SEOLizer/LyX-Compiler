#!/usr/bin/env bash
# tests/rmdir_2450_test.sh — #2450: rmdir auf den Linux-Zielen des IR-Wegs.
#
# BEFUND. `rmdir` wurde unabhaengig vom Ziel auf die LyxOS-ID 236 gesenkt
# (sys_unlink mit UNLINK_DIR @ 0x0208). Auf arm64 und riscv gibt es diese
# Nummer nicht; der Uebersetzer brach ab — und zwar schon bei
# `import std.fs; return SEEK_END`, weil die Unit den Aufruf mitbringt, auch
# wenn ihn niemand ruft. Elf Zeilen ueber dem fehlenden Fall steht der Block
# aus #2156, der genau diese Frage fuer stat/lstat/readlink/symlink schon
# beantwortet: die generische Linux-ABI hat nur die *at-Formen.
#
# WAS HIER GEMESSEN WIRD: die WIRKUNG, nicht die Meldung. Ein Test, der nur
# prueft, dass die Uebersetzung nicht mehr abbricht, waere auch von einem
# `rmdir`, das gar nichts tut, erfuellt — und genau diese Klasse hat im
# Bestand mehrfach einen Defekt verdeckt (#1827, #1829). Das Programm legt
# deshalb ein Verzeichnis an, entfernt es und fragt DANACH nach, ob es weg
# ist. Der Exit-Code sagt, welche Haelfte nicht gestimmt hat.
#
# Der lyxos-Zweig ist NICHT Teil dieses Tests. Dort traegt `rmdir` weiter die
# ID 236, und die Nummer 520 gibt es im Kernel nicht (#2011) — der Aufruf
# scheitert laut. Diese Ablehnung als Nachweis zu nehmen hiesse, einen Test
# zu bauen, der rot wird, sobald die Luecke zugeht.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
. "$(dirname "$0")/lib/qemu.sh"   # #2048: beide Paketnamen
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# Exit-Codes des Pruefprogramms:
#   10  das Verzeichnis liess sich nicht anlegen (Versuchsaufbau kaputt)
#   11  rmdir meldete einen Fehler
#   12  rmdir meldete Erfolg, das Verzeichnis ist aber noch da
#   42  alles wie erwartet
mach_quelle() { # $1 = Verzeichnispfad
  cat > "$TMP/p.lyx" <<LYX
unit main;
fn main(): int64 {
  var p: pchar := "$1"c;
  mkdir(p, 493);
  // Ein Verzeichnis laesst sich mit O_RDONLY oeffnen, solange es da ist.
  // Ein Builtin access() gibt es nicht (gemessen, auf keinem Ziel).
  var f1: int64 := open(p, 0, 0);
  if (f1 < 0) { return 10; }
  close(f1);
  var rc: int64 := rmdir(p);
  if (rc != 0) { return 11; }
  var f2: int64 := open(p, 0, 0);
  if (f2 >= 0) { close(f2); return 12; }
  return 42;
}
LYX
}

pruefe() { # $1 = Ziel, $2 = qemu-Programm (leer = nicht ausfuehrbar)
  local ziel="$1" qemu="$2"
  local dir="$TMP/d_$ziel"
  mach_quelle "$dir"
  if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/p.lyx" \
        --target="$ziel" -o "$TMP/p.$ziel" >"$TMP/c.$ziel.log" 2>&1); then
    no "$ziel uebersetzt" "$(grep -m1 -iE 'error|Builtin-ID' "$TMP/c.$ziel.log")"
    return
  fi
  ok "$ziel uebersetzt"

  if [ -z "$qemu" ]; then
    echo "HINWEIS: $ziel nicht ausgefuehrt (kein qemu) — die WIRKUNG ist damit ungemessen."
    return
  fi
  rm -rf "$dir"
  timeout 20 "$qemu" "$TMP/p.$ziel" >/dev/null 2>&1
  local rc=$?
  case "$rc" in
    42) ok "$ziel entfernt das Verzeichnis wirklich" ;;
    10) no "$ziel Wirkung" "mkdir/access schlug fehl — Versuchsaufbau, nicht rmdir" ;;
    11) no "$ziel Wirkung" "rmdir meldete einen Fehler (rc 11)" ;;
    12) no "$ziel Wirkung" "rmdir meldete Erfolg, das Verzeichnis ist noch da" ;;
    *)  no "$ziel Wirkung" "unerwarteter Exit $rc" ;;
  esac
  rm -rf "$dir"
}

pruefe arm64 "$QEMU_ARM64"
pruefe riscv "$QEMU_RISCV64"

# Gegenprobe auf dem Ziel, das immer ging: x86 senkt rmdir im eigenen Codegen.
# Ohne sie bliebe offen, ob der Versuchsaufbau ueberhaupt etwas misst.
dir="$TMP/d_x86"
mach_quelle "$dir"
if (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p.x86" \
      >"$TMP/c.x86.log" 2>&1); then
  rm -rf "$dir"
  timeout 20 "$TMP/p.x86" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 42 ]; then ok "x86 entfernt das Verzeichnis wirklich (Gegenprobe)"
  else no "x86 Gegenprobe" "Exit $rc statt 42 — der Versuchsaufbau misst nicht, was er soll"; fi
  rm -rf "$dir"
else
  no "x86 uebersetzt" "$(grep -m1 -iE 'error' "$TMP/c.x86.log")"
fi

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
