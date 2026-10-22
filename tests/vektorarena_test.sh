#!/usr/bin/env bash
# tests/vektorarena_test.sh — #2206: Vektorablagen wachsen nicht mehr unbegrenzt.
#
# `a + b` auf `parallel Array<f32>` legt das Ergebnis in einer frischen Ablage
# an. Bis 1.2.18G kam die aus einem eigenen mmap und wurde NIE zurueckgegeben:
# 502 Anforderungen fuer 500 Wiederholungen, 253 MiB belegt fuer eine
# Rechnung, die 1,5 MiB Daten braucht. In einer Schleife — also dem Normalfall
# fuer Vektorcode — lief jedes Programm dem Speicher weg.
#
# Die Kosten lagen dabei NICHT im Syscall, sondern in den Seitenfehlern auf
# immer frischem Speicher: 86696 gegen 94 bei der gleichwertigen C-Fassung,
# zusammen rund 90 % der Laufzeit. Nach dem Fix sind es 46 Seitenfehler, ein
# einziges mmap und 392 KiB — und der L1-Kern aus bench/ liegt statt 12,8x nur
# noch 1,3x hinter `gcc -O3 -march=native`.
#
# Geprueft wird die WIRKUNG, in BEIDEN Richtungen:
#
#   1. Der Speicher darf mit der Zahl der Durchlaeufe NICHT mehr wachsen —
#      und zwar in JEDER Schleifenform. Die Marke haengt an fuenf Stellen
#      (while, for-C-Form, for..to, for..in, repeat..until); fehlt sie an
#      einer, waechst nur diese eine, und das faellt sonst niemandem auf.
#
#   2. Ein Vektor, der dem Rumpf ENTKOMMT, muss korrekt bleiben. Ohne diese
#      Haelfte waere der Test auch von einer Fassung erfuellt, die immer
#      zuruecksetzt — und die taeuschte ein Leck gegen eine
#      Speicherkorruption ein, was deutlich schlimmer waere.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

# rss PROGRAMM  → belegter Speicher in KiB
rss() {
  ( ulimit -c 0; /usr/bin/time -v "$1" 2>&1 >/dev/null ) \
    | sed -n 's/.*Maximum resident set size (kbytes): *//p'
}

# waechst NAME SCHLEIFENKOPF SCHLEIFENENDE
# Uebersetzt dieselbe Schleife mit 200 und mit 20000 Durchlaeufen und
# vergleicht den Speicher. Ohne Marke sind das 3 MiB gegen 320 MiB.
waechst() {
  local name="$1" kopf="$2" fuss="$3"
  local rss_klein rss_gross
  local n
  for n in 200 20000; do
    cat > "$TMP/w.lyx" <<EOF
import std.io;
fn main(): int64 {
  var a: parallel Array<f32> := parallel Array<f32>(4096);
  var b: parallel Array<f32> := parallel Array<f32>(4096);
  var zaehler: int64 := 0;
  ${kopf//@N/$n}
    var c: parallel Array<f32> := a + b;
    zaehler += 1;
  ${fuss//@N/$n}
  PrintLn(zaehler);
  return 0;
}
EOF
    if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/w.lyx" -o "$TMP/w.$n" >"$TMP/w.log" 2>&1); then
      echo "FAIL $name: uebersetzt nicht"; sed -n '1,4p' "$TMP/w.log"; FAIL=$((FAIL+1)); return
    fi
    if [ "$n" = "200" ]; then rss_klein=$(rss "$TMP/w.$n"); else rss_gross=$(rss "$TMP/w.$n"); fi
  done

  # Hundertfache Durchlaufzahl darf den Speicher nicht vervielfachen. Die
  # Schranke ist bewusst grosszuegig (Faktor 4): gemessen wird 392 gegen 392,
  # ohne Marke waeren es 3200 gegen 321152.
  local schranke=$(( rss_klein * 4 ))
  if [ "$rss_gross" -le "$schranke" ]; then
    echo "PASS $name waechst nicht ($rss_klein KiB bei 200, $rss_gross KiB bei 20000)"
    PASS=$((PASS+1))
  else
    echo "FAIL $name waechst: $rss_klein KiB bei 200, $rss_gross KiB bei 20000 Durchlaeufen"
    FAIL=$((FAIL+1))
  fi
}

waechst "while"         'while (zaehler < @N) {'                  '}'
waechst "for-C-Form"    'for i := 0; i < @N; i := i + 1 {'        '}'
waechst "for..to"       'for i := 1 to @N {'                      '}'
waechst "for..in"       'for i in 1..@N {'                        '}'
waechst "repeat..until" 'repeat {'                                '} until (zaehler >= @N);'

# --- Die Gegenrichtung: ein entkommender Vektor bleibt gueltig -------------
# Zugewiesen wird an ein `halt`, das VOR der Schleife steht — der Wert muss
# sie ueberleben. Setzte die Marke hier zurueck, wuerde die Ablage im
# naechsten Durchlauf ueberschrieben und `halt` zeigte auf fremde Daten.
cat > "$TMP/e.lyx" <<'EOF'
import std.io;
fn main(): int64 {
  var a: parallel Array<f32> := parallel Array<f32>(8);
  var b: parallel Array<f32> := parallel Array<f32>(8);
  a[0] := 3.0; b[0] := 4.0;
  var h1: parallel Array<f32> := parallel Array<f32>(8);
  var h2: parallel Array<f32> := parallel Array<f32>(8);
  var h3: parallel Array<f32> := parallel Array<f32>(8);
  var h4: parallel Array<f32> := parallel Array<f32>(8);
  var h5: parallel Array<f32> := parallel Array<f32>(8);
  var w: int64 := 0;
  while (w < 20) { h1 := a + b; w += 1; }
  for i := 0; i < 20; i := i + 1 { h2 := a + b; }
  for j := 1 to 20 { h3 := a + b; }
  for k in 1..20 { h4 := a + b; }
  var m: int64 := 0;
  repeat { h5 := a + b; m += 1; } until (m >= 20);
  PrintLn((h1[0] as int64) + (h2[0] as int64) + (h3[0] as int64)
        + (h4[0] as int64) + (h5[0] as int64));
  return 0;
}
EOF
if (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/e.lyx" -o "$TMP/e" >"$TMP/e.log" 2>&1); then
  got=$( ulimit -c 0; "$TMP/e" 2>/dev/null )
  if [ "$got" = "35" ]; then
    echo "PASS entkommende Vektoren bleiben gueltig (5 x 7 = $got)"; PASS=$((PASS+1))
  else
    echo "FAIL entkommende Vektoren: '$got' erwartet '35'"; FAIL=$((FAIL+1))
  fi
else
  echo "FAIL entkommende Vektoren: uebersetzt nicht"; sed -n '1,4p' "$TMP/e.log"; FAIL=$((FAIL+1))
fi

# --- Und das Verhalten am Syscall -----------------------------------------
# Ein einziger Block statt einer Anforderung je Operation. Gezaehlt wird mit
# strace, weil die Zahl der mmap-Aufrufe die Aussage ist, nicht die Zeit.
if command -v strace >/dev/null 2>&1; then
  cat > "$TMP/s.lyx" <<'EOF'
import std.io;
fn main(): int64 {
  var a: parallel Array<f32> := parallel Array<f32>(4096);
  var b: parallel Array<f32> := parallel Array<f32>(4096);
  var r: int64 := 0;
  while (r < 5000) { var c: parallel Array<f32> := a + b; r += 1; }
  PrintLn(r);
  return 0;
}
EOF
  if (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/s.lyx" -o "$TMP/s" >/dev/null 2>&1); then
    n=$( ulimit -c 0; strace -c -e trace=mmap "$TMP/s" 2>&1 >/dev/null | awk '/mmap/{print $4}' )
    [ -z "$n" ] && n=0
    if [ "$n" -lt 50 ]; then
      echo "PASS 5000 Vektoroperationen brauchen $n mmap-Aufrufe (vorher: einen je Operation)"
      PASS=$((PASS+1))
    else
      echo "FAIL 5000 Vektoroperationen brauchen $n mmap-Aufrufe"; FAIL=$((FAIL+1))
    fi
  else
    echo "FAIL Syscall-Fall uebersetzt nicht"; FAIL=$((FAIL+1))
  fi
else
  echo "HINWEIS: strace fehlt — die Zahl der mmap-Aufrufe wird nicht geprueft."
fi

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
