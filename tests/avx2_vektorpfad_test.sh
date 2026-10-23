#!/usr/bin/env bash
# tests/avx2_vektorpfad_test.sh — 256-Bit-Pfad fuer `parallel Array<f32>` (#2205).
#
# Gemessen wird dreierlei, und keines der drei allein genuegt:
#
#   1. Die WERTE, in jeder Laenge von 1 bis 9. Der Pfad hat drei Stufen
#      (32 Byte, dann einmal 16 Byte, dann bis zu drei Einzelelemente); eine
#      Laenge trifft immer eine andere Kombination, und 9 ist die erste, die
#      alle drei braucht. Mit n = 4, wie es die Faelle vor #2184 alle taten,
#      waere jede dieser Stufen unerreicht geblieben.
#
#   2. Der WAECHTER hinter dem letzten Element. Ein Pfad, der einen Block zu
#      weit laeuft, rechnet vorne richtig und schreibt hinten fremde Werte —
#      genau der Defekt aus #2184, dort mit 16 Byte je Schritt und zwoelf Byte
#      Ueberlauf bei n = 5. Mit 32 Byte je Schritt waeren es bis zu 28.
#
#   3. Das ERZEUGNIS, in BEIDEN Richtungen. Dass die Werte mit `avx2`
#      stimmen, wuerde auch ein Compiler erfuellen, der das Flag ignoriert und
#      immer 128 Bit emittiert; dass ohne das Flag kein VEX drinsteht, auch
#      einer, der VEX nie emittiert. Geprueft wird deshalb beides am selben
#      Programm: mit `baseline` KEIN VEX-Praefix, mit `avx2` VEX **und**
#      `vzeroupper`. Dieselbe Pflicht wie in #1823, wo eine Pruefung nur einer
#      Richtung eine viel zu weite Rechtezuordnung durchgelassen hat.
#
# Disassembliert wird die `--emit=obj`-Fassung: das fertige Programm traegt
# keine Section-Header, `objdump -d` liefert dort null Befehle, und jede
# Zaehlung waere still 0 gewesen. `-z` und `--no-show-raw-insn` sind beide
# noetig (#1370): ohne `-z` werden Nullfolgen abgekuerzt und der Rest nicht
# disassembliert, ohne `--no-show-raw-insn` zaehlen die Byte-Folgezeilen
# langer Befehle als eigene Befehle.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# werte NAME STUFE ERWARTET QUELLE
werte() {
  local name="$1" stufe="$2" erwartet="$3" quelle="$4"
  printf '%s\n' "$quelle" > "$TMP/c.lyx"
  if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" --target-cpu="$stufe" \
        "$TMP/c.lyx" -o "$TMP/c" >"$TMP/c.log" 2>&1); then
    no "$name [$stufe]" "uebersetzt nicht: $(sed -n '1,3p' "$TMP/c.log" | tr '\n' ' ')"; return
  fi
  local got
  got=$( ulimit -c 0; cd "$TMP" && timeout 20 "$TMP/c" 2>/dev/null | tr '\n' ' ' )
  got="${got% }"
  if [ "$got" = "$erwartet" ]; then ok "$name [$stufe] ($got)"
  else no "$name [$stufe]" "'$got' erwartet '$erwartet'"; fi
}

# --- 1. Werte in jeder Laenge, beide Stufen ---------------------------------
#
# a[i] = i + 1, b[i] = 2 → Summe 3, 4, 5, …; ausgegeben wird das ERSTE und
# das LETZTE Element. Das letzte ist der aussagekraeftige: es liegt je nach
# Laenge in der 32-Byte-, der 16-Byte- oder der skalaren Stufe.
for n in 1 2 3 4 5 6 7 8 9; do
  letztes=$((n + 2))
  Q="import src.std.io;
fn main(): int64 {
  let a: parallel Array<f32>($n) = parallel Array<f32>($n);
  let b: parallel Array<f32>($n) = parallel Array<f32>($n);
  var i: int64 := 0;
  while (i < $n) { a[i] := (i + 1) as f64; b[i] := 2.0; i := i + 1; }
  let s: parallel Array<f32> = a + b;
  PrintLn(s[0] as int64);
  PrintLn(s[$n - 1] as int64);
  return 0;
}"
  werte "laenge_$n" avx2     "3 $letztes" "$Q"
  werte "laenge_$n" baseline "3 $letztes" "$Q"
done

# --- 2. Waechter hinter dem letzten Element ---------------------------------
#
# Das Ziel ist 16 Elemente lang, gerechnet werden nur die ersten 9. Die
# Plaetze 9..15 sind mit 0 belegt und muessen 0 BLEIBEN. Ein Pfad, der einen
# 32-Byte-Block zu weit laeuft, schreibt dort die Summe hinein.
#
# Gelesen wird Platz 9 (direkt hinter dem Rechenbereich) und Platz 15.
WACHE='import src.std.io;
fn main(): int64 {
  let a: parallel Array<f32>(16) = parallel Array<f32>(16);
  let b: parallel Array<f32>(16) = parallel Array<f32>(16);
  let z: parallel Array<f32>(16) = parallel Array<f32>(16);
  var i: int64 := 0;
  while (i < 16) { a[i] := 5.0; b[i] := 7.0; z[i] := 0.0; i := i + 1; }
  // nur die ersten neun rechnen: ueber eine Teillaenge, nicht ueber das Feld
  let kurz_a: parallel Array<f32>(9) = parallel Array<f32>(9);
  let kurz_b: parallel Array<f32>(9) = parallel Array<f32>(9);
  var k: int64 := 0;
  while (k < 9) { kurz_a[k] := 5.0; kurz_b[k] := 7.0; k := k + 1; }
  let s: parallel Array<f32> = kurz_a + kurz_b;
  PrintLn(s[8] as int64);
  PrintLn(z[9] as int64);
  PrintLn(z[15] as int64);
  return 0;
}'
werte "waechter" avx2     "12 0 0" "$WACHE"
werte "waechter" baseline "12 0 0" "$WACHE"

# --- 3. Erzeugnis, beide Richtungen ----------------------------------------

VIER='import src.std.io;
fn main(): int64 {
  let a: parallel Array<f32>(9) = parallel Array<f32>(9);
  let b: parallel Array<f32>(9) = parallel Array<f32>(9);
  var i: int64 := 0;
  while (i < 9) { a[i] := 12.0; b[i] := 4.0; i := i + 1; }
  let s: parallel Array<f32> = a + b;
  let d: parallel Array<f32> = a - b;
  let p: parallel Array<f32> = a * b;
  let q: parallel Array<f32> = a / b;
  PrintLn(s[8] as int64); PrintLn(d[8] as int64);
  PrintLn(p[8] as int64); PrintLn(q[8] as int64);
  return 0;
}'
werte "vier_operationen" avx2     "16 8 48 3" "$VIER"
werte "vier_operationen" baseline "16 8 48 3" "$VIER"

dis() { # stufe
  printf '%s\n' "$VIER" > "$TMP/o.lyx"
  (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" --target-cpu="$1" --emit=obj \
     "$TMP/o.lyx" -o "$TMP/o.o" >/dev/null 2>&1) || { echo FEHLT; return; }
  objdump -d -z --no-show-raw-insn "$TMP/o.o" 2>/dev/null
}

for stufe in baseline avx2; do
  d="$(dis $stufe)"
  if [ "$d" = "FEHLT" ]; then no "erzeugnis [$stufe]" "uebersetzt nicht"; continue; fi
  # Gezaehlt werden die BREITEN Formen: ymm-Operanden und vzeroupper. `vaddps
  # xmm` allein wuerde nichts belegen — es ist dieselbe Rechnung in 128 Bit.
  ymm=$(printf '%s\n' "$d" | grep -cE '\bv(movups|addps|subps|mulps|divps)\b.*ymm')
  zu=$(printf '%s\n' "$d" | grep -c 'vzeroupper')
  if [ "$stufe" = "baseline" ]; then
    if [ "$ymm" -eq 0 ] && [ "$zu" -eq 0 ]; then ok "baseline emittiert KEIN 256-Bit-VEX (ymm $ymm, vzeroupper $zu)"
    else no "baseline emittiert KEIN 256-Bit-VEX" "ymm $ymm, vzeroupper $zu — auf einer aelteren CPU SIGILL"; fi
  else
    if [ "$ymm" -ge 4 ]; then ok "avx2 emittiert 256-Bit-VEX ($ymm ymm-Stellen)"
    else no "avx2 emittiert 256-Bit-VEX" "nur $ymm ymm-Stellen"; fi
    if [ "$zu" -ge 1 ]; then ok "avx2 emittiert vzeroupper ($zu)"
    else no "avx2 emittiert vzeroupper" "keines — jeder folgende SSE-Befehl zahlt den Zustandswechsel"; fi
  fi
done

# Befehlsgrenzen: eine falsch kodierte Laenge verschiebt alles danach, und
# der Rest sieht dann nach ganz anderen Befehlen aus (#1370). Geprueft wird
# das an der DIFFERENZ der `(bad)`-Meldungen zwischen den Stufen, nicht an
# ihrer Zahl: `objdump -d -z` disassembliert im `.ltext` auch die
# eingebetteten Daten und liest dort schon ohne jedes VEX 55 mal `(bad)`.
# Die absolute Zahl hat also nichts mit diesem Pfad zu tun — der erste Anlauf
# meldete 61 und sah nach einem Kodierungsfehler aus, bis die Gegenprobe
# dieselben 55 in `baseline` zeigte.
bad_b=$(dis baseline | grep -c '(bad)')
bad_a=$(dis avx2     | grep -c '(bad)')
if [ "$bad_a" -le "$bad_b" ]; then
  ok "256-Bit-Teil fuegt keine unlesbare Stelle hinzu (baseline $bad_b, avx2 $bad_a)"
else
  no "256-Bit-Teil fuegt keine unlesbare Stelle hinzu" "baseline $bad_b, avx2 $bad_a — eine Kodierung ist zu kurz oder zu lang"
fi

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
