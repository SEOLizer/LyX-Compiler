#!/usr/bin/env bash
# tests/canary_rahmenpuffer_2245_test.sh — #2245: Stack-Canary nur in
# Funktionen, deren Rahmen ueberhaupt zu erreichen ist.
#
# Bis 1.2.22A trug JEDE Funktion einen: 13 466 Pruefungen im Selbstbau, eine
# je Rueckkehrweg, und dieser Epilog laeuft bei jeder Rueckkehr (#2228). Die
# Regel ist jetzt die von `-fstack-protector-strong`: geprueft wird, wo ein
# Aggregat im Rahmen liegt (Feld, Wert-Struct, Feld-Literal, parallel Array),
# wo die ADRESSE eines Locals genommen wird (`@x` — danach schreibt beliebiger
# Code dorthin) und wo ein asm-Block steht. Eine Funktion, die nur Skalare
# haelt, hat keinen Puffer, ueber den ihr Rueckkehrpunkt zu erreichen waere.
#
# GEMESSEN WIRD BEIDES, und zwar am ERZEUGNIS und an der WIRKUNG:
#
#   1. Wirkung: ein Ueberlauf in einer Funktion MIT Feld loest weiter aus
#      ("stack smashing detected"). Ein Test, der nur zaehlt, waere auch von
#      einem Compiler erfuellt, der den Canary ablegt und nie prueft.
#   2. Gegenseite am Erzeugnis: ein Programm aus lauter Skalarfunktionen
#      enthaelt KEINE Pruefung, dasselbe Programm mit einem Feld je Funktion
#      enthaelt welche. Ohne diese Richtung waere auch "Canary ueberall"
#      gruen — und das war ja der Ausgangszustand.
#   3. Dritter Fall: `@x` auf einem SKALAR genuegt. Sonst waere die Regel zu
#      eng und eine Funktion, deren Rahmen per Zeiger beschrieben wird, haette
#      keinen Schutz mehr.
#
# Gezaehlt wird das Bytemuster der Pruefung: 4C 8B 5D F8 = `mov r11,[rbp-8]`.
# Sie steht nur im Canary-Epilog; der Prolog schreibt mit 48 89 45 F8. Das
# Erzeugnis hat keine Abschnittstabelle, objdump kann es also nicht nach
# Funktionen aufteilen (siehe sprung_ausrichtung_2244_test.sh) — das Muster im
# ganzen Abbild zu zaehlen genuegt fuer die Aussage "keine / welche".

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ulimit -c 0
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# zaehle <name> — Anzahl der Canary-Pruefungen im Erzeugnis
zaehle() {
  python3 - "$TMP/$1.bin" <<'PY'
import sys
d=open(sys.argv[1],'rb').read()
print(d.count(bytes([0x4C,0x8B,0x5D,0xF8])))
PY
}

baue() { # name  (Quelle auf stdin)
  cat > "$TMP/$1.lyx"
  rm -f "$TMP/$1.bin"
  if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/$1.lyx" -o "$TMP/$1.bin" >"$TMP/$1.log" 2>&1); then
    no "$1" "uebersetzt nicht: $(grep -m1 -iE 'error|lyxc:' "$TMP/$1.log")"; return 1
  fi
  return 0
}

# --- 1. Wirkung: der Ueberlauf loest weiter aus --------------------------
baue ueberlauf <<'LYX'
unit main;
import std.io;
fn schreib(p: int64, n: int64): int64 {
  var i: int64 := 0;
  while i < n { poke64(p + 16 + i * 8, 0 - 1); i := i + 1; }
  return i;
}
fn ueberlauf(n: int64): int64 {
  var f: int64[2];
  f[0] := 5;
  return schreib(@f, n);
}
fn main(): int64 {
  PrintStr("start\n"c);
  PrintInt(ueberlauf(3)); PrintStr("\n"c);
  PrintStr("zurueck\n"c);
  return 0;
}
LYX
if [ -f "$TMP/ueberlauf.bin" ]; then
  aus=$( (timeout 20 "$TMP/ueberlauf.bin") 2>&1 ); rc=$?
  if printf '%s' "$aus" | grep -q 'stack smashing detected'; then
    ok "Ueberlauf in einer Funktion mit Feld wird erkannt (rc=$rc)"
  else
    no "Ueberlauf" "keine Meldung 'stack smashing detected' (rc=$rc, Ausgabe: $(printf '%s' "$aus" | tr '\n' ' '))"
  fi
  if printf '%s' "$aus" | grep -q 'zurueck'; then
    no "Ueberlauf" "die Funktion kam durch — der Canary hat nicht gegriffen"
  else
    ok "Die Rueckkehr findet nicht statt"
  fi
fi

# --- 2. Gegenseite am Erzeugnis -----------------------------------------
HAUPT='fn main(): int64 {
  PrintInt(f0(1)); PrintInt(f1(1)); PrintInt(f2(1)); PrintInt(f3(1));
  PrintInt(f4(1)); PrintInt(f5(1)); PrintInt(f6(1)); PrintInt(f7(1));
  PrintStr("\n"c);
  return 0;
}'

{ echo 'unit main;'; echo 'import std.io;'
  for i in 0 1 2 3 4 5 6 7; do echo "fn f$i(a: int64): int64 { var x: int64 := a + $i; return x * 2; }"; done
  echo "$HAUPT"; } > "$TMP/skalar.src"
baue skalar < "$TMP/skalar.src"

{ echo 'unit main;'; echo 'import std.io;'
  for i in 0 1 2 3 4 5 6 7; do echo "fn f$i(a: int64): int64 { var b: int64[2]; b[0] := a + $i; return b[0] * 2; }"; done
  echo "$HAUPT"; } > "$TMP/feld.src"
baue feld < "$TMP/feld.src"

{ echo 'unit main;'; echo 'import std.io;'
  echo 'fn g(p: int64): int64 { return peek64(p) * 2; }'
  for i in 0 1 2 3 4 5 6 7; do echo "fn f$i(a: int64): int64 { var x: int64 := a + $i; return g(@x); }"; done
  echo "$HAUPT"; } > "$TMP/adresse.src"
baue adresse < "$TMP/adresse.src"

if [ -f "$TMP/skalar.bin" ] && [ -f "$TMP/feld.bin" ] && [ -f "$TMP/adresse.bin" ]; then
  ns=$(zaehle skalar); nf=$(zaehle feld); na=$(zaehle adresse)
  # Gleiche Wirkung auf allen drei: die Programme rechnen dasselbe.
  for v in skalar feld adresse; do
    g=$( timeout 20 "$TMP/$v.bin" 2>&1 | tr -d '\n' )
    if [ "$g" = "246810121416" ]; then ok "$v laeuft und rechnet richtig ($g)"
    else no "$v" "'$g' erwartet '246810121416'"; fi
  done
  if [ "$ns" -eq 0 ]; then ok "nur Skalare: keine Canary-Pruefung im Erzeugnis"
  else no "nur Skalare" "$ns Pruefung(en) — die Regel greift nicht"; fi
  if [ "$nf" -ge 8 ]; then ok "je Funktion ein Feld: $nf Pruefungen"
  else no "Feld" "nur $nf Pruefungen, erwartet mindestens 8 (eine je Funktion)"; fi
  if [ "$na" -ge 8 ]; then ok "je Funktion @x auf einem Skalar: $na Pruefungen"
  else no "@x" "nur $na Pruefungen, erwartet mindestens 8 — eine genommene Adresse muss genuegen"; fi
fi

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
