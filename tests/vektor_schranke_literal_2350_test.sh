#!/usr/bin/env bash
# tests/vektor_schranke_literal_2350_test.sh — #2350: eine LITERALE Schranke
# in der Schleifenbedingung (`while (i < 1000)`) darf vektorisiert werden.
#
# Vorher verlangte `cg_vmErkennen` Zaehler UND Schranke als Local. Im
# Selbstbau waren das 329 Ablehnungen mit dem Grund CONDITION_BOUND_LITERAL
# (`while bit < 8`, `while (r < 7)`), obwohl eine Konstante VOR der Schleife
# bekannt ist — also besser bekannt als ein Local, das der Rumpf theoretisch
# noch anfassen koennte.
#
# Geprueft wird dreifach, weil keine der drei Fragen die anderen beantwortet:
#
#   1. der WERT: dieselbe Rechnung muss dasselbe Ergebnis liefern wie die
#      Fassung mit Local-Schranke. Ein Vektorweg, der falsch rechnet, faellt
#      sonst nicht auf — und genau das ist bei einer Ablage die teure Variante
#      (#2199: zu breite Ablage traf die Nachbarelemente).
#   2. das ERZEUGNIS: es muss wirklich vektorisiert worden sein. Ein Test, der
#      nur den Wert prueft, waere auch von der skalaren Fassung erfuellt — die
#      Aenderung waere wirkungslos und der Test gruen.
#   3. die GEGENPROBE: ein Fall, der NICHT vektorisiert werden darf, darf es
#      auch nicht. Hier die Schranke 0 (Schleife laeuft nie); ohne diese Seite
#      waere auch eine viel zu weite Freigabe erfuellt (#1823).
#
# Der Nachweis fuer 2. und 3. laeuft ueber das Compilatprofil (#2343), nicht
# ueber einen Bytescan: der Reason-Code benennt die Entscheidung, und genau
# diese Codes sind laut #2350 die Messgroesse des Fortschritts.
#
# n ist KEIN Vielfaches der Vektorbreite (1000 Byte bei Breite 1, 16 je Block
# -> 62 Bloecke und 8 Rest), damit der Rest-Durchgang mitgeprueft wird.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
export LYXC
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# ---------------------------------------------------------------- 1. Wert
cat > "$TMP/lit.lyx" <<'EOF'
import std.io;

fn main(): int64 {
  var a: int64 := alloc(1000);
  var b: int64 := alloc(1000);
  var c: int64 := alloc(1000);
  var i: int64 := 0;
  while (i < 1000) { poke8(a + i, (i & 127)); i := i + 1; }
  i := 0;
  while (i < 1000) { poke8(b + i, ((i * 3) & 127)); i := i + 1; }

  // Die Schleife, um die es geht: Schranke als LITERAL.
  i := 0;
  while (i < 1000) { poke8(c + i, peek8(a + i) + peek8(b + i)); i := i + 1; }

  // Summe und die Raender einzeln: eine um einen Block verschobene Ablage
  // faellt in der Summe auf, eine um ein Element verschobene am Rand.
  var s: int64 := 0;
  i := 0;
  while (i < 1000) { s := s + peek8(c + i); i := i + 1; }
  PrintStr("summe="c);  PrintLn(s);
  PrintStr("erste="c);  PrintLn(peek8(c));
  PrintStr("letzte="c); PrintLn(peek8(c + 999));
  // Hinter der Schleife muss i die Schranke tragen, nicht den Vektorstand.
  PrintStr("i_danach="c); PrintLn(i);
  return 0;
}
EOF

if ! ( cd "$TMP" && "$LYXC" --std-path="$ROOT" lit.lyx -o lit ) >"$TMP/b.log" 2>&1; then
  no "uebersetzt" "$(grep -v Copyright "$TMP/b.log" | grep -m1 -iE 'error|lyxc:')"
  echo "=== PASS=$PASS FAIL=$FAIL"; exit 1
fi
AUS="$( cd "$TMP" && timeout 60 ./lit 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ]; then
  no "laeuft" "rc=$rc, Ausgabe: $(echo "$AUS" | tr '\n' ' ' | cut -c1-200)"
  echo "=== PASS=$PASS FAIL=$FAIL"; exit 1
fi
ok "uebersetzt und laeuft"

hol() { echo "$AUS" | sed -n "s/^$1=//p"; }
# Gegengerechnet, nicht aus einem Lauf uebernommen:
#   c[i] = (i & 127) + ((i*3) & 127), beide Summanden < 128, Summe < 256,
#   also keine Verschmaelerung. Summe ueber i = 0..999 mit awk nachgerechnet.
ERW="$(awk 'BEGIN{s=0; for(i=0;i<1000;i++){s += (i%128) + ((i*3)%128)} print s}')"
ERW_ERSTE=0
ERW_LETZTE="$(awk 'BEGIN{print (999%128) + ((999*3)%128)}')"
for paar in "summe:$ERW" "erste:$ERW_ERSTE" "letzte:$ERW_LETZTE" "i_danach:1000"; do
  k="${paar%%:*}"; e="${paar##*:}"; v="$(hol "$k")"
  if [ "$v" = "$e" ]; then ok "$k = $e"; else no "$k" "'$v' statt $e"; fi
done

# ------------------------------------------------- 2. Erzeugnis: vektorisiert
PROF="$TMP/prof.json"
( cd "$TMP" && "$LYXC" --std-path="$ROOT" --compile-profile="$PROF" \
    --compile-profile-level=detailed lit.lyx -o lit_p ) >/dev/null 2>&1
if [ ! -s "$PROF" ]; then
  no "Profil" "kein Compilatprofil erzeugt"
else
  ANG="$(grep -o '"outcome": *"applied"' "$PROF" | wc -l)"
  if [ "$ANG" -ge 1 ]; then
    ok "mindestens eine Schleife vektorisiert (applied = $ANG)"
  else
    no "vektorisiert" "keine Entscheidung mit outcome=applied — die literale Schranke wurde nicht angenommen"
  fi
  if grep -q 'CONDITION_BOUND_LITERAL"' "$PROF"; then
    no "Grund verschwunden" "CONDITION_BOUND_LITERAL steht noch im Bericht, die Schranke wurde also weiter abgelehnt"
  else
    ok "kein CONDITION_BOUND_LITERAL mehr in diesem Programm"
  fi
fi

# --------------------------------------------- 3. Gegenprobe: leere Schranke
cat > "$TMP/leer.lyx" <<'EOF'
import std.io;

fn main(): int64 {
  var a: int64 := alloc(64);
  var b: int64 := alloc(64);
  var c: int64 := alloc(64);
  var i: int64 := 0;
  // Schranke 0: die Schleife laeuft nie. Der Vektorweg hat hier nichts zu
  // suchen; der skalare tut ohne Sonderfall das Richtige.
  while (i < 0) { poke8(c + i, peek8(a + i) + peek8(b + i)); i := i + 1; }
  PrintStr("i="c); PrintLn(i);
  return 0;
}
EOF
PROF2="$TMP/prof2.json"
( cd "$TMP" && "$LYXC" --std-path="$ROOT" --compile-profile="$PROF2" \
    --compile-profile-level=detailed leer.lyx -o leer ) >/dev/null 2>&1
AUS2="$( cd "$TMP" && timeout 60 ./leer 2>&1 )"
if [ "$(echo "$AUS2" | sed -n 's/^i=//p')" = "0" ]; then
  ok "leere Schranke: i bleibt 0"
else
  no "leere Schranke" "i = '$(echo "$AUS2" | sed -n 's/^i=//p')' statt 0"
fi
if grep -q 'CONDITION_BOUND_LITERAL_EMPTY' "$PROF2"; then
  ok "leere Schranke wird mit eigenem Grund abgelehnt (CONDITION_BOUND_LITERAL_EMPTY)"
else
  no "Gegenprobe" "die Schranke 0 wurde nicht als CONDITION_BOUND_LITERAL_EMPTY abgelehnt — die Freigabe ist zu weit"
fi

echo "=== PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
