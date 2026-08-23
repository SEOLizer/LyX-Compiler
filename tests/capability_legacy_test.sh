#!/usr/bin/env bash
# tests/capability_legacy_test.sh — #1340, Schritt 1: das Legacy-Gate.
#
# README.md:179 und capabilities.md:21 sagen zu: ohne `@capabilities` laeuft ein
# Programm ohne jede Einschraenkung. Zwei Stellen hielten sich nicht daran und
# behandelten "gar nicht annotiert" wie "@capabilities([])":
#
#   * das LCBS-Pruning (cap_shouldStrip) warf jede Unit weg, deren Bedarf sich
#     mit der leeren Wurzelmenge nicht schnitt,
#   * Regel 1 (ComputeNoGrant) meldete jede deklarierte Capability als im
#     Parent fehlend.
#
# Solange keine Unit in std/ deklariert, faellt das nicht auf — deshalb ist der
# Zustand heute stabil. Mit der ERSTEN Deklaration waere jedes Programm ohne
# Annotation betroffen, einschliesslich src/lyxc.lyx. Dieser Test haelt das
# Gate fest, BEVOR die 421 Units annotiert werden.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$ROOT/tests/lib/lyxc_guard.sh"; [ -f "$_g" ] && . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1${2:+: $2}"; FAIL=$((FAIL+1)); }

mkdir -p "$TMP/p/paket"
cat > "$TMP/p/paket/mituc.lyx" <<'EOF'
@capabilities([fs.read])
unit paket.mituc;
pub fn Wert(): int64 { return 33; }
EOF

baut_und_rechnet() {   # Name, Quelldatei, erwarteter Rueckgabewert
  if ! (cd "$TMP/p" && "$LYXC" -I . "$2" -o "$TMP/p/a.out") >"$TMP/a.log" 2>&1; then
    no "$1" "$(grep -m1 -iE 'sema error|parse error' "$TMP/a.log")"
    return
  fi
  "$TMP/p/a.out"; local rc=$?
  if [ "$rc" = "$3" ]; then ok "$1 (= $3)"; else no "$1" "rc=$rc statt $3"; fi
}

# --- Der Kern: unannotiert heisst unbeschraenkt -----------------------------
# Ohne das Gate wird paket.mituc weggeworfen und der Fehler erscheint als
# `undefined function 'Wert'` — an der Nutzung statt an der Ursache.
cat > "$TMP/p/ohne.lyx" <<'EOF'
import paket.mituc;
fn main(): int64 { return Wert(); }
EOF
baut_und_rechnet "unannotiertes Programm nutzt annotierte Unit" ohne.lyx 33

# --- Die Durchsetzung darf dabei nicht verlorengehen ------------------------
# Wer @capabilities schreibt, trifft eine Aussage — auch mit leerer Liste.
cat > "$TMP/p/leer.lyx" <<'EOF'
@capabilities([])
import paket.mituc;
fn main(): int64 { return Wert(); }
EOF
AUS=$(cd "$TMP/p" && "$LYXC" -I . leer.lyx -o "$TMP/p/leer.out" 2>&1)
if [ -x "$TMP/p/leer.out" ] && "$TMP/p/leer.out" >/dev/null 2>&1; then
  no "@capabilities([]) wirkt weiterhin" "die Unit kommt durch, obwohl nichts gewaehrt ist"
else
  ok "@capabilities([]) wirkt weiterhin"
fi
# Und der Ausfall muss die URSACHE nennen, nicht nur die Folge.
if echo "$AUS" | grep -q "wegen fehlender Capabilities entfernt"; then
  ok "der Ausfall nennt das Pruning als Ursache"
else
  no "der Ausfall nennt das Pruning als Ursache" "nur '$(echo "$AUS" | grep -m1 -i 'sema error')'"
fi

# --- Mit passender Capability geht es --------------------------------------
cat > "$TMP/p/passend.lyx" <<'EOF'
@capabilities([fs.read])
import paket.mituc;
fn main(): int64 { return Wert(); }
EOF
baut_und_rechnet "annotiertes Programm mit passender Capability" passend.lyx 33

# --- Und der Bestand: lyxc selbst hat kein @capabilities --------------------
# Das ist der Fall, der bei der ersten std-Deklaration zuerst umfaellt.
if grep -q "^@capabilities" "$ROOT/src/lyxc.lyx"; then
  echo "SKIP src/lyxc.lyx traegt inzwischen @capabilities — der Fall unten ist gegenstandslos"
else
  ok "src/lyxc.lyx traegt weiterhin kein @capabilities (Legacy-Fall bleibt gedeckt)"
fi

echo "----"
echo "$PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
