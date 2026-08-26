#!/usr/bin/env bash
# tests/assert_opcodes_test.sh — #1339, Teil 2: die Zusicherungen.
#
# `ir_lower` erzeugt IRO_ASSERT_NOT_ZERO vor JEDER Division, damit eine Null
# zu einem kontrollierten Abbruch führt statt zu SIGFPE. Behandelt hat den
# Opcode ausser dem lyxos-Backend keines — er verschwand lautlos, und die
# Division lief ungeprüft.
#
# Sichtbar wurde das erst durch die Opcode-Prüfung aus dem ersten Teil von
# #1339: seither scheiterte eine simple Division für arm64, riscv, arm-cm4
# und esp32 mit "kennt Opcode 159 nicht". Dieser Test hält beides fest — dass
# Division wieder übersetzt, und dass die Prüfbefehle wirklich im Code stehen.
#
# WICHTIG zur Aussagekraft: auf diesem Rechner lässt sich kein arm64-, riscv-
# oder Cortex-M-Binary AUSFÜHREN (kein qemu-user installiert). Die Prüfung
# erfolgt deshalb an den Bytes: die Sprung- und Abbruchsequenz muss im
# erzeugten Code vorkommen. Das belegt die Emission, nicht das Laufverhalten —
# und genau das steht hier, statt einen Laufzeitnachweis vorzutäuschen.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

printf 'fn main(): int64 { var a: int64 := 10; var b: int64 := 2; return a / b; }\n' > "$TMP/div.lyx"

# ===========================================================================
# Division uebersetzt wieder — auf den Zielen, die eine gepruefte Kodierung haben
# ===========================================================================

# esp32 seit #1789 mit dabei: die Basis-ISA hat keinen Divisionsbefehl, also
# eine Softwareroutine — damit auf JEDEM Xtensa-Kern richtig und nicht nur auf
# denen mit der optionalen DIV32-Erweiterung.
for t in arm64 riscv arm-cm4 esp32; do
  rm -f "$TMP/d_$t"
  if "$LYXC" --std-path="$ROOT" "$TMP/div.lyx" --target=$t -o "$TMP/d_$t" >/dev/null 2>&1; then
    ok "Division uebersetzt fuer $t"
  else
    no "Division uebersetzt fuer $t" "$("$LYXC" --std-path="$ROOT" "$TMP/div.lyx" --target=$t -o "$TMP/d_$t" 2>&1 | head -1)"
  fi
done

# #1789: Hier stand die Gegenprobe, dass xtensa die Zusicherung LAUT ablehnt.
# Die Begruendung ("ausser `nop` keine gegen die eigene Byte-Konvention
# gepruefte Kodierung") ist mit #1786 hinfaellig geworden: BRI12 und J sind
# gegen den Disassembler belegt, und ILL ist im Lauf nachgewiesen (SIGILL).
#
# Geprueft wird deshalb jetzt die WIRKUNG statt der Ablehnung: die Zusicherung
# muss ausloesen. Das ist der tragfaehigere Nachweis — ein Test, dessen gruener
# Zustand eine fehlende Faehigkeit voraussetzt, verrottet mit dem naechsten
# Ausbau (in dieser Sitzung viermal passiert).
QEMU_XT="$(command -v qemu-xtensa-static || true)"
HUELLE_XT="$ROOT/tests/lib/xtensa_huelle.py"
printf 'fn main(): int64 { var a: int64 := 10; var b: int64 := 0; return a / b; }\n' > "$TMP/div0.lyx"
if ! "$LYXC" --std-path="$ROOT" "$TMP/div0.lyx" --target=esp32 -o "$TMP/d0_xt" >/dev/null 2>&1; then
  no "xtensa: Division durch 0 loest die Zusicherung aus" "uebersetzt nicht"
elif [ -z "$QEMU_XT" ]; then
  ok "xtensa: Division durch 0 uebersetzt (qemu fehlt, nicht ausgefuehrt)"
elif ! python3 "$HUELLE_XT" "$TMP/d0_xt" "$TMP/d0.run" >/dev/null 2>&1; then
  no "xtensa: Division durch 0 loest die Zusicherung aus" "Huelle scheiterte"
else
  timeout 10 "$QEMU_XT" "$TMP/d0.run" >/dev/null 2>&1; rc0=$?
  # 132 = SIGILL: ILL hat ausgeloest, das Programm ist NICHT weitergelaufen.
  if [ "$rc0" -eq 132 ]; then ok "xtensa: Division durch 0 loest die Zusicherung aus"
  else no "xtensa: Division durch 0 loest die Zusicherung aus" "rc=$rc0, erwartet 132"; fi
fi

# ===========================================================================
# Die Pruefbefehle stehen wirklich im Code
# ===========================================================================

# Ein Test auf "uebersetzt" allein waere auch gruen, wenn der Opcode wieder
# stillschweigend verschwaende — er stuende ja bloss in der Liste. Deshalb die
# Bytes.
hat_muster() { # name, datei, hexmuster (little endian, wie im Code)
  if [ ! -f "$2" ]; then no "$1" "kein Binary"; return; fi
  if od -An -tx1 "$2" | tr -d ' \n' | grep -q "$3"; then ok "$1"
  else no "$1" "Muster $3 fehlt im erzeugten Code"; fi
}

# arm64: CBNZ x0, +16 (B5000080) springt ueber MOV/MOV/SVC.
hat_muster "arm64: CBNZ ueberspringt den Abbruch" "$TMP/d_arm64" "800000b5"
# riscv: BNE t0, x0, +12 (00029663) springt ueber LI/LI/ecall.
hat_muster "riscv: BNE ueberspringt den Abbruch"  "$TMP/d_riscv" "6396020"
# arm-cm4: BNE +0 (D100) gefolgt von BKPT #0 (BE00).
hat_muster "arm-cm4: BNE gefolgt von BKPT"        "$TMP/d_arm-cm4" "00d100be"

# ===========================================================================
# IRO_CONST_STR — Zeichenketten (#1339, zweite Scheibe)
# ===========================================================================

# Ohne diesen Opcode scheiterte auf riscv und arm-cm4 schon `PrintLn("hallo")`.
# Ohne `import std.io`: PrintLn ist ein Builtin, und die IR-Strecke kennt
# StrLen aus der Unit nicht (eigene Luecke, hier nicht Gegenstand). Geprueft
# wird die ZEICHENKETTE, nicht die Bibliothek.
printf 'fn main(): int64 { PrintLn("hallo"); return 0; }\n' > "$TMP/str.lyx"
# esp32 seit #1786 mit dabei: dort liegen die Bytes inline im Codestrom und die
# Adresse entsteht PC-relativ ueber ein CALL0 auf eine Ruecksprungmarke —
# xtensa hat keinen Befehl, der den Programmzaehler liest.
#
# Bis 1.1.9N stand hier stattdessen die Gegenprobe, dass xtensa den Opcode LAUT
# ablehnt. Ein Test, dessen gruener Zustand eine fehlende Faehigkeit
# voraussetzt, verrottet mit dem naechsten Ausbau; der laute Default wird
# weiterhin in tests/ir_builtins_test.sh geprueft, dort an einer Luecke, die
# offen ist.
for t in arm64 riscv arm-cm4 esp32; do
  rm -f "$TMP/s_$t"
  if "$LYXC" --std-path="$ROOT" "$TMP/str.lyx" --target=$t -o "$TMP/s_$t" >/dev/null 2>&1; then
    ok "Zeichenkette uebersetzt fuer $t"
  else
    no "Zeichenkette uebersetzt fuer $t" "$("$LYXC" --std-path="$ROOT" "$TMP/str.lyx" --target=$t -o "$TMP/s_$t" 2>&1 | head -1)"
  fi
done

# Die Bytes stehen inline im Codestrom — und der Sprung muss sie GENAU
# ueberspringen. Das ist die eigentliche Fehlerquelle bei inline abgelegten
# Daten: eine um zwei Byte falsche Weite laesst den Prozessor in die
# Zeichenkette hineinlaufen, und das faellt bei keinem Uebersetzungslauf auf.
pruefe_sprung() { # name, datei, arch
  if python3 "$ROOT/tests/lib/pruefe_sprung.py" "$2" "$3"; then ok "$1"
  else no "$1" "Sprungweite passt nicht zur Zeichenkette"; fi
}
pruefe_sprung "arm64: Sprung ueberspringt die Zeichenkette genau"   "$TMP/s_arm64"   a64
pruefe_sprung "riscv: Sprung ueberspringt die Zeichenkette genau"   "$TMP/s_riscv"   rv
pruefe_sprung "arm-cm4: Sprung ueberspringt die Zeichenkette genau" "$TMP/s_arm-cm4" cm

# ===========================================================================
# Gegenproben
# ===========================================================================

# Ohne Division darf keine Zusicherung im Code stehen — sonst waere der
# Nachweis oben wertlos (das Muster koennte aus dem Rahmencode stammen).
printf 'fn main(): int64 { var a: int64 := 10; var b: int64 := 2; return a + b; }\n' > "$TMP/add.lyx"
rm -f "$TMP/a_arm64"
"$LYXC" --std-path="$ROOT" "$TMP/add.lyx" --target=arm64 -o "$TMP/a_arm64" >/dev/null 2>&1
if [ -f "$TMP/a_arm64" ]; then
  if od -An -tx1 "$TMP/a_arm64" | tr -d ' \n' | grep -q "800000b5"; then
    no "ohne Division keine Zusicherung im Code" "CBNZ-Muster auch ohne Division vorhanden"
  else
    ok "ohne Division keine Zusicherung im Code"
  fi
else
  no "ohne Division keine Zusicherung im Code" "uebersetzt nicht"
fi

# Der x86-Weg ist unberuehrt: er hat seine eigenen Pruefungen im Codegen und
# geht gar nicht ueber die IR-Strecke.
printf 'import std.io;\nfn main(): int64 { var a: int64 := 10; var b: int64 := 2; PrintLn(IntToStr(a / b)); return 0; }\n' > "$TMP/x86.lyx"
rm -f "$TMP/x86"
if "$LYXC" --std-path="$ROOT" "$TMP/x86.lyx" -o "$TMP/x86" >/dev/null 2>&1; then
  got="$("$TMP/x86" 2>&1)"
  if [ "$got" = "5" ]; then ok "x86-Division rechnet unveraendert richtig"
  else no "x86-Division rechnet unveraendert richtig" "'$got' erwartet '5'"; fi
else
  no "x86-Division rechnet unveraendert richtig" "uebersetzt nicht"
fi

# Und die Liste im Backend muss weiterhin zum Dispatcher passen — die Prüfung
# aus dem ersten Teil von #1339 gilt auch für die neuen Zweige.
for b in "src/backend/riscv_linux.lyx:rv" "src/backend/xtensa.lyx:xt" \
         "src/backend/arm_cm_backend.lyx:cm" "src/backend/arm64/emit_arm64.lyx:a64"; do
  datei="${b%%:*}"; praefix="${b##*:}"
  fehlend="$(python3 - "$ROOT/$datei" "$praefix" <<'PY'
import re,sys
s=open(sys.argv[1],encoding='utf-8').read(); pre=sys.argv[2]
i=s.index("fn %s_opBehandelt" % pre); j=s.index("return 0;", i)
liste=set(re.findall(r'op == ([A-Za-z0-9_]+)', s[i:j]))
k=s.index("fn emitInstr("); m=s.index("\n  fn ", k+10)
disp=set(re.findall(r'op == ([A-Za-z0-9_]+)', s[k:m]))
print(" ".join(sorted(disp - liste)))
PY
)"
  if [ -z "$fehlend" ]; then ok "$(basename "$datei"): Liste deckt den Dispatcher"
  else no "$(basename "$datei"): Liste deckt den Dispatcher" "nicht eingetragen: $fehlend"; fi
done

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
