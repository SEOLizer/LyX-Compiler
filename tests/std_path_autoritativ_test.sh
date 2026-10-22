#!/usr/bin/env bash
# tests/std_path_autoritativ_test.sh — #2201: bei gesetztem --std-path gilt der
# angegebene Baum; /usr/include/lyx/units wird dann NICHT mehr durchsucht.
#
# Warum es diesen Test gibt:
#
# `std.cpu.dispatch` wurde mit #2186 entfernt. tests/stdlib_z20_test.sh
# importierte die Unit weiter und blieb auf dem Entwicklungsrechner GRUEN —
# dort hatte eine frueher installierte .deb ihre Kopie in /usr/include liegen
# gelassen, und der Resolver nahm sie, obwohl --std-path auf das Repo zeigte:
#
#   [import] std.cpu.dispatch -> /usr/include/lyx/units/std/cpu/dispatch.lyx
#   [import] std.cpu.features -> std/cpu/features.lyx
#
# Eine Unit aus dem Repo, eine aus der Installation, im selben Aufruf. Alle
# sieben Testziele liefen lokal durch; gemeldet hat die Luecke erst die CI, die
# keine Installation hat. Ein lokaler Nachweis war an dieser Stelle wertlos.
#
# Gemessen wird deshalb die WIRKUNG in beiden Richtungen, und der Fall wird
# nachgestellt statt vorausgesetzt: der Test legt sich seinen eigenen
# "Installationsbaum" an, damit er auf jeder Maschine dasselbe prueft — auf
# einer ohne /usr/include/lyx/units waere die erste Haelfte sonst wertlos.
#
# Die Reihenfolge VOR dem Installationspfad ist unberuehrt: relativ zum
# Arbeitsverzeichnis zuerst, dann Paketpfade, dann -I, dann --std-path. Nur
# der Sprung in die Installation entfaellt. tests/dangling_import_test.sh ruft
# `--std-path=std` aus dem Repo-Wurzelverzeichnis auf und loest `std.text`
# ueber den CWD-Weg auf — haette dieser Fix auch den angefasst, waere der Test
# zu Recht rot geworden.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
no()  { echo "FAIL $1${2:+: $2}"; FAIL=$((FAIL+1)); }

# Ein eigener Baum, der die Rolle der Installation spielt, plus ein zweiter,
# der die Rolle von --std-path spielt und die Unit NICHT enthaelt.
mkdir -p "$TMP/inst/std" "$TMP/eigen/std"
cat > "$TMP/inst/std/nurinstalliert.lyx" <<'EOF'
unit std.nurinstalliert;
pub fn NurInstalliertWert(): int64 { return 77; }
EOF
# Der eigene Baum braucht wenigstens eine Unit, damit er als Baum erkennbar
# ist und der Fall nicht aus einem anderen Grund scheitert.
cat > "$TMP/eigen/std/eigen.lyx" <<'EOF'
unit std.eigen;
pub fn EigenWert(): int64 { return 5; }
EOF

cat > "$TMP/p.lyx" <<'EOF'
import std.nurinstalliert;
fn main(): int64 { return NurInstalliertWert(); }
EOF

# --- Richtung 1: mit --std-path darf die fremde Kopie NICHT genommen werden --
# Gemessen wird aus einem leeren Verzeichnis, damit der CWD-Weg nicht
# mitspricht — sonst prueft der Fall etwas anderes als gemeint.
out=$( cd "$TMP/leer" 2>/dev/null || { mkdir -p "$TMP/leer"; cd "$TMP/leer"; }
       "$LYXC" --std-path="$TMP/eigen" -I"$TMP/nichtda" "$TMP/p.lyx" -o "$TMP/p" 2>&1 )
if echo "$out" | grep -q "Modul nicht gefunden"; then
  ok "mit --std-path wird eine fremde Unit nicht still genommen"
else
  no "mit --std-path wird eine fremde Unit nicht still genommen" "$(echo "$out" | head -2)"
fi
# Die Meldung muss sagen, WARUM nicht gefunden wurde — sonst sucht der
# naechste an der falschen Stelle.
if echo "$out" | grep -q "NICHT durchsucht"; then
  ok "die Meldung nennt den uebersprungenen Pfad"
else
  no "die Meldung nennt den uebersprungenen Pfad" "Begruendung fehlt"
fi

# --- Richtung 2: OHNE --std-path muss sie gefunden werden -------------------
# Sonst waere ein installiertes lyxc kaputt (#1368) — genau die Stufe, die
# diesen Rueckfall ueberhaupt eingefuehrt hat. Der eigene "Installationsbaum"
# steht hier als -I, weil ein Test nicht nach /usr/include schreiben darf.
rm -f "$TMP/p"
if ( cd "$TMP/leer" && "$LYXC" -I"$TMP/inst" "$TMP/p.lyx" -o "$TMP/p" >/dev/null 2>&1 ) && [ -f "$TMP/p" ]; then
  ( ulimit -c 0; "$TMP/p" ); rc=$?
  if [ "$rc" -eq 77 ]; then
    ok "ohne --std-path wird die Unit gefunden und liefert ihren Wert (rc=$rc)"
  else
    no "ohne --std-path wird die Unit gefunden" "rc=$rc erwartet 77"
  fi
else
  no "ohne --std-path wird die Unit gefunden" "uebersetzte nicht"
fi

# --- Der Ausweg, den die Meldung nennt, muss auch gehen ---------------------
rm -f "$TMP/p"
if ( cd "$TMP/leer" && "$LYXC" --std-path="$TMP/eigen" -I"$TMP/inst" "$TMP/p.lyx" -o "$TMP/p" >/dev/null 2>&1 ) \
   && [ -f "$TMP/p" ]; then
  ok "mit --std-path plus ausdruecklichem -I geht es wieder"
else
  no "mit --std-path plus ausdruecklichem -I geht es wieder" "uebersetzte nicht"
fi

# --- Die Stufen davor sind unberuehrt ---------------------------------------
# Eine Unit, die im --std-path-Baum LIEGT, muss weiter gefunden werden.
cat > "$TMP/q.lyx" <<'EOF'
import std.eigen;
fn main(): int64 { return EigenWert(); }
EOF
rm -f "$TMP/q"
if ( cd "$TMP/leer" && "$LYXC" --std-path="$TMP/eigen" "$TMP/q.lyx" -o "$TMP/q" >/dev/null 2>&1 ) && [ -f "$TMP/q" ]; then
  ( ulimit -c 0; "$TMP/q" ); rc=$?
  if [ "$rc" -eq 5 ]; then
    ok "eine Unit im angegebenen Baum wird weiter gefunden (rc=$rc)"
  else
    no "eine Unit im angegebenen Baum wird weiter gefunden" "rc=$rc erwartet 5"
  fi
else
  no "eine Unit im angegebenen Baum wird weiter gefunden" "uebersetzte nicht"
fi

# Und der CWD-Weg bleibt der erste: aus dem Repo-Wurzelverzeichnis mit
# --std-path=std (ein Baum, der std/std/ NICHT hat) muessen die eigenen Units
# weiter aufgehen. Das ist der Fall aus tests/dangling_import_test.sh.
rm -f "$TMP/r"
cat > "$TMP/r.lyx" <<'EOF'
import std.text;
fn main(): int64 { return 0; }
EOF
if ( cd "$ROOT" && "$LYXC" --std-path=std "$TMP/r.lyx" -o "$TMP/r" >/dev/null 2>&1 ) && [ -f "$TMP/r" ]; then
  ok "der CWD-Weg bleibt vor --std-path"
else
  no "der CWD-Weg bleibt vor --std-path" "std.text nicht mehr gefunden"
fi

# --- Die vier Aufloesestellen muessen uebereinstimmen -----------------------
# sema, ir_lower, codegen_x86 und wildcard_import lesen Importe getrennt. Ein
# Weg, der die Unit noch holt, waehrend ein anderer sie verweigert, macht das
# Ergebnis davon abhaengig, welcher zuerst fragt. Geprueft wird deshalb auch
# ein IR-Ziel: dort liest ir_lower.
rm -f "$TMP/p.a64"
out=$( cd "$TMP/leer" && "$LYXC" --std-path="$TMP/eigen" --target=arm64 "$TMP/p.lyx" -o "$TMP/p.a64" 2>&1 )
if [ ! -f "$TMP/p.a64" ] && echo "$out" | grep -q "Modul nicht gefunden"; then
  ok "auch der IR-Weg (arm64) nimmt die fremde Unit nicht"
else
  no "auch der IR-Weg (arm64) nimmt die fremde Unit nicht" "$(echo "$out" | head -2)"
fi

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
