#!/bin/bash
# #1720 Block A — die Gleitkomma-Builtins auf der IR-Strecke.
#
# Sie sind in sema registriert und wurden nur auf dem x86-Schnellweg erzeugt;
# auf JEDEM IR-Ziel fehlten sie. Die IR-Opcodes gab es laengst und die
# Backends erzeugen sie fuer den Operator-Weg (`a + b` mit f64-Operanden) —
# die gleichnamigen Funktionen liefen daran vorbei. Dieselbe Operation, zwei
# Wege, einer davon tot.
#
# Geprueft wird beides: dass sie gegen ein IR-Ziel UEBERSETZEN und dass sie
# auf x86 das Richtige RECHNEN. Nur zu bauen genuegt nicht — eine falsche
# Zuordnung (etwa fLe auf FCMP_LT) baut ebenfalls klaglos.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
P=0; F=0
ok()  { echo "PASS: $1"; P=$((P+1)); }
bad() { echo "FAIL: $1${2:+ — $2}"; F=$((F+1)); }

# --- 1: uebersetzt gegen --target=lyxos ---------------------------------------
for fn in "fAdd(1.5, 2.5)" "fSub(3.0, 1.0)" "fMul(2.0, 4.0)" "fDiv(8.0, 2.0)" \
          "fNeg(1.5)" "fAbs(0.0 - 1.5)"; do
  printf 'fn main(): int64 { var f: f64 := %s; return 0; }\n' "$fn" > "$TMP/t.lyx"
  if timeout 200 "$LYXC" --std-path="$ROOT" --target=lyxos "$TMP/t.lyx" -o "$TMP/t.out" >"$TMP/l" 2>&1
  then ok "lyxos: $fn"; else bad "lyxos: $fn" "$(grep -iE 'unbekannt|error' "$TMP/l" | head -1)"; fi
done
for fn in "fToInt(3.9)" "fLt(1.0, 2.0)" "fGe(2.0, 2.0)"; do
  printf 'fn main(): int64 { return %s; }\n' "$fn" > "$TMP/t.lyx"
  if timeout 200 "$LYXC" --std-path="$ROOT" --target=lyxos "$TMP/t.lyx" -o "$TMP/t.out" >"$TMP/l" 2>&1
  then ok "lyxos: $fn"; else bad "lyxos: $fn" "$(grep -iE 'unbekannt|error' "$TMP/l" | head -1)"; fi
done

# --- 2: fFloor/fCeil/fRound ---------------------------------------------------
# Sie brauchen `roundsd` (SSE4.1) und liessen sich deshalb nicht wie die
# uebrigen zwoelf auf vorhandene IR-Opcodes abbilden. Bis 1.1.4I standen sie
# hier als "muss weiterhin laut scheitern"; mit den IDs 300-302 sind sie
# umgesetzt, und genau dieser Eintrag hat die Aenderung eingefordert — der
# Test wurde rot, weil sie ploetzlich bauten.
for fn in fFloor fCeil fRound; do
  printf 'fn main(): int64 { var f: f64 := %s(1.7); return 0; }\n' "$fn" > "$TMP/t.lyx"
  if timeout 200 "$LYXC" --std-path="$ROOT" --target=lyxos "$TMP/t.lyx" -o "$TMP/t.out" >"$TMP/l" 2>&1
  then ok "lyxos: $fn(1.7)"
  else bad "lyxos: $fn" "$(grep -iE 'unbekannt|Builtin-ID' "$TMP/l" | head -1)"; fi
done

# --- 2b: und sie muessen richtig RUNDEN --------------------------------------
# floor(1.7)=1, ceil(1.2)=2, round(2.5)=2 (kaufmaennisch zur geraden Zahl, wie
# roundsd Modus 0 und wie der x86-Weg). Ein vertauschter Modus baut klaglos.
cat > "$TMP/rd.lyx" <<'EOF'
fn main(): int64 {
  var s: int64 := 0;
  if (fToInt(fFloor(1.7)) == 1) { s := s + 1; }
  if (fToInt(fCeil(1.2)) == 2)  { s := s + 2; }
  if (fToInt(fRound(2.5)) == 2) { s := s + 4; }
  if (fToInt(fRound(3.5)) == 4) { s := s + 8; }
  PrintInt(s); PrintStr("\n");
  return 0;
}
EOF
if timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/rd.lyx" -o "$TMP/rd.out" >"$TMP/l" 2>&1; then
  got="$("$TMP/rd.out" 2>&1 | tr -d '\r\n')"
  if [ "$got" = "15" ]; then ok "Rundung stimmt (floor/ceil/round, auch 3.5 -> 4)"
  else bad "Rundung" "Summe $got statt 15"; fi
else
  bad "Rundung" "uebersetzt nicht: $(grep -i error "$TMP/l" | head -1)"
fi

# --- 3: die Rechnung stimmt ---------------------------------------------------
# Bewusst ueber die AUSGABE, nicht ueber den Exit-Code: der ist 8 Bit breit,
# 2047 kaeme dort als 255 an.
cat > "$TMP/r.lyx" <<'EOF'
fn main(): int64 {
  var s: int64 := 0;
  if (fToInt(fAdd(1.5, 2.5)) == 4)  { s := s + 1; }
  if (fToInt(fSub(3.0, 1.0)) == 2)  { s := s + 2; }
  if (fToInt(fMul(2.0, 4.0)) == 8)  { s := s + 4; }
  if (fToInt(fDiv(9.0, 3.0)) == 3)  { s := s + 8; }
  if (fToInt(fNeg(5.0)) == 0 - 5)   { s := s + 16; }
  if (fToInt(fAbs(0.0 - 7.0)) == 7) { s := s + 32; }
  if (fLt(1.0, 2.0) == 1)           { s := s + 64; }
  if (fGt(1.0, 2.0) == 0)           { s := s + 128; }
  if (fGe(2.0, 2.0) == 1)           { s := s + 256; }
  if (fLe(2.0, 2.0) == 1)           { s := s + 512; }
  if (fEq(2.0, 2.0) == 1)           { s := s + 1024; }
  PrintInt(s); PrintStr("\n");
  return 0;
}
EOF
if timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/r.lyx" -o "$TMP/r.out" >"$TMP/l" 2>&1; then
  got="$("$TMP/r.out" 2>&1 | tr -d '\r\n')"
  if [ "$got" = "2047" ]; then ok "alle elf rechnen richtig (2047)"
  else bad "Rechnung" "Summe $got statt 2047 — ein Fall liefert das Falsche"; fi
else
  bad "Rechnung" "uebersetzt nicht: $(grep -i error "$TMP/l" | head -1)"
fi

echo "Ergebnis: $P PASS, $F FAIL"
[ "$F" -eq 0 ] || exit 1
