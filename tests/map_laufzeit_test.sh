#!/usr/bin/env bash
# tests/map_laufzeit_test.sh — #2150: Map-Laufzeit waechst, Schluessel 0,
# Map auf Modulebene, `x in a..`, panic-Meldung auf lyxos.
#
# Bis 1.2.16B:
#   (1) Die Map hatte eine FESTE Kapazitaet (x86 und IR): die siebzehnte
#       Eintragung in eine Map mit 16 Plaetzen sondierte endlos. Und der
#       Schluessel 0 galt als "frei": `m[0] := v` legte jedesmal einen neuen
#       Eintrag an. Jetzt: Eintraege mit eigenem belegt-Feld in einem eigenen
#       Block, Verdopplung ab drei Viertel Fuellung (codegen_x86.lyx,
#       tools/map_laufzeit_x86.s; ir_lower.lyx, _mapZugriff).
#   (2) `x in a..` (offenes Ende, #1129) liess der Parser nicht zu.
#   (3) `var g: Map<..>;` auf Modulebene: x86 wies `g[k] := v` ab, der IR-Weg
#       liess den Slot 0 (SIGSEGV).
#   (4) _lyx_map_new pruefte mmap nicht.
#   (5) lyxos: `panic("...")` in Anweisungsform endete stumm.
#
# Der Weg wird ueber Werte gemessen, die NUR mit Wachstum und belegt-Feld
# stimmen: 1000 Schluessel im Abstand 4096 (gleiche untere Bits — jede
# Sondierkette lang), Summe aller gelesenen Werte, Anzahl, ein fehlender
# Schluessel; Schluessel 0 zweimal gesetzt.
set -uo pipefail
ulimit -c 0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
. "$(dirname "$0")/lib/qemu.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

if [ -z "$QEMU_ARM64" ] || [ -z "$QEMU_RISCV64" ]; then echo "FAIL qemu fuer arm64/riscv fehlt — NICHT gemessen"; exit 1; fi

lauf() {  # ziel, binary
  case "$1" in
    linux) ( cd "$TMP" && timeout 30 "$2" ) ;;
    arm64) ( cd "$TMP" && timeout 30 "$QEMU_ARM64" "$2" ) ;;
    riscv) ( cd "$TMP" && timeout 30 "$QEMU_RISCV64" "$2" ) ;;
  esac
}

baue() {  # ziel, datei, ausgabe
  ( cd "$ROOT" && timeout 240 "$LYXC" --std-path="$ROOT" --target=$1 "$2" -o "$3" ) >"$3.log" 2>&1
}

# pruefe name datei soll-stdout [ziele]
pruefe() {
  local t ziele="${4:-linux arm64 riscv}"
  for t in $ziele; do
    rm -f "$TMP/p"
    if ! baue $t "$2" "$TMP/p"; then
      nok "$1 [$t]: uebersetzt nicht ($(grep -m1 -iE 'error|fehler' "$TMP/p.log"))"; continue
    fi
    local aus rc
    aus="$(lauf $t "$TMP/p" 2>&1 | tr '\0\n' '@|')"; rc=${PIPESTATUS[0]}
    if [ "$aus" = "$3" ] && [ "$rc" = 0 ]; then ok "$1 [$t]: [$aus]"
    else nok "$1 [$t]: [$aus] rc=$rc statt [$3] rc=0"; fi
  done
}

# --- (1) Schluessel 0 und Wachstum, Ganzzahl --------------------------------
cat > "$TMP/int.lyx" <<'EOF'
fn main(): int64 {
  var m: Map<int64, int64> := {1: 1};
  m[0] := 5; m[0] := 6;
  PrintInt(m[0]); Print(" "); PrintInt(len(m)); Print("|");
  // Gegenseite: ein fehlender Schluessel liest 0 und kommt nicht hinzu
  PrintInt(m[9]); Print(" "); PrintInt(len(m)); Print("|");
  var i: int64 := 0;
  while (i < 1000) { m[i * 4096 + 4096] := i + 1; i := i + 1; }
  var sum: int64 := 0;
  i := 0;
  while (i < 1000) { sum := sum + m[i * 4096 + 4096]; i := i + 1; }
  PrintInt(len(m)); Print(" "); PrintInt(sum); Print(" ");
  if (4096 * 1000 in m) { Print("j"); } else { Print("n"); }
  if (4096 * 1001 in m) { Print("j"); } else { Print("n"); }
  // Ueberschreiben nach dem Wachsen: keine neuen Eintraege
  m[4096] := 77;
  PrintInt(m[4096]); Print(" "); PrintInt(len(m)); Print(" "); PrintInt(m[0]); Print("\n");
  return 0;
}
EOF
pruefe "Map<int64>: Schluessel 0, Wachstum" "$TMP/int.lyx" "6 2|0 2|1002 500500 jn77 1002 6|"

# --- (1) pchar-Schluessel ueber die Wachstumsgrenze -------------------------
cat > "$TMP/str.lyx" <<'EOF'
fn main(): int64 {
  var s: Map<pchar, int64> := {"a": 1};
  s["b"] := 2; s["c"] := 3; s["d"] := 4; s["e"] := 5; s["f"] := 6; s["g"] := 7;
  s["h"] := 8; s["ij"] := 9; s["kl"] := 10; s["mn"] := 11; s["op"] := 12; s["qr"] := 13;
  s["a"] := 100;
  PrintInt(len(s)); Print(" "); PrintInt(s["a"]); Print(" "); PrintInt(s["mn"]); Print(" ");
  PrintInt(s["qr"]); Print(" "); PrintInt(s["zz"]); Print(" ");
  if ("ij" in s) { Print("j"); } else { Print("n"); }
  if ("i" in s) { Print("j"); } else { Print("n"); }
  Print("\n");
  return 0;
}
EOF
pruefe "Map<pchar>: Wachstum, Inhaltsvergleich" "$TMP/str.lyx" "13 100 11 13 0 jn|"

# --- (3) Map auf Modulebene ---------------------------------------------------
cat > "$TMP/global.lyx" <<'EOF'
var g: Map<int64, int64>;
var gs: Map<pchar, int64>;
fn fuelle() {
  var i: int64 := 0;
  while (i < 40) { g[i] := i * 2; i := i + 1; }
}
fn main(): int64 {
  fuelle();
  gs["x"] := 1; gs["y"] := 2; gs["x"] := 3;
  PrintInt(len(g)); Print(" "); PrintInt(g[0]); Print(" "); PrintInt(g[39]); Print(" ");
  PrintInt(len(gs)); Print(" "); PrintInt(gs["x"]); Print("\n");
  return 0;
}
EOF
pruefe "Map auf Modulebene" "$TMP/global.lyx" "40 0 78 2 3|"

# --- std.stats liest die Bauart der Map --------------------------------------
cat > "$TMP/stats.lyx" <<'EOF'
import std.stats;
fn main(): int64 {
  var m: Map<int64, int64> := {0: 0, 1: 0 - 5, 2: 7};
  var i: int64 := 10;
  while (i < 30) { m[i] := 1; i := i + 1; }
  PrintInt(MapCount(m as int64)); Print(" "); PrintInt(MapSum(m as int64)); Print(" ");
  PrintInt(MapMin(m as int64)); Print(" "); PrintInt(MapMax(m as int64)); Print("\n");
  return 0;
}
EOF
pruefe "std.stats ueber die Map" "$TMP/stats.lyx" "23 22 -5 7|" "linux arm64"

# --- (2) offenes Ende rechts von `in` ----------------------------------------
cat > "$TMP/offen.lyx" <<'EOF'
fn main(): int64 {
  var x: int64 := 50;
  if (x in 10..) { Print("j"); } else { Print("n"); }
  if (x in 51..) { Print("j"); } else { Print("n"); }
  if (x in 50..) { Print("j"); } else { Print("n"); }
  Print("\n");
  return 0;
}
EOF
pruefe "x in a.." "$TMP/offen.lyx" "jnj|"

# Gegenseite: an jeder anderen Stelle hat ein offener Bereich keine Grenze
cat > "$TMP/offen_for.lyx" <<'EOF'
fn main(): int64 {
  for i in 0.. { PrintInt(i); }
  return 0;
}
EOF
if baue linux "$TMP/offen_for.lyx" "$TMP/of"; then nok "for i in 0.. uebersetzt"
elif grep -q "keine obere Grenze" "$TMP/of.log"; then ok "for i in 0..: laut abgewiesen"
else nok "for i in 0..: $(head -c 200 "$TMP/of.log")"; fi
cat > "$TMP/offen_var.lyx" <<'EOF'
fn main(): int64 {
  var r: int64 := 1..;
  return 0;
}
EOF
if baue linux "$TMP/offen_var.lyx" "$TMP/ov"; then nok "var r := 1.. uebersetzt"
elif grep -q "nur rechts von" "$TMP/ov.log"; then ok "var r := 1..: laut abgewiesen"
else nok "var r := 1..: $(head -c 200 "$TMP/ov.log")"; fi

# --- (4) mmap scheitert beim Wachsen: Meldung statt Absturz (x86) -----------
cat > "$TMP/oom.lyx" <<'EOF'
fn main(): int64 {
  var m: Map<int64, int64>;
  var i: int64 := 0;
  while (i < 50000000) { m[i] := i; i := i + 1; }
  return 0;
}
EOF
if baue linux "$TMP/oom.lyx" "$TMP/oom"; then
  err="$( ( ulimit -v 200000; cd "$TMP" && timeout 60 ./oom ) 2>&1 >/dev/null )"; rc=$?
  if [ "$rc" = 1 ] && echo "$err" | grep -q "Speicheranforderung fehlgeschlagen (mmap)"; then ok "Wachsen ohne Speicher: Meldung, rc 1"
  else nok "Wachsen ohne Speicher: rc=$rc [$err]"; fi
else nok "oom: uebersetzt nicht"; fi

# --- (5) lyxos: panic in Anweisungsform schreibt die Meldung ----------------
# Lokal laeuft kein lyxos-Abbild mit Ausgabe (CLAUDE.md, LBF-Lader) — gemessen
# wird am Erzeugnis: der stderr-Schreibweg (mov rax, 0x0203) steht genau dann
# im Code, wenn panic eine Meldung traegt.
cat > "$TMP/pan.lyx" <<'EOF'
fn main(): int64 {
  var x: int64 := 3;
  if (x > 2) { panic("kaputt"); }
  return 0;
}
EOF
cat > "$TMP/ohne.lyx" <<'EOF'
fn main(): int64 {
  var x: int64 := 3;
  if (x > 2) { return 1; }
  return 0;
}
EOF
zaehl() { python3 -c "import sys; d=open(sys.argv[1],'rb').read(); print(d.count(bytes([0x48,0xB8,0x03,0x02,0,0,0,0,0,0])))" "$1"; }
if baue lyxos "$TMP/pan.lyx" "$TMP/pan.lbf" && baue lyxos "$TMP/ohne.lyx" "$TMP/ohne.lbf"; then
  a="$(zaehl "$TMP/pan.lbf")"; b="$(zaehl "$TMP/ohne.lbf")"
  if [ "$a" = 1 ] && [ "$b" = 0 ]; then ok "lyxos panic: stderr-Schreibweg vorhanden ($a), ohne panic keiner ($b)"
  else nok "lyxos panic: mit $a, ohne $b (erwartet 1/0)"; fi
else nok "lyxos panic: uebersetzt nicht"; fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
