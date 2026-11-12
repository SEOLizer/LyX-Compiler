#!/usr/bin/env bash
# tests/lyu_exporte_test.sh — #2035: was eine .lyu exportiert, und dass `pub`
# bei Konstanten gilt.
#
# Zwei Befunde, die zusammengehoeren:
#
#   1. sema nahm SYM_CON von der Sichtbarkeits- und Mehrdeutigkeitspruefung
#      aus (_symKindIsAmbiguityRelevant zaehlte sechs Arten auf, die siebte
#      fehlte). Eine `con` ohne pub war von aussen lesbar, und zwei Units mit
#      gleichnamiger `pub con` kollidierten unbemerkt — allein die
#      Import-Reihenfolge entschied, welcher Wert gilt. Das ist die Luecke aus
#      #1028, nur fuer diese eine Symbolart.
#
#   2. Die .lyu trug ALLE Symbole, die sema beim Uebersetzen sah: eine Unit
#      mit fuenf eigenen Konstanten hatte 31 Eintraege, std/math.lyu hatte 112
#      — darunter fremde (Prelude) und unit-interne Namen. Mit den
#      Konstantenwerten aus #2014 waere das interne sogar BENUTZBAR geworden,
#      sobald die Quelle fehlt.
#
# GEMESSEN WIRD DIE WIRKUNG: was steht in der Datei, und was laesst sich von
# aussen erreichen. Eine reine Zahlenpruefung ("weniger Symbole") waere auch
# von einem Filter erfuellt, der zu viel wegwirft — deshalb steht daneben
# immer die Gegenprobe, dass die Schnittstelle vollstaendig bleibt.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

mkdir -p "$TMP/w/bib"
cat > "$TMP/w/bib/schnitt.lyx" <<'EOF'
unit bib.schnitt;
pub con OEFFENTLICH: int64 := 7;
pub fn Sichtbar(): int64 { return 1; }
con INTERN: int64 := 99;
fn Verborgen(): int64 { return 2; }
EOF

( cd "$TMP/w" && timeout 120 "$LYXC" --compile-unit bib/schnitt.lyx -o bib/schnitt.lyu ) >"$TMP/cu.log" 2>&1
if [ ! -f "$TMP/w/bib/schnitt.lyu" ]; then
  nok "die Unit laesst sich nicht vorkompilieren"; echo; echo "Ergebnis: $PASS PASS, $FAIL FAIL"; exit 1
fi

echo "--- Was steht in der .lyu? ---"
info="$( cd "$ROOT" && timeout 60 "$LYXC" --unit-info "$TMP/w/bib/schnitt.lyu" 2>/dev/null )"

# Beide Richtungen: die Schnittstelle MUSS drin sein, das Interne NICHT.
if printf '%s' "$info" | grep -q "OEFFENTLICH" && printf '%s' "$info" | grep -q "Sichtbar"; then
  ok "die oeffentlichen Namen stehen in der .lyu"
else
  nok "ein oeffentlicher Name fehlt in der .lyu"
fi
if printf '%s' "$info" | grep -qE "INTERN|Verborgen"; then
  nok "unit-interne Namen stehen in der .lyu: $(printf '%s' "$info" | grep -oE 'INTERN|Verborgen' | tr '\n' ' ')"
else
  ok "unit-interne Namen bleiben draussen"
fi
# Fremde Namen: das Prelude steht in JEDER Datei, gehoert aber keiner Unit.
if printf '%s' "$info" | grep -qE "PROT_RW|MAP_ANON|ARCH_X86_64"; then
  nok "fremde (Prelude-)Namen stehen in der .lyu"
else
  ok "fremde Namen (Prelude) bleiben draussen"
fi

echo
echo "--- #2035: pub gilt auch fuer Konstanten ---"
cat > "$TMP/w/haupt_ok.lyx" <<'EOF'
unit main;
import std.io;
import bib.schnitt;
fn main(): int64 { PrintLn(IntToStr(OEFFENTLICH)); return 0; }
EOF
cat > "$TMP/w/haupt_priv.lyx" <<'EOF'
unit main;
import std.io;
import bib.schnitt;
fn main(): int64 { PrintLn(IntToStr(INTERN)); return 0; }
EOF

# Die Schnittstelle bleibt erreichbar — sonst ist die Verschaerfung ueber das
# Ziel hinausgeschossen.
if ( cd "$TMP/w" && timeout 120 "$LYXC" --std-path="$ROOT" haupt_ok.lyx -o ok1 ) >"$TMP/ok1.log" 2>&1; then
  w="$( cd "$TMP/w" && timeout 60 ./ok1 2>/dev/null )"
  if [ "$w" = "7" ]; then ok "eine pub-Konstante bleibt erreichbar und liefert 7"
  else nok "pub-Konstante liefert '$w' statt 7"; fi
else
  nok "eine pub-Konstante ist nicht mehr erreichbar — die Verschaerfung geht zu weit"
fi

# Und die private wird abgewiesen, MIT Quelle wie ohne.
if ( cd "$TMP/w" && timeout 120 "$LYXC" --std-path="$ROOT" haupt_priv.lyx -o pv1 ) >"$TMP/pv1.log" 2>&1; then
  nok "private Konstante ist mit Quelle von aussen lesbar: $( cd "$TMP/w" && ./pv1 2>/dev/null )"
else
  ok "private Konstante wird mit Quelle abgewiesen"
fi
mv "$TMP/w/bib/schnitt.lyx" "$TMP/schnitt.weg"
if ( cd "$TMP/w" && timeout 120 "$LYXC" --std-path="$ROOT" haupt_priv.lyx -o pv2 ) >"$TMP/pv2.log" 2>&1; then
  nok "private Konstante ist OHNE Quelle lesbar: $( cd "$TMP/w" && ./pv2 2>/dev/null )"
else
  ok "private Konstante wird auch OHNE Quelle abgewiesen (der Wert steht nicht in der .lyu)"
fi

echo
echo "--- #2035: gleichnamige pub-Konstanten werden gemeldet ---"
#
# Der gefaehrlichere Teil: bis 1.2.5H entschied allein die Import-Reihenfolge,
# welcher Wert gilt — "fehlerfrei uebersetzt, fehlerfrei ausgefuehrt, falsches
# Ergebnis". Bei Funktionen wird das seit #1028 gemeldet, bei Konstanten nicht.
mkdir -p "$TMP/k/bib"
cat > "$TMP/k/bib/a.lyx" <<'EOF'
unit bib.a;
pub con GEMEINSAM: int64 := 1;
EOF
cat > "$TMP/k/bib/b.lyx" <<'EOF'
unit bib.b;
pub con GEMEINSAM: int64 := 2;
EOF
cat > "$TMP/k/haupt.lyx" <<'EOF'
unit main;
import std.io;
import bib.a;
import bib.b;
fn main(): int64 { PrintLn(IntToStr(GEMEINSAM)); return 0; }
EOF
if ( cd "$TMP/k" && timeout 120 "$LYXC" --std-path="$ROOT" haupt.lyx -o kx ) >"$TMP/k.log" 2>&1; then
  nok "zwei gleichnamige pub-Konstanten gingen durch — der Wert haengt an der Import-Reihenfolge ($( cd "$TMP/k" && ./kx 2>/dev/null ))"
else
  if grep -q "mehrdeutiges Symbol" "$TMP/k.log"; then
    ok "gleichnamige pub-Konstanten werden als mehrdeutig gemeldet"
  else
    nok "abgewiesen, aber mit anderer Begruendung: $(grep -m1 -E 'error' "$TMP/k.log")"
  fi
fi

echo
echo "--- Die stdlib bleibt vollstaendig nutzbar ---"
#
# Gegenprobe zum Filter: was frueher benutzbar war, muss es bleiben. Ein
# Filter, der zu viel wegwirft, faellt hier auf — und zwar an einer echten
# Unit, nicht am eigenen Minimalbeispiel.
cat > "$TMP/std.lyx" <<'EOF'
unit main;
import std.io;
import std.math;
import std.string;
fn main(): int64 {
  PrintLn(IntToStr(Abs64(0 - 5)));
  PrintLn(IntToStr(Min64(3, 9)));
  PrintLn(IntToStr(StrLen("abc")));
  return 0;
}
EOF
if ( cd "$ROOT" && timeout 180 "$LYXC" --std-path="$ROOT" "$TMP/std.lyx" -o "$TMP/stdbin" ) >"$TMP/std.log" 2>&1; then
  aus="$(timeout 60 "$TMP/stdbin" 2>/dev/null | tr '\n' '|')"
  if [ "$aus" = "5|3|3|" ]; then
    ok "std.math und std.string bleiben nutzbar (5|3|3)"
  else
    nok "stdlib liefert [$aus] statt 5|3|3"
  fi
else
  nok "die stdlib laesst sich nicht mehr benutzen: $(grep -m1 -E 'error' "$TMP/std.log")"
fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
