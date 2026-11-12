#!/usr/bin/env bash
# tests/vektor_ausrichtung_2215_test.sh — Vektordaten auf einer Cache-Line,
# Vektorschleifen unten geprueft (#2215).
#
# #2215 suchte den Abstand von 1,24x (gemessen 1,17x) zwischen dem f32-Kern
# (bench/arr_add_f32, 16384 Elemente, avx2) und gcc -mavx2. Mit den Zaehlern
# aus #2195 war er eindeutig: die Ablage richtete die Daten nur auf 16 Byte
# aus, jeder zweite 32-Byte-Zugriff lag ueber zwei Cache-Lines
# (mem_inst_retired.split_loads = 51 Mio., die Haelfte aller Ladebefehle).
# Jetzt beginnen die Daten auf 64 Byte: 241 geteilte Zugriffe, 558 -> 488 Mio.
# Takte, gleichauf bzw. vor gcc. Dazu laufen die Vektorschleifen (AVX2 und
# SSE2, Binop und Negation) unten geprueft — ein Sprung je Durchlauf, als
# Paar ausgerichtet; der alte Ruecksprung endete in allen vier abgerollten
# Kopien des Benchmarks genau auf einer 32-Byte-Grenze.
#
# Geprueft wird die WIRKUNG:
#   1. jede Anlage — parallel Array<T>(n), a + b, -a; f32 und f64; n = 1..40 —
#      liefert eine Adresse, die durch 64 teilbar ist (vorher 16/32/48);
#   2. die Werte fuer jede Laenge 1..40 auf dem SSE- und dem AVX2-Weg: der
#      Rest hinter dem letzten vollen Block haengt an der neuen Schleifenform;
#   3. falls perf zaehlen darf: der f32-Kern hat praktisch keine geteilten
#      Ladezugriffe mehr (Zaehler, nicht Zeit — die Zeit schwankt).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ulimit -c 0
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# Ein Programm je Elementart: fuer n = 1..40 drei Anlagen, ihre Adressen mod 64
# aufsummiert (muss 0 sein), und die Summe aller Elemente von a + b und -a.
# Belegung ganzzahlig, damit die Summe in f32 exakt bleibt.
for typ in f32 f64; do
  cat > "$TMP/v_$typ.lyx" <<LYX
import std.io;
fn main(): int64 {
  var rest: int64 := 0;
  var summe: int64 := 0;
  var n: int64 := 1;
  while (n <= 40) {
    var a: parallel Array<$typ> := parallel Array<$typ>(n);
    var b: parallel Array<$typ> := parallel Array<$typ>(n);
    var i: int64 := 0;
    while (i < n) { a[i] := (i + 1) as f64; b[i] := (i * 3 + 2) as f64; i += 1; }
    var c: parallel Array<$typ> := a + b;
    var d: parallel Array<$typ> := -a;
    rest := rest + ((a as int64) & 63) + ((b as int64) & 63) + ((c as int64) & 63) + ((d as int64) & 63);
    i := 0;
    while (i < n) { summe := summe + (c[i] as int64) * 1000 + (d[i] as int64); i += 1; }
    n += 1;
  }
  PrintLn(rest);
  PrintLn(summe);
  return 0;
}
LYX
done
# c[i] = (i+1) + (3i+2) = 4i+3; d[i] = -(i+1)
ERW_SUMME=$(python3 -c "print(sum(sum((4*i+3)*1000-(i+1) for i in range(n)) for n in range(1,41)))")

for typ in f32 f64; do
  for cpu in baseline avx2; do
    opt=""; [ "$cpu" = avx2 ] && opt="--target-cpu=avx2"
    if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" $opt "$TMP/v_$typ.lyx" -o "$TMP/v_${typ}_$cpu" >"$TMP/b.log" 2>&1); then
      no "$typ $cpu" "uebersetzt nicht: $(grep -m1 -i error "$TMP/b.log")"; continue; fi
    if [ "$cpu" = avx2 ] && ! grep -q avx2 /proc/cpuinfo; then echo "HINWEIS: Rechner ohne AVX2 — $typ avx2 nur uebersetzt"; continue; fi
    out=$(cd "$TMP" && timeout 60 "$TMP/v_${typ}_$cpu" | tr '\n' ' '); rest=${out%% *}; summe=$(echo "$out" | awk '{print $2}')
    if [ "$rest" = "0" ]; then ok "$typ $cpu: alle 160 Anlagen auf 64 Byte"
    else no "$typ $cpu Ausrichtung" "Summe der Reste mod 64 = $rest (erwartet 0)"; fi
    if [ "$summe" = "$ERW_SUMME" ]; then ok "$typ $cpu: a+b und -a fuer n = 1..40 richtig"
    else no "$typ $cpu Werte" "'$summe' erwartet '$ERW_SUMME'"; fi
  done
done

# 3. Zaehler, wenn erlaubt
if command -v perf >/dev/null 2>&1 && perf stat -x, -e mem_inst_retired.split_loads /bin/true >/dev/null 2>&1 && grep -q avx2 /proc/cpuinfo; then
  if (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" --target-cpu=avx2 bench/arr_add_f32.lyx -o "$TMP/k" >/dev/null 2>&1); then
    sp=$(perf stat -x, -e mem_inst_retired.split_loads,mem_inst_retired.all_loads "$TMP/k" 4096 2000 2>&1 >/dev/null \
         | awk -F, '$3=="mem_inst_retired.split_loads"{s=$1} $3=="mem_inst_retired.all_loads"{a=$1} END{print s+0, a+0}')
    s=${sp% *}; a=${sp#* }
    if [ "$a" -gt 0 ] && [ $((s * 1000)) -lt "$a" ]; then ok "f32-Kern: $s geteilte von $a Ladezugriffen (< 0,1 %)"
    else no "geteilte Ladezugriffe" "$s von $a"; fi
  else no "Kern" "bench/arr_add_f32.lyx uebersetzt nicht"; fi
else
  echo "HINWEIS: perf darf nicht zaehlen (oder kein AVX2) — Zaehlerpruefung uebersprungen."
fi

echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
