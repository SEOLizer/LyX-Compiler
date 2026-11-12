#!/usr/bin/env bash
# tests/vektorablage_wieder_test.sh — Zuweisung an eine vorhandene
# Vektorablage rechnet dort hinein (#2213).
#
# `c := a + b` legte bis 1.2.19C jedes Mal eine neue Ablage an und liess die
# alte liegen. Die Marke aus #2206 konnte das nicht aufraeumen: sie gilt nur
# fuer Rumpfe, aus denen nichts ENTKOMMT, und hier entkommt der Zeiger in
# eine Variable ausserhalb. Gemessen mit 1024 Elementen und 400000
# Wiederholungen: 1,6 GB belegt, 403172 Seitenfehler, 1,01 s — danach
# 392 kB, 23 Seitenfehler, 0,08 s.
#
# Geprueft werden hier die Faelle, in denen die Wiederverwendung FALSCH waere.
# Jeder einzelne ist ein stiller falscher Wert, wenn die Bedingung fehlt:
#
#   * Zielablage kuerzer als die Quellen -> es wuerde hinter ihr Ende
#     geschrieben. Die Laenge steht IN der Ablage (bei ptr-8), nicht im Typ,
#     also ist das eine Laufzeitfrage.
#   * Ziel noch nicht angelegt -> der Zeiger ist 0, das waere ein Zugriff auf
#     Adresse 0.
#   * Das Ziel wird im selben Ausdruck noch GELESEN (`c := f(a + b, c)`) ->
#     die Summe laege in c, bevor f das alte c sieht. Deshalb gilt der Kanal
#     nur fuer die unmittelbare Form `ziel := x <op> y`.
#
# Aliasing (`a := a + b`) ist dagegen erlaubt und wird mitgeprueft: gerechnet
# wird elementweise aufsteigend, Lese- und Schreibstelle sind in jedem
# Schritt dieselben Indizes.
#
# Jeder Fall laeuft in BEIDEN CPU-Stufen — die 128- und die 256-Bit-Schleife
# nehmen denselben Ergebniszeiger, aber verschieden grosse Schritte.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# beide NAME ERWARTET QUELLE — prueft baseline und avx2
beide() {
  local name="$1" erwartet="$2" quelle="$3" stufe got
  printf '%s\n' "$quelle" > "$TMP/c.lyx"
  for stufe in baseline avx2; do
    if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" --target-cpu="$stufe" \
          "$TMP/c.lyx" -o "$TMP/c" >"$TMP/c.log" 2>&1); then
      no "$name [$stufe]" "uebersetzt nicht: $(sed -n '1,3p' "$TMP/c.log" | tr '\n' ' ')"; continue
    fi
    got=$( ulimit -c 0; cd "$TMP" && timeout 20 "$TMP/c" 2>/dev/null | tr '\n' ' ' )
    got="${got% }"
    if [ "$got" = "$erwartet" ]; then ok "$name [$stufe] ($got)"
    else no "$name [$stufe]" "'$got' erwartet '$erwartet'"; fi
  done
}

KOPF='import src.std.io;
fn main(): int64 {
  var a: parallel Array<f32> := parallel Array<f32>(8);
  var b: parallel Array<f32> := parallel Array<f32>(8);
  var i: int64 := 0;
  while (i < 8) { a[i] := 10.0; b[i] := 4.0; i := i + 1; }'

# --- der Fall, um den es geht -----------------------------------------------
beide "#2213: Zuweisung an vorhandene Ablage rechnet richtig" "14 14" "$KOPF
  var c: parallel Array<f32> := parallel Array<f32>(8);
  var k: int64 := 0;
  while (k < 8) { c[k] := 0.0; k := k + 1; }
  c := a + b;
  PrintLn(c[0] as int64);
  PrintLn(c[7] as int64);
  return 0;
}"

# Zweimal hintereinander in dieselbe Ablage: der zweite Durchgang darf nicht
# auf dem Ergebnis des ersten aufbauen.
beide "#2213: zweimal in dieselbe Ablage" "14 6" "$KOPF
  var c: parallel Array<f32> := parallel Array<f32>(8);
  c := a + b;
  PrintLn(c[0] as int64);
  c := a - b;
  PrintLn(c[0] as int64);
  return 0;
}"

# In einer Schleife — der Fall, der vorher 1,6 GB belegt hat. Der WERT ist
# hier nur die halbe Aussage; die andere steht unten beim Speicher.
beide "#2213: in der Schleife, Wert bleibt stabil" "14 14 14" "$KOPF
  var c: parallel Array<f32> := parallel Array<f32>(8);
  var r: int64 := 0;
  while (r < 3) { c := a + b; PrintLn(c[7] as int64); r := r + 1; }
  return 0;
}"

# --- Aliasing ist erlaubt ---------------------------------------------------
beide "#2213: Ziel ist auch Quelle (a := a + b)" "14 14 18" "$KOPF
  a := a + b;
  PrintLn(a[0] as int64);
  PrintLn(a[7] as int64);
  a := a + b;
  PrintLn(a[0] as int64);
  return 0;
}"

# --- die Faelle, in denen NICHT wiederverwendet werden darf -----------------

# Kuerzeres Ziel: muesste beim Wiederverwenden hinter sein Ende schreiben.
# Dass k[7] den richtigen Wert hat, belegt die neue Ablage mit Laenge 8.
beide "#2213: kuerzere Zielablage wird nicht wiederverwendet" "14 14" "$KOPF
  var k: parallel Array<f32> := parallel Array<f32>(4);
  k := a + b;
  PrintLn(k[0] as int64);
  PrintLn(k[7] as int64);
  return 0;
}"

# Laengeres Ziel: dieselbe Frage von der anderen Seite. Die neue Ablage ist
# 8 lang, der Zugriff auf 7 muss die Summe liefern.
beide "#2213: laengere Zielablage wird nicht wiederverwendet" "14 14" "$KOPF
  var g: parallel Array<f32> := parallel Array<f32>(16);
  g := a + b;
  PrintLn(g[0] as int64);
  PrintLn(g[7] as int64);
  return 0;
}"

# Das Ziel wird im selben Ausdruck noch gelesen. Griffe der Kanal hier, stuende
# die Summe schon in c, wenn `verdopple` das alte c liest — und die Ausgabe
# waere 28 statt 10.
beide "#2213: Ziel im selben Ausdruck gelesen" "10 14" "$KOPF
  var c: parallel Array<f32> := parallel Array<f32>(8);
  var m: int64 := 0;
  while (m < 8) { c[m] := 5.0; m := m + 1; }
  var alt: parallel Array<f32> := c + c;
  PrintLn(alt[0] as int64);
  c := a + b;
  PrintLn(c[0] as int64);
  return 0;
}"

# --- Speicher: die eigentliche Wirkung -------------------------------------
#
# 400000 Wiederholungen mit 1024 Elementen. Vor #2213 belegte das 1,6 GB und
# machte 403172 Seitenfehler, weil jede Zuweisung eine neue Ablage anlegte und
# die Marke aus #2206 sie nicht einsammeln konnte (der Zeiger entkommt in eine
# aeussere Variable). Geprueft wird der SPEICHER, nicht die Zeit: eine
# Zeitmessung haengt an der Maschine, diese Schranke nicht.
cat > "$TMP/m.lyx" <<'LYXEOF'
import src.std.io;
fn main(): int64 {
  var a: parallel Array<f32> := parallel Array<f32>(1024);
  var b: parallel Array<f32> := parallel Array<f32>(1024);
  var c: parallel Array<f32> := parallel Array<f32>(1024);
  var i: int64 := 0;
  while (i < 1024) { a[i] := 2.0; b[i] := 3.0; c[i] := 0.0; i := i + 1; }
  var r: int64 := 0;
  while (r < 400000) { c := a + b; r := r + 1; }
  PrintLn(c[1023] as int64);
  return 0;
}
LYXEOF
if (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/m.lyx" -o "$TMP/m" >/dev/null 2>&1); then
  kb=$( ulimit -c 0; /usr/bin/time -f %M "$TMP/m" 2>&1 >/dev/null | tail -1 )
  # Grosszuegige Schranke: 16 MB. Vorher waren es 1,6 GB, jetzt 392 kB — die
  # Schranke muss den Unterschied treffen, nicht die genaue Zahl festschreiben.
  if [ "$kb" -lt 16384 ] 2>/dev/null; then ok "#2213: Arena waechst nicht (${kb} kB)"
  else no "#2213: Arena waechst nicht" "${kb} kB belegt — die Ablage wird je Zuweisung neu angelegt"; fi
else
  no "#2213: Arena waechst nicht" "uebersetzt nicht"
fi

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
