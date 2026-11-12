#!/usr/bin/env bash
# tests/zielmatrix_2463_test.sh — #2463/#2465: Dateisystem-Builtins auf x86,
# arm64 und riscv, gemessen an der WIRKUNG.
#
# BEFUND. Eine Zielmatrix ueber alle 484 in sema registrierten Builtins x 4
# Ziele (lyxc 1.2.35A, geurteilt nach Exit-Code) ergab sechs Namen mit der
# Signatur "x86-Familie rot, IR-Ziele gruen":
#
#   truncate  pipe  sys_seek  sys_mkdir  sys_unlink  sys_rename
#
# Sie uebersetzen auf arm64 und riscv und scheiterten auf dem STANDARDZIEL mit
# "undefined function — no codegen implementation found". Fuer die vier
# sys_*-Namen stand die Umsetzung schon da, nur auf der anderen Seite:
# `_sysLinuxZiel` in src/ir_lower.lyx (#2266) bildet sie auf den Linux-Zielen
# auf die generischen IDs ab. Der x86-Schnellweg hatte kein Gegenstueck.
#
# DAZU #2465, der Grund, die Abbildung nicht einfach zu kopieren: auf LyxOS
# traegt `sys_mkdir` KEINEN Modus (Kernelnummer 139, capability-basiert). Der
# Linux-mkdir verlangt einen, und ein nicht belegter Slot ist 0 — ein
# GUELTIGER Modus. Gemessen entstand damit ein Verzeichnis mit Modus 000, das
# sein Eigentuemer nicht betreten kann, bei rc 0 und ohne Meldung.
#
# WAS HIER GEMESSEN WIRD: die Wirkung jedes einzelnen Aufrufs, nicht die
# Uebersetzbarkeit. Ein Test, der nur prueft, dass der Aufruf durchkommt, waere
# auch von einem `truncate` erfuellt, das nichts tut, und von einem
# `sys_mkdir`, das ein unbenutzbares Verzeichnis anlegt. Der Modus wird
# deshalb ausdruecklich am Erzeugnis abgelesen (`stat`), nicht aus rc 0
# geschlossen.
#
# Jeder Schritt hat seinen eigenen Rueckgabewert, damit ein Fehlschlag
# benennbar ist statt nur "nicht 42".

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
. "$(dirname "$0")/lib/qemu.sh"   # #2048: beide Paketnamen
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

D="$TMP/d"; E="$TMP/e"; F="$TMP/f"

# Rueckgabewerte: 10 sys_mkdir, 11 sys_rename, 12 open(O_CREAT),
# 20 truncate/Laenge, 30 sys_seek/Position, 31 sys_unlink, 42 alles gut.
cat > "$TMP/w.lyx" <<LYX
unit main;
fn main(): int64 {
  sys_mkdir("$D"c);
  var f1: int64 := open("$D"c, 0, 0);
  if (f1 < 0) { return 10; }
  close(f1);
  sys_rename("$D"c, "$E"c);
  var f2: int64 := open("$E"c, 0, 0);
  if (f2 < 0) { return 11; }
  close(f2);
  var fd: int64 := open("$F"c, 577, 420);
  if (fd < 0) { return 12; }
  write(fd, "abcdefghij"c, 10);
  close(fd);
  truncate("$F"c, 4);
  var fd2: int64 := open("$F"c, 0, 0);
  var laenge: int64 := sys_seek(fd2, 0, 2);
  close(fd2);
  if (laenge != 4) { return 20; }
  var fd3: int64 := open("$F"c, 0, 0);
  var pos: int64 := sys_seek(fd3, 2, 0);
  close(fd3);
  if (pos != 2) { return 30; }
  sys_unlink("$F"c);
  var f4: int64 := open("$F"c, 0, 0);
  if (f4 >= 0) { close(f4); return 31; }
  return 42;
}
LYX

deute() { # $1 = rc
  case "$1" in
    10) echo "sys_mkdir hat kein betretbares Verzeichnis erzeugt";;
    11) echo "sys_rename hat nicht umbenannt";;
    12) echo "open(O_CREAT) schlug fehl — Versuchsaufbau";;
    20) echo "truncate hat die Laenge nicht auf 4 gesetzt";;
    30) echo "sys_seek lieferte die falsche Position";;
    31) echo "sys_unlink hat die Datei nicht entfernt";;
    *)  echo "unerwarteter Exit $1";;
  esac
}

pruefe() { # $1 = Name, $2 = --target (leer = x86), $3 = Starter
  local name="$1" ziel="$2" starter="$3"
  rm -rf "$D" "$E" "$F"
  if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/w.lyx" $ziel \
        -o "$TMP/w.bin" >"$TMP/c.log" 2>&1); then
    no "$name uebersetzt" "$(grep -m1 -iE 'error|undefined function' "$TMP/c.log")"
    return
  fi
  ok "$name uebersetzt"
  if [ -n "$ziel" ] && [ -z "$starter" ]; then
    echo "HINWEIS: $name nicht ausgefuehrt (kein qemu) — die WIRKUNG ist ungemessen."
    return
  fi
  timeout 20 $starter "$TMP/w.bin" >/dev/null 2>&1
  local rc=$?
  if [ "$rc" -ne 42 ]; then
    no "$name Wirkung" "$(deute $rc)"
    rm -rf "$D" "$E" "$F"; return
  fi
  ok "$name: alle sechs Aufrufe wirken"

  # #2465: Der Modus wird am ERZEUGNIS abgelesen. Aus rc 0 folgt er nicht —
  # mkdir meldet auch bei Modus 000 Erfolg.
  local m; m="$(stat -c '%a' "$E" 2>/dev/null)"
  if [ "$m" = "755" ]; then
    ok "$name: sys_mkdir setzt DEFAULT_DIR_MODE (0755)"
  else
    no "$name Modus" "Verzeichnis hat Modus '${m:-nicht vorhanden}' statt 755 (#2465)"
  fi
  rm -rf "$D" "$E" "$F"
}

pruefe "x86"   ""      ""
pruefe "arm64" "--target=arm64" "$QEMU_ARM64"
pruefe "riscv" "--target=riscv" "$QEMU_RISCV64"

# `pipe` hat keine Wirkung, die sich ohne zweiten Prozess ablesen laesst —
# geprueft wird deshalb nur, dass es auf allen drei Zielen uebersetzt. Das ist
# bewusst weniger: vorher scheiterte es auf x86 ueberhaupt.
printf 'unit main;\nfn main(): int64 { var p: [2]int64; pipe(p); return 0; }\n' > "$TMP/p.lyx"
for z in "" "--target=arm64" "--target=riscv"; do
  n="${z:-x86}"; n="${n#--target=}"
  if (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/p.lyx" $z \
        -o "$TMP/p.bin" >"$TMP/p.log" 2>&1); then
    ok "pipe uebersetzt ($n)"
  else
    no "pipe uebersetzt ($n)" "$(grep -m1 -iE 'error|undefined function' "$TMP/p.log")"
  fi
done

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
