#!/usr/bin/env bash
# tests/asm_operanden_test.sh — #1324.
#
# `asm { }` kannte nur Befehle OHNE Operanden bzw. mit festem Register. Es gab
# keine Moeglichkeit, einen Lyx-Wert vor dem Block in ein bestimmtes Register
# zu bringen oder ein Ergebnis daraus zurueckzuholen. Damit waren portbasierte
# Hardwarezugriffe nicht ausdrueckbar: die Portadresse wird zur Laufzeit aus
# Bus, Geraet, Funktion und Offset gerechnet und muss nach dx.
#
# Die Form ist GCC-artig, aber mit AUSGESCHRIEBENEM Registernamen statt
# Constraint-Buchstaben — es gibt keinen Registerzuteiler, und ein
# Constraint-Buchstabe wuerde eine Wahl versprechen, die niemand trifft:
#
#   asm { "in eax, dx" : out("eax", wert) : in("dx", port) }
#
# GEPRUEFT WIRD DER WERT, der durch das Register laeuft — nicht, dass es
# uebersetzt. Ein Test auf "uebersetzt" waere gruen, auch wenn die Bindung
# nichts bewegt.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/p.lyx"; rm -f "$TMP/p"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p" >/dev/null 2>&1; then
    no "$1" "uebersetzt nicht: $("$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p" 2>&1 | grep -i error | head -1)"
    return
  fi
  got="$(timeout 30 "$TMP/p" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then no "$1" "ABSTURZ (rc=$rc)"; return; fi
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1" "'$got' erwartet '$3'"; fi
}

# ===========================================================================
# Der Wert laeuft hin und zurueck
# ===========================================================================

out "#1324: in(...) laedt, out(...) holt zurueck" 'import std.io;
fn main(): int64 {
  var a: int64 := 7;
  var b: int64 := 0;
  asm { "nop" : out("rbx", b) : in("rbx", a) }
  PrintLn(IntToStr(b));
  return 0;
}' "7"

# Zwei Eingaben: die Auswertung des zweiten Ausdrucks darf das Register des
# ersten nicht zerstoeren — dieselbe Falle wie bei den Parameterkopien (#1351).
out "#1324: zwei Eingaberegister, beide kommen an" 'import std.io;
fn main(): int64 {
  var x: int64 := 10;
  var y: int64 := 32;
  var s1: int64 := 0;
  var s2: int64 := 0;
  asm { "nop" : out("rbx", s1), out("rcx", s2) : in("rbx", x), in("rcx", y) }
  PrintStr(IntToStr(s1)); PrintStr(" "); PrintLn(IntToStr(s2));
  return 0;
}' "10 32"

# Der Eingabewert darf ein gerechneter Ausdruck sein — genau darum geht es in
# der Meldung (Portadresse aus Bus, Geraet, Funktion, Offset).
out "#1324: gerechneter Ausdruck als Eingabe" 'import std.io;
fn main(): int64 {
  var bus: int64 := 3;
  var geraet: int64 := 5;
  var erg: int64 := 0;
  asm { "nop" : out("rbx", erg) : in("rbx", 0x80000000 + bus * 65536 + geraet * 2048) }
  PrintLn(IntToStr(erg));
  return 0;
}' "2147690496"

# rax als Zielregister: dort darf kein ueberfluessiges mov entstehen, der Wert
# muss aber trotzdem stimmen.
out "#1324: rax als Ein- und Ausgaberegister" 'import std.io;
fn main(): int64 {
  var a: int64 := 42;
  var b: int64 := 0;
  asm { "nop" : out("rax", b) : in("rax", a) }
  PrintLn(IntToStr(b));
  return 0;
}' "42"

# Eine globale Variable als Ziel.
out "#1324: globale Variable als out-Ziel" 'import std.io;
var g: int64 := 0;
fn main(): int64 {
  var a: int64 := 99;
  asm { "nop" : out("rbx", g) : in("rbx", a) }
  PrintLn(IntToStr(g));
  return 0;
}' "99"

# ===========================================================================
# Die Portbefehle uebersetzen
# ===========================================================================
# Ausgefuehrt werden sie nicht: `in`/`out` sind unter Linux ohne iopl
# privilegiert und wuerden mit SIGSEGV enden. Geprueft wird deshalb, dass die
# richtigen Bytes entstehen — 0xED (in eax, dx) bzw. 0xEF (out dx, eax).

cat > "$TMP/port.lyx" <<'EOF'
fn lesen(port: int64): int64 {
  var wert: int64 := 0;
  asm { "in eax, dx" : out("eax", wert) : in("dx", port) }
  return wert;
}
fn schreiben(port: int64, wert: int64): int64 {
  asm { "out dx, eax" : : in("dx", port), in("eax", wert) }
  return 0;
}
fn main(): int64 { return lesen(0x80) + schreiben(0x80, 1); }
EOF
if "$LYXC" --std-path="$ROOT" "$TMP/port.lyx" -o "$TMP/port" >/dev/null 2>&1; then
  hat_in="$(python3 -c "
import sys
d=open(sys.argv[1],'rb').read()
print(1 if b'\xed' in d else 0)" "$TMP/port" 2>/dev/null)"
  hat_out="$(python3 -c "
import sys
d=open(sys.argv[1],'rb').read()
print(1 if b'\xef' in d else 0)" "$TMP/port" 2>/dev/null)"
  if [ "$hat_in" = "1" ] && [ "$hat_out" = "1" ]; then
    ok "#1324: in eax, dx und out dx, eax werden emittiert"
  else
    no "#1324: in eax, dx und out dx, eax werden emittiert" "in=$hat_in out=$hat_out"
  fi
else
  no "#1324: in eax, dx und out dx, eax werden emittiert" "uebersetzt nicht: $("$LYXC" --std-path="$ROOT" "$TMP/port.lyx" -o "$TMP/port" 2>&1 | grep -i error | head -1)"
fi

# ===========================================================================
# Gegenproben
# ===========================================================================

# Ein asm-Block OHNE Operandenliste bleibt, was er war.
out "#1324: Block ohne Operanden unveraendert" 'import std.io;
fn main(): int64 {
  asm { "nop" "nop" }
  PrintLn("da");
  return 0;
}' "da"

# Ein unbekanntes Register wird gemeldet, nicht stillschweigend uebergangen.
printf 'fn main(): int64 {\n  var a: int64 := 1;\n  asm { "nop" : : in("r15", a) }\n  return 0;\n}\n' > "$TMP/bad.lyx"
if "$LYXC" --std-path="$ROOT" "$TMP/bad.lyx" -o "$TMP/bad" >/dev/null 2>&1; then
  no "#1324: unbekanntes Register wird gemeldet" "uebersetzt klaglos"
else
  meldung="$("$LYXC" --std-path="$ROOT" "$TMP/bad.lyx" -o "$TMP/bad" 2>&1 | grep -ci "unbekanntes Register")"
  if [ "$meldung" -ge 1 ]; then ok "#1324: unbekanntes Register wird gemeldet"
  else no "#1324: unbekanntes Register wird gemeldet" "andere Meldung"; fi
fi

# Auf den IR-Zielen gibt es die Bindung noch nicht — dort muss der Block laut
# abweisen statt etwas Halbes zu erzeugen.
printf 'fn main(): int64 {\n  var p: int64 := 128;\n  var w: int64 := 0;\n  asm { "in eax, dx" : out("eax", w) : in("dx", p) }\n  return w;\n}\n' > "$TMP/ir.lyx"
meldung="$("$LYXC" --std-path="$ROOT" "$TMP/ir.lyx" --target=lyxos -o "$TMP/ir.lbf" 2>&1 | grep -ci "nicht-unterstuetzte Mnemonic")"
if [ "$meldung" -ge 1 ]; then
  ok "#1324: IR-Ziele weisen den Portbefehl laut ab (Bindung dort offen)"
else
  no "#1324: IR-Ziele weisen den Portbefehl laut ab (Bindung dort offen)" "keine Meldung"
fi

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
