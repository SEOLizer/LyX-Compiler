#!/usr/bin/env bash
# tests/pub_visibility_test.sh — pub wird beim Import ausgewertet (Issue #1035).
#
# Pass1 registrierte JEDE Deklaration einer importierten Unit in der globalen
# Symboltabelle — auch die ohne `pub`. Das Schlüsselwort hatte für Imports
# damit keinerlei Wirkung: jeder unit-interne Helfer war von außen aufrufbar,
# die Unit-Grenze existierte nicht.
#
# Verschärfend: die Tabelle ist flach und `Lookup` durchsucht sie rückwärts.
# Ein Programm mit `import std.alloc` konnte deshalb am öffentlichen `alloc`
# vorbei an einem gleichnamigen PRIVATEN Symbol aus einem ganz anderen Import
# landen — je nach Import-Reihenfolge.
#
# Ein privates Symbol wird jetzt übersprungen; gemeldet wird erst, wenn es gar
# keine öffentliche Fassung gibt. Geprüft wird beides: dass privat wirklich
# unsichtbar ist, und dass öffentliche Namen weiterhin binden.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

mkdir -p "$TMP/lib"
cat > "$TMP/lib/vis.lyx" <<'EOF'
pub fn OeffentlicherHelfer(a: int64): int64 { return a + 1; }
fn PrivaterHelfer(a: int64): int64 { return a + 2; }
pub var g_oeffentlich: int64;
var g_privat: int64;
pub type OeffentlicherTyp = class { x: int64; };
type PrivaterTyp = class { y: int64; };
EOF

# --- 1. Privater Aufruf wird gemeldet ------------------------------------
cat > "$TMP/a1.lyx" <<'EOF'
import lib.vis;
fn main(): int64 { return PrivaterHelfer(1); }
EOF
out=$( cd "$TMP" && LYX_STD_PATH="$ROOT/std" "$LYXC" a1.lyx -o "$TMP/a1" 2>&1 )
if echo "$out" | grep -q "'PrivaterHelfer' ist in Unit 'lib.vis' nicht pub"; then
  ok "privater Aufruf wird gemeldet"
else
  no "privater Aufruf wird gemeldet" "$(echo "$out" | grep -i error | head -1)"
fi

# --- 2. Öffentlicher Aufruf bleibt möglich -------------------------------
cat > "$TMP/a2.lyx" <<'EOF'
import lib.vis;
fn main(): int64 { return OeffentlicherHelfer(41); }
EOF
rm -f "$TMP/a2"
( cd "$TMP" && LYX_STD_PATH="$ROOT/std" "$LYXC" a2.lyx -o "$TMP/a2" >/dev/null 2>&1 )
if [ -f "$TMP/a2" ]; then
  timeout 5 "$TMP/a2" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 42 ]; then ok "oeffentlicher Aufruf (=42)"; else no "oeffentlicher Aufruf" "exit=$rc"; fi
else
  no "oeffentlicher Aufruf" "compile fehlgeschlagen"
fi

# --- 3. Privater TYP wird gemeldet ---------------------------------------
cat > "$TMP/a3.lyx" <<'EOF'
import lib.vis;
fn main(): int64 { var p: PrivaterTyp := new PrivaterTyp(); p.y := 7; return p.y; }
EOF
out=$( cd "$TMP" && LYX_STD_PATH="$ROOT/std" "$LYXC" a3.lyx -o "$TMP/a3" 2>&1 )
if echo "$out" | grep -q "'PrivaterTyp' ist in Unit 'lib.vis' nicht pub"; then
  ok "privater Typ wird gemeldet"
else
  no "privater Typ wird gemeldet" "$(echo "$out" | grep -i error | head -1)"
fi

# --- 4. Öffentlicher Typ bleibt nutzbar ----------------------------------
cat > "$TMP/a4.lyx" <<'EOF'
import lib.vis;
fn main(): int64 { var p: OeffentlicherTyp := new OeffentlicherTyp(); p.x := 42; return p.x; }
EOF
rm -f "$TMP/a4"
( cd "$TMP" && LYX_STD_PATH="$ROOT/std" "$LYXC" a4.lyx -o "$TMP/a4" >/dev/null 2>&1 )
if [ -f "$TMP/a4" ]; then
  timeout 5 "$TMP/a4" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 42 ]; then ok "oeffentlicher Typ (=42)"; else no "oeffentlicher Typ" "exit=$rc"; fi
else
  no "oeffentlicher Typ" "compile fehlgeschlagen"
fi

# --- 5. extern-Bindungen bleiben sichtbar --------------------------------
# Eine FFI-Unit traegt an ihren extern-Deklarationen typischerweise kein pub;
# sie anzubieten IST ihr Zweck. Ohne diese Ausnahme waere jede FFI-Unit
# unbrauchbar — std/audio/alsa.lyx etwa hat an keiner snd_pcm_*-Zeile ein pub.
mkdir -p "$TMP/lib2"
cat > "$TMP/lib2/ffi.lyx" <<'EOF'
extern fn getpid(): int64 link "libc.so.6";
EOF
cat > "$TMP/a5.lyx" <<'EOF'
import lib2.ffi;
fn main(): int64 { var p: int64 := getpid(); if (p > 0) { return 42; } return 1; }
EOF
out=$( cd "$TMP" && LYX_STD_PATH="$ROOT/std" "$LYXC" a5.lyx -o "$TMP/a5" 2>&1 )
if echo "$out" | grep -q "nicht pub"; then
  no "extern-Bindung bleibt sichtbar" "wurde als privat gemeldet"
else
  ok "extern-Bindung bleibt sichtbar"
fi

# --- 6. Privater Name verdeckt keinen oeffentlichen ----------------------
# Der Kern des Auffindens: ein privates Symbol darf die Suche nicht beenden.
mkdir -p "$TMP/lib3"
cat > "$TMP/lib3/oeff.lyx" <<'EOF'
pub fn Zwei(): int64 { return 42; }
EOF
cat > "$TMP/lib3/priv.lyx" <<'EOF'
fn Zwei(): int64 { return 7; }
pub fn Anker(): int64 { return Zwei(); }
EOF
cat > "$TMP/a6.lyx" <<'EOF'
import lib3.oeff;
import lib3.priv;
fn main(): int64 { return Zwei(); }
EOF
rm -f "$TMP/a6"
( cd "$TMP" && LYX_STD_PATH="$ROOT/std" "$LYXC" a6.lyx -o "$TMP/a6" >/dev/null 2>&1 )
if [ -f "$TMP/a6" ]; then
  timeout 5 "$TMP/a6" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 42 ]; then ok "privater Name verdeckt keinen oeffentlichen (=42)"
  else no "privater Name verdeckt keinen oeffentlichen" "exit=$rc, erwartet 42"; fi
else
  no "privater Name verdeckt keinen oeffentlichen" "compile fehlgeschlagen"
fi

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
