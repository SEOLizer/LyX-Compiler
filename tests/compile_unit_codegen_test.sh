#!/usr/bin/env bash
# tests/compile_unit_codegen_test.sh — #1587.
#
# `--compile-unit` endete nach sema. Jeder Fehler, den erst der Codegen sieht,
# blieb damit unentdeckt, bis irgendein Programm die Unit importierte:
# DIESELBE DATEI war als Programm rot und als Unit gruen.
#
# Fuer `make precompile-units` hiess das, dass eine gruene Vorkompilierung
# nichts belegt — genau die Sorte Zusicherung, auf die man sich verlaesst, ohne
# sie geprueft zu haben.
#
# Jetzt laeuft der Codegen mit; sein Erzeugnis wird verworfen, gebraucht wird
# allein die Diagnose. Eine Unit hat kein `main` — der Einsprungpunkt bleibt
# deshalb im Pruefmodus ohne Ziel. JEDER ANDERE unaufgeloeste Name bleibt ein
# Fehler, sonst pruefte der Lauf weniger, als er verspricht.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# ===========================================================================
# Der Fall aus dem Bericht: nicht konstanter globaler Startwert
# ===========================================================================
cat > "$TMP/kaputt.lyx" <<'EOF'
unit kaputt;
fn F(): int64 { return 1; }
var g: int64 := F() + 1;
EOF

# Erst der Beleg, dass der Codegen das WIRKLICH beanstandet — sonst prueft der
# Test unten nichts.
cat > "$TMP/alsprog.lyx" <<'EOF'
fn F(): int64 { return 1; }
var g: int64 := F() + 1;
fn main(): int64 { return g; }
EOF
if timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/alsprog.lyx" -o "$TMP/alsprog" >"$TMP/p.log" 2>&1; then
  no "Vorbedingung: der Codegen beanstandet den Startwert" "als Programm klaglos uebersetzt"
else
  grep -q "nicht bekannt" "$TMP/p.log" \
    && ok "Vorbedingung: als Programm meldet der Codegen den Startwert" \
    || no "Vorbedingung" "andere Meldung: $(grep -m1 -i error "$TMP/p.log")"
fi

# Und jetzt derselbe Inhalt als Unit.
if timeout 200 "$LYXC" --std-path="$ROOT" --compile-unit "$TMP/kaputt.lyx" -o "$TMP/kaputt.lyu" >"$TMP/u.log" 2>&1; then
  no "#1587: --compile-unit meldet den Codegen-Fehler" "rc=0 — die .lyu wurde geschrieben"
else
  grep -q "nicht bekannt" "$TMP/u.log" \
    && ok "#1587: --compile-unit meldet denselben Fehler wie der Programmbau" \
    || no "#1587: Meldung" "$(grep -m1 -i error "$TMP/u.log")"
fi

# Keine .lyu, wenn die Unit nicht traegt — sonst liegt eine Datei herum, die
# nach Erfolg aussieht.
if [ -f "$TMP/kaputt.lyu" ]; then
  no "#1587: keine .lyu bei Fehler" "die Datei wurde trotzdem geschrieben"
else
  ok "#1587: bei einem Fehler entsteht keine .lyu"
fi

# ===========================================================================
# Gegenprobe: gesunde Units gehen weiterhin durch
# ===========================================================================
cat > "$TMP/gut.lyx" <<'EOF'
unit gut;
pub con MAX: int64 := 42;
pub fn Doppelt(x: int64): int64 { return x * 2; }
var zaehler: int64 := 7;
EOF
if timeout 200 "$LYXC" --std-path="$ROOT" --compile-unit "$TMP/gut.lyx" -o "$TMP/gut.lyu" >"$TMP/g.log" 2>&1; then
  [ -f "$TMP/gut.lyu" ] && ok "#1587: gesunde Unit uebersetzt und schreibt ihre .lyu" \
                        || no "#1587: gesunde Unit" "keine .lyu geschrieben"
else
  no "#1587: gesunde Unit" "$(grep -m1 -iE 'error' "$TMP/g.log")"
fi

# Eine echte Unit der Standardbibliothek — sie hat kein `main`, und genau das
# darf der Pruefmodus nicht beanstanden.
for u in std/math.lyx std/string.lyx std/fs.lyx; do
  if timeout 300 "$LYXC" --std-path="$ROOT" --compile-unit "$ROOT/$u" -o "$TMP/u.lyu" >"$TMP/s.log" 2>&1; then
    ok "#1587: $u uebersetzt als Unit"
  else
    no "#1587: $u" "$(grep -m1 -iE 'error' "$TMP/s.log")"
  fi
done

# Ein WIRKLICH unbekannter Name muss weiter scheitern — die Ausnahme gilt nur
# fuer `main`.
cat > "$TMP/fehlt.lyx" <<'EOF'
unit fehlt;
pub fn Ruft(): int64 { return GibtsNicht(1); }
EOF
if timeout 200 "$LYXC" --std-path="$ROOT" --compile-unit "$TMP/fehlt.lyx" -o "$TMP/fehlt.lyu" >"$TMP/f.log" 2>&1; then
  no "#1587: unbekannter Aufruf in einer Unit" "klaglos uebersetzt"
else
  ok "#1587: unbekannter Aufruf wird weiterhin gemeldet"
fi

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
