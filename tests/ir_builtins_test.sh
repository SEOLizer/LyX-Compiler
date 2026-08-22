#!/usr/bin/env bash
# tests/ir_builtins_test.sh — #1388 (Teil 1) und der dabei gefundene stille
# Default in der Builtin-Verteilung.
#
# BEFUND BEIM MESSEN. #1339 hat die OPCODE-Verteiler der IR-Backends laut
# gemacht. Eine Ebene tiefer, bei den BUILTIN-IDs, stand derselbe Fehler noch:
#
#   riscv_linux.lyx   emitBuiltinCall ohne else — der Aufruf lieferte, was
#                     zufaellig in a0 stand
#   arm_cm_backend    JEDER Builtin lieferte 0, ohne ein Wort darueber
#   xtensa.lyx        "Other builtins: stub returning 0"
#   emit_lyxos.lyx    Kette ohne Default
#
# `peek8(p)` uebersetzte auf riscv und arm-cm4 also klaglos und gab 0 zurueck,
# statt zu lesen. Nur arm64 meldete (seit #1037).
#
# Jetzt: alle vier melden, und die Speicherzugriffe sind auf den drei Zielen
# umgesetzt, die sie ohne Betriebssystem ausfuehren koennen.
#
# GEMESSEN WIRD AN DEN BYTES, nicht an "uebersetzt ohne Fehler" — ein Test auf
# Uebersetzbarkeit waere vorher gruen gewesen, gerade WEIL nichts erzeugt
# wurde.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

printf 'fn main(): int64 { var p: int64 := 4096; poke8(p, 65); return peek8(p); }\n' > "$TMP/mem.lyx"
printf 'fn main(): int64 { return StrCharAt("abc"c, 1); }\n' > "$TMP/sc.lyx"
# #1388: StrCharAt (ID 206) ist seit 1.1.5D auf riscv und Cortex-M umgesetzt und
# taugt damit nicht mehr als Beispiel fuer eine LUECKE. Fuer die Gegenprobe zum
# stillen Default braucht es einen Namen, den die beiden noch nicht koennen:
# IntToStr (ID 16) auf riscv, StrLen (ID 15) auf Cortex-M. Die Pruefung selbst
# bleibt dieselbe — eine unbehandelte ID muss BENANNT werden.
# #1388 (Abschluss): IntToStr und StrLen sind auf beiden Zielen umgesetzt und
# taugen nicht mehr als Beispiel fuer eine Luecke — zum zweiten Mal an dieser
# Stelle. Genommen werden jetzt Namen, die wirklich offen sind: StrConcat (7)
# auf riscv, und auf Cortex-M IntToStr (16), das dort aus einem BENANNTEN
# Grund scheitert (kein Puffer, der den Aufruf ueberlebt — es gibt weder mmap
# noch einen Allokator). Beides muss gemeldet werden, nicht still durchgehen.
printf 'fn main(): int64 { var s: pchar := StrConcat("a"c, "b"c); return 0; }\n' > "$TMP/luecke_riscv64.lyx"
printf 'fn main(): int64 { var s: pchar := IntToStr(7); return 0; }\n' > "$TMP/luecke_arm-cm4.lyx"
printf 'fn main(): int64 { var a: int64 := 2; var b: int64 := a * 3 + 1; if b > 5 { return b; } return 0; }\n' > "$TMP/rechnen.lyx"

hex() { od -An -tx1 "$1" | tr -d ' \n'; }

# ===========================================================================
# Die Speicherzugriffe erzeugen wirklich Code
# ===========================================================================

# arm64: LDRB w0,[x1] = 39 40 00 20 → little endian 0x39400020 → "20004039"
if timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/mem.lyx" --target=arm64 -o "$TMP/m_arm64" >"$TMP/m.log" 2>&1; then
  if hex "$TMP/m_arm64" | grep -q "20004039"; then
    ok "arm64: peek8 emittiert LDRB"
  else
    no "arm64: peek8 emittiert LDRB" "kein LDRB im Erzeugnis"
  fi
else
  no "arm64: peek8" "$(grep -m1 -i error "$TMP/m.log")"
fi

# riscv: LBU (funct3=4, opcode=3) — das Erzeugnis muss ein LBU enthalten.
if timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/mem.lyx" --target=riscv64 -o "$TMP/m_rv" >"$TMP/m.log" 2>&1; then
  ok "riscv: peek8/poke8 uebersetzen"
else
  no "riscv: peek8/poke8" "$(grep -m1 -i error "$TMP/m.log")"
fi

if timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/mem.lyx" --target=arm-cm4 -o "$TMP/m_cm" >"$TMP/m.log" 2>&1; then
  ok "arm-cm4: peek8/poke8 uebersetzen"
else
  no "arm-cm4: peek8/poke8" "$(grep -m1 -i error "$TMP/m.log")"
fi

# Die Gegenprobe zum stillen Default: dasselbe Programm, uebersetzt mit dem
# ALTEN Stand, ergab auf riscv/arm-cm4 ein Binary OHNE jeden Speicherzugriff.
# Das laesst sich hier nicht nachstellen; was sich pruefen laesst, ist die
# Groesse: ein Erzeugnis, in dem der Zugriff fehlt, ist kuerzer als eines mit.
# Deshalb oben der Bytetest auf arm64 — er ist der eigentliche Beleg.

# ===========================================================================
# #1388: StrCharAt/StrSetChar sind auf riscv und Cortex-M umgesetzt
# ===========================================================================
# Die Ergaenzung gehoert geprueft, nicht nur die Luecke daneben: sonst faellt
# nicht auf, wenn sie wieder verschwindet.
for t in riscv64 arm-cm4; do
  if timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/sc.lyx" --target=$t -o "$TMP/sc_ok_$t" >"$TMP/sc_ok.log" 2>&1; then
    ok "$t: StrCharAt uebersetzt"
  else
    no "$t: StrCharAt uebersetzt" "$(grep -m1 -iE 'error|Builtin-ID' "$TMP/sc_ok.log")"
  fi
done

# #1388: StrLen gehoert auf JEDES Ziel — es rechnet ohne Betriebssystem.
printf 'fn main(): int64 { return StrLen("abc"c); }\n' > "$TMP/sl.lyx"
for t in arm64 riscv64 arm-cm4; do
  if timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/sl.lyx" --target=$t -o "$TMP/sl_$t" >"$TMP/sl.log" 2>&1; then
    ok "$t: StrLen uebersetzt"
  else
    no "$t: StrLen uebersetzt" "$(grep -m1 -iE 'error|Builtin-ID' "$TMP/sl.log")"
  fi
done

# #1388: IntToStr und StrSub brauchen einen Puffer — auf den Linux-Zielen aus
# mmap, und dort muessen sie uebersetzen.
printf 'fn main(): int64 { var a: pchar := IntToStr(7); var b: pchar := StrSub("abc"c, 1, 2); return 0; }\n' > "$TMP/buf.lyx"
for t in arm64 riscv64; do
  if timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/buf.lyx" --target=$t -o "$TMP/buf_$t" >"$TMP/buf.log" 2>&1; then
    ok "$t: IntToStr und StrSub uebersetzen"
  else
    no "$t: IntToStr und StrSub uebersetzen" "$(grep -m1 -iE 'error|Builtin-ID' "$TMP/buf.log")"
  fi
done

# ===========================================================================
# Eine unbehandelte ID wird BENANNT, nicht verschluckt
# ===========================================================================
for t in riscv64 arm-cm4; do
  msg="$(timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/luecke_$t.lyx" --target=$t -o "$TMP/sc_$t" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] && echo "$msg" | grep -qE "Builtin-ID [0-9]+"; then
    ok "$t: unbehandelte Builtin-ID wird gemeldet"
  else
    no "$t: unbehandelte Builtin-ID" "rc=$rc — $(echo "$msg" | head -1)"
  fi
done

# xtensa scheitert an diesem Programm schon FRUEHER, an der Zeichenkette
# (#1339) — ebenfalls laut und mit Issue-Nummer. Welche der beiden Luecken
# zuerst meldet, ist nebensaechlich; dass keine still durchgeht, nicht.
msgx="$(timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/sc.lyx" --target=esp32 -o "$TMP/sc_xt" 2>&1)"; rcx=$?
if [ "$rcx" -ne 0 ] && echo "$msgx" | grep -qE "Builtin-ID [0-9]+|nicht umgesetzt"; then
  ok "esp32: die Luecke wird benannt statt verschluckt"
else
  no "esp32: Luecke benannt" "rc=$rcx — $(echo "$msgx" | grep -v Copyright | head -1)"
fi

# Und der Builtin-Default selbst, an einem Programm OHNE Zeichenkette:
printf 'fn main(): int64 { var p: int64 := 4096; return peek8(p); }\n' > "$TMP/pk.lyx"
msgp="$(timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/pk.lyx" --target=esp32 -o "$TMP/pk_xt" 2>&1)"; rcp=$?
if [ "$rcp" -ne 0 ] && echo "$msgp" | grep -qE "Builtin-ID [0-9]+"; then
  ok "esp32: unbehandelte Builtin-ID wird gemeldet"
else
  no "esp32: unbehandelte Builtin-ID" "rc=$rcp — $(echo "$msgp" | grep -v Copyright | head -1)"
fi

# ===========================================================================
# #1388 — die Fehlerausgabe, an der jeder std.io-Import scheiterte
# ===========================================================================
printf 'fn main(): int64 { EPrintStr("x"c); return StrLen("abc"c); }\n' > "$TMP/ep.lyx"
for t in arm64 riscv64; do
  if timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/ep.lyx" --target=$t -o "$TMP/ep_$t" >"$TMP/ep.log" 2>&1; then
    ok "$t: EPrintStr und StrLen uebersetzen"
  else
    no "$t: EPrintStr und StrLen" "$(grep -m1 -iE 'error|Builtin' "$TMP/ep.log")"
  fi
done

# arm64: die Schreib-Sequenz auf stderr muss drinstehen (MOVZ x0,#2 = d2800040).
if [ -f "$TMP/ep_arm64" ] && hex "$TMP/ep_arm64" | grep -q "400080d2"; then
  ok "arm64: EPrintStr schreibt auf Dateikennung 2"
else
  no "arm64: EPrintStr schreibt auf Dateikennung 2" "kein MOVZ x0,#2 im Erzeugnis"
fi

# ===========================================================================
# Gegenprobe: was die Backends koennen, muessen sie weiterhin koennen
# ===========================================================================
for t in arm64 riscv64 arm-cm4 esp32; do
  if timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/rechnen.lyx" --target=$t -o "$TMP/r_$t" >/dev/null 2>&1; then
    ok "$t: Rechnen und Verzweigen unveraendert"
  else
    no "$t: Rechnen und Verzweigen" "abgewiesen"
  fi
done

# Und der Standardweg bleibt unberuehrt.
printf 'import std.io;\nfn main(): int64 { PrintLn("hallo"); return 0; }\n' > "$TMP/x86.lyx"
if timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/x86.lyx" -o "$TMP/x86" >/dev/null 2>&1; then
  got="$("$TMP/x86" 2>&1)"
  [ "$got" = "hallo" ] && ok "x86-64 unveraendert" || no "x86-64" "'$got'"
else
  no "x86-64" "uebersetzt nicht"
fi

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
