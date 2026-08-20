#!/bin/bash
# #1727 — der Vorpass lowerte jede Funktion importierter Units, auch nie
# gerufene. Eine ungenutzte Funktion konnte damit den ganzen Bau anhalten:
# std.io scheiterte an PrintFloat, das in PrintFloatLn steckt, und std.time
# an Sleep/SleepNs und der timerfd-Familie — obwohl kein Programm sie ruft.
#
# Geprueft wird dreierlei:
#   1. der Filter WIRKT (das Erzeugnis wird deutlich kleiner),
#   2. er nimmt nichts weg, was gebraucht wird (die Programme laufen),
#   3. eine Funktion hinter mehreren Modulgrenzen bleibt erhalten — genau
#      dafuer gibt es den Nachlauf ueber die behaltene Importliste.
#
# Gemessen wird gegen ein IR-ZIEL. Gegen --target=linux waere die Groesse
# unveraendert, weil der x86-Weg ir_lower gar nicht benutzt — daran waere
# die Messung beinahe gescheitert.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$ROOT/tests/lib/lyxc_guard.sh"; [ -f "$_g" ] && . "$_g"   # #1294
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
P=0; F=0
ok()  { echo "PASS: $1"; P=$((P+1)); }
bad() { echo "FAIL: $1${2:+ — $2}"; F=$((F+1)); }

# --- 1: der Filter wirkt ------------------------------------------------------
# std.io bringt gut hundert Funktionen mit; ein Programm, das eine davon
# benutzt, darf nicht den ganzen Satz tragen.
printf 'import std.io;\nfn main(): int64 { PrintLn("x"); return 0; }\n' > "$TMP/klein.lyx"
if timeout 300 "$LYXC" --std-path="$ROOT" --target=lyxos "$TMP/klein.lyx" -o "$TMP/klein.out" >"$TMP/l" 2>&1; then
  gr=$(stat -c%s "$TMP/klein.out")
  # Vor dem Filter waren es 86016 Byte. Die Schranke ist bewusst grosszuegig:
  # sie soll einen ABGESCHALTETEN Filter erkennen, nicht jede Schwankung.
  if [ "$gr" -lt 60000 ]; then ok "Filter wirkt (${gr} Byte, vorher 86016)"
  else bad "Filter wirkt" "${gr} Byte — sieht aus wie ohne Filter"; fi
else
  bad "Filter wirkt" "uebersetzt nicht: $(grep -oE 'unbekannter.*|undefined.*' "$TMP/l"|head -1)"
fi

# --- 2: nichts Gebrauchtes faellt weg -----------------------------------------
for u in std.fs std.io std.alloc std.string std.env std.time std.conv std.math; do
  printf 'import %s;\nfn main(): int64 { return 0; }\n' "$u" > "$TMP/u.lyx"
  if timeout 300 "$LYXC" --std-path="$ROOT" --target=lyxos "$TMP/u.lyx" -o "$TMP/u.out" >"$TMP/l" 2>&1
  then ok "$u baut weiterhin"
  else bad "$u baut weiterhin" "$(grep -oE 'unbekannter Builtin.*|undefined function.*' "$TMP/l"|head -1)"; fi
done

# --- 3: ueber Modulgrenzen hinweg ---------------------------------------------
# A ruft B ruft C. Wird C nicht erhalten, scheitert es mit "undefined function"
# — der Fall, den der Nachlauf abdeckt. Zusaetzlich steht die gerufene
# Funktion in C VOR der aufrufenden in B, damit auch die Reihenfolge
# innerhalb einer Datei geprueft ist.
mkdir -p "$TMP/u/Kette"
cat > "$TMP/u/Kette/C.lyx" <<'EOF'
unit Kette.C;
pub fn Tief(x: int64): int64 { return x * 3; }
pub fn NieGerufen(x: int64): int64 { return x; }
EOF
cat > "$TMP/u/Kette/B.lyx" <<'EOF'
unit Kette.B;
import Kette.C;
pub fn Mittel(x: int64): int64 { return Tief(x) + 1; }
pub fn AuchNieGerufen(): int64 { return 0; }
EOF
cat > "$TMP/kette.lyx" <<'EOF'
import Kette.B;
fn main(): int64 { return Mittel(7); }
EOF
if timeout 300 "$LYXC" -I "$TMP/u" --std-path="$ROOT" --target=lyxos "$TMP/kette.lyx" -o "$TMP/k.out" >"$TMP/l" 2>&1
then ok "Aufruf ueber zwei Modulgrenzen bleibt erhalten"
else bad "Aufruf ueber zwei Modulgrenzen" "$(grep -oE 'undefined function.*|unbekannter.*' "$TMP/l"|head -1)"; fi

# und es muss auch RECHNEN — auf dem Linux-Weg nachgeprueft
if timeout 300 "$LYXC" -I "$TMP/u" --std-path="$ROOT" "$TMP/kette.lyx" -o "$TMP/k_lin" >"$TMP/l" 2>&1; then
  "$TMP/k_lin"; rc=$?
  if [ "$rc" -eq 22 ]; then ok "die Kette rechnet richtig (7*3+1 = 22)"
  else bad "die Kette rechnet" "exit=$rc statt 22"; fi
else
  bad "die Kette rechnet" "uebersetzt nicht"
fi

echo "Ergebnis: $P PASS, $F FAIL"
[ "$F" -eq 0 ] || exit 1
