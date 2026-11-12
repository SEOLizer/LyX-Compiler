#!/usr/bin/env bash
# tests/profile_argumente_2180_test.sh — --profile laesst die Argumente in Ruhe (#2180).
#
# Die Eintrittsmessung von --profile steht nach dem Rahmenaufbau, aber VOR dem
# Sichern der Argumentregister. Sie fuehrt rdtsc aus, und rdtsc schreibt rdx —
# das dritte Argumentregister. Bis 1.2.20C bekam deshalb jede Funktion mit drei
# oder mehr Parametern als dritten die oberen Bits des Zeitstempelzaehlers;
# ein mit --profile gebauter Compiler starb beim Selbstbau mit SIGSEGV.
#
# Geprueft wird jede Argumentposition 1..8 einzeln (eine Summe koennte einen
# Fehler in einer Position durch einen in einer anderen ausgleichen): dieselbe
# Ausgabe mit und ohne --profile, und dass der Profilbericht die Funktion
# wirklich gemessen hat (sonst waere sie eingebettet und der Test blind).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ulimit -c 0
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# acht Parameter; die Schleife mit Ausgabe haelt die Funktion aus der
# Einbettung heraus. Rueckgabe: Parameter Nummer `welche`.
cat > "$TMP/a.lyx" <<'LYX'
import std.io;
fn waehle(welche: int64, a: int64, b: int64, c: int64, d: int64, e: int64, f: int64, g: int64): int64 {
  var r: int64 := 0; var i: int64 := 0;
  while (i < 1) {
    if (welche == 1) { r := a; } else if (welche == 2) { r := b; } else if (welche == 3) { r := c; }
    else if (welche == 4) { r := d; } else if (welche == 5) { r := e; } else if (welche == 6) { r := f; }
    else if (welche == 7) { r := g; } else { r := welche; }
    if (r < 0) { PrintLn(r); }
    i := i + 1;
  }
  return r;
}
fn main(): int64 {
  var k: int64 := 1;
  while (k <= 8) { PrintLn(waehle(k, 11, 22, 33, 44, 55, 66, 77)); k := k + 1; }
  return 0;
}
LYX
ERW="11 22 33 44 55 66 77 8"
for modus in normal profile; do
  opt=""; [ "$modus" = profile ] && opt="--profile"
  if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" $opt "$TMP/a.lyx" -o "$TMP/a.$modus" >"$TMP/$modus.log" 2>&1); then
    no "$modus" "uebersetzt nicht: $(grep -m1 -i error "$TMP/$modus.log")"; continue; fi
  ( cd "$TMP" && timeout 30 "$TMP/a.$modus" > "$TMP/$modus.out" 2>&1 ); rc=$?
  got="$(grep -v '^\[PROFILE\]' "$TMP/$modus.out" | tr '\n' ' ')"; got="${got% }"
  if [ "$rc" -eq 0 ] && [ "$got" = "$ERW" ]; then ok "$modus: alle acht Positionen richtig"
  else no "$modus" "rc=$rc, '$got' erwartet '$ERW'"; fi
done
if grep -q '^\[PROFILE\] waehle: 8 calls' "$TMP/profile.out" 2>/dev/null; then ok "waehle wurde gemessen (8 Aufrufe)"
else no "Messung" "waehle nicht mit 8 Aufrufen im Bericht: $(grep 'waehle' "$TMP/profile.out")"; fi

echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
